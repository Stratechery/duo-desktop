// A PC's Remote Desktop screen, view only (project notes, milestone 1): the password typed each time
// (saved passwords are milestone 3), the takeover notice before each connect, a plain first-use trust prompt, and
// the PC's picture in Whole Screen (aspect fit, black edges) where a Mac's picture goes. Linked only with DUO_RDP.
#if DUO_RDP
import AVFoundation
import SwiftUI
import UIKit

struct RemoteDesktopScreen: View {
    let entry: MacEntry
    let store: MacStore
    let leave: () -> Void

    enum Phase: Equatable {
        case password
        case connecting
        case live
        case ended(String?)
    }

    @State private var phase: Phase = .password
    @State private var password = ""
    @State private var takeover = false
    @State private var trustFingerprint: String?
    @State private var session: RemoteDesktopSession?
    @State private var picture = RDPPictureView()
    /// The session thread waits here for the trust answer.
    @State private var trustAnswer = TrustAnswer()

    private var current: MacEntry { store.entry(entry.id) ?? entry }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea(edges: .bottom)
                RDPPicture(view: picture)
                    .opacity(phase == .live ? 1 : 0)
                    .accessibilityIdentifier("rdpPicture")
                if phase != .live { panel }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                TopBarItem { BackToMacsButton(action: goBack) }
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                TopBarItem { TopRowName(mac: entry.name, screen: "Remote Desktop", notice: nil, maxWidth: 260) }
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0) }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        .alert("Connect to \(entry.name)?", isPresented: $takeover) {
            Button("Connect") { connect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RDPTrust.takeoverText(entry.name))
        }
        .alert("Trust \(entry.name)?", isPresented: Binding(get: { trustFingerprint != nil },
                                                            set: { if !$0 { answerTrust(false) } })) {
            Button("Trust and Connect") { answerTrust(true) }
            Button("Cancel", role: .cancel) { answerTrust(false) }
        } message: {
            Text("This is the first time this iPhone connects to \(entry.name). Windows made its own certificate, so no one else can vouch for it. Check that this fingerprint matches the PC's, then trust it. After this the app connects only to this certificate.\n\nSHA-256\n\(trustFingerprint ?? "")")
        }
        .onDisappear { session?.stop() }
        .onChange(of: AppAccess.isOpen) { _, open in if !open { session?.stop() } }
    }

    @ViewBuilder private var panel: some View {
        VStack(spacing: 16) {
            switch phase {
            case .password:
                Text("Sign in to \(entry.name) as \(current.rdpUser ?? "")")
                    .font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    .frame(maxWidth: 360)
                    .submitLabel(.go)
                    .onSubmit(askThenConnect)
                    .accessibilityIdentifier("rdpPassword")
                Button("Connect", action: askThenConnect)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("rdpConnect")
                Text("\(current.rdpScreen.size.label), text at \(current.rdpScreen.textSize.label)")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            case .connecting:
                ProgressView().tint(.white)
                Text("Connecting to \(entry.name)…").foregroundStyle(.white)
            case let .ended(why):
                Text(why ?? "Disconnected.").foregroundStyle(.white).multilineTextAlignment(.center)
                    .accessibilityIdentifier("rdpEnded")
                Button("Try Again") { phase = .password }
                    .buttonStyle(.borderedProminent)
                OtherWaysOffer(entry: current, current: .screenSharing, onDark: true) { session?.stop() }
            case .live:
                EmptyView()
            }
        }
        .padding(24)
    }

    private func askThenConnect() {
        guard !password.isEmpty else { return }
        if current.rdpSkipTakeover == true { connect() } else { takeover = true }
    }

    private func connect() {
        // Nothing reaches the PC while the app is locked (as the JetKVM).
        guard AppAccess.isOpen, let host = current.address(.tailscale) ?? current.address(.home) else {
            phase = .ended("Unlock the app, and check the PC's address in its settings.")
            return
        }
        let e = current
        let s = RemoteDesktopSession(.init(host: host, port: e.rdpPortValue, user: e.rdpUser ?? "",
                                           password: password, screen: e.rdpScreen,
                                           savedCertificate: e.rdpCertificate))
        password = ""
        let answer = trustAnswer
        s.onState = { st in
            switch st {
            case .connecting: phase = .connecting
            case .live: phase = .live
            case let .ended(why): phase = .ended(why); session = nil
            }
        }
        s.onFrame = { [picture] pb in picture.show(pb) }
        s.askTrust = { fp in
            DispatchQueue.main.async { trustFingerprint = fp }
            return answer.wait()
        }
        s.trusted = { fp in store.update(e.id) { $0.rdpCertificate = fp } }
        session = s
        phase = .connecting
        s.start()
    }

    private func answerTrust(_ ok: Bool) {
        guard trustFingerprint != nil else { return }
        trustFingerprint = nil
        trustAnswer.give(ok)
    }

    private func goBack() {
        session?.stop()
        trustAnswer.give(false)
        leave()
    }
}

/// The trust prompt's answer, handed from the main thread to the waiting session thread.
final class TrustAnswer: @unchecked Sendable {
    private let sema = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value = false
    func give(_ ok: Bool) { lock.withLock { value = ok }; sema.signal() }
    func wait() -> Bool { sema.wait(); return lock.withLock { value } }
}

/// The PC's picture: an AVSampleBufferDisplayLayer, aspect fit with black edges (as the JetKVM's picture).
final class RDPPictureView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        display.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ pb: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if display.sampleBufferRenderer.status == .failed { display.sampleBufferRenderer.flush() }
        display.sampleBufferRenderer.enqueue(sample)
    }
}

struct RDPPicture: UIViewRepresentable {
    let view: RDPPictureView
    func makeUIView(context: Context) -> RDPPictureView { view }
    func updateUIView(_ uiView: RDPPictureView, context: Context) {}
}
#endif
