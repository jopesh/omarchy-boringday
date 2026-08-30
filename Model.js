.pragma library

// Pure helpers for the anotherboring.day plugin: endpoints, URL rewriting,
// response parsing, and state (de)serialization. Nothing here touches QML or
// the filesystem, so the fiddly parts — thumbnail transforms, malformed
// payloads, an interval a user typed by hand — can be reasoned about alone.

var API_TRIPLE = "https://service.anotherboring.day/api/wallpapers/raycast-triple"
var API_RANDOM = "https://service.anotherboring.day/api/wallpapers/random-human"
var ART_PAGE = "https://anotherboring.day/art/"
var SITE = "https://anotherboring.day/"

// The rotation periods the panel offers. A value set by hand in shell.json is
// still honored as-is — it simply matches no chip, and intervalLabel()
// describes whatever it finds.
var INTERVALS = [3600, 10800, 43200, 86400]
var MIN_INTERVAL = 300
var MAX_INTERVAL = 86400

// ------------------------------------------------------------------ ceilings
//
// Everything that crosses the network is treated as hostile: the API is not
// ours, the CDNs behind it are not ours, and the state file sits in a
// directory anything running as the user can write to. So every payload gets a
// size it is not allowed to exceed, and the ceiling is enforced where the data
// is produced — curl stops downloading rather than the shell discovering the
// problem once it is already holding the bytes. The numbers live here because
// both halves need them: the parsers below, and the shell scripts the service
// builds out of them.

// A triple response is a few KB of JSON; our own state file is three records.
var MAX_JSON_CHARS = 256 * 1024
var MAX_STATE_CHARS = 64 * 1024

// Bytes on the wire. A thumbnail is a 640px-wide re-encode; a wallpaper is the
// full-size original, which for a museum scan can legitimately be tens of MB.
var MAX_THUMB_BYTES = 8 * 1024 * 1024
var MAX_IMAGE_BYTES = 64 * 1024 * 1024

// Pixels after decoding, which is the number that actually costs memory: a
// 200 KB PNG can unpack to gigabytes, so a byte ceiling alone bounds nothing.
// Thumbnails are decoded by the panel itself and get the tighter pair; the
// wallpaper is decoded by whatever paints the background, and 40 MP leaves
// room for an 8K screen and then some.
var MAX_THUMB_EDGE = 4000
var MAX_THUMB_PIXELS = 8 * 1000 * 1000
var MAX_IMAGE_EDGE = 12000
var MAX_IMAGE_PIXELS = 40 * 1000 * 1000

// Fields of a single record. These are not guesses at what the API sends but
// ceilings on what we are willing to carry: an id becomes a file name, a name
// becomes a notification argument, a description becomes a Text block.
var MAX_ID_CHARS = 64
var MAX_NAME_CHARS = 200
var MAX_LINE_CHARS = 120
var MAX_DESCRIPTION_CHARS = 4000
var MAX_URL_CHARS = 2048
var MAX_PATH_CHARS = 4096

// Records per response: the service keeps three, and no response has a reason
// to make us walk more than this looking for them.
var MAX_SCANNED_RECORDS = 32
var MAX_PIECES = 8
var MAX_RECENT = 10

function clampInterval(seconds) {
  var n = Number(seconds)
  if (!isFinite(n) || n <= 0) return 3600
  return Math.max(MIN_INTERVAL, Math.min(MAX_INTERVAL, Math.round(n)))
}

// No days branch: the longest period on offer is 24 hours, and "24 hours"
// is what the chip says, so "1 day" here would name the same choice twice.
function intervalLabel(seconds) {
  var n = clampInterval(seconds)
  if (n % 3600 === 0) return plural(n / 3600, "hour")
  if (n % 60 === 0) return plural(n / 60, "minute")
  return plural(n, "second")
}

function plural(count, unit) {
  return count + " " + unit + (count === 1 ? "" : "s")
}

// The chips the panel shows. ButtonGroup compares option values as strings,
// so the seconds are stringified here rather than at the call site.
// Reads after the word "every": "every hour", not "every 1 hour".
function everyLabel(seconds) {
  var n = clampInterval(seconds)
  return n === 3600 ? "hour" : intervalLabel(n)
}

function intervalOptions() {
  var out = []
  for (var i = 0; i < INTERVALS.length; i++) {
    out.push({
      value: String(INTERVALS[i]),
      label: (INTERVALS[i] / 3600) + "h",
      tooltip: "Change every " + everyLabel(INTERVALS[i])
    })
  }
  return out
}

// -1 for a value that is not one of the presets, so the panel can leave every
// chip unselected rather than lying about which one is in force.
function intervalIndex(seconds) {
  var n = clampInterval(seconds)
  for (var i = 0; i < INTERVALS.length; i++) if (INTERVALS[i] === n) return i
  return -1
}

// Cycle to the next preset. An off-preset value snaps to the first preset
// larger than it, so a hand-edited 45m becomes 1h rather than jumping to 30m.
function nextInterval(seconds) {
  var n = clampInterval(seconds)
  for (var i = 0; i < INTERVALS.length; i++)
    if (INTERVALS[i] > n) return INTERVALS[i]
  return INTERVALS[0]
}

// --------------------------------------------------------------- sanitizing

// Strings out of the payload end up in QML Text, in notification arguments and
// in file names. Control characters are stripped rather than escaped — no
// field here is meant to contain any — and every field is cut to a ceiling, so
// one enormous value cannot be pasted through the whole UI.
//
// Angle brackets go the same way, and for the same reason: a title is a title,
// not markup. The panel draws every one of these fields through a Text item
// pinned to Text.PlainText, but the same strings also reach surfaces this
// plugin does not own — the bar button's tooltip, the hero's status line, the
// notification daemon's body — and those decide for themselves whether what
// they were handed looks like rich text. A payload carrying `<img src=…>` in
// an artist name would then be a museum label that makes a network request.
// Removing the characters at the boundary settles it for every consumer at
// once rather than field by field, downstream, forever.
function boundedText(value, max, fallback) {
  if (value === undefined || value === null) return fallback
  var s = String(value).replace(/[\u0000-\u001f\u007f<>]+/g, " ").trim()
  if (!s) return fallback
  return s.length > max ? s.substring(0, max) : s
}

// A URL from the payload is handed to curl and, for the art page, to xdg-open.
// Only https survives, and only the characters a URL is allowed to be made of:
// that rules out an argument with a newline or a space in it as much as it
// rules out file:// and data:.
function boundedUrl(value) {
  var u = String(value === undefined || value === null ? "" : value)
  if (u.length === 0 || u.length > MAX_URL_CHARS) return ""
  if (!/^https:\/\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]+$/.test(u)) return ""
  return u
}

// The last cheap place to bound a payload is in front of JSON.parse, so that
// is where it is bounded. Throws like the parse it wraps: every caller is
// already prepared for a response it cannot read.
function parseJson(text, maxChars) {
  var s = String(text === undefined || text === null ? "" : text)
  if (s.length > maxChars) throw new Error("payload exceeds " + maxChars + " characters")
  return JSON.parse(s)
}

// anotherboring.day serves images from two CDNs, each with its own resize
// syntax. Anything else is handed back untouched — a full-size fetch is worse
// than a thumbnail, not broken.
function thumbnailUrl(url, width) {
  var u = String(url || "")
  var w = Math.max(1, Math.round(Number(width) || 640))
  if (!u) return ""
  if (u.indexOf("cloudinary.com") !== -1 && u.indexOf("/upload/") !== -1)
    return u.replace("/upload/", "/upload/w_" + w + ",c_limit,q_auto,f_auto/")
  if (u.indexOf("imagedelivery.net") !== -1)
    return u.replace(/\/([^\/]+)$/, "/w=" + w + ",fit=contain")
  return u
}

// Cloudflare Images URLs end in a variant name (`/full`) rather than a file
// extension, so fall back to .jpg instead of writing an extensionless file.
function extensionFor(url) {
  var path = String(url || "").split("?")[0].split("#")[0]
  var last = path.substring(path.lastIndexOf("/") + 1)
  var dot = last.lastIndexOf(".")
  if (dot <= 0) return ".jpg"
  var ext = last.substring(dot).toLowerCase()
  return /^\.(jpg|jpeg|png|webp|gif|bmp|avif)$/.test(ext) ? ext : ".jpg"
}

function isSafeId(id) {
  return new RegExp("^[A-Za-z0-9_-]{1," + MAX_ID_CHARS + "}$").test(String(id || ""))
}

// Ids become file names in the cache directory, so a piece whose id is not a
// plain slug is dropped rather than sanitized: the API has never returned one,
// and a silent rename would collide two pieces onto one cached file.
function normalize(raw) {
  if (!raw || typeof raw !== "object") return null
  if (!isSafeId(raw.id)) return null
  var id = String(raw.id)
  var url = boundedUrl(raw.url)
  if (!url) return null
  var thumb = thumbnailUrl(url, 640)
  return {
    id: id,
    name: boundedText(raw.name, MAX_NAME_CHARS, "Untitled"),
    artist: boundedText(raw.artist, MAX_LINE_CHARS, "Unknown artist"),
    creationDate: boundedText(raw.creationDate, MAX_LINE_CHARS, ""),
    description: boundedText(raw.description, MAX_DESCRIPTION_CHARS, ""),
    movement: boundedText(raw.movement, MAX_LINE_CHARS, ""),
    genre: boundedText(raw.genre, MAX_LINE_CHARS, ""),
    url: url,
    thumbnailUrl: thumb,
    listThumbnailUrl: thumbnailUrl(url, 160),
    // True when no CDN rewrite matched and the "thumbnail" is the full-size
    // original. It is not a broken piece, but it is not a 640px file either,
    // so it has to be held to the wallpaper's ceilings rather than the
    // thumbnail's or it would be refused on every fetch.
    thumbnailIsOriginal: thumb === url,
    externalUrl: boundedUrl(raw.externalUrl),
    artPage: ART_PAGE + id,
    releaseDate: boundedText(raw.releaseDate, MAX_LINE_CHARS, ""),
    isToday: false
  }
}

// The triple endpoint returns { today, random: [...] }. Today comes back first
// so the panel can label index 0 without a second lookup.
function parseTriple(text) {
  var json = parseJson(text, MAX_JSON_CHARS)
  if (!json || typeof json !== "object") return []
  var out = []
  var today = normalize(json.today)
  if (today) {
    today.isToday = true
    out.push(today)
  }
  var list = Array.isArray(json.random) ? json.random : []
  var scanned = Math.min(list.length, MAX_SCANNED_RECORDS)
  for (var i = 0; i < scanned && out.length < MAX_PIECES; i++) {
    var piece = normalize(list[i])
    if (!piece) continue
    if (today && piece.id === today.id) continue
    out.push(piece)
  }
  return out
}

function parseOne(text) {
  return normalize(parseJson(text, MAX_JSON_CHARS))
}

function subtitle(piece) {
  if (!piece) return ""
  var parts = [piece.artist]
  if (piece.creationDate) parts.push(piece.creationDate)
  return parts.join("  ·  ")
}

// The panel gives the metadata two reserved lines: who and when on the first,
// what school on the second. On one line the four fields ran past the panel's
// width and elided the school off the end of every piece.
function credit(piece) {
  if (!piece) return ""
  if (!piece.creationDate) return piece.artist || ""
  return (piece.artist || "") + ", " + piece.creationDate
}

// Movement and genre as a list rather than a joined string: the panel draws
// them as separate chips, so it needs them apart.
function tags(piece) {
  if (!piece) return []
  var out = []
  if (piece.movement) out.push(piece.movement)
  if (piece.genre) out.push(piece.genre)
  return out
}

// A file name a human can recognize in ~/Pictures, with the id appended so two
// pieces sharing a title never overwrite each other.
function downloadName(piece) {
  if (!piece) return "wallpaper.jpg"
  var base = String(piece.name || "wallpaper")
    .replace(/[^A-Za-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .substring(0, 60)
  if (!base) base = "wallpaper"
  return base + "-" + piece.id + extensionFor(piece.url)
}

function pushRecent(ids, id, cap) {
  var limit = Math.min(Number(cap) || 5, MAX_RECENT)
  var out = isSafeId(id) ? [String(id)] : []
  var list = Array.isArray(ids) ? ids : []
  for (var i = 0; i < list.length && out.length < limit; i++) {
    if (list[i] !== id && isSafeId(list[i])) out.push(String(list[i]))
  }
  return out
}

// A corrupt or absent state file must not wedge the service, so every read
// degrades to empty state rather than throwing. The file is ours but the
// directory it lives in is writable, and what comes out of it is not inert:
// `current` is handed to curl and drawn in the panel, so it goes through the
// same normalize() as a fresh API record rather than being trusted for having
// been on disk. A timestamp in the future would park the rotation for as long
// as it is wrong, so it is clamped to now.
function parseState(text) {
  var empty = { lastSwitchAt: 0, recentIds: [], current: null }
  try {
    var json = parseJson(text, MAX_STATE_CHARS)
    if (!json || typeof json !== "object") return empty
    var when = Number(json.lastSwitchAt)
    var ids = []
    var list = Array.isArray(json.recentIds) ? json.recentIds : []
    for (var i = 0; i < list.length && ids.length < MAX_RECENT; i++)
      if (isSafeId(list[i])) ids.push(String(list[i]))
    return {
      lastSwitchAt: isFinite(when) && when > 0 ? Math.min(when, Date.now()) : 0,
      recentIds: ids,
      current: normalize(json.current)
    }
  } catch (e) {
    return empty
  }
}

function stateJson(state) {
  return JSON.stringify({
    version: 1,
    lastSwitchAt: Number(state.lastSwitchAt) || 0,
    recentIds: Array.isArray(state.recentIds) ? state.recentIds : [],
    current: state.current || null
  }, null, 2) + "\n"
}

function statusJson(status) {
  return JSON.stringify(status, null, 2)
}
