# Another Boring Piece

An Omarchy shell plugin (Quickshell / QML). `Service.qml` owns state and IPC,
`Panel.qml` is the bar widget and its popup, `Model.js` holds pure helpers.

## Versions and releases

`manifest.json`'s `version`, the newest numbered section of `CHANGELOG.md` and
the latest `v`-tag always agree.

- Unreleased work is described under `## [Unreleased]` at the top of
  `CHANGELOG.md`. The manifest version does not change for it.
- Cutting a release is one commit on `main`: rename `[Unreleased]` to
  `[x.y.z] — YYYY-MM-DD`, add its link at the bottom, and set
  `manifest.json` to `x.y.z`. Then tag `vx.y.z` on that commit and push the tag;
  `.github/workflows/release.yml` publishes the release from that section.
- New features or settings are a minor bump; fixes only are a patch.
- `.github/workflows/version.yml` fails any push or pull request where the
  manifest and the changelog disagree.
