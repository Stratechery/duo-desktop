import SwiftUI

/// About and licences (plan §9, M4): the version, the Glass Act commit, and every notice the app must carry.
/// The notice files are copied into the bundle at build time from the pinned Glass Act checkout
/// (`scripts/bundle-notices.sh`); `scripts/verify-about-bundle.sh` checks the built app.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AboutList()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() } }
                }
        }
    }
}

extension AboutView {
    struct Notice: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    /// The bundled notice files, in the order shown. A missing file shows as missing, never silently.
    static let files: [(resource: String, ext: String, title: String)] = {
        var f: [(resource: String, ext: String, title: String)] = [
            ("Acknowledgements", "txt", "Glass Act and its components"),
            ("GlassActLICENSE", "txt", "Glass Act licence"),
            ("RustAV1ThirdPartyNotices", "md", "Glass Act AV1 decoder (Rust): third-party notices"),
            ("DuoDesktopNotice", "txt", "Code adapted from Glass Act"),
        ]
        #if DUO_TERMINAL
        f.append(("TerminalNotice", "txt", "SwiftTerm and SwiftNIO (Terminal view)"))
        #endif
        #if DUO_JETKVM
        f.append(("JetKVMNotice", "txt", "WebRTC (JetKVM view)"))
        #endif
        return f
    }()

    static func loadNotices(bundle: Bundle = .main) -> [Notice] {
        files.map { f in
            let text = bundle.url(forResource: f.resource, withExtension: f.ext)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            return Notice(id: f.resource, title: f.title, text: text ?? "Missing from this build: \(f.resource).\(f.ext)")
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static var glassActCommit: String {
        Bundle.main.url(forResource: "GLASSACT_COMMIT", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }
}

/// About's list on its own: in its own sheet from the Mac list, or pushed inside the session's info sheet.
struct AboutList: View {

    private let notices = AboutView.loadNotices()
    @AppStorage(DuoPasteboard.autoSendKey) private var autoSend = false

    var body: some View {
            List {
                Section {
                    LabeledContent("Version", value: AboutView.version)
                    LabeledContent("Glass Act") {
                        Text(String(AboutView.glassActCommit.prefix(12))).font(.body.monospaced())
                    }
                } footer: {
                    Text("Duo Desktop is built on Glass Act’s viewer library, pinned to this commit.")
                }
                Section {
                    // The picture's rate, moved here from the keys sheet (it read "—" outside a session).
                    LabeledContent("Picture", value: SessionModel.app.throughput ?? "—")
                        .accessibilityIdentifier("pictureRate")
                }
                Section {
                    Toggle("Send iPhone Copies Automatically", isOn: $autoSend)
                } header: {
                    Text("Clipboard")
                } footer: {
                    // The owner 2026-11-21 on the old text: "This refers to a setting that doesn't exist." iOS shows the
                    // Paste from Other Apps row only after the app has once read a copy from another app and iOS
                    // has asked; the app reads only with this on, after a copy made elsewhere during a session.
                    Text("Mac copies always come to this iPhone, and the Paste key sends this iPhone’s clipboard. "
                         + "Turn this on to also send what you copy in other apps. The first time, iOS asks "
                         + "whether Duo Desktop may paste from other apps; after that the choice is in "
                         + "Settings > Duo Desktop.")
                }
                Section("Licences") {
                    ForEach(notices) { n in
                        NavigationLink(n.title) {
                            ScrollView {
                                Text(n.text)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                            }
                            .navigationTitle(n.title)
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// What the screen shows while the app is locked: nothing of the Macs, one button.
struct LockedView: View {
    let lock: AppLock
    private let method = UnlockMethod.current

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: method.symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Duo Desktop is Locked")
                .font(.title2.weight(.semibold))
            Button {
                Task { await lock.unlock() }
            } label: {
                // White on the orange accent fill, forced so the system never picks a dark label (the owner 2026-11-21:
                // "Let's do white first and I will decide.").
                Text(method.unlockButton).foregroundStyle(.white).frame(minWidth: 220)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(lock.busy)
            if let m = lock.message {
                Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
