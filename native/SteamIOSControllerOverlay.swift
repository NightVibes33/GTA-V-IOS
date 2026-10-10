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

final class InputSettings: ObservableObject {
    static let shared = InputSettings()
    @Published var controllerOverlayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(controllerOverlayEnabled, forKey: "gtaios.steamios.controls.enabled")
            if !controllerOverlayEnabled {
                Task { @MainActor in
                    SteamIOSGamepadInput.shared.configureTouch(controls: [])
                }
            }
        }
    }
    private init() {
        controllerOverlayEnabled =
            (UserDefaults.standard.object(forKey: "gtaios.steamios.controls.enabled") as? Bool) ?? true
    }
}

@MainActor final class SteamIOSGamepadInput {
    static let shared = SteamIOSGamepadInput()
    private var state = TouchGamepadState()
    func configureTouch(controls: Set<UUID>) { state.configure(controls); publish() }
    func touch(owner: UUID, control: UUID, value: GamepadSample?) {
        state.update(owner: owner, control: control, value: value)
        publish()
    }
    func stop() { state.configure([]); publish() }
    private func publish() {
        let p = state.sample
        muguet_steamios_pad_update(state.connected, p.buttons, p.lt, p.rt, p.lx, p.ly, p.rx, p.ry)
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

enum GTAIOSSteamKeyboard {
    private static weak var input: UITextField?
    static func toggle() {
        guard let root = UIApplication.shared.windows.first?.rootViewController?.view else { return }
        if let input, input.isFirstResponder { input.resignFirstResponder(); return }
        let field: UITextField
        if let input { field = input }
        else {
            field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            field.autocorrectionType = .no
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
    var connected: Bool { !allowed.isEmpty }

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
    var isPad: Bool { if case .pad = self { return true }; return false }
    var padName: String? { if case .pad(let name) = self { return name }; return nil }
    var isPadStick: Bool { padName == "LS" || padName == "RS" }

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
}

final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    static let baseDiameter: CGFloat = 64

    @Published var controls: [TouchControl] = [] { didSet { save() } }
    @Published var visible = false              { didSet { save() } }
    @Published var editing = false              // transient, never persisted
    @Published var selected: UUID?              // transient

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gtaios-steamios-controls.json")
    }

    private static let currentLayoutVersion = 2

    private struct Saved: Codable {
        var controls: [TouchControl]
        var visible: Bool
        var layoutVersion: Int?
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            controls = Self.migrateLayout(
                s.controls.isEmpty ? Self.defaultLayout() : s.controls,
                from: s.layoutVersion ?? 1)
            visible = false
        } else {
            controls = Self.defaultLayout()
            visible = false
        }
        loading = false
        save()
    }

    private static func defaultLayout() -> [TouchControl] {
        func c(_ x: Double, _ y: Double, _ scale: Double, _ action: ControlAction) -> TouchControl {
            TouchControl(nx: x, ny: y, scale: scale, action: action)
        }
        return [
            c(0.15, 0.70, 1.65, .pad("LS")),
            c(0.70, 0.70, 1.55, .pad("RS")),
            c(0.25, 0.84, 0.78, .pad("L3")),
            c(0.72, 0.84, 0.78, .pad("R3")),
            c(0.89, 0.68, 1.00, .pad("A")),
            c(0.94, 0.57, 1.00, .pad("B")),
            c(0.84, 0.57, 1.00, .pad("X")),
            c(0.89, 0.46, 1.00, .pad("Y")),
            c(0.08, 0.49, 0.86, .pad("D↑")),
            c(0.08, 0.63, 0.86, .pad("D↓")),
            c(0.03, 0.56, 0.86, .pad("D←")),
            c(0.13, 0.56, 0.86, .pad("D→")),
            c(0.13, 0.16, 0.92, .pad("LB")),
            c(0.22, 0.13, 0.92, .pad("LT")),
            c(0.78, 0.13, 0.92, .pad("RT")),
            c(0.87, 0.16, 0.92, .pad("RB")),
            c(0.43, 0.16, 0.78, .pad("View")),
            c(0.50, 0.11, 0.78, .pad("Guide")),
            c(0.57, 0.16, 0.78, .pad("Menu"))
        ]
    }

    private static func migrateLayout(_ input: [TouchControl], from version: Int) -> [TouchControl] {
        guard version < currentLayoutVersion else { return input }
        var migrated = input

        func normalizeThumbClick(_ name: String, x: Double) {
            var keptOne = false
            migrated.removeAll { control in
                guard control.action.padName == name else { return false }
                if !keptOne {
                    keptOne = true
                    return false
                }
                return true
            }
            if !keptOne {
                migrated.append(TouchControl(nx: x, ny: 0.84, scale: 0.78, action: .pad(name)))
            }
        }

        // v2 completes and de-duplicates old saved layouts without replacing
        // any other user positions/remaps. After migration the version is
        // persisted, so later deliberate user deletion remains respected.
        normalizeThumbClick("L3", x: 0.25)
        normalizeThumbClick("R3", x: 0.72)
        return migrated
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(
            Saved(controls: controls, visible: visible,
                  layoutVersion: Self.currentLayoutVersion))
        else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    func ensureDefaultLayout() {
        if controls.isEmpty { controls = Self.defaultLayout() }
    }

    func resetDefaultLayout() {
        controls = Self.defaultLayout()
        selected = nil
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
    func hitsInteractive(_ p: CGPoint, in bounds: CGRect) -> Bool {
        guard InputSettings.shared.controllerOverlayEnabled else { return false }
        // Done/Add exist only while editing. Normal gameplay has NO overlay
        // chrome; Steam Settings is opened with the three-finger gesture.
        if editing {
            let barW: CGFloat = 2 * 44 + 10
            if CGRect(x: bounds.midX - barW / 2 - 10, y: 0,
                      width: barW + 20, height: 68).contains(p) { return true }
        }
        for c in controls {
            let r = Self.baseDiameter * CGFloat(c.scale) / 2
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
final class ControlsWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let m = TouchControlsModel.shared
        // The controller/editor is landscape-only. Portrait draws nothing here,
        // so the transparent UIWindow must NEVER trap Steam's touchscreen.
        guard bounds.width > bounds.height else { return nil }
        // Edit mode owns the landscape screen: drags and the scale pinch must not
        // leak through and swing the camera while controls are being arranged.
        if m.editing { return super.hitTest(point, with: event) }
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
    @ObservedObject private var input = InputSettings.shared
    @State private var pinchBase: Double?

    var body: some View {
        GeometryReader { geo in
            // Landscape only; portrait keeps the existing key row and joystick.
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: .top) {
                if landscape {
                    if input.controllerOverlayEnabled || m.editing {
                        ForEach(m.controls) { c in
                            TouchControlButton(control: c, screen: geo.size)
                        }
                    }
                    if m.editing { topBar }
                    if m.editing, let i = m.index(of: m.selected) {
                        MappingPanel(control: m.controls[i], screen: geo.size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(scalePinch, including: m.editing ? .all : .subviews)
            .onAppear { configureGamepad(landscape: landscape) }
            .onChange(of: geo.size) { _ in configureGamepad(landscape: landscape) }
            .onChange(of: m.controls) { _ in configureGamepad(landscape: landscape) }
            .onChange(of: input.controllerOverlayEnabled) { enabled in
                if !enabled {
                    m.editing = false
                    m.selected = nil
                }
                configureGamepad(landscape: landscape)
            }
            .onChange(of: m.editing) { _ in configureGamepad(landscape: landscape) }
            .onDisappear { SteamIOSGamepadInput.shared.configureTouch(controls: []) }
        }
        .ignoresSafeArea()
    }

    private func configureGamepad(landscape: Bool) {
        let ids = landscape && input.controllerOverlayEnabled && !m.editing
            ? m.controls.filter { $0.action.padName.map(TouchPadAction.supported) ?? false }.map(\.id) : []
        SteamIOSGamepadInput.shared.configureTouch(controls: Set(ids))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            glassButton("checkmark") {
                m.editing = false
                m.selected = nil
            }
            glassButton("plus") {
                var c = TouchControl()
                c.nx = 0.5 + Double(m.controls.count % 3) * 0.06
                c.ny = 0.5 + Double(m.controls.count % 2) * 0.06
                m.controls.append(c)
                m.selected = c.id
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
struct GlassShape: View {
    var circle = false
    var body: some View {
        // SteamIOS Liquid Glass when compiled against the iOS 26 SDK.
        // Older Xcode images compile a material fallback instead.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if circle {
                Circle().fill(.clear).glassEffect(.regular, in: Circle())
            } else {
                RoundedRectangle(cornerRadius: 18).fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }
    private var fallback: some View {
        Group {
            if circle {
                Circle().fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(.white.opacity(0.27), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
            }
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

    private var diameter: CGFloat { TouchControlsModel.baseDiameter * CGFloat(control.scale) }
    private var isStick: Bool { control.action.stickKeys != nil || control.action.isPadStick }
    private var isSelected: Bool { m.editing && m.selected == control.id }

    var body: some View {
        ZStack {
            if control.action.isPadStick {
                GlassShape(circle: true)
                Circle().fill(.white.opacity(isDown ? 0.55 : 0.25))
                    .frame(width: diameter * 0.42, height: diameter * 0.42)
                    .offset(x: padVector.width * diameter * 0.29, y: padVector.height * diameter * 0.29)
                Text(control.action.label).font(.caption).foregroundStyle(.white.opacity(0.8))
            } else if control.action.stickKeys != nil {
                GlassShape(circle: true)
                Circle().fill(.white.opacity(isDown ? 0.55 : 0.25))
                    .frame(width: diameter * 0.42, height: diameter * 0.42)
                Text(control.action.label).font(.caption).foregroundStyle(.white.opacity(0.8))
            } else {
                GlassShape(circle: true)
                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(isSelected ? 0.95
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
        .onChange(of: m.editing) { _ in if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: screen) { _ in if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: control.action) { _ in
            padVector = .zero; isDown = false
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
        let r  = TouchControlsModel.baseDiameter * CGFloat(control.scale) / 2
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
            Text("Controller mappings feed GTA V native input. LS and RS are analogue sticks; "
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
            section("System", [("Menu", .pad("Menu")), ("View", .pad("View")),
                               ("Guide", .pad("Guide"))])
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

