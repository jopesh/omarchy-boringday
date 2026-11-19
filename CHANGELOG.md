# Changelog

Notable changes to Another Boring Piece. Versions follow
[semantic versioning](https://semver.org), and each one is published as a
[GitHub release](https://github.com/jopesh/omarchy-boringday/releases) from a
`v`-prefixed tag.

## [1.1.0] — 2026-08-30

### Added

- **Build a theme from a piece.** `g`, the 󰸌 button, or
  `omarchy-shell boringday theme` hands the artwork to
  [aether](https://github.com/omacom-io/aether), which pulls sixteen colours
  out of it and retints Hyprland, waybar, mako, btop, the terminals and the
  editors, setting the piece as the wallpaper on the way through. Aether keeps
  one theme and rewrites it every time, so this is a switch rather than a
  collection; the theme that was current before it is untouched and still in
  `omarchy theme set`. Aether is optional — without it on `PATH` the action is
  drawn disabled and says so, and everything else works as before.
- Two settings for that build: `extractMode` (one of aether's palette modes,
  defaulting to `pastel`) and `lightMode` (build the light variant instead of
  the dark one). Both are validated against a list we control, and anything
  unrecognised falls back to `pastel` rather than failing the build.
- `←` / `→` now cycle the rotation period backwards and forwards while the
  cursor is on the rotation row.
- `boringday status` reports `extractMode`, `lightMode`, whether aether is
  present, and whether a theme build is in flight.

### Changed

- **Shuffle refills the list instead of setting a piece.** `s` and the 󰒟
  button now leave the wall alone: today's piece stays pinned at the top and
  the two rows behind it are replaced by two more drawn at random. Setting a
  random piece outright is still what `boringday random` and the rotation do.
- The 󰒟 and 󰑐 buttons moved onto the list's own header. The row under the
  preview acts on the piece being previewed; these act on the list.
- The bar pill says rotation with its glyph rather than its colour — 󰚰 while
  rotating, 󰋩 otherwise — so the bar keeps one colour. Right-click no longer
  shuffles.
- The rotation period is a value on the rotation row rather than four chips on
  a row of their own. A period set by hand in `shell.json` now reads as itself
  ("every 45 minutes") instead of leaving every chip unselected, and cycling
  from it lands on the nearest preset.

### Fixed

- A theme build, a background set and a scheduled rotation can no longer move
  the background symlink at the same time: a set queues behind a build and is
  applied when it exits, including when it fails, and a rotation beat that
  lands mid-build waits it out rather than being dropped.

## [1.0.0] — 2026-08-21

- First release. Today's piece plus two more in a bar pill, one click to set
  any of them, optional rotation on a schedule, `t` to keep a piece in the
  current theme, `d` to save a copy, and a `boringday` IPC target so all of it
  works with no bar widget on screen.

[1.1.0]: https://github.com/jopesh/omarchy-boringday/releases/tag/v1.1.0
[1.0.0]: https://github.com/jopesh/omarchy-boringday/releases/tag/v1.0.0
