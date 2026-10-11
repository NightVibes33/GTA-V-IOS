import Foundation
import UIKit
import GameController
import CoreHaptics
import Metal

@objc(GTAIOSSceneDelegate)
final class GTAIOSSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        LogStore.shared.write("scene", "Scene connected: \(session.persistentIdentifier)")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification,
                                        object: UIApplication.shared)
        LogStore.shared.write("scene", "Scene active; native event loop resumed")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                        object: UIApplication.shared)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification,
                                        object: UIApplication.shared)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification,
                                        object: UIApplication.shared)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        LogStore.shared.write("scene", "Scene disconnected")
    }
}

@_cdecl("gtaios_active_window_scene")
public func gtaiosActiveWindowScene() -> UnsafeMutableRawPointer? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
        ?? scenes.first(where: { $0.activationState == .foregroundInactive })
        ?? scenes.first else {
        LogStore.shared.write("scene", "Winit requested a window without an active UIScene")
        return nil
    }
    return Unmanaged.passUnretained(scene).toOpaque()
}


// Native Muguet build entry point. The visual interface is the project's
// original five-tab UIKit GTAFiveTabLauncher, not upstream Muguet's SwiftUI UI.
@_silgen_name("muguet_mount_external")
private func muguet_mount_external(_ path: UnsafePointer<CChar>) -> Bool
@_silgen_name("muguet_import_error")
private func muguet_import_error() -> UnsafePointer<CChar>?
@_silgen_name("muguet_game_ready")
private func muguet_game_ready() -> Bool
@_silgen_name("muguet_has_game_code")
private func muguet_has_game_code() -> Bool
@_silgen_name("muguet_unmount_external")
private func muguet_unmount_external()

@MainActor enum GTAIOSOrientation { static var playing = false }
@MainActor enum GTAIOSLandscape {
    static func enforce(_ finished: @escaping () -> Void) {
        GTAIOSOrientation.playing = true
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            LogStore.shared.write("orientation", "Landscape scene not available")
            finished()
            return
        }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(
                interfaceOrientations: .landscapeRight)) { error in
                LogStore.shared.write("orientation", "Landscape request error: \(error.localizedDescription)")
            }
            scene.windows.forEach {
                $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
        UIViewController.attemptRotationToDeviceOrientation()
        DispatchQueue.main.async {
            LogStore.shared.write("orientation", "Landscape requested; actual=\(scene.interfaceOrientation.rawValue)")
            finished()
        }
    }
}
enum NativeRuntimeBridge {
    static var launch: (() -> Void)?
    @MainActor static func play() {
        guard muguet_has_game_code(), muguet_game_ready(),
              USBStorageManager.shared.root != nil else {
            GTAReference.present("Cannot start GTA V",
                message: "Select the external game library and check that the engine is included in this IPA.",
                from: UIApplication.shared.windows.first?.rootViewController ?? UIViewController())
            return
        }
        do {
            try NativeMuguetSettings.save()
            TouchControlsModel.shared.ensureDefaultLayout()
            SteamIOSGamepadInput.shared.reserveSessionSlot()
            GTAIOSInputSensitivity.apply()
            LogStore.shared.write("native", "Starting embedded engine with external game library")
            GTAIOSLandscape.enforce { launch?() }
        } catch {
            LogStore.shared.write("native", "Settings write failed: \(error)")
        }
    }
}

@_cdecl("muguet_show_launcher")
public func muguetShowLauncher(_ viewController: UnsafeMutableRawPointer,
                               _ done: @convention(c) () -> Void) {
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let launcher = GTAFiveTabController()
    launcher.modalPresentationStyle = .fullScreen
    launcher.isModalInPresentation = true
    NativeRuntimeBridge.launch = { [weak launcher] in
        guard let launcher else { return }
        launcher.dismiss(animated: false) {
            done()
            DispatchQueue.main.async {
                GTAIOSLandscape.enforce {
                    TouchControlsHost.attach()
                    LogStore.shared.write("controls", "SteamIOS gameplay overlay attached in landscape")
                }
            }
        }
        NativeRuntimeBridge.launch = nil
    }
    parent.present(launcher, animated: false)
}

final class USBStorageManager {
    static let shared = USBStorageManager()
    static let changedNotification = Notification.Name("GTAiOS.NativeLibraryDidChange")
    private static let bookmarkKey = "gtaios.native.external-folder"
    private(set) var root: URL?
    private var securedURL: URL?
    var startupPathCount: Int { 2 }

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            chooseAsync(url, fromFile: false) { result in
                if case .failure(let error) = result {
                    LogStore.shared.write("usb", "Bookmark restoration failed: \(error.localizedDescription)")
                }
            }
        } catch {
            LogStore.shared.write("usb", "Cannot resolve external library bookmark: \(error)")
        }
    }

    func missingStartupAssets() -> [String] {
        guard let root else { return ["data/manifest.json", "b/8b0b5899ed/shaders/index.json"] }
        return ["data/manifest.json", "b/8b0b5899ed/shaders/index.json"].filter {
            !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    func chooseAsync(_ url: URL, fromFile: Bool,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        let choice = fromFile ? url.deletingLastPathComponent() : url
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = choice.startAccessingSecurityScopedResource()
            let root = ["", "playgta5.com", "mirror/playgta5.com",
                        "mirror/mirror/playgta5.com"].map {
                choice.appendingPathComponent($0, isDirectory: true)
            }.first {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("data/manifest.json").path)
            }
            let ok = choice.path.withCString { muguet_mount_external($0) }
            let message = muguet_import_error().map { String(cString: $0) }
            let ready = ok && muguet_game_ready() && root != nil
            let bookmark = ready ? (try? choice.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) : nil
            if !ready && scoped { choice.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard ready, let root else {
                    let error = NSError(domain: "GTAiOS.NativeLibrary", code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            message ?? "Select a readable folder containing data/manifest.json and b/8b0b5899ed/shaders/index.json."])
                    completion(.failure(error))
                    return
                }
                // The sandbox grant must outlive the engine's asynchronous I/O threads.
                if let previous = self.securedURL { previous.stopAccessingSecurityScopedResource() }
                self.securedURL = scoped ? choice : nil
                self.root = root
                if let bookmark { UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey) }
                LogStore.shared.write("usb", "Mounted native game library: \(root.lastPathComponent)")
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
                completion(.success(()))
            }
        }
    }

    func disconnect(completion: @escaping () -> Void) {
        securedURL?.stopAccessingSecurityScopedResource()
        securedURL = nil
        root = nil
        muguet_unmount_external()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        LogStore.shared.write("usb", "External game library unmounted")
        completion()
    }
}

enum NativeEngineStatus {
    struct Inspection { let byteCount: Int64 }
    static var nativeEngineLinked: Bool { muguet_has_game_code() }
    static func inspect(_ completion: @escaping (Result<Inspection, Error>) -> Void) {
        guard let root = USBStorageManager.shared.root else {
            completion(.failure(NSError(domain: "GTAiOS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose a game folder first."])))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let url = root.appendingPathComponent("data/manifest.json")
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let data = try Data(contentsOf: url)
                _ = try JSONSerialization.jsonObject(with: data)
                let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
                DispatchQueue.main.async { completion(.success(Inspection(byteCount: bytes))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

@_silgen_name("muguet_steamios_set_mouse_sensitivity")
private func muguet_steamios_set_mouse_sensitivity(_ value: Double)
@_silgen_name("muguet_steamios_set_stick_gain")
private func muguet_steamios_set_stick_gain(_ value: Double)

@MainActor enum GTAIOSInputSensitivity {
    static func apply() {
        let mouse = UserDefaults.standard.object(forKey: ControllerManager.sensitivityKey) as? Double ?? 2.0
        let stick = UserDefaults.standard.object(forKey: "gtaios.native.touchSensitivity") as? Double ?? 2.0
        muguet_steamios_set_mouse_sensitivity(min(max(mouse, 0.25), 12.0))
        muguet_steamios_set_stick_gain(min(max(stick, 0.25), 12.0))
        LogStore.shared.write("controls", "Live sensitivity mouse=\(mouse) stick=\(stick)")
    }
}
enum ControllerManager {
    static let deadzoneKey = "gtaios.native.deadzone"
    static let sensitivityKey = "gtaios.native.lookSensitivity"
    static let invertYKey = "gtaios.native.invertY"
    static let shared = ControllerManagerImpl()
}
final class ControllerManagerImpl {
    private var activeEngine: CHHapticEngine?
    func testRumble() -> Bool {
        guard let haptics = GCController.controllers().first?.haptics,
              let engine = haptics.createEngine(withLocality: .default) else { return false }
        do {
            let event = CHHapticEvent(eventType: .hapticContinuous,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                             CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)],
                relativeTime: 0, duration: 0.15)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.start()
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
            activeEngine = engine
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                engine.stop(completionHandler: nil)
                self?.activeEngine = nil
            }
            return true
        } catch { return false }
    }
}
enum ControllerSettingsViewController {
    static let bindingKey = "gtaios.native.controllerBindings"
}
final class NativePCMOutput {
    static let shared = NativePCMOutput()
    func setMasterVolume(_ volume: Float) {
        GTALaunchPreferences.setFraction("masterVolume", value: Double(volume))
    }
}

enum NativeMuguetSettings {
    static var configURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("config.json")
    }
    static func save() throws {
        let existing = (try? Data(contentsOf: configURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var json = existing
        json["start_mode"] = EngineOptions.value("mode") == "story" ? 1 : 2
        json["scale"] = Double(EngineOptions.value("scale")) ?? 0.65
        json["fps_limit"] = Int(EngineOptions.value("fps")) ?? 30
        json["texture_quality"] = Int(EngineOptions.value("textureQuality")) ?? 0
        json["touch_sensitivity"] = UserDefaults.standard.object(forKey: "gtaios.native.touchSensitivity") as? Double ?? 2.0
        json["mouse_sensitivity"] = UserDefaults.standard.object(forKey: ControllerManager.sensitivityKey) as? Double ?? 2.0
        json["mute"] = GTALaunchPreferences.enabled("mute", fallback: false)
        json["master_volume"] = GTALaunchPreferences.fraction("masterVolume", fallback: 1.0)
        json["multiplayer"] = UserDefaults.standard.bool(forKey: "gtaios.native.multiplayer")
        json["host"] = UserDefaults.standard.bool(forKey: "gtaios.native.host")
        json["server"] = UserDefaults.standard.string(forKey: "gtaios.native.server") ?? ""
        json["player_name"] = UserDefaults.standard.string(forKey: "gtaios.native.name") ?? UIDevice.current.name
        var args: [String] = []
        if EngineOptions.value("newgame") == "1" { args.append("-noautoload") }
        for key in ["shadowQuality","reflectionQuality","particleQuality","grassQuality",
                    "cityDensity","lodScale","pedVariety","vehicleVariety",
                    "pedLodBias","vehicleLodBias"] {
            let value = EngineOptions.value(key)
            if !value.isEmpty { args.append("-\(key)=\(value)") }
        }
        json["extra_args"] = args
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        LogStore.shared.write("settings", "Saved real native engine configuration")
    }
}

// This tab takes the place of the legacy WASM-host controller debugger.
// It edits Muguet's actual sensitivity/mute fields, not inactive remapping.
final class GTANativeControlsViewController: GTAReferencePage {
    override func viewDidLoad() {
        super.viewDidLoad()
        stack.addArrangedSubview(GTAReference.section("Controls"))
        let panel = GTAReference.panelView()
        panel.addArrangedSubview(GTAReference.label("Native Game Controls", size: 18, weight: .bold))
        let name = GCController.controllers().first?.vendorName ?? "No physical controller connected"
        panel.addArrangedSubview(GTAReference.label(name, size: 12, color: GTAReference.green))
        addSlider("Right-stick look speed", key: "gtaios.native.touchSensitivity",
                  fallback: 2, min: 0.25, max: 12, panel: panel)
        addSlider("Camera and mouse sensitivity", key: ControllerManager.sensitivityKey,
                  fallback: 2, min: 0.25, max: 12, panel: panel)
        let mute = UISwitch()
        mute.isOn = GTALaunchPreferences.enabled("mute", fallback: false)
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.addArrangedSubview(GTAReference.label("Mute game audio", size: 14))
        row.addArrangedSubview(UIView())
        row.addArrangedSubview(mute)
        mute.addAction(UIAction { _ in
            GTALaunchPreferences.setEnabled("mute", value: mute.isOn)
        }, for: .valueChanged)
        panel.addArrangedSubview(row)
        stack.addArrangedSubview(panel)
        let overlay = UISwitch()
        overlay.isOn = InputSettings.shared.controllerOverlayEnabled
        let overlayRow = UIStackView()
        overlayRow.axis = .horizontal
        overlayRow.alignment = .center
        overlayRow.addArrangedSubview(GTAReference.label("SteamIOS custom touch controller", size: 14))
        overlayRow.addArrangedSubview(UIView())
        overlayRow.addArrangedSubview(overlay)
        overlay.addAction(UIAction { _ in
            InputSettings.shared.controllerOverlayEnabled = overlay.isOn
            LogStore.shared.write("controls", "SteamIOS touch overlay enabled=\(overlay.isOn)")
        }, for: .valueChanged)
        panel.addArrangedSubview(overlayRow)
        let swipe = UISwitch()
        swipe.isOn = GTAIOSSwipeLookSettings.enabled
        let swipeRow = UIStackView()
        swipeRow.axis = .horizontal
        swipeRow.alignment = .center
        swipeRow.addArrangedSubview(GTAReference.label("Swipe to look (optional)", size: 14))
        swipeRow.addArrangedSubview(UIView())
        swipeRow.addArrangedSubview(swipe)
        swipe.addAction(UIAction { _ in
            GTAIOSSwipeLookSettings.enabled = swipe.isOn
        }, for: .valueChanged)
        panel.addArrangedSubview(swipeRow)
        panel.addArrangedSubview(GTAReference.label(
            "Drag on empty gameplay space to look around. Original SteamIOS sticks and buttons remain active.",
            size: 12, color: GTAReference.secondary))
        panel.addArrangedSubview(GTAReference.label("Swipe look sensitivity", size: 13,
                                                   weight: .semibold))
        let swipeSensitivity = UISlider()
        swipeSensitivity.minimumValue = 0.25
        swipeSensitivity.maximumValue = 12.0
        swipeSensitivity.value = Float(GTAIOSSwipeLookSettings.sensitivity)
        swipeSensitivity.addAction(UIAction { _ in
            GTAIOSSwipeLookSettings.sensitivity = Double(swipeSensitivity.value)
        }, for: .valueChanged)
        panel.addArrangedSubview(swipeSensitivity)
        let edit = GTAReference.control("Edit SteamIOS Controller Layout", symbol: "slider.horizontal.3")
        edit.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let editor = SteamIOSControllerEditorViewController()
            editor.modalPresentationStyle = .fullScreen
            self.present(editor, animated: true)
        }, for: .touchUpInside)
        panel.addArrangedSubview(edit)
        let reset = GTAReference.control("Reset SteamIOS Layout", symbol: "arrow.counterclockwise")
        reset.addAction(UIAction { _ in
            TouchControlsModel.shared.resetDefaultLayout()
            LogStore.shared.write("controls", "SteamIOS touch layout reset to original default")
        }, for: .touchUpInside)
        panel.addArrangedSubview(reset)
        stack.addArrangedSubview(GTAReference.label(
            "Original SteamIOS layout: uncolored glass controls, dual analog sticks, movable and resizable buttons, and keyboard/gamepad mapping. No Xbox presets or colored buttons.",
            size: 12, color: GTAReference.secondary))
    }
    private func addSlider(_ title: String, key: String, fallback: Double,
                           min: Double, max: Double, panel: UIStackView) {
        panel.addArrangedSubview(GTAReference.label(title, size: 13, weight: .semibold))
        let slider = UISlider()
        slider.minimumValue = Float(min)
        slider.maximumValue = Float(max)
        slider.value = Float(UserDefaults.standard.object(forKey: key) as? Double ?? fallback)
        slider.tintColor = GTAReference.green
        slider.addAction(UIAction { _ in
            UserDefaults.standard.set(Double(slider.value), forKey: key)
            GTAIOSInputSensitivity.apply()
        }, for: .valueChanged)
        panel.addArrangedSubview(slider)
    }
}


// Engine-supported local multiplayer settings from upstream Muguet.
// The stored host/join parameters are written to config.json at Play.
final class GTANativeMultiplayerViewController: GTAReferencePage {
    private let enabledSwitch = UISwitch()
    private let role = UISegmentedControl(items: ["Join", "Host"])
    private let nameField = UITextField()
    private let serverField = UITextField()
    private let form = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        let back = GTAReference.control("Back to Graphics", symbol: "chevron.left")
        back.addAction(UIAction { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(back)
        stack.addArrangedSubview(GTAReference.section("Multiplayer"))
        let panel = GTAReference.panelView()
        let enableRow = UIStackView()
        enableRow.axis = .horizontal
        enableRow.alignment = .center
        enableRow.addArrangedSubview(GTAReference.label("Play with friends", size: 14, weight: .semibold))
        enableRow.addArrangedSubview(UIView())
        enabledSwitch.isOn = UserDefaults.standard.bool(forKey: "gtaios.native.multiplayer")
        enabledSwitch.addAction(UIAction { [weak self] _ in
            UserDefaults.standard.set(self?.enabledSwitch.isOn ?? false, forKey: "gtaios.native.multiplayer")
            self?.updateVisibility()
        }, for: .valueChanged)
        enableRow.addArrangedSubview(enabledSwitch)
        panel.addArrangedSubview(enableRow)

        form.axis = .vertical
        form.spacing = 14
        role.selectedSegmentIndex = UserDefaults.standard.bool(forKey: "gtaios.native.host") ? 1 : 0
        role.addAction(UIAction { [weak self] _ in
            UserDefaults.standard.set(self?.role.selectedSegmentIndex == 1, forKey: "gtaios.native.host")
            self?.updateVisibility()
        }, for: .valueChanged)
        form.addArrangedSubview(GTAReference.label("Session", size: 13, weight: .semibold))
        form.addArrangedSubview(role)
        nameField.text = UserDefaults.standard.string(forKey: "gtaios.native.name") ?? UIDevice.current.name
        nameField.placeholder = "Player name"
        nameField.textColor = GTAReference.ink
        nameField.autocorrectionType = .no
        nameField.borderStyle = .roundedRect
        nameField.addAction(UIAction { [weak self] _ in
            UserDefaults.standard.set(self?.nameField.text ?? "", forKey: "gtaios.native.name")
        }, for: .editingChanged)
        form.addArrangedSubview(GTAReference.label("Your name", size: 13, weight: .semibold))
        form.addArrangedSubview(nameField)

        serverField.text = UserDefaults.standard.string(forKey: "gtaios.native.server")
        serverField.placeholder = "Host IP address"
        serverField.textColor = GTAReference.ink
        serverField.borderStyle = .roundedRect
        serverField.keyboardType = .numbersAndPunctuation
        serverField.autocorrectionType = .no
        serverField.autocapitalizationType = .none
        serverField.addAction(UIAction { [weak self] _ in
            UserDefaults.standard.set(self?.serverField.text ?? "", forKey: "gtaios.native.server")
        }, for: .editingChanged)
        form.addArrangedSubview(GTAReference.label("Server address (joining only)", size: 13, weight: .semibold))
        form.addArrangedSubview(serverField)
        panel.addArrangedSubview(form)
        stack.addArrangedSubview(panel)
        stack.addArrangedSubview(GTAReference.label(
            "Muguet host/join mode uses your local network. These parameters are passed directly to the native game runtime when Play is pressed.",
            size: 12, color: GTAReference.secondary))
        updateVisibility()
    }
    private func updateVisibility() {
        form.isHidden = !enabledSwitch.isOn
        serverField.isEnabled = role.selectedSegmentIndex == 0
        serverField.alpha = serverField.isEnabled ? 1 : 0.35
    }
}
