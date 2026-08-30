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

  // The bar's three sections in the order they are drawn, then the plugins
  // list. One scan over all four: the first entry claiming this plugin's id
  // wins, wherever it happens to have been written.
  function entryFor(config) {
    if (!config || typeof config !== "object") return ({})
    var layout = config.bar && config.bar.layout ? config.bar.layout : ({})
    var lists = [layout.left, layout.center, layout.right, config.plugins]
    var entries = []
    for (var l = 0; l < lists.length; l++)
      if (Array.isArray(lists[l])) entries = entries.concat(lists[l])
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (entry && typeof entry === "object" && String(entry.id) === pluginId) return entry
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
  // Validated here rather than at the point of use: a mode typed into
  // shell.json by hand is an argument on aether's command line, and an
  // unrecognised one would fail the generate outright instead of quietly
  // giving the palette aether picks by default.
  readonly property string extractMode: Model.extractMode(setting("extractMode", Model.DEFAULT_EXTRACT_MODE))
  readonly property bool lightMode: setting("lightMode", false) === true

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

  function cycleIntervalBack() {
    setIntervalSeconds(Model.prevInterval(intervalSeconds))
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
  property bool generating: false
  property string lastError: ""
  property string status: ""
  // lastError is the transient channel: every fetch clears it and the next
  // failure replaces it. A startup that could not lay down its own state file
  // is not transient — it lasts the session — so it gets a channel a
  // successful refresh cannot wipe a second later.
  property string stateError: ""

  readonly property var today: pieces.length > 0 ? pieces[0] : null
  // Slot 0 when it is genuinely today's piece, rather than whatever happens to
  // be first. rememberPiece keeps it there and the list shuffle leaves it
  // alone, so both ask the question here instead of each spelling it out.
  readonly property var pinnedToday: pieces.length > 0 && pieces[0].isToday === true
    ? pieces[0] : null
  readonly property int pieceLimit: 3
  // Phrased for the panel's "every ..." caption and the IPC replies, both of
  // which read it straight after the word "every".
  readonly property string intervalLabel: Model.everyLabel(intervalSeconds)

  signal applied(var piece)
  signal downloaded(string path)
  signal installed(string theme)
  signal themed(string mode)

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
    var todayPiece = pinnedToday
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
    // parseTriple will hand back as many records as the response carries, up
    // to its own ceiling. The list has one length everywhere else — the panel
    // reserves exactly this many rows and rememberPiece has always trimmed to
    // it — so a longer response is cut here rather than painting over the rest
    // of the popup.
    pieces = parsed.slice(0, pieceLimit)
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

  // ------------------------------------------------------------ script calls
  //
  // Every script below is started through here, so the incantation is written
  // once: a wall clock, bash, the script, and the name bash reports it by —
  // "boringday" is $0, not an argument any script reads, which is why the
  // arguments passed here start at $1.
  //
  // The wall clock is the point of it. Each script either reaches the network
  // or hands off to another program, and a Process that never exits leaves the
  // flag that guards it raised for the rest of the session: one
  // omarchy-theme-bg-set that never returns and no later shuffle, rotation or
  // Set is so much as attempted. The bound sits well past the sum of the curl
  // timeouts inside the script — it is there to catch a hang, not to cut work
  // short — and a script killed at it exits 124, which every handler below
  // already reads as the failure it is.
  function scriptCommand(seconds, body, args) {
    return ["timeout", "-k", "5", String(seconds), "bash", "-c", body, "boringday"].concat(args)
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
    "}",
    "",
    "ensure_image() { # url file max_bytes max_edge max_pixels timeout",
    // Checked even when the file is already in the cache: it is about to
    // become the desktop background, and the cache directory is writable by
    // anything running as the user. A file that fails is replaced rather than
    // deleted — fetch_image only renames a validated file into place, so the
    // old one survives a failed fetch. Deleting first would leave Omarchy's
    // current-background symlink pointing at nothing.
    "  if ! image_ok \"$2\" \"$3\" \"$4\" \"$5\"; then",
    "    fetch_image \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\"",
    "  fi",
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
    thumbProc.command = scriptCommand(300, thumbScript, [thumbDir, lines.join("\n")])
    thumbProc.running = true
  }

  // Rebuilt from the list rather than added to. Carrying old keys forward
  // grew the map by a piece per rotation for the life of the session — and
  // copied the whole of it again on every publish — to hold paths nothing
  // reads: the panel only ever asks about a piece that is in the list, and a
  // piece that comes back into it is republished by the fetch that precedes
  // every publish.
  function publishThumbnails() {
    var next = ({})
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
  property bool retryPending: false
  property string shuffleReason: "shuffle"

  function shuffle(reason) {
    if (randomProc.running || applying) return
    shuffleReason = reason || "shuffle"
    shuffleAttempts = 0
    retryPending = false
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
    // Asked again from onExited rather than from here. This runs on the
    // stream, with the process still on its way out, and a command written to
    // a Process that is still running is dropped — which lost the retry and
    // left the status line saying "Finding a piece…" for good.
    if (recentIds.indexOf(piece.id) !== -1 && shuffleAttempts < shuffleAttemptLimit) {
      retryPending = true
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
        root.retryPending = false
        root.lastError = root.fetchError(exitCode)
        root.status = ""
        return
      }
      if (root.retryPending) {
        root.retryPending = false
        Qt.callLater(root.requestRandom)
      }
    }
  }

  // ------------------------------------------------------------ list refill
  //
  // The other shuffle. That one picks a piece and puts it on the wall; this
  // one refills the list and touches nothing, because the list is a selector —
  // putting two pieces the user has not been offered in front of them is the
  // whole of what it is for.
  //
  // Today's piece is not re-rolled. It is the one row in the panel that is not
  // random, there is no endpoint that would hand back a different one, and the
  // badge and the header both say so. So slot 0 stays and the rows behind it
  // are refilled one call at a time — the triple endpoint is seeded per day
  // and answers with the same two companions however often it is asked, which
  // is why this cannot simply be a second refresh.

  property bool shufflingList: false
  property var listCollected: []
  property int listAttempts: 0
  // Bounded because the catalogue is finite and every attempt is a round trip:
  // a run that keeps drawing pieces it already has stops rather than spinning.
  readonly property int listAttemptLimit: pieceLimit * 3

  function listWanted() {
    return Math.max(1, pieceLimit - (pinnedToday ? 1 : 0))
  }

  function shuffleList() {
    // Behind a refresh as well as behind itself: both replace the list
    // wholesale, and the one that landed second would silently undo the other.
    if (shufflingList || loading) return
    shufflingList = true
    listCollected = []
    listAttempts = 0
    lastError = ""
    status = "Finding new pieces…"
    requestListPiece()
  }

  function requestListPiece() {
    listAttempts += 1
    listProc.command = jsonFetch(Model.API_RANDOM)
    listProc.running = true
  }

  function adoptListPiece(text) {
    var piece = null
    try {
      piece = Model.parseOne(text)
    } catch (e) {
      piece = null
    }
    // A bad response is not fatal here the way it is for a shuffle that was
    // going to set something: there are attempts left, and the run reports on
    // what it managed to collect. Retried from onExited, as ever.
    if (!piece) return
    // A duplicate is wrong rather than merely unwanted — the same piece twice
    // in three rows is never right — so today's piece and anything already in
    // this batch are refused outright. Recently-seen is deliberately not
    // consulted: the single-piece shuffle avoids it because it is about to put
    // the piece on the wall, and re-setting what is already there is a visible
    // no-op. Nothing is set here, so a familiar piece among the choices is
    // just a choice.
    if (pinnedToday && piece.id === pinnedToday.id) return
    for (var i = 0; i < listCollected.length; i++)
      if (listCollected[i].id === piece.id) return
    var next = listCollected.slice()
    next.push(piece)
    listCollected = next
  }

  function publishShuffledList() {
    shufflingList = false
    status = ""
    if (listCollected.length === 0) {
      listCollected = []
      lastError = "anotherboring.day had nothing new to show"
      return
    }
    var next = []
    if (pinnedToday) next.push(pinnedToday)
    for (var i = 0; i < listCollected.length && next.length < pieceLimit; i++)
      next.push(listCollected[i])
    listCollected = []
    pieces = next
    fetchThumbnails()
    // No ensureCurrentListed here, and that is the difference from a refresh.
    // A refresh replaces the list with a set the user did not choose, so the
    // wallpaper is put back into it rather than dropped; a refill is the user
    // asking for something different, and spending one of the two slots on the
    // piece already on the wall would leave a shuffle offering exactly one new
    // thing. It comes back on the next refresh.
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptListPiece(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.shufflingList = false
        root.listCollected = []
        root.status = ""
        root.lastError = root.fetchError(exitCode)
        return
      }
      // Asked again from here rather than from the stream handler, for the
      // reason the single-piece shuffle is: a command written to a Process
      // that is still on its way out is dropped, and the run would stall with
      // the status line still saying it was looking.
      if (root.listCollected.length < root.listWanted()
          && root.listAttempts < root.listAttemptLimit) {
        Qt.callLater(root.requestListPiece)
        return
      }
      root.publishShuffledList()
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
    "ensure_image \"$url\" \"$out\" " + imageLimits + " 120",
    "touch \"$out\"",
    "omarchy-theme-bg-set \"$out\"",
    "{ ls -1t \"$dir\" 2>/dev/null || true; } | tail -n +21 | while IFS= read -r stale; do",
    "  if [ \"$dir/$stale\" != \"$out\" ]; then rm -f -- \"$dir/$stale\"; fi",
    "done"
  ].join("\n")

  function apply(piece, reason) {
    if (!piece || !piece.url) return
    // Behind a generate for the same reason it queues behind another apply:
    // aether owns the background symlink while it is applying a theme, and a
    // Set landing in the middle of that has the two of them moving it at
    // once. The generate drains this queue when it exits, so the piece the
    // user picked still lands — a moment later, on top of the theme.
    if (applying || generating) {
      queuedPiece = piece
      queuedReason = reason || "set"
      return
    }
    applying = true
    lastError = ""
    pendingPiece = piece
    pendingReason = reason || "set"
    status = "Setting " + piece.name + "…"
    applyProc.command = scriptCommand(300, applyScript, [binDir, piece.url,
      wallpaperDir + "/" + piece.id + Model.extensionFor(piece.url)])
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
    armRotation()
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
    downloadProc.command = scriptCommand(180, downloadScript, [piece.url, Model.downloadName(piece)])
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
    "ensure_image \"$url\" \"$src\" " + imageLimits + " 120",
    "out=\"$dir/$name\"",
    "if [ ! -s \"$out\" ]; then",
    // Written aside and renamed, so the theme's rotation never finds a
    // half-copied file mid-install.
    "  tmp=$(mktemp \"$dir/.tmp.XXXXXX\")",
    // The copy can fail with the file half written — the apply running
    // alongside it prunes the cache this reads from — and this is a directory
    // the user keeps, with nothing else that would ever sweep it.
    "  trap 'rm -f \"$tmp\"' EXIT",
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
    installProc.command = scriptCommand(300, installScript, [binDir, piece.url,
      wallpaperDir + "/" + piece.id + Model.extensionFor(piece.url),
      Model.downloadName(piece), themeBackgroundsDir, backgroundLink, themeNamePath])
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

  // ------------------------------------------------------ generate a theme
  //
  // The piece stops being only a background and becomes the palette. Aether
  // pulls sixteen colours out of the image and retints the desktop from them
  // — Hyprland, waybar, mako, btop, the terminals, the editors — and sets the
  // image itself as the wallpaper along the way, because it owns Omarchy's
  // theme directory and the background symlink for as long as it is applying.
  //
  // One `aether --generate` and nothing after it. Aether keeps a single theme
  // of its own and rewrites it on every generate, so this is a switch rather
  // than a collection: generating from another piece replaces what this one
  // wrote, and the theme that was current before it is still sitting in the
  // theme switcher untouched. `t` is still the way to keep a piece.

  property bool aetherReady: false

  Process {
    id: aetherProbe
    // Asked once, at startup, so the panel can draw the action disabled
    // rather than leaving the CLI's absence to be discovered by clicking it.
    // Nothing here reaches the network or waits on anything, but it is still
    // started through scriptCommand for the reason every other script is: a
    // Process that never exits leaves a flag up for the rest of the session.
    command: root.scriptCommand(10, "command -v aether >/dev/null 2>&1", [])
    onExited: function (exitCode) { root.aetherReady = exitCode === 0 }
  }

  readonly property string generateScript: [
    "set -euo pipefail",
    imageTools,
    "export PATH=\"$1:$PATH\"",
    "url=$2",
    "out=$3",
    "mode=$4",
    "light=$5",
    // Probed again rather than taken from startup: aether can have been
    // removed since, and this is the check the call actually rests on.
    "command -v aether >/dev/null 2>&1 || exit 5",
    // The panel has a thumbnail; aether reads the piece itself, so the
    // full-size image is fetched and checked exactly as a Set fetches it.
    "ensure_image \"$url\" \"$out\" " + imageLimits + " 120",
    // Newest in the cache, so the twenty-file prune the next Set runs cannot
    // delete the file aether took its wallpaper from.
    "touch \"$out\"",
    // Built as an array so the optional flag is a separate argument rather
    // than a word split out of a string.
    "args=(--generate \"$out\" --extract-mode \"$mode\")",
    "if [ \"$light\" = \"1\" ]; then args+=(--light-mode); fi",
    "aether \"${args[@]}\""
  ].join("\n")

  property var generatingPiece: null
  property string generatingReason: "theme"

  function generateTheme(piece, reason) {
    if (!piece || !piece.url || generating || applying) return
    generating = true
    lastError = ""
    generatingPiece = piece
    generatingReason = reason || "theme"
    status = "Building a theme from " + piece.name + "…"
    generateProc.command = scriptCommand(300, generateScript, [binDir, piece.url,
      wallpaperDir + "/" + piece.id + Model.extensionFor(piece.url),
      extractMode, lightMode ? "1" : "0"])
    generateProc.running = true
  }

  Process {
    id: generateProc
    onExited: function (exitCode) {
      root.generating = false
      var piece = root.generatingPiece
      root.generatingPiece = null
      if (exitCode === 0 && piece) {
        root.status = "Theme built from " + piece.name
        // Aether set the wallpaper as part of applying, so this piece is what
        // is on the wall — recorded the way a Set records it, which also
        // restarts the rotation clock rather than leaving a theme the user
        // just asked for to be shuffled away a minute later.
        root.recordApplied(piece, root.generatingReason)
        root.themed(root.extractMode)
        statusClear.restart()
      } else {
        root.status = ""
        root.lastError = exitCode === 5 ? "Aether is not installed"
          : "Could not build a theme from that piece"
      }
      // Whatever queued behind the generate, including the failed case: the
      // queue is the user's Set, and a theme that did not build is no reason
      // to swallow it.
      if (root.queuedPiece) {
        var queued = root.queuedPiece
        var queuedReason = root.queuedReason
        root.queuedPiece = null
        root.apply(queued, queuedReason)
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
  // fresh hour. That only holds if the wait is derived from the timestamp
  // every time it is set, which is why there is one timer here and it is a
  // one-shot, re-armed from the clock rather than left repeating. A repeating
  // timer measures from whenever it happened to start: a restart 55 minutes
  // into an hour waited another full hour, and a manual switch left the next
  // rotation wherever the old cycle had already put it — sometimes seconds
  // away.

  function dueInMs() {
    var period = intervalSeconds * 1000
    if (!lastSwitchAt) return 0
    return Math.max(0, lastSwitchAt + period - Date.now())
  }

  // A rotation that is already due still waits out this much, so a login does
  // not race the network coming up.
  readonly property int rotationGrace: 8000

  function armRotation() {
    // Nothing to arm before the state file lands — the timestamp the wait is
    // measured from is still on disk — and nothing to touch either: this runs
    // from a property handler that fires while the component is still being
    // built. adoptState calls it the moment there is a schedule.
    if (!stateLoaded) return
    rotationTimer.stop()
    if (!autoRotate) return
    rotationTimer.interval = Math.max(rotationGrace, dueInMs())
    rotationTimer.start()
  }

  Timer {
    id: rotationTimer
    repeat: false
    onTriggered: {
      // A generate is aether applying an entire theme, wallpaper included. A
      // rotation landing in the middle of that has the two of them moving the
      // current-background symlink at once, so this beat waits the generate
      // out — a grace beat rather than a dropped period.
      if (root.generating) {
        interval = root.rotationGrace
        start()
        return
      }
      // Re-armed a whole period out before the shuffle rather than after it. A
      // fetch that fails records no switch, so re-deriving from the timestamp
      // afterwards would put the next attempt a grace beat away and spin
      // against a dead network for as long as it stayed dead. A shuffle that
      // does land arms it again off its own timestamp, which is this same
      // moment.
      interval = Math.max(root.rotationGrace, root.intervalSeconds * 1000)
      start()
      root.shuffle("auto")
    }
  }

  onAutoRotateChanged: armRotation()
  onIntervalSecondsChanged: armRotation()

  // ------------------------------------------------------------ persistence
  //
  // The directories this plugin owns are made once at startup, and the state
  // file is read in the same step, by the only thing that ever opens it. A
  // name can be swapped between the moment it is looked at and the moment it
  // is opened, so nothing here rests on the name: the file is opened once, and
  // it is that descriptor — not the path it was reached by — that is checked
  // for being a plain file and then read from. Nothing is handed back to Qt as
  // a path for it to open a second time, so there is no second open to race.
  //
  // The read is one byte wider than the ceiling and parseState refuses
  // anything that long, so an oversized file leaves the state empty and the
  // next switch writes over it. Nothing is deleted for being the wrong shape:
  // a rename replaces whatever is at the name anyway, and refusing to read is
  // the whole of what refusing has to mean.

  property bool stateReady: false
  property string stateText: ""

  readonly property string startupScript: [
    "set -euo pipefail",
    "mkdir -p \"$1\" \"$2\" \"$3\"",
    "state=$4",
    "limit=$5",
    // First run. The directories exist now and the first switch writes the
    // file: nothing to read is not a refusal.
    "[ -e \"$state\" ] || exit 0",
    // Decides nothing on its own — the descriptor below is what a refusal
    // rests on. It only spares the ordinary case, something else parked at
    // the name, from being opened at all.
    "if [ -L \"$state\" ] || [ ! -f \"$state\" ]; then exit 3; fi",
    "read_state() {",
    // bash reads this as fstat on the descriptor rather than a walk back down
    // the path, which is the point: a pipe or a device swapped in after the
    // check above is still a pipe or a device here, whatever the name says by
    // now, and is refused before a byte is read.
    "  [ -f /dev/fd/3 ] || return 1",
    "  head -c \"$limit\" <&3",
    "}",
    "read_state 3< \"$state\" || exit 3"
  ].join("\n")

  Process {
    id: startupProc
    // The bound matters more here than anywhere else: the open inside this
    // script is the one thing the descriptor check cannot cover, because
    // opening a pipe waits for a writer that may never come and that wait
    // happens before there is a descriptor to check. Short, because nothing
    // here should take even a second.
    command: root.scriptCommand(10, root.startupScript,
      [root.stateDir, root.wallpaperDir, root.thumbDir, root.statePath,
        String(Model.MAX_STATE_CHARS + 1)])
    stdout: StdioCollector {
      waitForEnd: true
      // As with every collector here, the ceiling is the producer's: head is
      // what keeps this one from being handed the size of the disk.
      onStreamFinished: root.stateText = text
    }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.stateReady = true
        root.adoptState(root.stateText)
        root.stateText = ""
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

  // The read is not instant and nothing waits for it: a keybinding fired at
  // login, or a panel opened straight away, can put a piece on the wall before
  // the file lands. What is on the wall now outranks what was on it last
  // session, so in that case the file is read for its recents alone — and the
  // switch that beat it, which persist() could not write while stateReady was
  // still false, is written now.
  function adoptState(text) {
    var state = Model.parseState(text)
    var switched = current !== null
    if (switched) {
      recentIds = Model.pushRecent(state.recentIds, current.id, 5)
    } else {
      lastSwitchAt = state.lastSwitchAt
      recentIds = state.recentIds
      current = state.current
    }
    stateLoaded = true
    ensureCurrentListed()
    armRotation()
    if (switched) persist()
  }

  // Written aside and renamed, like every other file this plugin lays down.
  // The rename is also what makes the write safe on its own terms: it replaces
  // whatever is sitting at the name — a symlink aimed elsewhere, a pipe,
  // yesterday's file — instead of writing through it, so the writer needs no
  // guard of its own and no reader ever sees half a state file.
  readonly property string writeScript: [
    "set -euo pipefail",
    "state=$1",
    "dir=$(dirname \"$state\")",
    "mkdir -p \"$dir\"",
    "tmp=$(mktemp \"$dir/.state.XXXXXX\")",
    "trap 'rm -f \"$tmp\"' EXIT",
    "printf '%s' \"$2\" > \"$tmp\"",
    "mv -f -- \"$tmp\" \"$state\""
  ].join("\n")

  // One write at a time, and only the newest of whatever arrived meanwhile:
  // the file is a snapshot, so an intermediate one is nothing to catch up on.
  property string queuedState: ""

  function persist() {
    if (!stateReady) return
    var json = Model.stateJson({
      lastSwitchAt: lastSwitchAt,
      recentIds: recentIds,
      current: current
    })
    if (writeProc.running) {
      queuedState = json
      return
    }
    writeState(json)
  }

  function writeState(json) {
    writeProc.command = scriptCommand(30, writeScript, [statePath, json])
    writeProc.running = true
  }

  Process {
    id: writeProc
    onExited: function (exitCode) {
      // Cleared by a good write as much as set by a bad one. A startup with
      // nowhere to write is true for the session; a single failed write is
      // not, and the next switch tries again.
      root.stateError = exitCode === 0 ? ""
        : "Could not save the state file — this session is not remembered"
      if (root.queuedState) {
        var next = root.queuedState
        root.queuedState = ""
        root.writeState(next)
      }
    }
  }

  Component.onCompleted: {
    startupProc.running = true
    aetherProbe.running = true
    refresh()
  }

  // -------------------------------------------------------------------- IPC
  //
  // The CLI surface: keybindings, menu entries, and scripts drive the plugin
  // through these without a bar widget being on screen.
  //
  //   omarchy-shell boringday random
  //   omarchy-shell boringday today
  //   omarchy-shell boringday theme
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

    // The piece on the wall, for the same reason install does: from a
    // keybinding there is no previewed piece for "this one" to mean.
    function theme(): string {
      if (!root.aetherReady) return "aether is not installed"
      if (!root.current) return "Nothing set by this plugin yet"
      root.generateTheme(root.current, "cli")
      return "Building a theme from " + root.current.name + "…"
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
        extractMode: root.extractMode,
        lightMode: root.lightMode,
        aether: root.aetherReady,
        loading: root.loading,
        applying: root.applying,
        generating: root.generating,
        lastError: root.lastError
      })
    }
  }
}
