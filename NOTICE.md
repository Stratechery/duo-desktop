# Third-party notices

Duo Desktop's own code is under the MIT licence in [LICENSE](LICENSE). It builds on Glass Act.

## Glass Act

- Upstream: https://github.com/brianmario/glassact
- Pinned commit: `4f52de7ce910c96ab259b0ebeaf48c75a2f1c7f6`, release v26.11.4 (`app/GLASSACT_COMMIT`)
- Licence: MIT, `Copyright (c) 2026 Brian Lopez`
  (https://github.com/brianmario/glassact/blob/4f52de7ce910c96ab259b0ebeaf48c75a2f1c7f6/LICENSE)

What comes from Glass Act:

| In this repository | From Glass Act | How |
|---|---|---|
| `app/DuoDesktop/SessionModel.swift`, `app/DuoDesktop/CanvasView.swift` | `Apps/iPad/SessionModel.swift`, `Apps/iPad/CanvasView.swift` | adapted; each file keeps its MIT header |
| the iPhone app's viewer library (`GlassActViewer`) and Rust AV1 decoder | the Swift package and `rust/av1` | linked at build time from a separate checkout; not copied here |
| `patches/*.patch` | the Host app (`Apps/Host/*`), the shared library (`Sources/*`), the test host, tests | changes only, as patches; Glass Act itself is downloaded from upstream at build time |

The full Glass Act licence is in [app/Notices/DuoDesktopNotice.txt](app/Notices/DuoDesktopNotice.txt).

## Carried into the built app

The app bundles and shows under About, copied from the Glass Act checkout at build time
(`app/scripts/bundle-notices.sh`): Glass Act's `LICENSE`, `Apps/Shared/Acknowledgements.txt` (Glass Act MIT,
libwebp BSD-3-Clause and patent grant, libaom BSD-2-Clause and the Alliance for Open Media Patent License 1.0,
av1gpu) and `rust/av1/THIRD_PARTY_NOTICES.md`. `app/scripts/verify-about-bundle.sh` checks a built app for
every one. Sparkle, listed in Glass Act's acknowledgements, is not part of Duo Desktop.

## Terminal versions only (`DUO_TERMINAL=YES`)

- **SwiftTerm** 1.99.3 (https://github.com/migueldeicaza/SwiftTerm), MIT.
- **swift-nio-ssh** 0.15.1 (https://github.com/apple/swift-nio-ssh) and the packages it uses (swift-nio,
  swift-crypto, swift-asn1, swift-atomics, swift-collections, swift-system), Apache License 2.0.

Their full notices are in [app/Notices/TerminalNotice.txt](app/Notices/TerminalNotice.txt), bundled only into the
Terminal versions.

## JetKVM versions only (`DUO_JETKVM=YES`)

- **WebRTC** M158 (https://webrtc.org/support/license), BSD-style licence with a patent grant, as packaged by
  **stasel/WebRTC** 158.0.0 (https://github.com/stasel/WebRTC), BSD-3-Clause.
- `jetkvm-client/` is our own code (MIT). It contains no JetKVM code; see
  [jetkvm-client/LICENSES.md](jetkvm-client/LICENSES.md).

Their full notices are in [app/Notices/JetKVMNotice.txt](app/Notices/JetKVMNotice.txt), bundled only into the
JetKVM versions.

## Basic Screen Sharing versions only (`DUO_VNC=YES`; not finished)

- **RoyalVNCKit** at commit `090b96eddeee183e9fec293c5cd881d302a4349d` (https://github.com/royalapplications/royalvnc),
  MIT, `Copyright (c) 2025 Royal Apps`. `royalvnc/` is a copy of it with our changes; its own `LICENSE` is kept there
  and the changes are listed in `royalvnc/README-DUO.md` and `royalvnc/patches/`.
- **CryptoSwift** 1.9.0 (https://github.com/krzyzanowskim/CryptoSwift), downloaded at build time, zlib-style licence.

Their full notices are in [app/Notices/BasicScreenSharingNotice.txt](app/Notices/BasicScreenSharingNotice.txt),
bundled only into those versions.
