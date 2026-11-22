# Licences — jetkvm-client

This package is MIT (same as Duo Desktop). It contains no JetKVM code: the JetKVM device software and web UI
(`jetkvm/kvm`) are GPL-2.0, so only message layouts (facts) were read from it and the Swift was written from scratch.
Source read for the layouts: https://github.com/jetkvm/kvm at `22d610af59ef199f444f8993c06377415d6296e5`
(`internal/hidrpc/*.go`, `web.go`, `webrtc.go`, `session_input.go`, `jsonrpc.go`).

| Dependency | Pinned | Licence | Notes |
|---|---|---|---|
| `stasel/WebRTC` (Swift package) | exact `158.0.0`, revision `3b7fca3bf68209386d7c9818235bd178281f90af` | BSD-3-Clause (packaging) | binary target `WebRTC-M158.xcframework.zip`, checksum `dd26ba28fb9c8dbc82f4be3085e8d112a4e2a4e654e1786a9977a748c24c4912` |
| WebRTC itself (inside the xcframework) | M158 | BSD-style, "Copyright (c) 2011, The WebRTC project authors" + patent grant; https://webrtc.org/support/license | the app must show this notice (Acknowledgements) |

No other dependencies. Nothing GPL. Apple frameworks only otherwise (Foundation, CoreGraphics, CoreVideo, ImageIO).
