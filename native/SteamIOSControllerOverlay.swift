// SteamIOS controller UI port from NightVibes33/Madeira, steamos-ios branch.
// Preserve its glass controls, touch ownership, normalized layout, editing,
// mapping, and persistence. Route the actual events into native GTA V input.
import Foundation
import SwiftUI
import UIKit

@_silgen_name("muguet_steamios_pad_update")
private func muguet_steamios_pad_update(_ connected: Bool, _ buttons: UInt16,
    _ lt: UInt8, _ rt: UInt8, _ lx: Int16, _ ly: Int16, _ rx: Int16, _ ry: Int16)
@_silgen_name("muguet_steamios_key")
private func muguet_steamios_key(_ vk: Int32, _ pressed: Bool)
@_silgen_name("muguet_steamios_mouse")
private func muguet_steamios_mouse(_ button: Int32, _ pressed: Bool)
@_silgen_name("muguet_steamios_packet_count")
private func muguet_steamios_packet_count() -> UInt64
@_silgen_name("muguet_steamios_text")
private func muguet_steamios_text(_ character: UInt16)

// GTAiOS Controls tab shares SteamIOS's actual persisted visibility flag.
// This wrapper does not maintain a separate cosmetic switch.
@MainActor final class InputSettings {
    static let shared = InputSettings()
    var controllerOverlayEnabled: Bool {
        get { TouchControlsModel.shared.visible }
        set {
            TouchControlsModel.shared.visible = newValue
            if !newValue { SteamIOSGamepadInput.shared.stop() }
        }
    }
}

@MainActor final class SteamIOSGamepadInput {
    static let shared = SteamIOSGamepadInput()
    private var state = TouchGamepadState()
    func reserveSessionSlot() {
        if TouchControlsModel.shared.visible {
            state.reserved = true
            publish()
            LogStore.shared.write("controls", "SteamIOS player 1 reserved before engine start")
        }
    }
    private var lastDiagnostic = Date.distantPast
    func configureTouch(controls: Set<UUID>) { state.configure(controls); publish() }
    func touch(owner: UUID, control: UUID, value: GamepadSample?) {
        state.update(owner: owner, control: control, value: value)
        publish()
    }
    func stop() { state.configure([]); publish() }
    private func publish() {
        let p = state.sample
        muguet_steamios_pad_update(state.connected, p.buttons, p.lt, p.rt, p.lx, p.ly, p.rx, p.ry)
        // Logs are real cross-language acknowledgements, not a simulated
        // controller. A button/stick must reach Rust to advance packets.
        let active = p.buttons != 0 || p.lt > 0 || p.rt > 0 ||
                     p.lx != 0 || p.ly != 0 || p.rx != 0 || p.ry != 0
        if active && Date().timeIntervalSince(lastDiagnostic) >= 2 {
            lastDiagnostic = Date()
            LogStore.shared.write("controls",
                "SteamIOS -> native Rust packets=\(muguet_steamios_packet_count()) " +
                "buttons=0x\(String(p.buttons, radix: 16)) LT=\(p.lt) RT=\(p.rt) " +
                "sticks=\(p.lx),\(p.ly),\(p.rx),\(p.ry)")
        }
    }
}

private func winios_post_key(_ vk: Int32, _ down: Int32) {
    muguet_steamios_key(vk, down != 0)
}
private func winios_pointer(_ x: Int32, _ y: Int32, _ flags: Int32, _ data: Int32) {
    if flags & 2 != 0 { muguet_steamios_mouse(0, true) }
    if flags & 4 != 0 { muguet_steamios_mouse(0, false) }
    if flags & 8 != 0 { muguet_steamios_mouse(2, true) }
    if flags & 16 != 0 { muguet_steamios_mouse(2, false) }
}

final class GTAIOSSteamKeyboardDelegate: NSObject, UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString replacement: String) -> Bool {
        if replacement.isEmpty {
            muguet_steamios_text(8) // Backspace
        } else {
            for scalar in replacement.utf16 { muguet_steamios_text(scalar) }
        }
        return false // Keep a clean input view; guest receives characters.
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        muguet_steamios_text(13)
        return false
    }
}
enum GTAIOSSteamKeyboard {
    private static weak var input: UITextField?
    private static let keyboardDelegate = GTAIOSSteamKeyboardDelegate()
    static func toggle() {
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow })?.rootViewController?.view
        guard let root else { return }
        if let input, input.isFirstResponder { input.resignFirstResponder(); return }
        let field: UITextField
        if let input { field = input }
        else {
            field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.delegate = keyboardDelegate
            root.addSubview(field)
            self.input = field
        }
        field.becomeFirstResponder()
    }
}

import Foundation
import SwiftUI
import UIKit

// MARK: - Pure touch state (also compiled by the host regression test)
struct GamepadSample: Equatable, Sendable {
    var buttons: UInt16 = 0
    var lt: UInt8 = 0, rt: UInt8 = 0
    var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0

    static func axis(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let v = max(-1, min(1, value))
        return Int16((v * (v < 0 ? 32768 : 32767)).rounded())
    }

    /// Same arbitration as the fork: a physical stick outside its XInput
    /// dead zone wins; otherwise use a deflected touch stick. A resting touch
    /// stick must not erase a small physical deflection.
    static func merge(physical p: Self, touch t: Self) -> Self {
        var result = p
        result.buttons |= t.buttons
        result.lt = max(p.lt, t.lt); result.rt = max(p.rt, t.rt)
        if hypot(Double(p.lx), Double(p.ly)) <= 7849 && (t.lx != 0 || t.ly != 0) {
            result.lx = t.lx; result.ly = t.ly
        }
        if hypot(Double(p.rx), Double(p.ry)) <= 8689 && (t.rx != 0 || t.ry != 0) {
            result.rx = t.rx; result.ry = t.ry
        }
        return result
    }
}

enum TouchPadAction {
    static let buttons: [String: UInt16] = [
        "A": 0x1000, "B": 0x2000, "X": 0x4000, "Y": 0x8000,
        "D↑": 1, "D↓": 2, "D←": 4, "D→": 8,
        "LB": 0x0100, "RB": 0x0200, "L3": 0x0040, "R3": 0x0080,
        "Menu": 0x0010, "View": 0x0020, "Guide": 0x0400
    ]
    static func supported(_ name: String) -> Bool {
        buttons[name] != nil || ["LT", "RT", "LS", "RS"].contains(name)
    }
    static func vector(x: Double, y: Double) -> (Double, Double) {
        guard x.isFinite && y.isFinite else { return (0, 0) }
        let length = max(1, hypot(x, y))
        return (x / length, y / length)
    }
    static func sample(_ name: String, x: Double = 0, y: Double = 0) -> GamepadSample {
        var result = GamepadSample()
        result.buttons = buttons[name] ?? 0
        if name == "LT" { result.lt = 255 }
        if name == "RT" { result.rt = 255 }
        let (x, y) = vector(x: x, y: y)
        if name == "LS" { result.lx = GamepadSample.axis(x); result.ly = GamepadSample.axis(y) }
        if name == "RS" { result.rx = GamepadSample.axis(x); result.ry = GamepadSample.axis(y) }
        return result
    }
}

struct TouchGamepadState {
    private struct Hold { var control: UUID; var value: GamepadSample }
    private var allowed = Set<UUID>()
    private var holds: [UUID: Hold] = [:]
    /// Player 1 stays connected at rest for the whole session, even with no
    /// visible touch control (GamepadInput.reserveSessionSlot). Layout changes
    /// and lifecycle clearing release holds but keep the reservation.
    var reserved = false
    var connected: Bool { reserved || !allowed.isEmpty }

    mutating func configure(_ controls: Set<UUID>) {
        allowed = controls
        // Layout changes invalidate all in-flight gestures, including remaps
        // which preserve the control's ID.
        clear()
    }
    mutating func update(owner: UUID, control: UUID, value: GamepadSample?) {
        guard allowed.contains(control), let value else { holds[owner] = nil; return }
        holds[owner] = Hold(control: control, value: value)
    }
    mutating func clear() { holds.removeAll() }
    var sample: GamepadSample {
        var result = GamepadSample()
        for hold in holds.values {
            let s = hold.value
            result.buttons |= s.buttons
            result.lt = max(result.lt, s.lt); result.rt = max(result.rt, s.rt)
            // Duplicate stick controls choose the stronger vector; lexical
            // tie-breaking makes equal opposite inputs deterministic.
            func stronger(_ x: Int16, _ y: Int16, _ a: Int16, _ b: Int16) -> Bool {
                let n = Int64(x) * Int64(x) + Int64(y) * Int64(y)
                let m = Int64(a) * Int64(a) + Int64(b) * Int64(b)
                return n > m || (n == m && (x > a || (x == a && y > b)))
            }
            if stronger(s.lx, s.ly, result.lx, result.ly) { result.lx = s.lx; result.ly = s.ly }
            if stronger(s.rx, s.ry, result.rx, result.ry) { result.rx = s.rx; result.ry = s.ry }
        }
        return result
    }
}
// MARK: - UIKit touch lifetime

/// UIKit supplies explicit cancellation and independent finger identities;
/// SwiftUI's DragGesture.onEnded alone cannot release every interrupted press.
struct TouchPadSurface: UIViewRepresentable {
    let control: UUID
    let action: String
    let changed: (CGSize, Bool) -> Void
    func makeUIView(context: Context) -> TouchPadView { TouchPadView() }
    func updateUIView(_ view: TouchPadView, context: Context) {
        view.configure(control: control, action: action, changed: changed)
    }
    static func dismantleUIView(_ view: TouchPadView, coordinator: ()) { view.releaseAll() }
}

final class TouchPadView: UIView {
    private struct Finger { var owner: UUID; var start: CGPoint }
    private var fingers: [ObjectIdentifier: Finger] = [:]
    private var control = UUID()
    private var action = ""
    private var changed: ((CGSize, Bool) -> Void)?
    private var previousSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    func configure(control: UUID, action: String, changed: @escaping (CGSize, Bool) -> Void) {
        if self.control != control || self.action != action { releaseAll() }
        self.control = control; self.action = action; self.changed = changed
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size { releaseAll(); previousSize = bounds.size }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { releaseAll() } }
    @objc private func interrupted() { releaseAll(); changed?(.zero, false) }
    func releaseAll() {
        for finger in fingers.values {
            SteamIOSGamepadInput.shared.touch(owner: finger.owner, control: control, value: nil)
        }
        fingers.removeAll()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            fingers[ObjectIdentifier(touch)] = Finger(owner: UUID(), start: touch.location(in: self))
        }
        update(touches)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
    private func update(_ touches: Set<UITouch>) {
        guard UIApplication.shared.applicationState == .active else { interrupted(); return }
        for touch in touches {
            guard let finger = fingers[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self), radius = max(1, bounds.width * 0.35)
            let (x, y) = TouchPadAction.vector(x: Double((point.x - finger.start.x) / radius),
                                              y: Double((finger.start.y - point.y) / radius))
            SteamIOSGamepadInput.shared.touch(owner: finger.owner, control: control,
                value: TouchPadAction.sample(action, x: x, y: y))
            changed?(CGSize(width: x, height: -y), true)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let finger = fingers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            SteamIOSGamepadInput.shared.touch(owner: finger.owner, control: control, value: nil)
        }
        if fingers.isEmpty { changed?(.zero, false) }
    }
}

enum ControlAction: Codable, Equatable, Hashable {
    case none
    case key(Int32)          // Windows virtual-key code
    case mouseLeft
    case mouseRight
    case joystickWASD        // renders as a stick, posts W/A/S/D
    case joystickArrows      // renders as a stick, posts the arrow keys
    case keyboardToggle      // raises the iOS keyboard, as in portrait
    case pad(String)         // ml1930: touch gamepad action, preserving saved layout names.

    /// The four keys a stick drives, up/right/down/left. nil for non-sticks.
    var stickKeys: [Int32]? {
        switch self {
        case .joystickWASD:   return [0x57, 0x44, 0x53, 0x41]   // W D S A
        case .joystickArrows: return [0x26, 0x27, 0x28, 0x25]   // up right down left
        default: return nil
        }
    }
    /// SF Symbol drawn in the middle of a key stick's face. WASD and the arrow
    /// keys share one control (`.dirStick`) and would draw the same ring, so a
    /// user could not tell them apart without pressing one. nil for every other
    /// control, including the controller sticks, which carry their own label.
    var stickGlyph: String? {
        switch self {
        case .joystickWASD:   return "keyboard"
        case .joystickArrows: return "arrow.up.and.down.and.arrow.left.and.right"
        default:              return nil
        }
    }
    var isPad: Bool { if case .pad = self { return true }; return false }
    var padName: String? { if case .pad(let name) = self { return name }; return nil }
    var isPadStick: Bool { padName == "LS" || padName == "RS" }

    // ------------------------------------------------------------------
    // HOW A VIRTUAL CONTROLLER BUTTON IS DRAWN. The shape is part of the
    // button's identity: a wide rounded rectangle says "shoulder", a capsule
    // says "system", a coloured circle says "face", so a layout reads without
    // its labels. Saved layouts keep their names ("Menu", "View", "D↑"); only
    // the drawing changes.
    // ------------------------------------------------------------------
    enum PadFace { case round, wide, capsule, small }

    var padFace: PadFace? {
        guard let n = padName else { return nil }
        switch n {
        case "LB", "RB", "LT", "RT": return .wide
        case "Menu", "View":         return .capsule
        case "L3", "R3":             return .small
        default:                     return .round
        }
    }
    /// SF Symbol drawn instead of a label: the four D-pad directions.
    var padGlyph: String? {
        switch padName {
        case "D↑": return "arrowtriangle.up.fill"
        case "D↓": return "arrowtriangle.down.fill"
        case "D←": return "arrowtriangle.left.fill"
        case "D→": return "arrowtriangle.right.fill"
        default:   return nil
        }
    }
    /// The text drawn on the control. Menu/View are the XInput names the
    /// layout stores; the buttons themselves read START/SELECT.
    var padFaceLabel: String {
        switch padName {
        case "Menu": return "START"
        case "View": return "SELECT"
        default:     return label
        }
    }
    /// Drawn size, given the layout's diameter for a round button. Shoulders
    /// are wide, Start/Select are small pills, stick clicks are small circles.
    func controlSize(diameter d: CGFloat) -> CGSize {
        switch padFace {
        case .wide:    return CGSize(width: d * 1.6, height: d * 0.74)
        case .capsule: return CGSize(width: d * 1.2, height: d * 0.5)
        case .small:   return CGSize(width: d * 0.8, height: d * 0.8)
        default:       return CGSize(width: d, height: d)
        }
    }

    var label: String {
        switch self {
        case .none:            return "—"
        case .mouseLeft:       return "L"
        case .mouseRight:      return "R"
        case .keyboardToggle:  return "⌨"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "↕"
        case .pad(let n):      return n
        case .key(let vk):     return ControlAction.keyLabel(vk)
        }
    }

    /// Minimal for pass 1 — the full VK table arrives with the mapping panel.
    static func keyLabel(_ vk: Int32) -> String {
        switch vk {
        case 0x0D: return "⏎"
        case 0x20: return "␣"
        case 0x1B: return "Esc"
        case 0x09: return "⇥"
        case 0x10: return "⇧"
        case 0x11: return "Ctl"
        case 0x12: return "Alt"
        case 0x25: return "←"
        case 0x26: return "↑"
        case 0x27: return "→"
        case 0x28: return "↓"
        default:
            if vk >= 0x30, vk <= 0x5A, let u = UnicodeScalar(UInt32(vk)) {
                return String(Character(u))
            }
            return String(format: "%02X", vk)
        }
    }
}

/// One on-screen control.
///
/// Position is NORMALISED (0–1 of the screen), never points: the device gets
/// rotated and the logical surface can change size, and a layout stored in
/// absolute coordinates scatters the first time either happens.
struct TouchControl: Codable, Identifiable, Equatable {
    var id = UUID()
    var nx: Double = 0.5
    var ny: Double = 0.5
    var scale: Double = 1.0
    var action: ControlAction = .mouseLeft   // usable the moment it is created
    /// A physical controller input that also performs this control's key or
    /// mouse action when the game runs in keyboard-and-mouse controller mode
    /// (PadKeyboardMouse): "A", "RT", "D↑", ...; "LS"/"RS" for a key stick.
    /// Optional, so layouts saved before it existed still decode.
    var padBinding: String?
}

final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    static let baseDiameter: CGFloat = 64

    @Published var controls: [TouchControl] = [] { didSet { save() } }
    @Published var visible = true               { didSet { save() } }
    @Published var editing = false {            // transient, never persisted
        didSet {
            // ml1970: an ended edit is written back to the custom layout it came from.
            if !oldValue && editing { editBaseline = controls }
            if oldValue && !editing { ControlPresetsModel.shared.editingEnded(baseline: editBaseline) }
        }
    }
    @Published var selected: UUID?              // transient
    /// ml1970: the named layout (TouchControlPresets.swift) these controls were
    /// loaded from; nil for controls no layout holds.
    @Published var layoutID: String?            { didSet { save() } }
    /// ml1970: no controls file existed at launch, so the built-in controller
    /// layout may be applied once (ControlPresetsModel.applyDefaultIfNeeded).
    var needsDefaultLayout = false
    private var editBaseline: [TouchControl] = []

    /// One size for the whole layout (0.5...2), multiplying each control's own
    /// pinch `scale`. A library entry keeps its own (Control size) and sets it
    /// for its session; transient, so the developer interface stays at 1.
    @Published var sizeScale: Double = 1.0

    /// A control's drawn diameter. The view, the hit test and the mapping
    /// panel's placement all use it, so the touch region and the pixels agree.
    static func diameter(_ c: TouchControl) -> CGFloat {
        baseDiameter * CGFloat(c.scale) * CGFloat(shared.sizeScale)
    }
    /// The drawn frame: the diameter for round controls, the pad button's own
    /// shape otherwise (ControlAction.controlSize).
    static func size(_ c: TouchControl) -> CGSize { c.action.controlSize(diameter: diameter(c)) }

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gtaios-steamios-controls.json")
    }

    /// `layout` is optional so files written before it existed still decode.
    private struct Saved: Codable { var controls: [TouchControl]; var visible: Bool; var layout: String? }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            controls = s.controls
            visible  = (UserDefaults.standard.object(forKey: "gtaios.steamios.controls.enabled") as? Bool) ?? s.visible
            layoutID = s.layout
        }
        needsDefaultLayout = !FileManager.default.fileExists(atPath: Self.url.path)
        loading = false
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(Saved(controls: controls, visible: visible, layout: layoutID))
        else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    /// ml1990: touch controls will feed player 1 this session (visible
    /// controller mappings, or the built-in a user without controls is about to get with MADEIRA_CONTROLS_XBOX_DEFAULT=1).
    var offersControllerInput: Bool {
        visible && (controls.contains { $0.action.padName.map(TouchPadAction.supported) ?? false }
                    || ControlPresetsModel.shared.defaultPending)
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return controls.firstIndex { $0.id == id }
    }

    /// ml644: does this WINDOW point land on something interactive?
    ///
    /// Hit-test geometrically, never by walking the UIView hierarchy. SwiftUI
    /// does not back each Button with its own UIView — the entire overlay is one
    /// _UIHostingView and taps are routed by SwiftUI's own gesture machinery. So
    /// `super.hitTest` returns that same hosting view for EVERY point, buttons
    /// included, and ml643's "is it the root view?" test therefore rejected every
    /// touch in the window. Nothing responded, and edit mode — whose branch
    /// captured everything — could never be entered to mask it.
    /// `topBar: false` in a library session, where LibraryHUD replaces the bar.
    func hitsInteractive(_ p: CGPoint, in bounds: CGRect, topBar: Bool = true) -> Bool {
        // Top bar: two 44pt buttons 10pt apart in play mode, centred, 10pt down,
        // plus the layout menu while touch controls are on (ml1970).
        // Padded generously; a few points of slop costs nothing and a missed tap
        // costs a build.
        let buttons: CGFloat = TouchControlsOverlay.showsLayoutMenu(self) ? 3 : 2
        let barW: CGFloat = buttons * 44 + (buttons - 1) * 10
        if topBar, CGRect(x: bounds.midX - barW / 2 - 10, y: 0,
                          width: barW + 20, height: 68).contains(p) { return true }
        guard visible else { return false }
        for c in controls {
            let r = Self.diameter(c) / 2
            let cx = CGFloat(c.nx) * bounds.width
            let cy = CGFloat(c.ny) * bounds.height
            if hypot(p.x - cx, p.y - cy) <= r { return true }
        }
        return false
    }
}

/// Click-through EXCEPT where a control actually is.
///
/// PassthroughWindow (the joystick pad's) returns nil unconditionally because it
/// only ever draws. This one has to take input, so it discriminates: a hit that
/// lands on the hosting root view means empty space, and empty space belongs to
/// the game underneath — mouse-look must keep working between the buttons.
final class SteamIOSInGameSettingsGesture: NSObject {
    static let shared = SteamIOSInGameSettingsGesture()
    @objc func openEditor(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        TouchControlsModel.shared.ensureDefaultLayout()
        TouchControlsModel.shared.visible = true
        TouchControlsModel.shared.editing = true
        TouchControlsModel.shared.selected = nil
        TouchControlsHost.attach()
        LogStore.shared.write("controls", "SteamIOS in-game editor opened by three-finger tap")
    }
}

final class ControlsWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let m = TouchControlsModel.shared
        if m.editing { return super.hitTest(point, with: event) }
        if ControlPresetsModel.enabled, let root = rootViewController?.view,
           let hit = super.hitTest(point, with: event), hit !== self,
           !hit.isDescendant(of: root) { return hit }
        guard m.hitsInteractive(point, in: bounds) else { return nil }
        return super.hitTest(point, with: event)
    }
}

enum TouchControlsHost {
    private static var window: ControlsWindow?
    private static var productHidden = false
    private static var observingOrientation = false

    static func setHidden(_ hidden: Bool) {
        productHidden = hidden
        window?.isHidden = hidden
        if hidden {
            Task { @MainActor in SteamIOSGamepadInput.shared.stop() }
        }
    }

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
        if window == nil {
            // ml644: orientationDidChangeNotification is NOT posted unless
            // generation has been switched on, so without this the overlay would
            // keep a portrait-sized frame after the first rotation.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let w = ControlsWindow(windowScene: scene)
            // Above the joystick pad's +100. A higher windowLevel is the only
            // ordering nothing inside the app window can undo.
            w.windowLevel = .normal + 101
            w.backgroundColor = .clear
            w.isHidden = productHidden // deliberately never made key
            let host = UIHostingController(rootView: TouchControlsOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.frame = scene.coordinateSpace.bounds
        window?.isHidden = productHidden
        // Restore SteamIOS's in-game settings gesture. It is attached to the
        // real Metal window, so empty game surface still receives normal taps.
        if let gameplay = scene.windows.first(where: { $0 !== window && $0.windowLevel < .normal + 101 }),
           let view = gameplay.rootViewController?.view {
            let marker = "gtaios-steamios-three-finger-editor"
            if !(view.gestureRecognizers ?? []).contains(where: { $0.name == marker }) {
                let gesture = UITapGestureRecognizer(target: SteamIOSInGameSettingsGesture.shared,
                                                      action: #selector(SteamIOSInGameSettingsGesture.openEditor(_:)))
                gesture.numberOfTouchesRequired = 3
                gesture.cancelsTouchesInView = false
                gesture.name = marker
                view.addGestureRecognizer(gesture)
            }
        }
        if !observingOrientation {
            observingOrientation = true
            NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in TouchControlsHost.attach() }
        }
        fputs("[controls] ml644 overlay attached frame=\(window?.frame ?? .zero) " +
              "controls=\(TouchControlsModel.shared.controls.count)\n", stderr)
    }
}



struct TouchControlsOverlay: View {
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var pinchBase: Double?

    var body: some View {
        GeometryReader { geo in
            let landscape = true // GTAiOS landscape-only
            ZStack(alignment: .top) {
                if landscape {
                    if m.visible || m.editing {
                        controls(geo.size, session: false)
                    }
                    topBar
                    if m.editing, let i = m.index(of: m.selected) {
                        MappingPanel(control: m.controls[i], screen: geo.size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(scalePinch, including: m.editing ? .all : .subviews)
            .onAppear { applyDefaultLayout(geo); configureGamepad(landscape: landscape) }
            .onChange(of: geo.size) { _, _ in applyDefaultLayout(geo); configureGamepad(landscape: landscape) }
            .onChange(of: m.controls) { _, _ in configureGamepad(landscape: landscape) }
            .onChange(of: m.visible) { _, _ in configureGamepad(landscape: landscape) }
            .onChange(of: m.editing) { _, _ in configureGamepad(landscape: landscape) }
            .onDisappear { SteamIOSGamepadInput.shared.configureTouch(controls: []) }
        }
        .ignoresSafeArea()
    }

    /// Every control in ONE GlassEffectContainer: on iOS 26 the system merges
    /// glass shapes that come within `spacing` of each other, so a D-pad cross
    /// or a face diamond pinched tight reads as one piece of glass and a button
    /// dragged next to another flows into it. 12 pt: the built-in layout's
    /// neighbours sit further apart than that, so nothing merges until it is
    /// moved almost touching. Before 26 the same views stack as plain material.
    @ViewBuilder private func controls(_ screen: CGSize, session: Bool) -> some View {
        let buttons = ForEach(m.controls) { c in
            TouchControlButton(control: c, screen: screen)

        }
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                ZStack { buttons }
                    .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            }
        } else {
            buttons
        }
    }

    private func configureGamepad(landscape: Bool) {
        let ids = landscape && m.visible && !m.editing 
            ? m.controls.filter { $0.action.padName.map(TouchPadAction.supported) ?? false }.map(\.id) : []
        SteamIOSGamepadInput.shared.configureTouch(controls: Set(ids))
    }

    /// ml1970: with MADEIRA_CONTROLS_XBOX_DEFAULT=1, a user with no controls file gets the built-in controller
    /// layout on the first landscape overlay, laid out for this screen (never over an existing controls file).
    private func applyDefaultLayout(_ geo: GeometryProxy) {
        guard m.needsDefaultLayout, geo.size.width > geo.size.height else { return }
        let i = geo.safeAreaInsets
        ControlPresetsModel.shared.applyDefaultIfNeeded(screen: ControlPresetScreen(
            width: Double(geo.size.width), height: Double(geo.size.height),
            left: Double(i.leading), right: Double(i.trailing),
            top: Double(i.top), bottom: Double(i.bottom)))
    }

    /// ml1970: while editing, a Done button ends the edit (keeping it in the
    /// active custom layout) in place of the checkmark, and the show/hide glyph
    /// is hidden. MADEIRA_CONTROLS_EDITOR_DONE=0 restores the previous bar.
    static let editorDone = GamepadInput.flag("MADEIRA_CONTROLS_EDITOR_DONE")

    /// ml1970: the layout menu, offered only while touch controls are shown.
    static func showsLayoutMenu(_ m: TouchControlsModel) -> Bool {
        ControlPresetsModel.enabled && m.visible && !m.editing
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if m.editing && Self.editorDone {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        m.selected = nil
                        m.editing = false
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(GlassShape())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done editing controls")
            } else {
                glassButton("gamecontroller", dim: !m.visible) { m.visible.toggle() }
                if Self.showsLayoutMenu(m) {
                    ControlLayoutMenu()
                        .transition(.opacity.combined(with: .scale))
                }
                glassButton(m.editing ? "checkmark" : "pencil") {
                    m.editing.toggle()
                    if !m.editing { m.selected = nil }
                }
            }
            if m.editing {
                glassButton("plus") {
                    var c = TouchControl()
                    // Stagger, so repeated adds do not stack invisibly.
                    c.nx = 0.5 + Double(m.controls.count % 3) * 0.06
                    c.ny = 0.5 + Double(m.controls.count % 2) * 0.06
                    m.controls.append(c)
                    m.selected = c.id
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.top, 10)
        .animation(.easeInOut(duration: 0.22), value: m.editing)
    }

    /// Pinch anywhere scales the SELECTED control. With nothing selected it does
    /// nothing rather than guessing which one you meant.
    private var scalePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                guard m.editing, let i = m.index(of: m.selected) else { return }
                if pinchBase == nil { pinchBase = m.controls[i].scale }
                m.controls[i].scale = min(max((pinchBase ?? 1) * Double(v), 0.5), 3.0)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func glassButton(_ system: String, dim: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            // Stroke only — never a .fill variant.
            Image(systemName: system)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(dim ? 0.35 : 1.0))
                .frame(width: 44, height: 44)
                .background(GlassShape(circle: true))
        }
        .buttonStyle(.plain)
    }
}

/// Shared glass backing, with the pre-26 fallback the codebase already uses.
/// A circle, a capsule or a rounded rectangle; `tint` colours the glass itself
/// (the four face buttons), so the colour is a hue on the material rather than
/// an opaque disc. Inside a GlassEffectContainer these merge when they come
/// close, which is what makes a tight D-pad or face diamond read as one piece.
struct GlassShape: View {
    var circle = false
    var capsule = false
    var cornerRadius: CGFloat = 18
    var tint: Color? = nil
    fileprivate var shape: AnyShape {
        if circle { return AnyShape(Circle()) }
        if capsule { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
    var body: some View {
        Color.clear.glassFace(self)
    }
}

extension View {
    /// Glass BEHIND this view, with the view as the glass's content. Inside a
    /// GlassEffectContainer every glass effect is composited together as one
    /// layer over the container's other children, so a label that is merely a
    /// sibling of its glass ends up blurred underneath it; a label that is the
    /// glass view's own content is drawn on top, as the system's buttons are.
    @ViewBuilder func glassFace(_ g: GlassShape) -> some View {
        if #available(iOS 26.0, *) {
            if let tint = g.tint {
                self.glassEffect(.regular.tint(tint.opacity(0.55)), in: g.shape)
            } else {
                self.glassEffect(.regular, in: g.shape)
            }
        } else {
            self.background {
                g.shape.fill(.ultraThinMaterial)
                if let tint = g.tint { g.shape.fill(tint.opacity(0.35)) }
            }
        }
    }
}

extension ControlAction {
    /// Xbox face colours. Everything else is uncoloured: a wash of tint on every
    /// button would make the four that mean something unreadable.
    var padTint: Color? {
        switch padName {
        case "A": return Color(red: 0.36, green: 0.76, blue: 0.30)
        case "B": return Color(red: 0.88, green: 0.28, blue: 0.24)
        case "X": return Color(red: 0.24, green: 0.53, blue: 0.92)
        case "Y": return Color(red: 0.96, green: 0.76, blue: 0.16)
        default:  return nil
        }
    }
}

struct JoystickFace: View {
    var held: Bool
    var dir: Int
    /// ml646: the portrait pad grows out of a key-sized ring when you hold it.
    /// An overlay stick is a PERMANENT control — it must be full size at rest
    /// with only the knob moving, so size is decoupled from press here rather
    /// than faked by passing held:true (which would also kill the knob travel
    /// and the press styling).
    var alwaysExpanded = false
    /// SF Symbol naming what this stick drives (ControlAction.stickGlyph), so a
    /// WASD stick and an arrow-key stick differ at a glance. At rest it is drawn
    /// on the knob in the middle of the ring and travels with it; a ring at idle
    /// size shows the glyph alone, where a knob plus a symbol would be a smudge.
    /// nil (the portrait pad) draws the face exactly as before.
    var glyph: String?
    /// false: the caller puts the glass behind this face itself. The overlay
    /// stick draws the face at pad size and scales it to the control; glass
    /// under that scaleEffect is drawn off-centre from the ring and knob.
    var glass = true
    private var expanded: Bool { held || alwaysExpanded }

    static let idleDiameter: CGFloat = 22
    static let padRadius: CGFloat = 58
    private var idleDiameter: CGFloat { Self.idleDiameter }
    private var padRadius: CGFloat { Self.padRadius }
    private let knobTravelRatio: CGFloat = 0.30

    private func knobOffset(_ d: CGFloat) -> CGSize {
        guard dir >= 0, expanded else { return .zero }
        let travel = d * knobTravelRatio
        let a = Double(dir) * 45.0 * .pi / 180.0
        return CGSize(width: travel * CGFloat(sin(a)), height: -travel * CGFloat(cos(a)))
    }

    var body: some View {
        let d = expanded ? padRadius * 2 : idleDiameter
        let face = ZStack {
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: expanded ? 2 : 1.5)
            if let g = glyph, !expanded {
                Image(systemName: g)
                    .font(.system(size: d * 0.62, weight: .medium))
                    .foregroundColor(.white)
                    .opacity(0.95)
            }
            Circle()
                .fill(Color.white)
                .frame(width: d * 0.42, height: d * 0.42)
                .overlay(
                    // Roundness cue. It reads at key size but turns into a
                    // smudge on the big pad, so it fades out as the ring
                    // springs open rather than scaling up with it.
                    Circle()
                        .trim(from: 0.55, to: 0.70)
                        .stroke(Color.black.opacity(0.38),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .padding(d * 0.075)
                        .opacity(expanded ? 0 : 1)
                )
                .overlay {
                    // Dark on the white knob, inside its rim: it reads at rest and
                    // follows the knob when the stick is deflected.
                    if let g = glyph, expanded {
                        Image(systemName: g)
                            .font(.system(size: d * 0.22, weight: .semibold))
                            .foregroundColor(.black)
                            .opacity(0.62)
                    }
                }
                .offset(knobOffset(d))
                // A glyph-bearing ring at idle size shows the glyph instead of the knob.
                .opacity(glyph == nil || expanded ? 1 : 0)
        }
        .frame(width: d, height: d)
        // The ring, glyph and knob are the glass's content, not siblings of it:
        // an overlay stick sits in the controls' GlassEffectContainer, which
        // composites every glass over its siblings and blurred the knob.
        if glass {
            face.glassFace(GlassShape(circle: true))
        } else {
            face
        }
    }
}


struct TouchControlButton: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var isDown = false
    @State private var dragBase: CGPoint?
    @State private var stickDir: Int = -1
    @State private var padVector = CGSize.zero

    private var diameter: CGFloat { TouchControlsModel.diameter(control) }
    private var size: CGSize { TouchControlsModel.size(control) }
    private var isStick: Bool { control.action.stickKeys != nil || control.action.isPadStick }
    private var isSelected: Bool { m.editing && m.selected == control.id }

    /// The resting outline and the edit-mode selection ring, in the shape the
    /// control actually has.
    private var outline: AnyShape {
        switch control.action.padFace {
        case .some(.wide):    return AnyShape(RoundedRectangle(cornerRadius: size.height * 0.30))
        case .some(.capsule): return AnyShape(Capsule())
        default:              return AnyShape(Circle())
        }
    }

    /// A controller button: coloured circle (A/B/X/Y), arrow (D-pad), wide
    /// shoulder (LB/RB/LT/RT), START/SELECT pill, small L3/R3.
    @ViewBuilder private var padFace: some View {
        let a = control.action
        switch a.padFace ?? .round {
        case .round:
            Group {
                if let g = a.padGlyph {
                    Image(systemName: g)
                        .font(.system(size: size.height * 0.40, weight: .semibold))
                        .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.88))
                } else {
                    Text(a.padFaceLabel)
                        .font(.system(size: size.height * (a.padFaceLabel.count > 2 ? 0.24 : 0.40), weight: .semibold))
                        .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.92))
                }
            }
            .frame(width: size.width, height: size.height)
            .glassFace(GlassShape(circle: true, tint: a.padTint))
        case .small:
            Text(a.padFaceLabel)
                .font(.system(size: size.height * 0.36, weight: .semibold))
                .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
                .frame(width: size.width, height: size.height)
                .glassFace(GlassShape(circle: true))
        case .wide:
            Text(a.padFaceLabel)
                .font(.system(size: size.height * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.88))
                .frame(width: size.width, height: size.height)
                .glassFace(GlassShape(cornerRadius: size.height * 0.30))
        case .capsule:
            Text(a.padFaceLabel)
                .font(.system(size: size.height * 0.40, weight: .semibold))
                .kerning(0.6)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
                .frame(width: size.width, height: size.height)
                .glassFace(GlassShape(capsule: true))
        }
    }

    var body: some View {
        ZStack {
            if control.action.isPadStick {
                ZStack {
                    Circle().fill(.white.opacity(isDown ? 0.55 : 0.25))
                        .frame(width: diameter * 0.42, height: diameter * 0.42)
                        .offset(x: padVector.width * diameter * 0.29, y: padVector.height * diameter * 0.29)
                    Text(control.action.label).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .frame(width: diameter, height: diameter)
                .glassFace(GlassShape(circle: true))
            } else if control.action.stickKeys != nil {
                // Reuse the portrait pad's face so both look and animate the
                // same; scale it to whatever size this control was pinched to.
                // The glass goes on at the control's real size, outside the
                // scaleEffect, so it stays centred on the ring and knob.
                JoystickFace(held: isDown, dir: stickDir, alwaysExpanded: true,
                              glyph: control.action.stickGlyph, glass: false)
                    .frame(width: JoystickFace.padRadius * 2,
                           height: JoystickFace.padRadius * 2)
                    .scaleEffect(diameter / (JoystickFace.padRadius * 2))
                    .frame(width: diameter, height: diameter)
                    .glassFace(GlassShape(circle: true))
            } else if control.action.isPad {
                padFace
            } else {
                // The label is the glass's content (see glassFace), so it is drawn
                // on top of the glass rather than blurred underneath it.
                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
                    .frame(width: size.width, height: size.height)
                    .glassFace(GlassShape(circle: true))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(outline.stroke(.white.opacity(isSelected ? 0.95
                                               : (isStick ? 0 : 0.28)),
                                lineWidth: isSelected ? 2 : 1))
        // A stick must not shrink under the thumb; only round buttons do that.
        .scaleEffect(!isStick && isDown ? 0.92 : 1.0)
        // ml890: no press animation. Pressing the on-screen Enter key killed the
        // whole process with a SwiftUI trap on com.apple.SwiftUI.AsyncRenderer
        // (DisplayList.ViewUpdater.ViewCache.commitAsyncValues) while this
        // glass control animated its press; the state change now applies at once.
        // ml646: the springy knob, same curve as the portrait pad overlay.
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: stickDir)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    m.controls.removeAll { $0.id == control.id }
                    m.selected = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        .overlay {
            if let action = control.action.padName, !m.editing {
                TouchPadSurface(control: control.id, action: action) { vector, down in
                    padVector = vector; isDown = down
                }
            }
        }
        .onDisappear { if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: m.editing) { _, _ in if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: screen) { _, _ in if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: control.action) { old, new in
            if old.isPad || new.isPad { padVector = .zero; isDown = false }
        }
        .position(x: CGFloat(control.nx) * screen.width,
                  y: CGFloat(control.ny) * screen.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if m.editing {
                        m.selected = control.id
                        guard let i = m.index(of: control.id) else { return }
                        if dragBase == nil { dragBase = CGPoint(x: control.nx, y: control.ny) }
                        let b = dragBase ?? .zero
                        m.controls[i].nx = min(max(b.x + Double(v.translation.width  / screen.width),  0.03), 0.97)
                        m.controls[i].ny = min(max(b.y + Double(v.translation.height / screen.height), 0.03), 0.97)
                    } else if let q = control.action.stickKeys {
                        isDown = true
                        applyStick(snap(v.translation), q)
                    } else if !isDown {
                        isDown = true
                        press(true)
                    }
                }
                .onEnded { _ in
                    dragBase = nil
                    if let q = control.action.stickKeys {
                        applyStick(-1, q)          // release every held direction
                        isDown = false
                    } else if isDown {
                        isDown = false
                        press(false)
                    }
                },
            including: control.action.isPad && !m.editing ? .subviews : .all
        )
    }

    /// 8-way snap. Screen y grows downward, so measure clockwise from "up".
    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < diameter * 0.22 { return -1 }        // deadzone scales with the control
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    private func stickKeys(_ d: Int, _ q: [Int32]) -> [Int32] {
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is. A blanket
    /// release/re-press would make a held direction stutter as the thumb
    /// wanders inside one sector.
    private func applyStick(_ next: Int, _ q: [Int32]) {
        guard next != stickDir else { return }
        let old = Set(stickKeys(stickDir, q)), new = Set(stickKeys(next, q))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        if stickDir == -1, next != -1 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        stickDir = next
    }

    /// Haptic on the DOWN edge only — a held movement key would otherwise buzz
    /// continuously for as long as you walk.
    private func press(_ down: Bool) {
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        switch control.action {
        case .key(let vk):
            winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:
            winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)   // LEFTDOWN / LEFTUP
        case .mouseRight:
            winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)   // RIGHTDOWN / RIGHTUP
        case .keyboardToggle:
            if down { GTAIOSSteamKeyboard.toggle() }
        case .none, .joystickWASD, .joystickArrows:
            break                                              // sticks drive themselves
        case .pad:
            break     // TouchPadSurface owns pad presses and cancellation.
        }
    }
}

/// ml645 — the mapping panel. Shown for the selected control in edit mode.
struct MappingPanel: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var tab = 0                    // 0 keyboard, 1 controller


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(0, "keyboard")
                tabButton(1, "gamecontroller")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            ScrollView {
                (tab == 0 ? AnyView(keyboardTab) : AnyView(controllerTab))
                    .padding(10)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(GlassShape())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .position(layout.center)
    }

    private struct Placement { var center: CGPoint; var size: CGSize }

    /// ml646: the panel must NEVER sit under the control it is editing.
    ///
    /// The old version only tried below/above and then clamped, which on a
    /// 390pt-tall landscape phone silently put the panel right on top of any
    /// control near the middle: 240 of panel + 64 of control + gaps does not fit
    /// in 390 either way, so the clamp was the only thing deciding placement.
    ///
    /// Try each side in turn, at shrinking sizes, and take the first that fits
    /// on the screen along the axis it separates on. Clamping the OTHER axis is
    /// then always safe — below/above are separated vertically, so no horizontal
    /// clamp can reintroduce an overlap, and vice versa.
    private var layout: Placement {
        let cx = CGFloat(control.nx) * screen.width
        let cy = CGFloat(control.ny) * screen.height
        let r  = TouchControlsModel.diameter(control) / 2
        let gap: CGFloat = 14, edge: CGFloat = 8

        for size in [CGSize(width: 340, height: 236),
                     CGSize(width: 300, height: 196),
                     CGSize(width: 264, height: 164)] {
            let clampX = min(max(cx, size.width  / 2 + edge), screen.width  - size.width  / 2 - edge)
            let clampY = min(max(cy, size.height / 2 + edge), screen.height - size.height / 2 - edge)
            if cy + r + gap + size.height <= screen.height - edge {
                return Placement(center: CGPoint(x: clampX, y: cy + r + gap + size.height / 2), size: size)
            }
            if cy - r - gap - size.height >= edge {
                return Placement(center: CGPoint(x: clampX, y: cy - r - gap - size.height / 2), size: size)
            }
            if cx + r + gap + size.width <= screen.width - edge {
                return Placement(center: CGPoint(x: cx + r + gap + size.width / 2, y: clampY), size: size)
            }
            if cx - r - gap - size.width >= edge {
                return Placement(center: CGPoint(x: cx - r - gap - size.width / 2, y: clampY), size: size)
            }
        }
        // Nothing fits alongside — smallest panel, corner furthest from the
        // control, so it still cannot cover it.
        let size = CGSize(width: 264, height: 164)
        return Placement(
            center: CGPoint(x: cx < screen.width  / 2 ? screen.width  - size.width  / 2 - edge
                                                      : size.width  / 2 + edge,
                            y: cy < screen.height / 2 ? screen.height - size.height / 2 - edge
                                                      : size.height / 2 + edge),
            size: size)
    }

    private func tabButton(_ i: Int, _ icon: String) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)                       // stroke, not filled
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(tab == i ? 1.0 : 0.38))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    // ---- catalogues ----
    private var letters: [(String, ControlAction)] {
        (0x41...0x5A).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var digits: [(String, ControlAction)] {
        (0x30...0x39).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var fkeys: [(String, ControlAction)] {
        (0...11).map { ("F\($0 + 1)", ControlAction.key(Int32(0x70 + $0))) }
    }
    private var numpad: [(String, ControlAction)] {
        (0...9).map { ("N\($0)", ControlAction.key(Int32(0x60 + $0))) }
        + [("N*", .key(0x6A)), ("N+", .key(0x6B)), ("N−", .key(0x6D)),
           ("N.", .key(0x6E)), ("N/", .key(0x6F))]
    }

    private var keyboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if GamepadInput.keyboardMouseAvailable, !control.action.isPad, control.action != .none, control.action != .keyboardToggle {
                bindingSection
            }
            section("Pointer, sticks & special", [
                ("L click", .mouseLeft), ("R click", .mouseRight),
                ("WASD", .joystickWASD), ("Arrows", .joystickArrows),
                ("Keyboard", .keyboardToggle), ("None", .none),
            ])
            section("Letters", letters)
            section("Numbers", digits)
            section("Function", fkeys)
            section("Modifiers & editing", [
                ("Esc", .key(0x1B)), ("Tab", .key(0x09)), ("Caps", .key(0x14)),
                ("Shift", .key(0x10)), ("Ctrl", .key(0x11)), ("Alt", .key(0x12)),
                ("Space", .key(0x20)), ("Enter", .key(0x0D)), ("Bksp", .key(0x08)),
                ("Win", .key(0x5B)),
            ])
            section("Navigation", [
                ("←", .key(0x25)), ("↑", .key(0x26)), ("→", .key(0x27)), ("↓", .key(0x28)),
                ("Ins", .key(0x2D)), ("Del", .key(0x2E)), ("Home", .key(0x24)),
                ("End", .key(0x23)), ("PgUp", .key(0x21)), ("PgDn", .key(0x22)),
            ])
            section("Symbols", [
                ("-", .key(0xBD)), ("=", .key(0xBB)), ("[", .key(0xDB)), ("]", .key(0xDD)),
                ("\\", .key(0xDC)), (";", .key(0xBA)), ("'", .key(0xDE)), (",", .key(0xBC)),
                (".", .key(0xBE)), ("/", .key(0xBF)), ("`", .key(0xC0)),
            ])
            section("Numpad", numpad)
        }
    }

    private var controllerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controller controls feed XInput player 1. LS and RS are analogue sticks; "
                 + "LT and RT are full-press triggers. Touch and physical controls can be used together.")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            section("Face", [("A", .pad("A")), ("B", .pad("B")), ("X", .pad("X")), ("Y", .pad("Y"))])
            section("D-pad", [("D↑", .pad("D↑")), ("D↓", .pad("D↓")),
                              ("D←", .pad("D←")), ("D→", .pad("D→"))])
            section("Bumpers & triggers", [("LB", .pad("LB")), ("RB", .pad("RB")),
                                           ("LT", .pad("LT")), ("RT", .pad("RT"))])
            section("Sticks", [("LS", .pad("LS")), ("RS", .pad("RS")),
                               ("L3", .pad("L3")), ("R3", .pad("R3"))])
            // Start and Select are XInput's Menu and View; the layout keeps the
            // XInput names, the chips and the buttons read Start/Select.
            section("System", [("Start", .pad("Menu")), ("Select", .pad("View")),
                               ("Guide", .pad("Guide"))])
        }
    }

    /// Keyboard-and-mouse controller mode: which physical input performs this
    /// control's action. A key stick binds to a stick; everything else to a
    /// button or trigger. The chosen chip is highlighted; tapping it again clears.
    private var bindingSection: some View {
        let names = control.action.stickKeys != nil ? PadBindings.stickNames : PadBindings.buttonNames
        return VStack(alignment: .leading, spacing: 6) {
            Text("Controller button for this action (keyboard & mouse mode)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(names, id: \.self) { name in
                    let on = control.padBinding == name
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if let i = m.index(of: control.id) { m.controls[i].padBinding = on ? nil : name }
                    } label: {
                        Text(name == "Menu" ? "Start" : name == "View" ? "Select" : name)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.55)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.6) : .white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func section(_ title: String, _ items: [(String, ControlAction)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    chip(it.0, it.1)
                }
            }
        }
    }

    private func chip(_ label: String, _ action: ControlAction) -> some View {
        let on = control.action == action
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let i = m.index(of: control.id) { m.controls[i].action = action }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white.opacity(action.isPad ? 0.55 : 1.0))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(on ? 0.36 : 0.12)))
        }
        .buttonStyle(.plain)
    }
}

struct PadBindings: Equatable {
    static let buttonNames = ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "L3", "R3",
                              "Menu", "View", "D↑", "D↓", "D←", "D→"]
    static let stickNames = ["LS", "RS"]

    /// What each digital input does; the triggers count as digital here.
    var buttons: [String: ControlAction]
    /// The key stick the left stick drives (.joystickWASD/.joystickArrows), or
    /// .none when the right stick took the keys and the left one is unused.
    var leftStick: ControlAction
    /// The right stick moves the mouse (default) or drives a key stick.
    var rightStick: ControlAction
    /// Vertical speed of the right-stick mouse relative to its horizontal speed
    /// (1 = the same). Games scale pitch and yaw differently from a mouse, and a
    /// stick cannot be compensated by hand the way a wrist does.
    var mouseVertical: Double = 1.0

    /// The built-in template: the keyboard-and-mouse layout most PC games use.
    static let template = PadBindings(
        buttons: ["A": .key(0x20),            // Space
                  "B": .key(0x11),            // Ctrl
                  "X": .key(0x45),            // E
                  "Y": .key(0x52),            // R
                  "LB": .key(0x51),           // Q
                  "RB": .key(0x46),           // F
                  "LT": .mouseRight,
                  "RT": .mouseLeft,
                  "L3": .key(0x10),           // Shift
                  "R3": .key(0x43),           // C
                  "Menu": .key(0x1B),         // Escape
                  "View": .key(0x09),         // Tab
                  "D↑": .key(0x26), "D↓": .key(0x28), "D←": .key(0x25), "D→": .key(0x27)],
        leftStick: .joystickWASD,
        rightStick: .none)                    // .none on the right stick means: the mouse

    /// The template with the layout's own bindings on top, then the game's binds
    /// table on top of that. A binding replaces the template's entry for that
    /// input; a key stick bound to RS takes the right stick away from the mouse.
    /// In the table, `.none` on a button means "does nothing", on RS "the mouse",
    /// on LS "unused".
    static func build(controls: [TouchControl], binds: [String: ControlAction]? = nil, mouseVertical: Double? = nil) -> PadBindings {
        var b = template
        if let v = mouseVertical, v.isFinite { b.mouseVertical = min(max(v, 0.25), 2.0) }
        for c in controls {
            guard let name = c.padBinding else { continue }
            if c.action.stickKeys != nil {
                if name == "LS" { b.leftStick = c.action }
                else if name == "RS" { b.rightStick = c.action }
            } else if buttonNames.contains(name), !c.action.isPad, c.action != .none {
                b.buttons[name] = c.action
            }
        }
        for (name, action) in binds ?? [:] where !action.isPad {
            if name == "LS" { b.leftStick = action.stickKeys != nil ? action : .none }
            else if name == "RS" { b.rightStick = action.stickKeys != nil ? action : .none }
            else if buttonNames.contains(name), action.stickKeys == nil { b.buttons[name] = action }
        }
        return b
    }

    /// What the template gives an input, for the binds page's "Default" rows.
    static func templateAction(_ name: String) -> ControlAction {
        switch name {
        case "LS": return template.leftStick
        case "RS": return template.rightStick
        default:   return template.buttons[name] ?? .none
        }
    }

    /// The binds page's row labels: XInput names in the table, Start/Select on screen.
    static func displayName(_ name: String) -> String {
        name == "Menu" ? "Start" : name == "View" ? "Select" : name
    }

    var usesMouseStick: Bool { rightStick.stickKeys == nil }
}


import Foundation
import SwiftUI
import UIKit

// ============================================================================
// ml1530/ml1970 — NAMED TOUCH-CONTROL LAYOUTS.
//
// A layout is the landscape editor's `TouchControlsModel.controls`. The user's
// own layouts ("Custom Layout 1", "Custom Layout 2", ...) are kept app-wide in
// Documents/madeira-control-presets.json, beside madeira-controls.json, so a
// device backup carries them. Built-ins ship in code and can be loaded but
// never changed: there is one, a full XInput layout named "Xbox controller".
//
// madeira-controls.json stays the working copy the overlay draws; it records
// which layout it was loaded from (`TouchControlsModel.layoutID`) so edits made
// in the editor are written back to that custom layout when editing ends.
//
// The layout menu is offered in two places: the landscape overlay's top bar
// (`ControlLayoutMenu`) and, in a library session, where LibraryHUD replaces
// that bar, as a "Controller layout" row of the in-game Session menu (the same
// view, `.row` style). A library game remembers its layout (`LibraryEntry.
// controlLayout`); other games and the overlay outside the library keep the
// one shared working copy.
//
// Switches (Documents/madeira.cfg `env.NAME = value`, or the environment):
//   MADEIRA_CONTROL_PRESETS=0        no layout menu, no write-back (default on)
//   MADEIRA_CONTROLS_XBOX_DEFAULT=1  a user with no controls file gets the
//                                    built-in once (default OFF: otherwise the
//                                    built-in is only applied from the menu)
// ============================================================================

// MARK: - Pure preset state (also compiled by the host regression test)

struct ControlPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var controls: [TouchControl]
}

/// The screen a built-in layout is placed on, in points, with its safe-area
/// insets. Built-ins are laid out in points from the edges and then normalised
/// to THIS screen, so one layout reads right on a phone and on a tablet.
struct ControlPresetScreen: Equatable {
    var width: Double
    var height: Double
    var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0

    /// The overlay is landscape-only, so a portrait screen is laid out as the
    /// landscape one it rotates to: the top/bottom insets move to the sides.
    var landscape: ControlPresetScreen {
        guard height > width else { return self }
        let side = max(top, bottom)
        return ControlPresetScreen(width: height, height: width, left: side, right: side,
                                   top: 0, bottom: min(bottom, 21))
    }

    /// A 6.3-inch phone in landscape: what the stored copy of a built-in is
    /// laid out for. Loading lays it out again for the real screen.
    static let referencePhone = ControlPresetScreen(width: 874, height: 402,
                                                    left: 59, right: 59, top: 0, bottom: 21)
}

enum ControlPresetLayout {
    static let xboxID = "builtin.xbox"
    static let xboxName = "Xbox controller"
    /// Mirrors `TouchControlsModel.baseDiameter`.
    static let baseDiameter = 64.0

    /// The margins a built-in keeps from each edge, whatever the reported insets.
    static func margins(_ s: ControlPresetScreen) -> (left: Double, right: Double, top: Double, bottom: Double) {
        (max(s.left, 16), max(s.right, 16), max(s.top, 8), max(s.bottom, 8))
    }

    /// The overlay's own buttons, centred at the top (TouchControlsModel.
    /// hitsInteractive claims this band). A built-in leaves it free.
    static func topBarRect(_ s: ControlPresetScreen) -> CGRect {
        CGRect(x: s.width / 2 - 100, y: 0, width: 200, height: 76)
    }

    /// The drawn bounding box, in points: `baseDiameter` × the control's scale
    /// for a round button, the pad button's own shape otherwise (a wide
    /// shoulder, a Start/Select pill), centred on its normalised position.
    static func box(_ c: TouchControl, screen s: ControlPresetScreen) -> CGRect {
        let z = c.action.controlSize(diameter: CGFloat(baseDiameter * c.scale))
        return CGRect(x: c.nx * s.width - Double(z.width) / 2, y: c.ny * s.height - Double(z.height) / 2,
                      width: Double(z.width), height: Double(z.height))
    }

    /// The built-in controller layout, using the editor's controller mappings:
    ///
    ///   LT LB  (top left)                              (top right)  RB RT
    ///   D-pad  above the left stick        A/B/X/Y diamond above the right stick
    ///   LS (bottom left)  L3    View  Menu     R3  RS (bottom right)
    ///
    /// Placed in points from the safe-area edges, then normalised. `k` scales
    /// the whole thing up on a tall (tablet) screen, where a phone-sized stick
    /// would be lost; every scale stays inside the editor's 0.5–3.0 pinch clamp.
    static func xbox(for screen: ControlPresetScreen) -> [TouchControl] {
        let s = screen.landscape
        let W = s.width, H = s.height
        guard W > 0, H > 0 else { return [] }
        let k = min(max(H / 400, 1.0), 1.3)
        let (L, R, T, B) = margins(s)
        var out: [TouchControl] = []
        func add(_ name: String, _ scale: Double, _ x: Double, _ y: Double) {
            var c = TouchControl()
            c.action = .pad(name)
            c.scale = scale
            c.nx = x / W
            c.ny = y / H
            out.append(c)
        }
        func d(_ scale: Double) -> Double { baseDiameter * scale }
        let stickScale = 1.45 * k, faceScale = 0.78 * k, dpadScale = 0.7 * k
        let shoulderScale = 0.88 * k, systemScale = 0.75 * k, clickScale = 0.62 * k

        // Sticks: bottom corners, clear of the home indicator.
        let stick = d(stickScale)
        let stickY = H - B - 12 * k - stick / 2
        let lStickX = L + 76 * k, rStickX = W - R - 76 * k
        add("LS", stickScale, lStickX, stickY)
        add("RS", stickScale, rStickX, stickY)
        let stickTop = stickY - stick / 2

        // Shoulders: a column in each top corner, trigger above bumper as on
        // the controller. Drawn 1.6× as wide as they are tall and 0.74 d high
        // (ControlAction.controlSize), so the column is two of those plus a gap.
        let sh = d(shoulderScale), shW = sh * 1.6, shH = sh * 0.74
        let shoulderX = shW / 2 + 6 * k
        let triggerY = T + 6 * k + shH / 2
        let bumperY = triggerY + shH + 8 * k
        add("LT", shoulderScale, L + shoulderX, triggerY)
        add("LB", shoulderScale, L + shoulderX, bumperY)
        add("RB", shoulderScale, W - R - shoulderX, bumperY)
        add("RT", shoulderScale, W - R - shoulderX, triggerY)
        // The columns' bottom and inner edge, for placing the D-pad cross and
        // the face diamond below them (or, on a short screen, inboard of them).
        let rowBottom = bumperY + shH / 2
        let columnInner = shoulderX + shW / 2 + 10 * k

        // D-pad: a tight cross at the left edge, between the shoulder column
        // and the stick, so the middle of the screen stays clear. When the
        // screen is too short for that stack (a phone with a tall column), the
        // cross moves inboard of the column instead and rises beside it.
        let dp = d(dpadScale), arm = dp + 6 * k
        let stacked = rowBottom + 8 * k + 2 * arm + dp <= stickTop - 8 * k
        let dpadX = stacked ? L + 6 * k + arm + dp / 2 : L + columnInner + arm + dp / 2
        let dpadY = stacked ? rowBottom + 8 * k + arm + dp / 2
                            : max(stickTop - 22 * k - arm - dp / 2, T + 6 * k + arm + dp / 2)
        add("D↑", dpadScale, dpadX, dpadY - arm)
        add("D←", dpadScale, dpadX - arm, dpadY)
        add("D→", dpadScale, dpadX + arm, dpadY)
        add("D↓", dpadScale, dpadX, dpadY + arm)

        // A/B/X/Y: a tight diamond at the right edge, mirroring the D-pad.
        // Diagonal neighbours sit o·√2 apart, which clears one face button's
        // diameter.
        let face = d(faceScale)
        let o = face / 2 + 22 * k
        let cx = stacked ? W - R - 6 * k - o - face / 2 : W - R - columnInner - o - face / 2
        let cy = stacked ? rowBottom + 8 * k + o + face / 2
                         : max(stickTop - 22 * k - o - face / 2, T + 6 * k + o + face / 2)
        add("Y", faceScale, cx, cy - o)
        add("X", faceScale, cx - o, cy)
        add("B", faceScale, cx + o, cy)
        add("A", faceScale, cx, cy + o)

        // View / Menu: bottom centre, between the sticks.
        let sys = d(systemScale)
        let sysY = H - B - 20 * k - sys / 2
        add("View", systemScale, W / 2 - 46 * k, sysY)
        add("Menu", systemScale, W / 2 + 46 * k, sysY)

        // L3 / R3: small buttons on the inner side of each stick, level with
        // its bottom edge.
        let click = d(clickScale)
        let clickY = stickY + stick / 2 - click / 2
        add("L3", clickScale, lStickX + stick / 2 + 20 * k + click / 2, clickY)
        add("R3", clickScale, rStickX - stick / 2 - 20 * k - click / 2, clickY)
        return out
    }
}

/// The layout list: built-ins (read-only, in code), then the user's own
/// (persisted). Pure value type; `ControlPresetsModel` owns the file.
struct ControlPresetStore: Equatable {
    static let builtIns: [ControlPreset] = [
        ControlPreset(id: ControlPresetLayout.xboxID, name: ControlPresetLayout.xboxName,
                      controls: ControlPresetLayout.xbox(for: .referencePhone)),
    ]
    static let maxNameLength = 40

    private(set) var user: [ControlPreset] = []

    init(user: [ControlPreset] = []) { self.user = user.filter { !Self.isBuiltIn($0.id) } }

    var all: [ControlPreset] { Self.builtIns + user }

    static func isBuiltIn(_ id: String) -> Bool { builtIns.contains { $0.id == id } }

    func preset(_ id: String) -> ControlPreset? { all.first { $0.id == id } }

    /// The id if a layout still has it, else nil: a game's remembered layout may
    /// have been deleted since, and controls that no layout holds are unsaved.
    func resolvedID(_ id: String?) -> String? { id.flatMap { preset($0)?.id } }

    static func clean(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    /// Case-insensitive, whitespace-trimmed: "xbox controller " IS the built-in.
    func named(_ name: String) -> ControlPreset? {
        let n = Self.clean(name).lowercased()
        guard !n.isEmpty else { return nil }
        return all.first { $0.name.lowercased() == n }
    }

    /// "Custom Layout N", the lowest N not taken.
    func nextCustomName() -> String {
        var n = 1
        while named("Custom Layout \(n)") != nil { n += 1 }
        return "Custom Layout \(n)"
    }

    enum SaveResult: Equatable {
        case created(String)      // new user layout, its id
        case replaced(String)     // an existing user layout of that name, its id
        case refusedBuiltIn       // the name is a built-in's: pick another
        case refusedEmpty
    }

    /// Save a layout under a name. A built-in's name is refused (built-ins are
    /// never overwritten); a user layout's name replaces that layout in place.
    mutating func save(name: String, controls: [TouchControl],
                       newID: () -> String = { UUID().uuidString }) -> SaveResult {
        let n = Self.clean(name)
        guard !n.isEmpty else { return .refusedEmpty }
        if let existing = named(n) {
            if Self.isBuiltIn(existing.id) { return .refusedBuiltIn }
            guard let i = user.firstIndex(where: { $0.id == existing.id }) else { return .refusedEmpty }
            user[i].controls = controls
            return .replaced(existing.id)
        }
        let id = newID()
        user.append(ControlPreset(id: id, name: n, controls: controls))
        return .created(id)
    }

    /// Overwrite a user layout's controls. false for a built-in or a missing id.
    mutating func overwrite(id: String, controls: [TouchControl]) -> Bool {
        guard let i = user.firstIndex(where: { $0.id == id }) else { return false }
        user[i].controls = controls
        return true
    }

    /// false for a built-in or a missing id.
    mutating func delete(id: String) -> Bool {
        guard let i = user.firstIndex(where: { $0.id == id }) else { return false }
        user.remove(at: i)
        return true
    }

    private struct File: Codable { var version: Int; var presets: [ControlPreset] }

    /// Only the user's layouts are written; built-ins live in code.
    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(File(version: 1, presets: user))
    }

    static func decoded(_ data: Data) throws -> ControlPresetStore {
        let f = try JSONDecoder().decode(File.self, from: data)
        guard f.version == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "preset file version \(f.version)"))
        }
        return ControlPresetStore(user: f.presets)
    }

    /// What loading a layout puts on screen: its controls with FRESH ids (a
    /// control's id keys its touch state, and two loads of one layout must not
    /// share them), positions inside the editor's drag clamp, and scales inside
    /// the pinch clamp. A built-in is laid out again for the screen it is
    /// loaded on.
    static func layout(of p: ControlPreset, screen: ControlPresetScreen?) -> [TouchControl] {
        var controls = p.controls
        if p.id == ControlPresetLayout.xboxID, let screen {
            let fitted = ControlPresetLayout.xbox(for: screen)
            if !fitted.isEmpty { controls = fitted }
        }
        return controls.map { c in
            var c = c
            c.id = UUID()
            c.nx = min(max(c.nx, 0.03), 0.97)
            c.ny = min(max(c.ny, 0.03), 0.97)
            c.scale = min(max(c.scale, 0.5), 3.0)
            return c
        }
    }
}

// MARK: - Persistence and overlay actions

/// Owns madeira-control-presets.json and applies layouts to TouchControlsModel.
/// Main thread only, like the overlay that drives it.
final class ControlPresetsModel: ObservableObject {
    static let shared = ControlPresetsModel()
    static let enabled = GamepadInput.flag("MADEIRA_CONTROL_PRESETS")
    /// Opt-in. "No madeira-controls.json" is not a fresh install: the file is
    /// only written once the controls or their visibility change, so an
    /// existing user who never touched them has none either and would get an
    /// 18-button overlay they did not ask for. Nothing on disk tells the two
    /// apart reliably, so the built-in is applied automatically only on request.
    static let xboxDefault = GamepadInput.optIn("MADEIRA_CONTROLS_XBOX_DEFAULT")

    @Published private(set) var store = ControlPresetStore()
    /// A file that exists and cannot be read is left untouched: saving is
    /// refused instead of overwriting it.
    private(set) var readOnly = false
    private var logged = 0

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gtaios-steamios-control-presets.json")
    }

    private init() {
        guard let d = try? Data(contentsOf: Self.url) else { return }
        do {
            store = try ControlPresetStore.decoded(d)
        } catch {
            readOnly = true
            log("unreadable file kept, saving disabled: \(error.localizedDescription)")
        }
    }

    /// The controller built-in needs touch XInput; without it its buttons are inert.
    private static var touchPad: Bool { MainActor.assumeIsolated { GamepadInput.touchEnabled } }

    /// What the layout menu lists.
    var available: [ControlPreset] {
        (Self.touchPad ? ControlPresetStore.builtIns : []) + store.user
    }

    var active: ControlPreset? { TouchControlsModel.shared.layoutID.flatMap { store.preset($0) } }

    /// On-screen controls that no layout holds: switching away would lose them.
    var currentIsUnsaved: Bool {
        let m = TouchControlsModel.shared
        return m.layoutID == nil && !m.controls.isEmpty
    }

    /// With MADEIRA_CONTROLS_XBOX_DEFAULT=1, a user with no madeira-controls.json gets the controller layout the
    /// first time the landscape overlay appears.
    var defaultPending: Bool {
        TouchControlsModel.shared.needsDefaultLayout && Self.enabled && Self.xboxDefault && Self.touchPad
    }

    private func log(_ line: String) {
        guard logged < 64 else { return }
        logged += 1
        fputs("[controls-layout] ml1970 \(line)\n", stderr)
    }

    @discardableResult private func persist() -> Bool {
        guard !readOnly else { return false }
        do {
            try store.encoded().write(to: Self.url, options: .atomic)
            return true
        } catch {
            log("write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The landscape screen the overlay is laid out on.
    static func currentScreen() -> ControlPresetScreen {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        guard let window, window.bounds.width > 0 else { return .referencePhone }
        let i = window.safeAreaInsets
        let s = ControlPresetScreen(width: Double(window.bounds.width), height: Double(window.bounds.height),
                                    left: Double(i.left), right: Double(i.right),
                                    top: Double(i.top), bottom: Double(i.bottom))
        return s.landscape
    }

    /// Never over a layout the user already has: only when no controls file existed.
    func applyDefaultIfNeeded(screen: ControlPresetScreen) {
        let m = TouchControlsModel.shared
        guard m.needsDefaultLayout else { return }
        let apply = defaultPending && m.controls.isEmpty
        m.needsDefaultLayout = false
        guard apply else { return }
        load(ControlPresetLayout.xboxID, screen: screen, reason: "new-user-default")
    }

    /// Replace the on-screen layout with this one.
    func load(_ id: String, screen: ControlPresetScreen, reason: String = "chosen") {
        guard let p = store.preset(id) else { return }
        let m = TouchControlsModel.shared
        let controls = ControlPresetStore.layout(of: p, screen: screen)
        m.selected = nil
        m.controls = controls
        m.layoutID = p.id
        log("loaded layout=\(ControlPresetStore.isBuiltIn(p.id) ? "xbox" : "custom") controls=\(controls.count) reason=\(reason)")
    }

    /// Keep the unsaved on-screen controls as the next "Custom Layout N".
    @discardableResult func keepCurrent() -> Bool {
        guard !readOnly else { return false }
        let m = TouchControlsModel.shared
        var s = store
        guard case .created(let id) = s.save(name: s.nextCustomName(), controls: m.controls) else { return false }
        store = s
        m.layoutID = id
        persist()
        log("kept on-screen controls as a custom layout controls=\(m.controls.count)")
        return true
    }

    /// "Create new layout": an empty custom layout, made active, opened in the editor.
    @discardableResult func createLayout() -> Bool {
        guard !readOnly else { return false }
        var s = store
        guard case .created(let id) = s.save(name: s.nextCustomName(), controls: []) else { return false }
        store = s
        persist()
        let m = TouchControlsModel.shared
        m.selected = nil
        m.controls = []
        m.layoutID = id
        m.visible = true
        m.editing = true
        log("created custom layout")
        return true
    }

    /// Delete a custom layout. The on-screen copy of a deleted active layout
    /// becomes the controller layout, or stays as unsaved controls without it.
    @discardableResult func delete(_ id: String) -> Bool {
        guard !readOnly else { return false }
        var s = store
        guard s.delete(id: id) else { return false }
        store = s
        persist()
        log("deleted custom layout")
        let m = TouchControlsModel.shared
        if m.layoutID == id {
            if Self.touchPad { load(ControlPresetLayout.xboxID, screen: Self.currentScreen(), reason: "deleted") }
            else { m.layoutID = nil }
        }
        return true
    }

    /// An edit session ended. Edits to a custom layout are written back to it;
    /// a built-in stays as shipped, so an edited copy of one becomes unsaved
    /// controls that the menu offers to keep before switching away.
    func editingEnded(baseline: [TouchControl]) {
        guard Self.enabled else { return }
        let m = TouchControlsModel.shared
        guard let id = m.layoutID else { return }
        if ControlPresetStore.isBuiltIn(id) {
            if baseline != m.controls {
                m.layoutID = nil
                log("edited built-in kept as unsaved controls=\(m.controls.count)")
            }
            return
        }
        var s = store
        guard !readOnly, s.overwrite(id: id, controls: m.controls) else { return }
        store = s
        persist()
        log("saved custom layout controls=\(m.controls.count)")
    }
}

// MARK: - Layout menu (landscape overlay, library session menu)

/// The layout menu: the controller built-in, the user's custom layouts,
/// "Create new layout" (opens the editor on an empty layout) and deleting the
/// active custom layout. Shown only while touch controls are on. `.glass` is
/// the overlay's round top-bar button; `.row` is a labelled row of the library
/// session's Session menu.
struct ControlLayoutMenu: View {
    enum Style { case glass, row }

    @ObservedObject private var presets = ControlPresetsModel.shared
    @ObservedObject private var m = TouchControlsModel.shared
    private let style: Style
    /// Called after a layout was loaded, created or deleted, with true when the
    /// editor was opened (a library session saves the game's profile, and closes
    /// its menu to show the editor).
    private let didChoose: ((_ openedEditor: Bool) -> Void)?

    init(style: Style = .glass, didChoose: ((_ openedEditor: Bool) -> Void)? = nil) {
        self.style = style
        self.didChoose = didChoose
    }

    private enum Choice: Equatable { case load(String), create }
    @State private var pending: Choice?
    @State private var confirmDelete: ControlPreset?

    var body: some View {
        Group {
            if style == .row {
                LabeledContent("Controller layout") { menu }
            } else {
                menu
            }
        }
        .alert("Keep the current controls?", isPresented: shown($pending)) {
            if !presets.readOnly {
                Button("Keep as \u{201C}\(presets.store.nextCustomName())\u{201D}") {
                    let choice = pending
                    pending = nil
                    presets.keepCurrent()
                    perform(choice)
                }
            }
            Button("Replace", role: .destructive) {
                let choice = pending
                pending = nil
                perform(choice)
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("The controls on screen are not saved in a layout.")
        }
        .alert("Delete \u{201C}\(confirmDelete?.name ?? "")\u{201D}?", isPresented: shown($confirmDelete)) {
            Button("Delete", role: .destructive) {
                if let p = confirmDelete, presets.delete(p.id) { didChoose?(false) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
    }

    private var menu: some View {
        Menu {
            Section("Controller layout") {
                ForEach(presets.available) { p in
                    Button { request(.load(p.id)) } label: {
                        if m.layoutID == p.id { Label(p.name, systemImage: "checkmark") }
                        else if ControlPresetStore.isBuiltIn(p.id) { Label(p.name, systemImage: "gamecontroller") }
                        else { Text(p.name) }
                    }
                }
            }
            if !presets.readOnly {
                Button("Create new layout", systemImage: "plus") { request(.create) }
            }
            if let a = presets.active, !ControlPresetStore.isBuiltIn(a.id), !presets.readOnly {
                Button("Delete \u{201C}\(a.name)\u{201D}", systemImage: "trash", role: .destructive) {
                    confirmDelete = a
                }
            }
        } label: {
            switch style {
            case .glass:
                // Same look as the overlay's glass buttons; stroke glyph only.
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(GlassShape(circle: true))
            case .row:
                HStack(spacing: 4) {
                    Text(presets.active?.name ?? "Custom")
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }
        }
        .accessibilityLabel("Controller layout")
    }

    private func shown<T>(_ b: Binding<T?>) -> Binding<Bool> {
        Binding(get: { b.wrappedValue != nil }, set: { if !$0 { b.wrappedValue = nil } })
    }

    private func request(_ choice: Choice) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if presets.currentIsUnsaved { pending = choice } else { perform(choice) }
    }

    private func perform(_ choice: Choice?) {
        switch choice {
        case .load(let id):
            presets.load(id, screen: ControlPresetsModel.currentScreen())
            didChoose?(false)
        case .create:
            if presets.createLayout() { didChoose?(true) }
        case nil: break
        }
    }
}

// GTA native input bridge supports the same controller layout model.
enum GamepadInput {
    static let keyboardMouseAvailable = true
    static let touchEnabled = true
    static func flag(_ name: String) -> Bool {
        ["MADEIRA_CONTROL_PRESETS", "MADEIRA_CONTROLS_EDITOR_DONE"].contains(name)
    }
    static func optIn(_ name: String) -> Bool { name == "MADEIRA_CONTROLS_XBOX_DEFAULT" }
}
extension TouchControlsModel {
    func ensureDefaultLayout() {
        guard controls.isEmpty else { return }
        ControlPresetsModel.shared.load(ControlPresetLayout.xboxID,
            screen: ControlPresetsModel.currentScreen(), reason: "initial-GTA-layout")
        needsDefaultLayout = false
    }
    func resetDefaultLayout() {
        ControlPresetsModel.shared.load(ControlPresetLayout.xboxID,
            screen: ControlPresetsModel.currentScreen(), reason: "reset-GTA-layout")
        needsDefaultLayout = false
        selected = nil
    }
}
// The entire original SteamIOS editor, previewed without launching GTA V.
// Live gamepad input is neutral while editing, never sent to a fake game.
final class SteamIOSControllerEditorViewController: UIViewController {
    private var host: UIHostingController<TouchControlsOverlay>?
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.025, green: 0.045, blue: 0.075, alpha: 1)
        TouchControlsModel.shared.ensureDefaultLayout()
        TouchControlsModel.shared.editing = true
        TouchControlsModel.shared.selected = nil
        let hosting = UIHostingController(rootView: TouchControlsOverlay())
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hosting.didMove(toParent: self)
        host = hosting
        let back = UIButton(type: .system)
        var style = UIButton.Configuration.filled()
        style.title = "Back to Controls"
        style.baseBackgroundColor = UIColor.black.withAlphaComponent(0.75)
        style.baseForegroundColor = .white
        back.configuration = style
        back.translatesAutoresizingMaskIntoConstraints = false
        back.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        view.addSubview(back)
        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            back.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])
        LogStore.shared.write("controls", "Full SteamIOS controller layout editor opened")
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        TouchControlsModel.shared.editing = false
        TouchControlsModel.shared.selected = nil
        SteamIOSGamepadInput.shared.stop()
        LogStore.shared.write("controls", "SteamIOS controller layout editor closed")
    }
}
