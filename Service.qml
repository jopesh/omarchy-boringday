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
  // lastError is the transient channel: every fetch clears it and the next
  // failure replaces it. A startup that could not lay down its own state file
  // is not transient — it lasts the session — so it gets a channel a
  // successful refresh cannot wipe a second later.
  property string stateError: ""

  readonly property var today: pieces.length > 0 ? pieces[0] : null
  readonly property int pieceLimit: 3
  // Phrased for the panel's "every ..." caption and the IPC replies, both of
  // which read it straight after the word "every".
  readonly property string intervalLabel: Model.everyLabel(intervalSeconds)

  signal applied(var piece)
  signal downloaded(string path)
  signal installed(string theme)

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

  // Both API fetches go out like this. https only, a wall-clock timeout, and a
  // ceiling curl applies to the body while it is still streaming rather than
  // after the fact — the StdioCollector on the other end has no limit of its
  // own and will hold whatever it is handed, so the producer is the only place
  // a limit means anything. Past the ceiling curl gives up with exit 63 and
  // the response is never parsed.
  function jsonFetch(endpoint) {
    return ["curl", "-fsS", "--proto", "=https",
      "--max-time", "20", "--max-filesize", String(Model.MAX_JSON_CHARS),
      endpoint + "?cacheBust=" + Date.now()]
  }

  // Worth telling apart from a dead network: the endpoint answered, it just
  // answered with more than we agreed to read.
  function fetchError(exitCode) {
    return exitCode === 63 ? "anotherboring.day sent more than we will read"
      : "Could not reach anotherboring.day"
  }

  function refresh() {
    if (tripleProc.running) return
    lastError = ""
    loading = true
    tripleProc.command = jsonFetch(Model.API_TRIPLE)
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
      if (exitCode !== 0) root.lastError = root.fetchError(exitCode)
    }
  }

  // ----------------------------------------------------------- image tools
  //
  // Shared by every script below that pulls an image down, because they all
  // need the same two things. curl stops at a byte ceiling instead of writing
  // whatever the far end feels like sending, and nothing is moved into place
  // until a header probe agrees the file is an image of a size we are willing
  // to decode. A 200 KB PNG can unpack to gigabytes, so bytes alone bound
  // nothing: the panel's Image and the desktop background should not be the
  // first things to discover a 40000x40000 file.

  readonly property string imageTools: [
    "image_ok() { # file max_bytes max_edge max_pixels",
    "  local file=$1 max_bytes=$2 max_edge=$3 max_pixels=$4 probe kind w h",
    // Asked about a file that is not there yet on every apply, so the missing
    // case is a quiet no rather than a redirect error on stderr.
    "  [ -f \"$file\" ] || return 1",
    "  local size; size=$(wc -c < \"$file\" 2>/dev/null) || return 1",
    "  [ \"$size\" -gt 0 ] && [ \"$size\" -le \"$max_bytes\" ] || return 1",
    "  if command -v identify >/dev/null 2>&1; then",
    "    probe=$(identify -quiet -ping -limit memory 64MiB -limit map 64MiB \\",
    "      -format '%m %w %h' \"$file[0]\" 2>/dev/null) || return 1",
    "  else",
    "    # No ImageMagick. file(1) names the type and the dimensions of every",
    "    # format the CDNs actually serve except AVIF, which is refused here",
    "    # rather than guessed at.",
    "    local described; described=$(file -b -- \"$file\") || return 1",
    "    case $described in",
    "      JPEG\\ image\\ data*) kind=JPEG ;;",
    "      PNG\\ image\\ data*) kind=PNG ;;",
    "      GIF\\ image\\ data*) kind=GIF ;;",
    "      *WebP\\ image*) kind=WEBP ;;",
    "      *) return 1 ;;",
    "    esac",
    "    probe=\"$kind $(printf '%s' \"$described\" |",
    "      sed -nE 's/.*[^0-9]([0-9]+) ?x ?([0-9]+).*/\\1 \\2/p')\"",
    "  fi",
    "  read -r kind w h <<< \"$probe\" || return 1",
    "  case $kind in JPEG|PNG|WEBP|AVIF|GIF|BMP) ;; *) return 1 ;; esac",
    "  [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 1",
    "  [ \"$w\" -ge 1 ] && [ \"$h\" -ge 1 ] || return 1",
    "  [ \"$w\" -le \"$max_edge\" ] && [ \"$h\" -le \"$max_edge\" ] || return 1",
    "  [ $((w * h)) -le \"$max_pixels\" ] || return 1",
    "}",
    "",
    "fetch_image() { # url dest max_bytes max_edge max_pixels timeout",
    "  local url=$1 dest=$2 max_bytes=$3 max_edge=$4 max_pixels=$5 timeout=$6",
    "  local dir tmp",
    "  dir=$(dirname \"$dest\")",
    "  mkdir -p \"$dir\"",
    "  tmp=$(mktemp \"$dir/.tmp.XXXXXX\")",
    "  if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 5 \\",
    "      --max-time \"$timeout\" --max-filesize \"$max_bytes\" -o \"$tmp\" \"$url\"; then",
    "    rm -f \"$tmp\"; return 1",
    "  fi",
    "  if ! image_ok \"$tmp\" \"$max_bytes\" \"$max_edge\" \"$max_pixels\"; then",
    "    rm -f \"$tmp\"; return 1",
    "  fi",
    "  mv -f \"$tmp\" \"$dest\"",
    "}"
  ].join("\n")

  readonly property string imageLimits: [Model.MAX_IMAGE_BYTES,
    Model.MAX_IMAGE_EDGE, Model.MAX_IMAGE_PIXELS].join(" ")

  // Thumbnail ceilings are per piece rather than fixed, because a thumbnail is
  // only a thumbnail when one of the two CDN rewrites matched. For any other
  // host Model hands back the URL untouched — worse than a thumbnail, but not
  // broken — and holding that full-size original to a 640px file's ceilings
  // would refuse it on every fetch, blank the preview for good, and re-download
  // it on every refresh.
  function thumbLimitsFor(piece) {
    return piece && piece.thumbnailIsOriginal
      ? [Model.MAX_IMAGE_BYTES, Model.MAX_IMAGE_EDGE, Model.MAX_IMAGE_PIXELS]
      : [Model.MAX_THUMB_BYTES, Model.MAX_THUMB_EDGE, Model.MAX_THUMB_PIXELS]
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
    imageTools,
    "dir=$1",
    "mkdir -p \"$dir\"",
    "while IFS=$'\\t' read -r id url max_bytes max_edge max_pixels; do",
    "  if [ -z \"${id:-}\" ] || [ -z \"${url:-}\" ]; then continue; fi",
    "  out=\"$dir/$id.jpg\"",
    "  if [ -s \"$out\" ]; then continue; fi",
    "  fetch_image \"$url\" \"$out\" \"$max_bytes\" \"$max_edge\" \"$max_pixels\" 30 || true",
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
      lines.push([pieces[i].id, pieces[i].thumbnailUrl]
        .concat(thumbLimitsFor(pieces[i])).join("\t"))
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
    randomProc.command = jsonFetch(Model.API_RANDOM)
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
        root.lastError = root.fetchError(exitCode)
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
    imageTools,
    "export PATH=\"$1:$PATH\"",
    "url=$2",
    "out=$3",
    "dir=$(dirname \"$out\")",
    "mkdir -p \"$dir\"",
    // Checked even when the cache already had it: the file is about to become
    // the desktop background, and the cache directory is writable by anything
    // running as the user. A cached file that fails is replaced rather than
    // deleted — fetch_image only renames a validated file into place, so the
    // old one survives a failed fetch. Deleting first would leave Omarchy's
    // current-background symlink pointing at nothing.
    "if ! image_ok \"$out\" " + imageLimits + "; then",
    "  fetch_image \"$url\" \"$out\" " + imageLimits + " 120",
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
    imageTools,
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
    "fetch_image \"$url\" \"$out\" " + imageLimits + " 120",
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
      // The script prints one path, but a collector holds whatever it is
      // given, so the path is taken at a length a path can actually be.
      onStreamFinished: root.downloadedPath = String(text || "").trim().substring(0, Model.MAX_PATH_CHARS)
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

  // ------------------------------------------------------- install to theme
  //
  // Setting a piece only moves Omarchy's current-background symlink, and that
  // symlink belongs to the theme: switch themes, or cycle with `omarchy theme
  // bg next`, and the piece is gone. Installing copies the image into the
  // theme's own user backgrounds folder — the directory that rotation reads
  // from — so the piece becomes one of the theme's backgrounds rather than a
  // pointer into a cache that is pruned at twenty files.
  //
  // The copy is named for the piece, id included, so installing the same piece
  // twice is a no-op rather than a second file. And if the wall is currently
  // showing the cache copy of this very piece, the symlink is moved onto the
  // installed one: same image on screen, but no longer resting on a file the
  // next twenty switches will delete.

  readonly property string themeNamePath: home + "/.local/state/omarchy/current/theme.name"
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"
  readonly property string themeBackgroundsDir: home + "/.config/omarchy/backgrounds"

  readonly property string installScript: [
    "set -euo pipefail",
    imageTools,
    "export PATH=\"$1:$PATH\"",
    "url=$2",
    "src=$3",
    "name=$4",
    "root=$5",
    "link=$6",
    "theme=$(cat \"$7\" 2>/dev/null || true)",
    // No theme, or a name that would not be a single directory under the
    // backgrounds root: nothing sane to install into, so say so and stop.
    "case ${theme:-} in \"\"|.|..|*/*) exit 4 ;; esac",
    "dir=\"$root/$theme\"",
    "mkdir -p \"$dir\"",
    // As in applyScript: replaced, not deleted, because the wall may be
    // resting on this very file.
    "if ! image_ok \"$src\" " + imageLimits + "; then",
    "  fetch_image \"$url\" \"$src\" " + imageLimits + " 120",
    "fi",
    "out=\"$dir/$name\"",
    "if [ ! -s \"$out\" ]; then",
    // Written aside and renamed, so the theme's rotation never finds a
    // half-copied file mid-install.
    "  tmp=$(mktemp \"$dir/.tmp.XXXXXX\")",
    "  cp -f \"$src\" \"$tmp\"",
    "  chmod 644 \"$tmp\"",
    "  mv -f \"$tmp\" \"$out\"",
    "fi",
    "if [ \"$(readlink -f \"$link\" 2>/dev/null || true)\" = \"$(readlink -f \"$src\")\" ]; then",
    "  omarchy-theme-bg-set \"$out\"",
    "fi",
    "printf '%s' \"$theme\""
  ].join("\n")

  property string installedTheme: ""

  function installToTheme(piece) {
    if (!piece || !piece.url || installProc.running) return
    status = "Adding " + piece.name + " to the theme…"
    lastError = ""
    installProc.command = ["bash", "-c", installScript, "boringday", binDir, piece.url,
      wallpaperDir + "/" + piece.id + Model.extensionFor(piece.url),
      Model.downloadName(piece), themeBackgroundsDir, backgroundLink, themeNamePath]
    installProc.running = true
  }

  Process {
    id: installProc
    stdout: StdioCollector {
      waitForEnd: true
      // A theme name off local state rather than the network, but it is drawn
      // in the panel, so it is bounded like anything else that is.
      onStreamFinished: root.installedTheme = Model.boundedText(text, Model.MAX_LINE_CHARS, "")
    }
    onExited: function (exitCode) {
      if (exitCode === 0 && root.installedTheme) {
        root.status = "Added to " + root.installedTheme
        root.installed(root.installedTheme)
        statusClear.restart()
      } else {
        root.status = ""
        root.lastError = exitCode === 4 ? "No current theme to add it to"
          : "Could not add that to the theme"
      }
    }
  }

  function openArtPage(piece) {
    if (!piece) return
    Quickshell.execDetached(["xdg-open", piece.artPage])
  }

  function openSite() {
    Quickshell.execDetached(["xdg-open", Model.SITE])
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
  //
  // The directories this plugin owns are made once at startup, and the state
  // file is measured in the same step. FileView reads whatever it is pointed
  // at, however large, so the ceiling has to be applied before it is pointed
  // at anything: an oversized file is deleted — it is a cache, and the next
  // switch rewrites it — and anything that is not a plain file is refused.

  property bool stateReady: false

  readonly property string startupScript: [
    "set -euo pipefail",
    "mkdir -p \"$1\" \"$2\" \"$3\"",
    "state=$4",
    "if [ -h \"$state\" ]; then rm -f \"$state\"; fi",
    "if [ -f \"$state\" ] && [ \"$(wc -c < \"$state\")\" -gt " + Model.MAX_STATE_CHARS + " ]; then",
    "  rm -f \"$state\"",
    "fi",
    "if [ -e \"$state\" ] && [ ! -f \"$state\" ]; then exit 3; fi"
  ].join("\n")

  Process {
    id: startupProc
    command: ["bash", "-c", root.startupScript, "boringday",
      root.stateDir, root.wallpaperDir, root.thumbDir, root.statePath]
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.stateReady = true
        return
      }
      // Nothing readable on disk and nowhere to write one. The service still
      // has to reach stateLoaded or rotation would never start, but it runs
      // from here on without persistence — the schedule restarts from zero
      // every session and shuffle stops avoiding what it just showed — so it
      // says so rather than going quiet about it.
      root.stateError = "Could not use the state file — nothing is remembered"
      root.adoptState("")
    }
  }

  FileView {
    id: stateFile
    path: root.stateReady ? root.statePath : ""
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.adoptState(text())
    // First run: no file yet. Without this the service would never reach
    // stateLoaded, and rotation would never start. Guarded on stateReady so
    // the empty path this starts with does not count as a failed read.
    onLoadFailed: if (root.stateReady) root.adoptState("")
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
    if (!stateReady) return
    stateFile.setText(Model.stateJson({
      lastSwitchAt: lastSwitchAt,
      recentIds: recentIds,
      current: current
    }))
  }

  Component.onCompleted: {
    startupProc.running = true
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

    // Deliberately the piece on the wall rather than one of today's: from a
    // keybinding there is nothing previewed to mean instead.
    function install(): string {
      if (!root.current) return "Nothing set by this plugin yet"
      root.installToTheme(root.current)
      return "Adding " + root.current.name + " to the current theme…"
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
