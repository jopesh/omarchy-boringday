# Another Boring Piece — for Omarchy

Hand-picked fine art from [anotherboring.day](https://anotherboring.day) as your
Omarchy background. A pill in the bar opens today's piece plus two more, one
click sets any of them, and an optional schedule keeps the wall moving.

This is the Omarchy port of the
[Raycast extension](https://github.com/raycast/extensions/tree/main/extensions/another-boring-piece)
of the same name. It talks to the same public endpoints and needs no account,
no API key, and no helper app.

## Install

```bash
omarchy plugin add https://github.com/johnschmidt/omarchy-anotherboring-day.git --enable
```

Or, for a checkout you already have on disk:

```bash
git clone <repo> ~/.config/omarchy/plugins/boringday.wallpapers
omarchy-shell shell rescanPlugins
omarchy plugin enable boringday.wallpapers right
```

Requires Omarchy 4 (the Quickshell-based `omarchy-shell`), plus `curl` and
`jq`, which Omarchy already ships.

## Using it

Click the 󰋩 pill in the bar to open the panel. The pill turns to the accent
color while automatic rotation is on. Right-click shuffles a random piece
without opening anything; middle-click refetches today's set.

In the panel:

| Key       | Action                                    |
|-----------|-------------------------------------------|
| `↑` / `↓` | Move the cursor; browsing a piece previews it |
| `Enter`   | Set the piece under the cursor as the background |
| `s`       | Shuffle — set a random piece               |
| `d`       | Save a copy of the previewed piece to your pictures folder |
| `e`       | Expand or collapse a truncated description |
| `o`       | Open the piece's page on anotherboring.day |
| `r`       | Fetch today's set again                    |
| `a`       | Toggle automatic rotation                  |
| `i`       | Cycle the rotation interval                |
| `Esc`     | Close                                      |

Descriptions are clamped to three lines; when there is more, a **Show more**
link appears under them (`e` toggles it from the keyboard). Expanding is the
only thing that changes the popup's content height — see below.

**Recently set** lists the last few pieces you used; pick one to put it back.

### A note on layout

The popup is a fixed size and never resizes. Every block that renders
per-piece text — title, credit, description, status — reserves a height
measured from the theme's own font, and holds it whether the text is short,
long, or missing. Browsing the three pieces therefore swaps pixels and moves
nothing: no reflow, no jumping, no resizing card. Content that legitimately
grows — an expanded description, a new history row — extends the scroll area
rather than the window.

## From the command line

The service registers a `boringday` IPC target, so everything works without the
bar widget on screen — from a keybinding, a script, or over ssh into the session.

```bash
omarchy-shell boringday random          # set a random piece now
omarchy-shell boringday today           # set today's piece
omarchy-shell boringday auto toggle     # on | off | toggle
omarchy-shell boringday interval 1800   # seconds
omarchy-shell boringday current         # what's on the wall
omarchy-shell boringday status          # JSON: interval, next change, errors
omarchy-shell boringday refresh         # refetch today's set
```

A Hyprland binding, in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER SHIFT, W, Another boring piece, exec, omarchy-shell boringday random
```

An entry in `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
{
  "title": "Boring piece",
  "icon": "󰋩",
  "action": "omarchy-shell boringday random"
}
```

## Settings

Settings live inline on the plugin's entry in `~/.config/omarchy/shell.json`,
the same place every other bar widget keeps its settings. The panel's toggle
and the `boringday auto` IPC call both write here, so there is one switch, not
three.

```jsonc
{ "id": "boringday.wallpapers",
  "autoRotate": true,        // rotate on a schedule
  "intervalSeconds": 3600,   // 300 – 86400; the panel cycles 30m / 1h / 6h / 1d
  "notify": true }           // notification naming each piece as it changes
```

The interval is wall-clock, not uptime: the time of the last change is
persisted, so restarting the shell resumes the schedule instead of granting a
fresh hour. Rotation only advances while `omarchy-shell` is running — there is
no timer outside the session.

## Where things land

| Path                                         | What                                        |
|----------------------------------------------|---------------------------------------------|
| `~/.cache/omarchy/boringday/wallpapers/`      | Full-size images, newest 20 kept            |
| `~/.cache/omarchy/boringday/thumbs/`          | Panel previews, newest 60 kept              |
| `~/.local/state/omarchy/boringday/state.json` | History, last change, recently-seen ids     |
| `$(xdg-user-dir PICTURES)`                    | Copies saved with `d`, never overwritten    |

Setting a piece calls `omarchy-theme-bg-set`, which repoints Omarchy's current
background symlink — the same path the built-in background switcher uses.

**One consequence worth knowing:** the background belongs to the current theme.
Switching themes, or cycling with `omarchy theme bg next`, moves you back to
that theme's own backgrounds. Re-open the panel and press `Enter` (or bind
`boringday current`) to put the piece back. If you would rather a piece join a
theme's rotation permanently, save it with `d` and copy it into
`~/.config/omarchy/backgrounds/<theme>/`.

## How it fits together

Two entry points from one manifest:

- **`Service.qml`** (`kind: service`) — headless, loaded once per session. Owns
  every fetch, the download cache, the rotation schedule, the persisted
  history, and the `boringday` IPC target.
- **`Panel.qml`** (`kind: bar-widget`) — the bar pill and its popup. Pure view:
  it reads the service and calls into it. A bar surface exists per monitor, so
  the widget deliberately owns no state — two screens show the same thing, and
  closing the panel stops nothing.

`Model.js` holds the parts worth reading on their own: the two CDN thumbnail
transforms, response parsing, interval formatting, and state serialization.
Images are fetched to disk with `curl` and rendered from local files, so a
dropped network degrades to a stale preview rather than a broken one.

## License

MIT. The artwork itself belongs to anotherboring.day and the respective
museums and estates; this plugin only points your desktop at it.
