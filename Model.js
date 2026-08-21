.pragma library

// Pure helpers for the anotherboring.day plugin: endpoints, URL rewriting,
// response parsing, and state (de)serialization. Nothing here touches QML or
// the filesystem, so the fiddly parts — thumbnail transforms, malformed
// payloads, an interval a user typed by hand — can be reasoned about alone.

var API_TRIPLE = "https://service.anotherboring.day/api/wallpapers/raycast-triple"
var API_RANDOM = "https://service.anotherboring.day/api/wallpapers/random-human"
var ART_PAGE = "https://anotherboring.day/art/"

// The presets the panel cycles through. A value set by hand in shell.json is
// honored as-is; intervalLabel() just describes whatever it finds.
var INTERVALS = [1800, 3600, 21600, 86400]
var MIN_INTERVAL = 300
var MAX_INTERVAL = 86400

function clampInterval(seconds) {
  var n = Number(seconds)
  if (!isFinite(n) || n <= 0) return 3600
  return Math.max(MIN_INTERVAL, Math.min(MAX_INTERVAL, Math.round(n)))
}

function intervalLabel(seconds) {
  var n = clampInterval(seconds)
  if (n % 86400 === 0) return plural(n / 86400, "day")
  if (n % 3600 === 0) return plural(n / 3600, "hour")
  if (n % 60 === 0) return plural(n / 60, "minute")
  return plural(n, "second")
}

function plural(count, unit) {
  return count + " " + unit + (count === 1 ? "" : "s")
}

// Cycle to the next preset. An off-preset value snaps to the first preset
// larger than it, so a hand-edited 45m becomes 1h rather than jumping to 30m.
function nextInterval(seconds) {
  var n = clampInterval(seconds)
  for (var i = 0; i < INTERVALS.length; i++)
    if (INTERVALS[i] > n) return INTERVALS[i]
  return INTERVALS[0]
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
  return /^[A-Za-z0-9_-]+$/.test(String(id || ""))
}

// Ids become file names in the cache directory, so a piece whose id is not a
// plain slug is dropped rather than sanitized: the API has never returned one,
// and a silent rename would collide two pieces onto one cached file.
function normalize(raw) {
  if (!raw || typeof raw !== "object") return null
  if (!isSafeId(raw.id)) return null
  var id = String(raw.id)
  var url = String(raw.url || "")
  if (url.indexOf("https://") !== 0) return null
  return {
    id: id,
    name: String(raw.name || "Untitled"),
    artist: String(raw.artist || "Unknown artist"),
    creationDate: String(raw.creationDate || ""),
    description: String(raw.description || ""),
    movement: String(raw.movement || ""),
    genre: String(raw.genre || ""),
    url: url,
    thumbnailUrl: thumbnailUrl(url, 640),
    listThumbnailUrl: thumbnailUrl(url, 160),
    externalUrl: String(raw.externalUrl || ""),
    artPage: ART_PAGE + id,
    releaseDate: String(raw.releaseDate || ""),
    isToday: false
  }
}

// The triple endpoint returns { today, random: [...] }. Today comes back first
// so the panel can label index 0 without a second lookup.
function parseTriple(text) {
  var json = JSON.parse(String(text || ""))
  var out = []
  var today = normalize(json.today)
  if (today) {
    today.isToday = true
    out.push(today)
  }
  var list = Array.isArray(json.random) ? json.random : []
  for (var i = 0; i < list.length; i++) {
    var piece = normalize(list[i])
    if (!piece) continue
    if (today && piece.id === today.id) continue
    out.push(piece)
  }
  return out
}

function parseOne(text) {
  return normalize(JSON.parse(String(text || "")))
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
  var parts = [piece.artist]
  if (piece.creationDate) parts.push(piece.creationDate)
  return parts.join("  ·  ")
}

function provenance(piece) {
  if (!piece) return ""
  var parts = []
  if (piece.movement) parts.push(piece.movement)
  if (piece.genre) parts.push(piece.genre)
  return parts.join("  ·  ")
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
  var limit = Number(cap) || 5
  var out = [String(id)]
  var list = Array.isArray(ids) ? ids : []
  for (var i = 0; i < list.length && out.length < limit; i++) {
    if (list[i] !== id) out.push(String(list[i]))
  }
  return out
}

// A corrupt or absent state file must not wedge the service, so every read
// degrades to empty state rather than throwing.
function parseState(text) {
  var empty = { lastSwitchAt: 0, recentIds: [], current: null }
  try {
    var json = JSON.parse(String(text || ""))
    if (!json || typeof json !== "object") return empty
    return {
      lastSwitchAt: Number(json.lastSwitchAt) || 0,
      recentIds: Array.isArray(json.recentIds) ? json.recentIds.map(String) : [],
      current: json.current && typeof json.current === "object" ? json.current : null
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
