# Another Boring Piece — for Omarchy

![Preview Image](preview.png)

Hand-picked fine art from [anotherboring.day](https://anotherboring.day) as your
Omarchy background. A pill in the bar opens today's piece plus two more, one
click sets any of them, and an optional schedule keeps the wall moving.

The Omarchy port of the
[Raycast extension](https://github.com/raycast/extensions/tree/main/extensions/another-boring-piece)
of the same name: same public endpoints, no account, no API key.

Requires Omarchy 4 (the Quickshell-based `omarchy-shell`).
[Aether](https://github.com/omacom-io/aether) is optional, and only for building a theme out of
a piece.

## Install

```bash
omarchy plugin add https://github.com/jopesh/omarchy-boringday.git --enable
```

Or from a checkout — the directory must be named for the plugin id, since that
is where the shell looks:

```bash
git clone https://github.com/jopesh/omarchy-boringday.git \
  ~/.config/omarchy/plugins/boringday.wallpapers
omarchy-shell shell rescanPlugins
omarchy plugin enable boringday.wallpapers right
```

## Using it

Click the 󰋩 pill to open the panel; middle-click refetches today's set. The
pill becomes 󰚰 while rotation is on — the glyph carries the state, so the bar
keeps one colour.

The three rows are a selector: browsing previews a piece, and the wall only
changes when you set it. Under the preview, **Set as background** puts the
previewed piece on the wall and **More** holds everything else you can do with
it: save a copy, add it to the current theme, build a theme from it, or open
its page. The row marked *on wall* is the one on screen.

**Shuffle**, on the list's header, refills the list rather than setting anything: today's piece stays pinned at
the top and the two rows behind it are replaced by two more drawn at random.
Setting a random piece outright is still what `boringday random` and the
rotation do.

| Key       | Action                                            |
|-----------|---------------------------------------------------|
| `↑` / `↓` | Move the cursor — browsing a piece previews it     |
| `Enter`   | Set the previewed piece as the background          |
| `s`       | Shuffle — refill the list with new pieces          |
| `t`       | Add the previewed piece to the current theme       |
| `g`       | Build a desktop theme from the previewed piece     |
| `d`       | Save a copy to your pictures folder                |
| `e`       | Expand or collapse a truncated description         |
| `o`       | Open the piece's page on anotherboring.day         |
| `m`       | Open the More menu                                 |
| `r`       | Fetch today's set again                            |
| `a`       | Toggle automatic rotation                          |
| `←` / `→` | Cycle the rotation period, cursor on that row       |
| `i`       | Cycle the rotation period                          |
| `Esc`     | Close                                              |

### Keeping a piece

Setting a piece moves Omarchy's current-background symlink, and that symlink
belongs to the theme — switch themes, or cycle with `omarchy theme bg next`,
and the piece is gone.

`t` makes it permanent: the image is copied into
`~/.config/omarchy/backgrounds/<theme>/`, the folder that rotation reads from,
so the piece becomes one of the theme's own backgrounds. Adding the same piece
twice does nothing, and if it is the piece on screen the symlink moves onto the
permanent copy.

### Building a theme from a piece

`g`, or **More → Build a theme from it**, hands the piece to [aether](https://github.com/omacom-io/aether) and lets
it retint the desktop from the artwork: sixteen colours out of the image and
into Hyprland, waybar, mako, btop, the terminals and the editors, with the
piece itself set as the wallpaper on the way through.

Aether keeps one theme of its own and rewrites it every time, so this is a
switch rather than a collection — building from another piece replaces what the
last one wrote. The theme that was current before it is untouched and still in
`omarchy theme set`, which is how you go back.

Aether is optional. Without it on `PATH` the action is drawn disabled and says
so; everything else in the plugin works as before.

## From the command line

The service registers a `boringday` IPC target, so everything works with no bar
widget on screen — from a keybinding, a script, or over ssh into the session.

```bash
omarchy-shell boringday random          # set a random piece now
omarchy-shell boringday today           # set today's piece
omarchy-shell boringday install         # add the piece on the wall to this theme
omarchy-shell boringday theme           # build a desktop theme from the piece on the wall
omarchy-shell boringday auto toggle     # on | off | toggle
omarchy-shell boringday interval 1800   # seconds (rotates to random pieces)
omarchy-shell boringday rotateTo today  # follow the daily release; or random
omarchy-shell boringday current         # what's on the wall
omarchy-shell boringday status          # JSON: interval, next change, errors
omarchy-shell boringday refresh         # refetch today's set
```

A Hyprland binding, in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER SHIFT, W, Another boring piece, exec, omarchy-shell boringday random
```

## Settings

Settings live inline on the plugin's entry in `~/.config/omarchy/shell.json`,
the same place every other bar widget keeps its settings — so the panel's
toggle and the `boringday auto` call are the same switch.

```jsonc
{ "id": "boringday.wallpapers",
  "autoRotate": true,        // rotate on a schedule
  "intervalSeconds": 3600,   // the panel cycles 1h / 3h / 12h / 24h
  "rotateTo": "random",      // or "today": follow the daily release instead
  "notify": true,            // notification naming each piece as it changes
  "extractMode": "normal",   // how aether reads a palette out of the artwork
  "lightMode": false }       // build the light variant instead of the dark one
```

`extractMode` is one of aether's own modes. It defaults to `normal`, which
leaves the choice to aether: it decides between a monochrome and a chromatic
palette by analysing the image. `pastel` gives a soft low-chroma reading that
keeps a desktop built from a painting habitable, while `monochromatic`,
`analogous`, `material`, `colorful`, `muted`, `bright`, `complementary`,
`triadic`, `split-complementary`, `tetradic`, `fire`, `ocean`, `forest`,
`earthtone`, `neon`, `sunset`, `vaporwave`, `midnight`, `aurora`,
`high-contrast` and `duotone` each force a treatment; `aether --list-modes`
describes them. Both settings apply only to themes built from a piece, and
anything unrecognised falls back to `normal`.

The panel offers the presets and today's piece in a dropdown. A value set by
hand is shown as itself — `"intervalSeconds": 2700` reads "Every 45
minutes" — and matches no row. Cycling with `i` or `←` / `→` from one lands
on the nearest preset.

The interval is wall-clock, not uptime: the last change is persisted, so
restarting the shell resumes the schedule rather than granting a fresh hour.
Rotation only advances while `omarchy-shell` is running.

## Where things land

| Path                                          | What                                              |
|-----------------------------------------------|---------------------------------------------------|
| `~/.cache/omarchy/boringday/wallpapers/`      | Full-size images, newest 20 kept                  |
| `~/.cache/omarchy/boringday/thumbs/`          | Panel previews, newest 60 kept                    |
| `~/.local/state/omarchy/boringday/state.json` | Last change, current piece, recently-seen ids     |
| `~/.config/omarchy/backgrounds/<theme>/`      | Pieces added with `t`, kept until you delete them |
| `$(xdg-user-dir PICTURES)`                    | Copies saved with `d`, never overwritten          |
| `~/.config/omarchy/themes/aether/`            | The theme `g` builds, rewritten on every build    |

The list of pieces is not persisted — it is rebuilt on every start. The piece
on your wall is, whole record and all, so the panel opens describing what is on
screen without asking the server for anything.

## How it fits together

`Service.qml` is headless and loaded once per session: it owns every fetch, the
caches, the rotation schedule, and the `boringday` IPC target. `Panel.qml` is
the bar pill and its popup, and pure view — a bar surface exists per monitor,
so it owns no state. `Model.js` holds the parts worth reading alone: the CDN
thumbnail transforms, response parsing, and state serialization.

Images are fetched to disk with `curl` and rendered from local files, so a
dropped network degrades to a stale preview rather than a broken one. Nothing
off the network is taken on trust: responses have a size `curl` refuses to
exceed mid-download, records are cut to a bounded shape, and every image is
checked against its own header — type and decoded dimensions — before it is
previewed or set. The ceilings are the `MAX_` constants at the top of
`Model.js`.

## License

MIT. The artwork belongs to anotherboring.day and the respective museums and
estates; this plugin only points your desktop at it.
