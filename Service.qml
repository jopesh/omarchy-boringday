import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless half of the plugin: it owns every fetch, every download, the
// rotation schedule, and what is currently set. The bar widget is a view onto
// this object, so a rotation keeps running with the panel closed — and with no
// bar widget on screen at all, an `omarchy-shell boringday random` still works.
Item {
  id: root

  // Injected by the shell's service loader (see shell.qml ensureService).
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "boringday.wallpapers"
  readonly property string home: Quickshell.env("HOME")
  readonly property string cacheDir: home + "/.cache/omarchy/boringday"
  readonly property string wallpaperDir: cacheDir + "/wallpapers"
  readonly property string thumbDir: cacheDir + "/thumbs"
  readonly property string stateDir: home + "/.local/state/omarchy/boringday"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string binDir: omarchyPath ? omarchyPath + "/bin" : "/usr/share/omarchy/bin"

  // ------------------------------------------------------------- settings
  //
  // Settings live inline on this plugin's shell.json entry, the same place the
  // bar widget's own settings live — so the widget's auto-rotate toggle and a
  // hand-edited shell.json are the same switch. The service reads the config
  // itself rather than being told by the widget: a widget exists per monitor,
  // and rotation must have exactly one owner.
  readonly property var settings: entryFor(shell ? shell.shellConfig : null)

  function entryFor(config) {
    if (!config || typeof config !== "object") return ({})
    var sections = ["left", "center", "right"]
    var layout = config.bar && config.bar.layout ? config.bar.layout : null
    for (var s = 0; s < sections.length; s++) {
      var entries = layout ? layout[sections[s]] : null
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        if (entry && typeof entry === "object" && String(entry.id) === pluginId) return entry
      }
    }
    var plugins = Array.isArray(config.plugins) ? config.plugins : []
    for (var p = 0; p < plugins.length; p++) {
      var pluginEntry = plugins[p]
      if (pluginEntry && typeof pluginEntry === "object" && String(pluginEntry.id) === pluginId) return pluginEntry
    }
    return ({})
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property bool autoRotate: setting("autoRotate", false) === true
  readonly property int intervalSeconds: Model.clampInterval(setting("intervalSeconds", 3600))
  readonly property bool notifyOnSwitch: setting("notify", true) === true

  // Persist through the shell so the write lands in shell.json next to every
  // other widget setting instead of in a private file of our own.
  function writeSetting(name, value) {
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    var next = ({})
    for (var key in settings) next[key] = settings[key]
    next[name] = value
    delete next.id
    shell.updateEntryInline(pluginId, next)
    return true
  }

  function setAutoRotate(enabled) {
    writeSetting("autoRotate", enabled === true)
  }

  function toggleAutoRotate() {
    setAutoRotate(!autoRotate)
    return !autoRotate
  }

  function setIntervalSeconds(seconds) {
    writeSetting("intervalSeconds", Model.clampInterval(seconds))
  }

  function cycleInterval() {
    setIntervalSeconds(Model.nextInterval(intervalSeconds))
  }

  // ---------------------------------------------------------------- state

  property var pieces: []
  property var thumbs: ({})
  property var current: null
  property var recentIds: []
  property double lastSwitchAt: 0

  property bool stateLoaded: false
  property bool loading: false
  property bool applying: false
  property string lastError: ""
  property string status: ""

  readonly property var today: pieces.length > 0 ? pieces[0] : null
  readonly property int pieceLimit: 3
  // Phrased for the panel's "every ..." caption and the IPC replies, both of
  // which read it straight after the word "every".
  readonly property string intervalLabel: Model.everyLabel(intervalSeconds)

  signal applied(var piece)
  signal downloaded(string path)

  // A shuffle and a scheduled rotation both come from the random endpoint, so
  // the piece they land on was never part of today's triple and the panel had
  // no way to describe the wallpaper it had just set. That response already
  // carries the whole record — title, artist, date, school, description — so
  // nothing extra is fetched here beyond the thumbnail: the piece just needs
  // somewhere to live. It goes in directly behind today's, pushing the oldest
  // of the others out, which keeps the list at its three slots and today's
  // piece at the front where the panel expects it.
  function rememberPiece(piece) {
    if (!piece || !piece.id) return
    var next = []
    var todayPiece = pieces.length > 0 && pieces[0].isToday === true ? pieces[0] : null
    if (todayPiece && todayPiece.id !== piece.id) next.push(todayPiece)
    next.push(piece)
    for (var i = 0; i < pieces.length && next.length < pieceLimit; i++) {
      var candidate = pieces[i]
      if (!candidate || candidate.id === piece.id) continue
      if (todayPiece && candidate.id === todayPiece.id) continue
      next.push(candidate)
    }
    pieces = next
    // Kicked off now rather than after the wallpaper lands, so the panel has
    // the preview ready by the time the full-size image finishes downloading.
    fetchThumbnails()
  }

  // The list is rebuilt from the network every start, so a piece that arrived
  // from a shuffle is not in it — but `current` is persisted, whole record and
  // all, so the wallpaper on screen can be put back on the list without asking
  // the server for anything. Called from both sides of the startup race: the
  // state file and the first fetch land in either order.
  function ensureCurrentListed() {
    if (!current || !current.id || pieces.length === 0) return
    for (var i = 0; i < pieces.length; i++)
      if (pieces[i].id === current.id) return
    rememberPiece(current)
  }

  // --------------------------------------------------------------- fetching

  function refresh() {
    if (tripleProc.running) return
    lastError = ""
    loading = true
    tripleProc.command = ["curl", "-fsS", "--max-time", "20",
      Model.API_TRIPLE + "?cacheBust=" + Date.now()]
    tripleProc.running = true
  }

  function adoptTriple(text) {
    var parsed = []
    try {
      parsed = Model.parseTriple(text)
    } catch (e) {
      lastError = "anotherboring.day sent something unreadable"
      return
    }
    if (parsed.length === 0) {
      lastError = "anotherboring.day returned no pieces"
      return
    }
    pieces = parsed
    lastError = ""
    fetchThumbnails()
    // Refreshing replaces the list wholesale, which would otherwise drop the
    // wallpaper that is actually on screen out of the panel.
    ensureCurrentListed()
  }

  Process {
    id: tripleProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptTriple(text)
    }
    onExited: function (exitCode) {
      root.loading = false
      if (exitCode !== 0) root.lastError = "Could not reach anotherboring.day"
    }
  }

  // ------------------------------------------------------------ thumbnails
  //
  // Thumbnails are fetched to disk with curl rather than handed to Image as
  // https URLs: the panel then renders from the local file, which survives a
  // dropped network and keeps image loading off Qt's network stack entirely.
  // A path is published only once its file exists, so the Image binding flips
  // straight from empty to a loadable source.

  property bool thumbsPending: false

  readonly property string thumbScript: [
    "set -euo pipefail",
    "dir=$1",
    "mkdir -p \"$dir\"",
    "while IFS=$'\\t' read -r id url; do",
    "  if [ -z \"${id:-}\" ] || [ -z \"${url:-}\" ]; then continue; fi",
    "  out=\"$dir/$id.jpg\"",
    "  if [ -s \"$out\" ]; then continue; fi",
    "  tmp=$(mktemp \"$dir/.tmp.XXXXXX\")",
    "  if curl -fsSL --max-time 30 -o \"$tmp\" \"$url\"; then mv -f \"$tmp\" \"$out\"; else rm -f \"$tmp\"; fi",
    "done <<< \"$2\"",
    "{ ls -1t \"$dir\" 2>/dev/null || true; } | tail -n +61 | while IFS= read -r stale; do rm -f -- \"$dir/$stale\"; done"
  ].join("\n")

  function fetchThumbnails() {
    if (pieces.length === 0) return
    if (thumbProc.running) {
      thumbsPending = true
      return
    }
    var lines = []
    for (var i = 0; i < pieces.length; i++)
      lines.push(pieces[i].id + "\t" + pieces[i].thumbnailUrl)
    thumbProc.command = ["bash", "-c", thumbScript, "boringday", thumbDir, lines.join("\n")]
    thumbProc.running = true
  }

  function publishThumbnails() {
    var next = ({})
    for (var key in thumbs) next[key] = thumbs[key]
    for (var i = 0; i < pieces.length; i++)
      next[pieces[i].id] = thumbDir + "/" + pieces[i].id + ".jpg"
    thumbs = next
  }

  Process {
    id: thumbProc
    onExited: function () {
      root.publishThumbnails()
      if (root.thumbsPending) {
        root.thumbsPending = false
        Qt.callLater(root.fetchThumbnails)
      }
    }
  }

  // ---------------------------------------------------------------- shuffle
  //
  // The random endpoint is free to hand back a piece that was on screen an
  // hour ago. Ask again a couple of times when it does, then take what we are
  // given rather than spinning against a small catalogue.

  readonly property int shuffleAttemptLimit: 3
  property int shuffleAttempts: 0
  property string shuffleReason: "shuffle"

  function shuffle(reason) {
    if (randomProc.running || applying) return
    shuffleReason = reason || "shuffle"
    shuffleAttempts = 0
    status = "Finding a piece…"
    lastError = ""
    requestRandom()
  }

  function requestRandom() {
    shuffleAttempts += 1
    randomProc.command = ["curl", "-fsS", "--max-time", "20",
      Model.API_RANDOM + "?cacheBust=" + Date.now()]
    randomProc.running = true
  }

  function adoptRandom(text) {
    var piece = null
    try {
      piece = Model.parseOne(text)
    } catch (e) {
      piece = null
    }
    if (!piece) {
      lastError = "anotherboring.day sent something unreadable"
      status = ""
      return
    }
    if (recentIds.indexOf(piece.id) !== -1 && shuffleAttempts < shuffleAttemptLimit) {
      Qt.callLater(requestRandom)
      return
    }
    rememberPiece(piece)
    apply(piece, shuffleReason)
  }

  Process {
    id: randomProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptRandom(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.lastError = "Could not reach anotherboring.day"
        root.status = ""
      }
    }
  }

  // ------------------------------------------------------------------ apply
  //
  // Download once into the cache, then hand the path to omarchy-theme-bg-set,
  // which owns the current-background symlink and tells the shell to repaint.
  // The cache is capped at 20 images, newest kept, the one just applied always
  // spared — it is the file the symlink points at.

  property var pendingPiece: null
  property string pendingReason: "set"
  property var queuedPiece: null
  property string queuedReason: "set"

  readonly property string applyScript: [
    "set -euo pipefail",
    "export PATH=\"$1:$PATH\"",
    "url=$2",
    "out=$3",
    "dir=$(dirname \"$out\")",
    "mkdir -p \"$dir\"",
    "if [ ! -s \"$out\" ]; then",
    "  tmp=$(mktemp \"$dir/.tmp.XXXXXX\")",
    "  if ! curl -fsSL --max-time 120 -o \"$tmp\" \"$url\"; then rm -f \"$tmp\"; exit 1; fi",
    "  mv -f \"$tmp\" \"$out\"",
    "fi",
    "touch \"$out\"",
    "omarchy-theme-bg-set \"$out\"",
    "{ ls -1t \"$dir\" 2>/dev/null || true; } | tail -n +21 | while IFS= read -r stale; do",
    "  if [ \"$dir/$stale\" != \"$out\" ]; then rm -f -- \"$dir/$stale\"; fi",
    "done"
  ].join("\n")

  function apply(piece, reason) {
    if (!piece || !piece.url) return
    if (applying) {
      queuedPiece = piece
      queuedReason = reason || "set"
      return
    }
    applying = true
    lastError = ""
    pendingPiece = piece
    pendingReason = reason || "set"
    status = "Setting " + piece.name + "…"
    applyProc.command = ["bash", "-c", applyScript, "boringday", binDir, piece.url,
      wallpaperDir + "/" + piece.id + Model.extensionFor(piece.url)]
    applyProc.running = true
  }

  function applyToday(reason) {
    if (today) apply(today, reason || "today")
    else refresh()
  }

  function recordApplied(piece, reason) {
    var now = Date.now()
    current = piece
    lastSwitchAt = now
    recentIds = Model.pushRecent(recentIds, piece.id, 5)
    persist()
    applied(piece)
    // Notify only for changes the user is not already looking at: a scheduled
    // rotation, or a keybinding that fired with no panel open. A click in the
    // panel gets its feedback from the panel.
    if (notifyOnSwitch && (reason === "auto" || reason === "cli")) notify(piece)
  }

  function notify(piece) {
    Quickshell.execDetached([binDir + "/omarchy-notification-send", "-g", "󰋩",
      piece.name, Model.subtitle(piece)])
  }

  Process {
    id: applyProc
    onExited: function (exitCode) {
      root.applying = false
      var piece = root.pendingPiece
      root.pendingPiece = null
      if (exitCode === 0 && piece) {
        root.status = ""
        root.recordApplied(piece, root.pendingReason)
      } else {
        root.status = ""
        root.lastError = "Could not set that background"
      }
      if (root.queuedPiece) {
        var queued = root.queuedPiece
        var queuedReason = root.queuedReason
        root.queuedPiece = null
        root.apply(queued, queuedReason)
      }
    }
  }

  // --------------------------------------------------------------- download
  //
  // Save a copy somewhere the user keeps pictures. xdg-user-dir knows where
  // that is on a localized desktop; ~/Pictures is the fallback.

  readonly property string downloadScript: [
    "set -euo pipefail",
    "url=$1",
    "name=$2",
    "dir=$(xdg-user-dir PICTURES 2>/dev/null || true)",
    "if [ -z \"${dir:-}\" ] || [ \"$dir\" = \"$HOME\" ]; then dir=\"$HOME/Pictures\"; fi",
    "mkdir -p \"$dir\"",
    "out=\"$dir/$name\"",
    "n=2",
    "while [ -e \"$out\" ]; do",
    "  out=\"$dir/${name%.*}-$n.${name##*.}\"",
    "  n=$((n + 1))",
    "done",
    "tmp=$(mktemp \"$dir/.tmp.XXXXXX\")",
    "if ! curl -fsSL --max-time 120 -o \"$tmp\" \"$url\"; then rm -f \"$tmp\"; exit 1; fi",
    "mv -f \"$tmp\" \"$out\"",
    "chmod 644 \"$out\"",
    "printf '%s' \"$out\""
  ].join("\n")

  property string downloadedPath: ""

  function download(piece) {
    if (!piece || !piece.url || downloadProc.running) return
    status = "Saving " + piece.name + "…"
    lastError = ""
    downloadProc.command = ["bash", "-c", downloadScript, "boringday", piece.url, Model.downloadName(piece)]
    downloadProc.running = true
  }

  Process {
    id: downloadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.downloadedPath = String(text || "").trim()
    }
    onExited: function (exitCode) {
      if (exitCode === 0 && root.downloadedPath) {
        root.status = "Saved to " + root.downloadedPath
        root.downloaded(root.downloadedPath)
        statusClear.restart()
      } else {
        root.status = ""
        root.lastError = "Could not save that image"
      }
    }
  }

  Timer {
    id: statusClear
    interval: 4000
    onTriggered: root.status = ""
  }

  function openArtPage(piece) {
    if (!piece) return
    Quickshell.execDetached(["xdg-open", piece.artPage])
  }

  // -------------------------------------------------------------- rotation
  //
  // The interval is wall-clock, not uptime: the last switch is persisted, so a
  // shell restart resumes the schedule where it left off instead of granting a
  // fresh hour. The catch-up runs a beat after startup so a login does not
  // race the network coming up.

  function dueInMs() {
    var period = intervalSeconds * 1000
    if (!lastSwitchAt) return 0
    return Math.max(0, lastSwitchAt + period - Date.now())
  }

  Timer {
    id: rotationTimer
    running: root.autoRotate && root.stateLoaded
    repeat: true
    interval: Math.max(60000, root.intervalSeconds * 1000)
    onTriggered: root.shuffle("auto")
  }

  Timer {
    id: catchUpTimer
    interval: 8000
    repeat: false
    onTriggered: {
      if (root.autoRotate && root.dueInMs() === 0) root.shuffle("auto")
    }
  }

  onAutoRotateChanged: if (autoRotate && stateLoaded) catchUpTimer.restart()

  // ------------------------------------------------------------ persistence

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.adoptState(text())
    // First run: no file yet. Without this the service would never reach
    // stateLoaded, and rotation would never start.
    onLoadFailed: root.adoptState("")
  }

  function adoptState(text) {
    var state = Model.parseState(text)
    lastSwitchAt = state.lastSwitchAt
    recentIds = state.recentIds
    current = state.current
    stateLoaded = true
    ensureCurrentListed()
    if (autoRotate) catchUpTimer.restart()
  }

  function persist() {
    stateFile.setText(Model.stateJson({
      lastSwitchAt: lastSwitchAt,
      recentIds: recentIds,
      current: current
    }))
  }

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", stateDir, wallpaperDir, thumbDir])
    refresh()
  }

  // -------------------------------------------------------------------- IPC
  //
  // The CLI surface: keybindings, menu entries, and scripts drive the plugin
  // through these without a bar widget being on screen.
  //
  //   omarchy-shell boringday random
  //   omarchy-shell boringday today
  //   omarchy-shell boringday auto toggle
  //   omarchy-shell boringday status

  IpcHandler {
    target: "boringday"

    function random(): string {
      root.shuffle("cli")
      return "Finding a piece…"
    }

    function today(): string {
      root.applyToday("cli")
      return root.today ? root.today.name + " — " + root.today.artist : "Fetching today's piece…"
    }

    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function current(): string {
      if (!root.current) return "Nothing set by this plugin yet"
      return root.current.name + " — " + root.current.artist
    }

    function auto(state: string): string {
      var wanted = String(state || "toggle").toLowerCase()
      var next = root.autoRotate
      if (wanted === "on" || wanted === "true" || wanted === "enable") next = true
      else if (wanted === "off" || wanted === "false" || wanted === "disable") next = false
      else next = !root.autoRotate
      root.setAutoRotate(next)
      return next ? "Rotating every " + root.intervalLabel : "Rotation off"
    }

    function interval(seconds: string): string {
      var wanted = Number(seconds)
      if (!isFinite(wanted) || wanted <= 0) return "Interval is " + root.intervalLabel
      root.setIntervalSeconds(wanted)
      return "Rotating every " + Model.everyLabel(wanted)
    }

    function status(): string {
      return Model.statusJson({
        autoRotate: root.autoRotate,
        intervalSeconds: root.intervalSeconds,
        notify: root.notifyOnSwitch,
        nextChangeInSeconds: root.autoRotate ? Math.round(root.dueInMs() / 1000) : null,
        current: root.current ? { id: root.current.id, name: root.current.name, artist: root.current.artist } : null,
        today: root.today ? { id: root.today.id, name: root.today.name, artist: root.today.artist } : null,
        loading: root.loading,
        applying: root.applying,
        lastError: root.lastError
      })
    }
  }
}
