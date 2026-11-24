// Milestone 4 of the Remote Desktop plan (the Windows key band and shortcuts), proven without a PC: one
// test per band key. On a PC the key goes through the same keyboard engine a Mac's session uses, then `RDPInput`,
// and must come out as the Windows chord in set-1 scan codes, pressed and released in order. On a Mac the same key
// must still send the Mac chord. No connection is made.
import XCTest
@testable import DuoDesktop
import GlassActSession

@MainActor
final class RemoteDesktopM4Tests: XCTestCase {
    private final class Recorder: RDPOutput {
        var events: [RDPEvent] = []
        func send(_ event: RDPEvent) { events.append(event) }
    }

    /// What a Mac's session sends: (down?, Mac key code).
    private final class MacRecorder: InputSink {
        var keys: [String] = []
        func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
            if kind == InputKind.keyDown { keys.append("v\(x)") }
            if kind == InputKind.keyUp { keys.append("^\(x)") }
        }
    }

    private var rec = Recorder()
    private var pc: MacKeyboardEngine!
    private var mac: MacKeyboardEngine!
    private var macRec = MacRecorder()

    override func setUp() {
        rec = Recorder()
        let input = RDPInput()
        input.isOpen = { true }
        input.output = rec
        pc = MacKeyboardEngine(sink: input)
        pc.target = .windows
        macRec = MacRecorder()
        mac = MacKeyboardEngine(sink: macRec)
    }

    // Set-1 scan codes, as the PC receives them.
    private static let ctrl: UInt8 = 0x1D, alt: UInt8 = 0x38, win: UInt8 = 0x5B, shift: UInt8 = 0x2A

    private func down(_ c: UInt8, ext: Bool = false) -> RDPEvent { .key(flags: ext ? 0x0100 : 0, code: c) }
    private func up(_ c: UInt8, ext: Bool = false) -> RDPEvent { .key(flags: ext ? 0x8100 : 0x8000, code: c) }

    /// Modifier down, key down, key up, modifier up.
    private func chord(_ mod: UInt8, modExt: Bool = false, _ key: UInt8, keyExt: Bool = false) -> [RDPEvent] {
        [down(mod, ext: modExt), down(key, ext: keyExt), up(key, ext: keyExt), up(mod, ext: modExt)]
    }

    /// The band key with this id, on a PC and on a Mac: what each sends.
    private func press(_ id: String) {
        guard let s = MacShortcut.all.first(where: { $0.id == id }) else { return XCTFail("no key \(id)") }
        pc.sendShortcut(s)
        mac.sendShortcut(s)
    }

    /// The Mac chord: ⌘ (55) [plus ⇧ 56] down, key down and up, modifiers up in reverse.
    private func macChord(_ key: Int, shift: Bool = false) -> [String] {
        shift ? ["v56", "v55", "v\(key)", "^\(key)", "^55", "^56"] : ["v55", "v\(key)", "^\(key)", "^55"]
    }

    func testCopyIsCtrlC() {
        press("copy")
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x2E))
        XCTAssertEqual(macRec.keys, macChord(8))
    }

    func testPasteIsCtrlV() {
        press("paste")
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x2F))
        XCTAssertEqual(macRec.keys, macChord(9))
    }

    func testCutIsCtrlX() {
        press("cut")
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x2D))
        XCTAssertEqual(macRec.keys, macChord(7))
    }

    func testUndoIsCtrlZ() {
        press("undo")
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x2C))
        XCTAssertEqual(macRec.keys, macChord(6))
    }

    /// Redo is Ctrl+Y on Windows; ⇧⌘Z on a Mac.
    func testRedoIsCtrlY() {
        press("redo")
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x15))
        XCTAssertEqual(macRec.keys.sorted(), macChord(6, shift: true).sorted())
        XCTAssertEqual(macRec.keys.count, 6)
    }

    func testSelectAllIsCtrlA() {
        press("selectall")
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x1E))
        XCTAssertEqual(macRec.keys, macChord(0))
    }

    func testSaveIsCtrlS() {
        press("save")
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x1F))
        XCTAssertEqual(macRec.keys, macChord(1))
    }

    func testFindIsCtrlF() {
        press("find")
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x21))
        XCTAssertEqual(macRec.keys, macChord(3))
    }

    /// Search is ⊞+S (E0 5B, then S); Spotlight (⌘Space) on a Mac.
    func testSearchIsWindowsS() {
        press("spotlight")
        XCTAssertEqual(rec.events, chord(Self.win, modExt: true, 0x1F))
        XCTAssertEqual(macRec.keys, macChord(49))
    }

    /// Close is Alt+F4; ⌘W on a Mac.
    func testCloseIsAltF4() {
        press("close")
        XCTAssertEqual(rec.events, chord(Self.alt, 0x3E))
        XCTAssertEqual(macRec.keys, macChord(13))
    }

    /// Apps is Alt held + Tab (the switcher stays up), then Alt up on the second tap; ⌘Tab held on a Mac. The Alt key
    /// shows held while the switcher is open, and a tap on Alt picks.
    func testAppsIsAltTabHeld() {
        press("switchapp")
        XCTAssertEqual(rec.events, [down(Self.alt), down(0x0F), up(0x0F)])
        XCTAssertEqual(macRec.keys, ["v55", "v48", "^48"])
        XCTAssertEqual(pc.switcherModifier, .option)
        pc.tapModifier(.option)
        mac.tapModifier(.command)
        XCTAssertEqual(rec.events.last, up(Self.alt))
        XCTAssertEqual(macRec.keys.last, "^55")
        XCTAssertFalse(pc.switcherOpen)
    }

    /// Ctrl Alt Del: Ctrl, Alt, Delete (E0 53) down, then up in reverse; the other form uses End (E0 4F). Never on a
    /// Mac (the power key there is still ⌘Q).
    func testCtrlAltDelBothForms() {
        pc.sendCtrlAltDel(.ctrlAltDelete)
        XCTAssertEqual(rec.events, [down(Self.ctrl), down(Self.alt), down(0x53, ext: true), up(0x53, ext: true),
                                    up(Self.alt), up(Self.ctrl)])
        rec.events = []
        pc.sendCtrlAltDel(.ctrlAltEnd)
        XCTAssertEqual(rec.events, [down(Self.ctrl), down(Self.alt), down(0x4F, ext: true), up(0x4F, ext: true),
                                    up(Self.alt), up(Self.ctrl)])
        mac.sendCtrlAltDel(.ctrlAltDelete)
        XCTAssertEqual(macRec.keys, [])
        mac.sendShortcut(.quit)
        XCTAssertEqual(macRec.keys, macChord(12))
    }

    /// The "…" page on a PC: Task View is ⊞+Tab; Print Screen is E0 37; ⌦ is the PC's Delete (E0 53).
    func testMorePageTaskViewPrintScreenDelete() {
        pc.sendShortcut(.windowsTaskView)
        XCTAssertEqual(rec.events, chord(Self.win, modExt: true, 0x0F))
        rec.events = []
        pc.keyDown(SpecialKeysLayout.printScreen)
        pc.keyUp(SpecialKeysLayout.printScreen)
        XCTAssertEqual(rec.events, [down(0x37, ext: true), up(0x37, ext: true)])
        rec.events = []
        pc.keyDown(SpecialKeysLayout.forwardDelete)
        pc.keyUp(SpecialKeysLayout.forwardDelete)
        XCTAssertEqual(rec.events, [down(0x53, ext: true), up(0x53, ext: true)])
    }

    /// The band's cells: on a PC the power key's place is Ctrl Alt Del and "…" puts Print Screen and Task View in
    /// esc's and tab's places; on a Mac both pages are as before.
    func testBandCellsOnPCAndMac() {
        let pcMore = SpecialKeysLayout.rows(functionKeys: true, windows: true)[2].map(\.id)
        XCTAssertEqual(Array(pcMore.prefix(2)), ["k-printscreen", "s-taskview"])
        let macMore = SpecialKeysLayout.rows(functionKeys: true)[2].map(\.id)
        XCTAssertEqual(Array(macMore.prefix(2)), ["k-escape", "k-tab"])
        XCTAssertEqual(SpecialKeysLayout.rows(functionKeys: false, windows: true)[1].last?.id, "s-quit")
        XCTAssertEqual(MacShortcut.spotlight.for(.windows).title, "Search")
        XCTAssertEqual(MacShortcut.spotlight.for(.mac).title, "Spotlight")
    }

    /// A latched ⌃ (shown "Ctrl") then a letter on a PC is Ctrl+letter, as before (milestone 2 unchanged).
    func testLatchedCtrlStillWorks() {
        pc.tapModifier(.control)
        let c = MacKey("c", 8)
        pc.keyDown(c)
        pc.keyUp(c)
        XCTAssertEqual(rec.events, chord(Self.ctrl, 0x2E))
    }
}
