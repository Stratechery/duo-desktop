# jetkvm-client — JetKVM native client engine for Duo Desktop

Swift package, no UI. Speaks the JetKVM's own web-app protocol over plain HTTP + WebRTC:
local login → signaling WebSocket → WebRTC (H.264 video in; `rpc`, `hidrpc`, `hidrpc-unreliable-ordered` data
channels out) → keyboard and pointer as hidrpc binary messages. iOS 16+ / macOS 13+.

Targets:
- `JetKVMProtocol` — pure Swift wire formats (hidrpc encode/decode, signaling JSON, login cookie, rpc events). Unit tested.
- `JetKVMClient` — `JetKVMSession`, the live session (depends on `stasel/WebRTC` 158.0.0, see `LICENSES.md`).
- `jetkvm-probe` — command-line live check.

## Surface

```swift
let s = JetKVMSession(host: "jetkvm.example.ts.net", password: pw)  // pw from Keychain; nil = no-password mode
Task { for await st in s.states { … } }     // .connecting(step:) .live(deviceVersion:) .takenOver .failed(JetKVMError) .disconnected
Task { for await f in s.frames { … } }      // JetKVMFrame: width, height, pixelBuffer (CVPixelBuffer), cgImage()
try await s.connect()                       // login + signaling + hidrpc handshake + first frame; throws JetKVMError
s.videoTrack?.add(rtcMTLVideoView)          // or show the track directly with WebRTC's Metal view
s.sendPointer(x: 0.5, y: 0.5)               // absolute, normalised 0…1; buttons: [.primary] to press, [] to release
s.sendPointerDelta(dx: 10, dy: 0)           // relative move (see "Pointer on multi-display Macs")
s.click(x:y:) · s.sendScroll(dy:dx:)        // wheel steps −127…127
s.sendKey(usage: 0xE1, down: true) · s.tapKey(usage:) · s.sendKeyboard(modifiers:keys:)   // USB HID usages
s.disconnect()                              // releases the JetKVM for other viewers
```

Errors: `wrongPassword`, `loginFailed(status:)`, `unreachable`, `signaling`, `webRTC`, `timeout`,
`unsupportedFirmware(hidrpcVersion:)` (the device answered the hidrpc handshake with a version other than 1; no answer at all ends as `timeout`).

Taken over: the device sends JSON-RPC `otherSessionConnected` on `rpc` when another viewer connects, then closes us;
the session reports `.takenOver` and tears down.

## Pointer on multi-display Macs

On a two-display Mac (2026-11-21), macOS mapped the JetKVM's absolute pointer to the **second** display (the 1920×1080 bench
screen at x=1920), not to the JetKVM's own HDMI display (main, 1920×1200): absolute (0.53, 0.52) put the real
cursor at 2938,562 = bench-screen origin + 3 %/2 %. Relative moves follow the cursor wherever it is. The app wiring
should use relative moves (or ask the owner) on Macs with more than one display.

## Live check

```
swift build
.build/debug/jetkvm-probe <host> <password-file> <out.png>     # JETKVM_TRACE=1 prints protocol events
```
Takes the JetKVM from any other viewer (one session at a time) for about 5 seconds.
