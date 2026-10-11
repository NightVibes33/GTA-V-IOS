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
        if !GTAIOSOrientation.playing { USBStorageManager.shared.restoreIfNeeded() }
        if !GTAIOSOrientation.playing, let windowScene = scene as? UIWindowScene {
            windowScene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)
            ) { error in
                LogStore.shared.write("orientation", "Portrait launcher request: \(error.localizedDescription)")
            }
            windowScene.windows.forEach {
                $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            LogStore.shared.write("orientation", "Portrait enforced on launcher activation")
        }
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
    // Called only after the portrait-only launcher is dismissed. The Rust
    // winit event loop switches the underlying Metal controller to landscape
    // when it receives the Play callback; never request landscape while the
    // portrait launcher is still the visible controller.
    static func enforce(_ finished: @escaping () -> Void) {
        GTAIOSOrientation.playing = true
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            LogStore.shared.write("orientation", "Landscape scene unavailable")
            finished()
            return
        }
        scene.windows.forEach {
            $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(
            UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscapeRight)
        ) { error in
            LogStore.shared.write("orientation", "Game-only landscape request: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            LogStore.shared.write("orientation", "Gameplay geometry after Play: \(scene.interfaceOrientation.rawValue)")
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
            // Dismiss the portrait-only launcher first. The gameplay mask
            // changes on the native winit window before requesting rotation.
            GTAIOSOrientation.playing = true
            launch?()
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
            // Give winit one event-loop tick to switch its root controller's
            // supported orientations from portrait to landscape.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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

@MainActor
final class USBStorageManager {
    static let shared = USBStorageManager()
    static let changedNotification = Notification.Name("GTAiOS.NativeLibraryDidChange")
    private static let bookmarkKey = "gtaios.native.external-folder"
    nonisolated static let manifestPath = "data/manifest.json"
    nonisolated static let shaderIndexPath = "b/8b0b5899ed/shaders/index.json"
    private let worker = DispatchQueue(label: "gtaios.usb-library.serial", qos: .userInitiated)
    private(set) var root: URL?
    private(set) var reconnectRequired = false
    private(set) var recoveryMessage: String?
    private var securedURL: URL?
    private var generation: UInt64 = 0
    private var restoreInFlight = false
    var startupPathCount: Int { 2 }

    private init() {
        // Start only one asynchronous restoration attempt per launch. A vanished
        // File Provider cannot be recreated from a remembered filesystem path.
        restoreIfNeeded()
    }

    func restoreIfNeeded() {
        guard root == nil, !restoreInFlight, !reconnectRequired,
              let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        restoreInFlight = true
        let expected = generation
        worker.async {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                DispatchQueue.main.async {
                    self.restoreInFlight = false
                    guard self.generation == expected, self.root == nil else { return }
                    LogStore.shared.write("usb",
                        stale ? "Saved USB bookmark is stale; validating and renewing access"
                              : "Saved USB bookmark resolved; validating live provider access")
                    self.chooseAsync(url, fromFile: false, restoring: true) { result in
                        if case .failure(let error) = result {
                            LogStore.shared.write("usb",
                                "Saved library unavailable; reconnect via Files picker: " +
                                error.localizedDescription)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.restoreInFlight = false
                    guard self.generation == expected, self.root == nil else { return }
                    self.setRecovery(error, context: "bookmark restoration")
                }
            }
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func setRecovery(_ error: Error, context: String) {
        // Keep the bookmark for a later manual regrant. Clearing it on -2001
        // would turn a temporarily missing USB provider into permanent data loss
        // of the saved access token.
        guard root == nil else { return }
        reconnectRequired = true
        recoveryMessage = "Reconnect the USB-C drive, then tap Reconnect Drive and select the GTA V folder in Files. The game assets will not be copied."
        let ns = error as NSError
        let provider = Self.isProviderFailure(ns)
        LogStore.shared.write("usb",
            "\(context) failed (\(ns.domain) \(ns.code))" +
            (provider ? " — File Provider unavailable; new user-selected URL required"
                      : " — library could not be opened"))
        notifyChanged()
    }

    private nonisolated static func isProviderFailure(_ error: NSError) -> Bool {
        if error.domain == "NSFileProviderErrorDomain" &&
            [-2001, -2012, -2013].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain &&
            [5, 6, 9].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isProviderFailure(underlying)
        }
        return false
    }

    private nonisolated static func libraryError(_ message: String) -> NSError {
        NSError(domain: "GTAiOS.NativeLibrary", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // iOS gives the document picker a security-scoped folder URL. For a
    // provider-backed file Apple requires NSFileCoordinator to serialize reads
    // with provider changes. Only the two small startup JSON files are read.
    private nonisolated static func coordinatedData(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            readResult = Result { try Data(contentsOf: readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let readResult else {
            throw libraryError("The Files provider did not return a readable game file.")
        }
        return try readResult.get()
    }

    private nonisolated static func validateFolder(_ selected: URL) throws -> URL {
        let fm = FileManager.default
        for suffix in ["", "playgta5.com", "mirror/playgta5.com",
                       "mirror/mirror/playgta5.com"] {
            let root = selected.appendingPathComponent(suffix, isDirectory: true)
            let manifestURL = root.appendingPathComponent(manifestPath)
            let shaderURL = root.appendingPathComponent(shaderIndexPath)
            guard fm.fileExists(atPath: manifestURL.path) &&
                  fm.fileExists(atPath: shaderURL.path) else { continue }
            let manifestData = try coordinatedData(manifestURL)
            let json = try JSONSerialization.jsonObject(with: manifestData)
            guard let dictionary = json as? [String: Any],
                  dictionary["files"] is [Any] else {
                throw libraryError("The selected game manifest has no files array.")
            }
            let shaderData = try coordinatedData(shaderURL)
            _ = try JSONSerialization.jsonObject(with: shaderData)
            return root
        }
        throw libraryError("The GTA V folder is not currently readable. Check the USB-C connection and select the folder containing data/manifest.json and b/8b0b5899ed/shaders/index.json.")
    }

    private nonisolated static func isInAppContainer(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/")
    }

    // Game startup requires verified provider access, not simply an old URL or
    // fileExists result. The native I/O threads retain the selected scope.
    func chooseAsync(_ url: URL, fromFile: Bool, restoring: Bool = false,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard !GTAIOSOrientation.playing else {
            completion(.failure(Self.libraryError(
                "Exit the game before changing its external game folder.")))
            return
        }
        let selected = fromFile ? url.deletingLastPathComponent() : url
        generation &+= 1
        let ticket = generation
        reconnectRequired = false
        recoveryMessage = nil
        worker.async {
            let acquiredScope = selected.startAccessingSecurityScopedResource()
            do {
                guard acquiredScope || Self.isInAppContainer(selected) else {
                    throw Self.libraryError("iOS did not grant access to this external folder. Select it again in the Files picker.")
                }
                let checkedRoot = try Self.validateFolder(selected)
                let ok = selected.path.withCString { muguet_mount_external($0) }
                guard ok && muguet_game_ready() else {
                    let detail = muguet_import_error().map { String(cString: $0) }
                        ?? "The native engine cannot mount these game files."
                    throw Self.libraryError(detail)
                }
                // On iOS, a bookmark generated from a security-scoped picker
                // URL retains its access grant. The macOS-only .withSecurityScope
                // option is deliberately not used here.
                let newBookmark = try? selected.bookmarkData(
                    options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                DispatchQueue.main.async {
                    guard self.generation == ticket else {
                        if acquiredScope { selected.stopAccessingSecurityScopedResource() }
                        return
                    }
                    let oldGrant = self.securedURL
                    self.securedURL = acquiredScope ? selected : nil
                    self.root = checkedRoot
                    self.reconnectRequired = false
                    self.recoveryMessage = nil
                    if let newBookmark {
                        UserDefaults.standard.set(newBookmark, forKey: Self.bookmarkKey)
                    }
                    oldGrant?.stopAccessingSecurityScopedResource()
                    LogStore.shared.write("usb",
                        restoring ? "Restored verified USB library with active scope"
                                  : "Mounted native game library: \(checkedRoot.lastPathComponent)")
                    self.notifyChanged()
                    completion(.success(()))
                }
            } catch {
                if acquiredScope { selected.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    guard self.generation == ticket else { return }
                    if self.root == nil { self.setRecovery(error, context: restoring ? "restore" : "mount") }
                    completion(.failure(error))
                }
            }
        }
    }

    // Check the live provider again immediately before starting game threads.
    // A persisted bookmark or a previously mounted path is NOT proof that a
    // removable disk is still present.
    func verifyReadyForPlay(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard let candidate = root else {
            completion(.failure(Self.libraryError("Reconnect the GTA V drive in Files.")))
            return
        }
        let ticket = generation
        worker.async {
            let result = Result<Void, Error> {
                _ = try Self.coordinatedData(candidate.appendingPathComponent(Self.manifestPath))
                _ = try Self.coordinatedData(candidate.appendingPathComponent(Self.shaderIndexPath))
            }
            DispatchQueue.main.async {
                guard self.generation == ticket else {
                    completion(.failure(Self.libraryError("The game folder changed during validation.")))
                    return
                }
                if case .failure(let error) = result {
                    self.invalidateMountedLibrary(error)
                }
                completion(result)
            }
        }
    }

    private func invalidateMountedLibrary(_ error: Error) {
        generation &+= 1
        let oldGrant = securedURL
        root = nil
        securedURL = nil
        // Native unmount must follow any outstanding worker mount/validation,
        // then release the security scope (never while Rust may be mounting).
        worker.async {
            muguet_unmount_external()
            DispatchQueue.main.async { oldGrant?.stopAccessingSecurityScopedResource() }
        }
        setRecovery(error, context: "pre-Play provider validation")
    }

    // These paths were already validated on the serial worker. Do not hit a
    // 20GB external File Provider synchronously from every launcher redraw.
    func missingStartupAssets() -> [String] {
        root == nil ? [Self.manifestPath, Self.shaderIndexPath] : []
    }

    func disconnect(completion: @escaping () -> Void) {
        generation &+= 1
        let oldGrant = securedURL
        root = nil
        securedURL = nil
        reconnectRequired = false
        recoveryMessage = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        notifyChanged()
        worker.async {
            muguet_unmount_external()
            DispatchQueue.main.async {
                oldGrant?.stopAccessingSecurityScopedResource()
                LogStore.shared.write("usb", "External game library unmounted")
                completion()
            }
        }
    }
}
@MainActor
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
