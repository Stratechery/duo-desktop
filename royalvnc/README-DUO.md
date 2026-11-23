# Duo Desktop's copy of RoyalVNCKit

RoyalVNCKit (MIT, Royal Apps, https://github.com/royalapplications/royalvnc) at commit
`090b96eddeee183e9fec293c5cd881d302a4349d` (`ROYALVNC_COMMIT`), the last before its owner archived it on 2026-10-05.
Duo Desktop's Basic Screen Sharing uses it (build switch `DUO_VNC`, `app/project-vnc.yml`). Upstream fixes nothing now;
this copy is ours to keep working.

**What was copied, unchanged at first** (the commit "RoyalVNCKit copied verbatim"): `LICENSE`, `README.md`, `USAGE.md`,
`Package.swift`, and `Sources/RoyalVNCKit`, `Sources/RoyalVNCKitC`, `Sources/Z`, `Sources/d3des`. Not copied: the demos,
the bundled zlib for Windows, the bindings, the design files, the Android scripts.

**Our changes** are all in `patches/0001-duo-desktop-changes.patch` (upstream files only; regenerate it with
`git diff <verbatim commit> -- Sources Package.swift` after any change) and marked "Duo Desktop" in the source:
1. `Package.swift` rewritten: Apple platforms only, static library, upstream CryptoSwift pinned `exact: "1.9.0"` (not
   Royal's fork branch), no Cstb (upstream used it only on Linux, Windows and Android), no demos; a test target.
2. Sign-in fixes, after upstream issues #41 to #43 and the unmerged #48:
   #41 user name and password over 63 UTF-8 bytes, or holding a NUL, are refused, not cut by characters;
   #42 Diffie-Hellman values keep the server's width (a leading zero byte no longer fails the sign-in);
   #43 the server's key size, prime, generator and peer key are checked before any arithmetic.
3. Mac-account sign-in only: the security choice takes type 30 and nothing else, and refuses a server without it
   (`VNCError.AuthenticationError.macAccountSignInNotOffered`) before any credential is asked for.

**Tests:** `swift test` here (5 tests, `Tests/RoyalVNCKitTests/DuoSignInTests.swift`; no network).

**Licences:** `app/Notices/BasicScreenSharingNotice.txt` (RoyalVNCKit, CryptoSwift 1.9.0, D3DES; zlib is the system's;
stb is not included), shown in Settings → About in the `DUO_VNC` build. Source headers are kept as they were.
