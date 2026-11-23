// The Remote Desktop engine, linked only with the DUO_RDP switch (project notes, Remote Desktop milestone 0).
// FreeRDP 3 and OpenSSL 3, static, from scripts/build-freerdp.sh. Milestone 0 only links it and names it in About;
// nothing here connects to any PC.
#if DUO_RDP
import FreeRDP

enum RemoteDesktopEngine {
    /// FreeRDP's own version string, e.g. "3.33.1".
    static var freeRDPVersion: String { String(cString: freerdp_get_version_string()) }
}
#endif
