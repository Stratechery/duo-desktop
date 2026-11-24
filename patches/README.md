# Patches to Glass Act

Glass Act (https://github.com/brianmario/glassact, MIT) is pinned at the commit in `app/GLASSACT_COMMIT` (release v26.11.4).
Nothing of Glass Act is copied into this repository; these patches change it at build time.

- `app/GLASSACT_PATCHES`: the patches the iPhone app's viewer library is built with. `app/scripts/fetch-glassact.sh`
  applies them to `vendor/glassact`, and `app/scripts/check-glassact.sh` refuses a copy with anything else in it.
- `patches/HOST_PATCHES`: the same list plus one Host-only patch, for the Mac Host. `host/prepare-host.sh` applies
  them to `vendor/glassact-host`.

Every change inside the patched files is marked `Duo Screens build` (the project's old name).

| Patch | What it does |
|---|---|
| `testhost-input-log-and-release.patch` | Test host only: logs every key, click and scroll it receives, and lets go of held keys and buttons when a session ends, as the real Host does. Used by the UI tests. |
| `testhost-picture-size.patch` | Test host only: `--picture-steps` sends a smaller picture than the screen, as the real Host does on a slow link. |
| `host-main-display-only.patch` | Host: shares the main display by default; "Choose Display…" is hidden; never falls back to "the first display listed". |
| `glassact-multiscreen-M2.patch` | Library + test host: messages to list a Mac's screens and pick one (DISPLAY_LIST, DISPLAY_SELECT, DISPLAY_SELECTED). `glassact-testhost --displays` shows four fake screens. |
| `host-multiscreen-M3.patch` | Host: shares the screen the phone picked (main if none), sends the list when screens change, keeps the pointer and clicks inside the shown screen. Resolution and virtual-display modes become Scale. |
| `glassact-typing-notices.patch` | Library + Host: tells the phone when the Mac's screen is locked, and where the text cursor is (a position only; never any text). |
| `glassact-overview-snapshots.patch` | Library + Host: small still pictures of each screen for the phone's overview. |
| `glassact-auto-unlock.patch` | Library + Host: the phone can send the Mac's password to unlock a locked screen. The Host types it only if the screen is still locked, and never logs it. |
| `duo-terminal-key-install-on-main.patch` | Library + Host: the phone can ask the Host to add the phone's SSH key to the Mac account's `~/.ssh/authorized_keys`, for the Terminal view. Only for a phone the Mac's user approved, that may control the Mac (not "view only", not an agent). Also the review fixes: each message is handled only by the connection that sent it. |
| `host-macos15-setup-window.patch` | Host only: fixes a crash of the first-start setup window on macOS 15. |

All the new messages are additive: an older Host ignores them, and an older app never sends them.
