import UIKit
import UniformTypeIdentifiers
import Metal
import GameController
import AVKit
import AVFoundation

// Reference-driven native navigation: every destination has its own controller.
// Decorative GTA V images are bundled; all action/status data comes from iOS or runtime APIs.
enum GTAReference {
    static let green = UIColor(red: 0.29, green: 1.00, blue: 0.61, alpha: 1)
    static let blue = UIColor(red: 0.39, green: 0.72, blue: 1, alpha: 1)
    static let night = UIColor(red: 0.015, green: 0.029, blue: 0.057, alpha: 1)
    static let panel = UIColor(red: 0.053, green: 0.079, blue: 0.137, alpha: 1)
    static let ink = UIColor(red: 0.94, green: 0.96, blue: 1, alpha: 1)
    static let secondary = UIColor(red: 0.72, green: 0.77, blue: 0.88, alpha: 1)

    static func label(_ value: String, size: CGFloat = 14, weight: UIFont.Weight = .regular,
                      color: UIColor = GTAReference.ink) -> UILabel {
        let l = UILabel()
        l.text = value
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.numberOfLines = 0
        l.adjustsFontForContentSizeCategory = true
        return l
    }
    static func panelView(_ padding: CGFloat = 14) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: padding, leading: padding,
                                               bottom: padding, trailing: padding)
        stack.backgroundColor = panel
        stack.layer.cornerRadius = 17
        stack.layer.cornerCurve = .continuous
        stack.layer.borderWidth = 0.8
        stack.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        return stack
    }
    static func control(_ text: String, symbol: String, color: UIColor = panel) -> UIButton {
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.filled()
        cfg.title = text
        cfg.image = UIImage(systemName: symbol)
        cfg.imagePlacement = .leading
        cfg.imagePadding = 8
        cfg.baseBackgroundColor = color
        cfg.baseForegroundColor = color == green ? night : ink
        cfg.cornerStyle = .large
        cfg.contentInsets = .init(top: 15, leading: 12, bottom: 15, trailing: 12)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { old in
            var result = old
            result.font = .systemFont(ofSize: 14, weight: .bold)
            return result
        }
        b.configuration = cfg
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.8
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 55).isActive = true
        return b
    }
    // Compact native settings rows: the artwork is decoration; these
    // buttons retain their actual selection actions and persisted state.
    // Reference-style compact settings control. Text at the right comes
    // exclusively from the persisted engine option or user preferences.
    private static let optionValueTag = 683491
    static func settingsRow(_ title: String, symbol: String, value: String = "") -> UIButton {
        let button = UIButton(type: .system)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.018)
        button.layer.cornerRadius = 10
        button.accessibilityLabel = title
        button.accessibilityValue = value
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        let symbolView = UIImageView(image: UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)))
        symbolView.tintColor = blue
        symbolView.contentMode = .scaleAspectFit
        symbolView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(symbolView)
        let name = label(title, size: 13, weight: .semibold)
        name.numberOfLines = 2
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(name)
        row.addArrangedSubview(UIView())
        let valueLabel = label(value, size: 11, weight: .semibold, color: ink)
        valueLabel.tag = optionValueTag
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 2
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(valueLabel)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
        chevron.tintColor = secondary
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        chevron.contentMode = .scaleAspectFit
        row.addArrangedSubview(chevron)
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: button.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -8),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
        return button
    }
    static func updateSetting(_ button: UIButton, value: String) {
        (button.viewWithTag(optionValueTag) as? UILabel)?.text = value
        button.accessibilityValue = value
    }
    // Native console-launcher action tile with accessible, working targets.
    static func actionTile(_ title: String, detail: String, symbol: String,
                           accent: UIColor = GTAReference.blue) -> UIButton {
        let button = UIButton(type: .system)
        button.backgroundColor = panel
        button.layer.cornerRadius = 16
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 0.8
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.17).cgColor
        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 5
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)))
        icon.tintColor = accent
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 29).isActive = true
        content.addArrangedSubview(icon)
        let heading = label(title, size: 12, weight: .bold)
        heading.textAlignment = .center
        heading.numberOfLines = 2
        content.addArrangedSubview(heading)
        let subtitle = label(detail, size: 10, color: secondary)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 2
        content.addArrangedSubview(subtitle)
        button.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])
        button.accessibilityLabel = title + ", " + detail
        return button
    }
    static func hairline() -> UIView {
        let view = UIView()
        view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        view.backgroundColor = UIColor.white.withAlphaComponent(0.11)
        return view
    }
    static func statusRow(_ title: String, detail: UILabel, symbol: String) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = blue
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 23).isActive = true
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label(title, size: 13, weight: .semibold))
        row.addArrangedSubview(UIView())
        detail.textAlignment = .right
        detail.textColor = secondary
        detail.font = .systemFont(ofSize: 11, weight: .medium)
        detail.numberOfLines = 2
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(detail)
        return row
    }
    static func section(_ value: String) -> UILabel {
        label(value, size: 21, weight: .bold)
    }
    static func present(_ title: String, message: String, from controller: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }
    static func exportLogs(from controller: UIViewController) {
        let url = LogStore.shared.exportURL()
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = controller.view
        controller.present(activity, animated: true)
    }
}

/// Loads the project creator's actual GitHub profile photo and caches it
/// under Caches. Offline launches use the last fetched image.
final class GTAContributorAvatarView: UIImageView {
    private static let url = URL(string: "https://avatars.githubusercontent.com/u/214680657?s=256&v=4")!
    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NightVibes33-github-avatar", isDirectory: false)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        image = UIImage(named: "gtaios-developer-avatar")
            ?? UIImage(systemName: "person.crop.circle.fill")
        tintColor = GTAReference.blue
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = 42
        layer.cornerCurve = .continuous
        layer.borderWidth = 2
        layer.borderColor = GTAReference.green.withAlphaComponent(0.7).cgColor
        accessibilityLabel = "NightVibes33 GitHub profile picture"
        loadProfilePicture()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func loadProfilePicture() {
        if let cache = Self.cacheURL, let data = try? Data(contentsOf: cache),
           let photo = UIImage(data: data) {
            image = photo
        }
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse,
                  http.statusCode == 200, let data, data.count <= 2_000_000,
                  let photo = UIImage(data: data) else { return }
            if let cache = Self.cacheURL { try? data.write(to: cache, options: .atomic) }
            DispatchQueue.main.async { self?.image = photo }
        }.resume()
    }
}

// A responsive gradient action, not a pre-rendered / fake Play image.
// A lightweight gradient only for UIKit chrome, never for game artwork.
final class GTACinematicSurface: UIView {
    private let gradient = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [
            UIColor(red: 0.08, green: 0.075, blue: 0.15, alpha: 1).cgColor,
            UIColor(red: 0.025, green: 0.038, blue: 0.080, alpha: 1).cgColor,
            GTAReference.night.cgColor
        ]
        gradient.locations = [0, 0.60, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds }
}

final class GTAVNeonLaunchButton: UIButton {
    private let glow = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        glow.colors = [
            UIColor(red: 0.035, green: 0.72, blue: 0.30, alpha: 1).cgColor,
            UIColor(red: 0.015, green: 0.29, blue: 0.25, alpha: 1).cgColor,
            GTAReference.night.cgColor
        ]
        glow.locations = [0, 0.52, 1]
        glow.startPoint = CGPoint(x: 0, y: 0.1)
        glow.endPoint = CGPoint(x: 0.85, y: 1)
        layer.insertSublayer(glow, at: 0)
        layer.cornerRadius = 19
        layer.masksToBounds = true
        var cfg = UIButton.Configuration.plain()
        cfg.title = "Play GTA V"
        cfg.image = UIImage(systemName: "play.fill")
        cfg.imagePadding = 11
        cfg.baseForegroundColor = .white
        cfg.contentInsets = .init(top: 14, leading: 12, bottom: 14, trailing: 12)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var copy = attrs
            copy.font = .systemFont(ofSize: 19, weight: .heavy)
            return copy
        }
        configuration = cfg
        accessibilityIdentifier = "gtav-native-launch-action"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        glow.frame = bounds
        glow.cornerRadius = layer.cornerRadius
    }
}

final class GTAFiveTabController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GTAReference.night
        delegate = self
        let pages: [(UIViewController, String, String)] = [
            (GTAReferenceLibraryController(), "Home", "house.fill"),
            (GTAReferenceGraphicsController(), "Graphics", "display"),
            (ControllerSettingsViewController(), "Controls", "gamecontroller.fill"),
            (GTAReferenceMoreController(), "More", "ellipsis")
        ]
        viewControllers = pages.map { entry in
            let nav = GameNavigationController(rootViewController: entry.0)
            nav.setNavigationBarHidden(true, animated: false)
            nav.navigationBar.tintColor = GTAReference.green
            nav.navigationBar.barStyle = .black
            nav.tabBarItem = UITabBarItem(title: entry.1, image: UIImage(systemName: entry.2), tag: 0)
            return nav
        }
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GTAReference.night
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.14)
        let item = appearance.stackedLayoutAppearance
        item.normal.iconColor = GTAReference.secondary
        item.normal.titleTextAttributes = [.foregroundColor: GTAReference.secondary,
            .font: UIFont.systemFont(ofSize: 10, weight: .medium)]
        item.selected.iconColor = GTAReference.green
        item.selected.titleTextAttributes = [.foregroundColor: GTAReference.green,
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold)]
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = GTAReference.green
        tabBar.unselectedItemTintColor = GTAReference.secondary
        tabBar.isTranslucent = false
        #if targetEnvironment(simulator)
        chooseSnapshotTab()
        #endif
    }
    // GTA V iOS is landscape-only throughout its entire lifecycle.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    func select(_ index: Int) { selectedIndex = index }
    #if targetEnvironment(simulator)
    private func chooseSnapshotTab() {
        // Only used by GitHub simulator screenshots. No status values are mocked.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--snapshot-library") { selectedIndex = 0 }
        if arguments.contains("--snapshot-graphics") { selectedIndex = 1 }
        if arguments.contains("--snapshot-controls") { selectedIndex = 2 }
        if arguments.contains("--snapshot-more") { selectedIndex = 3 }
    }
    #endif
}
extension GTAFiveTabController: UITabBarControllerDelegate {}

class GTAReferencePage: UIViewController {
    let scroll = UIScrollView()
    let stack = UIStackView()
    var extendsHeroUnderStatusBar: Bool { false }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GTAReference.night
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 15
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: extendsHeroUnderStatusBar ? view.topAnchor : view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: extendsHeroUnderStatusBar ? 0 : 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 17),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -17)
        ])
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }
    func switchTab(_ index: Int) { (tabBarController as? GTAFiveTabController)?.select(index) }
    func openEngineReport() {
        navigationController?.setNavigationBarHidden(false, animated: true)
        let gameplay = GameViewController()
        gameplay.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(gameplay, animated: true)
    }

}

final class GTAReferenceLibraryController: GTAReferencePage, UIDocumentPickerDelegate {
    private let connection = GTAReference.label("", size: 12, weight: .semibold,
                                                color: GTAReference.secondary)
    private let diskInfo = GTAReference.label("", size: 12, weight: .medium,
                                              color: GTAReference.secondary)
    private let engineInfo = GTAReference.label("", size: 11, weight: .medium,
                                                color: GTAReference.secondary)
    private var verifiedRoot: URL?
    private var lastInspectedBytes: Int64?
    private let assetCoverage = GTAReference.label("", size: 11, weight: .semibold,
                                                    color: GTAReference.secondary)
    private let playButton = GTAReference.control("Select GTA V Files", symbol: "folder.fill",
                                                  color: GTAReference.green)
    private var pickerPresented = false
    override func viewDidLoad() {
        super.viewDidLoad()
        stack.addArrangedSubview(GTAReference.section("GTA V iOS"))
        stack.addArrangedSubview(GTAReference.label("Your GTA V game library · game assets stay on your drive",
                                                    size: 13, color: GTAReference.secondary))
        let card = GTAReference.panelView(15)
        let cardRow = UIStackView()
        cardRow.axis = .horizontal
        cardRow.spacing = 13
        cardRow.alignment = .center
        let detail = UIStackView()
        detail.axis = .vertical
        detail.spacing = 8
        detail.addArrangedSubview(GTAReference.label("Grand Theft Auto V", size: 17, weight: .bold))
        detail.addArrangedSubview(GTAReference.label("Rockstar Games", size: 12,
                                                   color: GTAReference.secondary))
        connection.numberOfLines = 2
        detail.addArrangedSubview(connection)
        detail.addArrangedSubview(GTAReference.label("USB-C · local game assets", size: 11,
                                                   color: GTAReference.blue))
        cardRow.addArrangedSubview(detail)
        card.addArrangedSubview(cardRow)
        card.addArrangedSubview(diskInfo)
        card.addArrangedSubview(assetCoverage)
        stack.addArrangedSubview(card)
        playButton.accessibilityIdentifier = "gtav-native-launch-action"
        playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 65).isActive = true
        playButton.addTarget(self, action: #selector(playPressed), for: .touchUpInside)
        stack.addArrangedSubview(playButton)
        stack.addArrangedSubview(GTAReference.section("Quick Actions"))
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 8
        actions.distribution = .fillEqually
        let browse = GTAReference.actionTile("Select Folder", detail: "Open Files picker", symbol: "folder.fill")
        browse.addTarget(self, action: #selector(browsePressed), for: .touchUpInside)
        let validate = GTAReference.actionTile("Validate Files", detail: "Inspect native data", symbol: "checkmark.shield.fill", accent: GTAReference.green)
        validate.addTarget(self, action: #selector(validatePressed), for: .touchUpInside)
        let disconnect = GTAReference.actionTile("Disconnect", detail: "Release USB access", symbol: "externaldrive.badge.xmark", accent: UIColor.systemRed)
        disconnect.addTarget(self, action: #selector(disconnectPressed), for: .touchUpInside)
        actions.addArrangedSubview(browse)
        actions.addArrangedSubview(validate)
        actions.addArrangedSubview(disconnect)
        stack.addArrangedSubview(actions)
        let infoCard = GTAReference.panelView()
        infoCard.addArrangedSubview(GTAReference.label("Game Information", size: 19, weight: .bold))
        infoCard.addArrangedSubview(GTAReference.label("Title: Grand Theft Auto V · Developer: Rockstar Games",
                                                       size: 12, color: GTAReference.secondary))
        infoCard.addArrangedSubview(engineInfo)
        stack.addArrangedSubview(infoCard)
        NotificationCenter.default.addObserver(self, selector: #selector(storageChanged),
            name: USBStorageManager.changedNotification, object: nil)
        refresh()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refresh() }
    @objc private func storageChanged() { refresh() }
    private func refresh() {
        let hasFiles = USBStorageManager.shared.root != nil
        let engine = NativeEngineStatus.nativeEngineLinked
        var launchConfiguration = playButton.configuration
        launchConfiguration?.title = !hasFiles ? "Select GTA V Files" : (engine ? "Play GTA V" : "Check Engine")
        launchConfiguration?.image = UIImage(systemName: hasFiles && engine ? "play.fill" : "folder.fill")
        playButton.configuration = launchConfiguration
        if let root = USBStorageManager.shared.root {
            let missing = USBStorageManager.shared.missingStartupAssets()
            let confirmed = verifiedRoot == root.standardizedFileURL
            if !confirmed { lastInspectedBytes = nil }
            connection.text = !missing.isEmpty ? "Missing startup paths" :
                (confirmed ? "Engine file inspected · startup paths present" :
                    "Startup paths detected · validation pending")
            connection.textColor = verifiedRoot == root.standardizedFileURL && missing.isEmpty ?
                GTAReference.green : GTAReference.blue
            diskInfo.text = "Selected folder: " + root.lastPathComponent
            let total = USBStorageManager.shared.startupPathCount
            let detected = max(0, total - missing.count)
            assetCoverage.text = "Startup paths detected: \(detected) / \(total)"
            assetCoverage.textColor = missing.isEmpty ? GTAReference.green : GTAReference.secondary
            if confirmed, let bytes = lastInspectedBytes {
                engineInfo.text = "Inspected game.wasm: " +
                    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            } else {
                engineInfo.text = "Run Validate to inspect real engine file bytes"
            }
        } else {
            verifiedRoot = nil
            lastInspectedBytes = nil
            connection.text = "Not selected"
            connection.textColor = GTAReference.blue
            diskInfo.text = "Select your own local game mirror from the Files app"
            assetCoverage.text = "No startup paths inspected"
            assetCoverage.textColor = GTAReference.secondary
            engineInfo.text = "Game engine archive: not connected"
        }
    }
    // Direct system folder selection; no action sheet or WebView intermediary.
    @objc private func browsePressed() {
        guard !pickerPresented, presentedViewController == nil else {
            LogStore.shared.write("usb", "Files picker already visible")
            return
        }
        pickerPresented = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .fullScreen
        LogStore.shared.write("usb", "Opening iOS Files folder picker")
        present(picker, animated: true)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerPresented = false
        LogStore.shared.write("usb", "Files folder selection cancelled")
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        pickerPresented = false
        guard let selected = urls.first else { return }
        LogStore.shared.write("usb", "Selected GTA V folder: " + selected.lastPathComponent)
        USBStorageManager.shared.chooseAsync(selected, fromFile: false) { [weak self] result in
            guard let self else { return }
            self.refresh()
            switch result {
            case .success:
                LogStore.shared.write("usb", "Native engine mounted selected game folder")
            case .failure(let error):
                LogStore.shared.write("usb", "Game folder mount failed: " + error.localizedDescription)
                GTAReference.present("Cannot read GTA V files", message: error.localizedDescription, from: self)
            }
        }
    }
    @objc private func playPressed() {
        guard USBStorageManager.shared.root != nil else { browsePressed(); return }
        guard NativeEngineStatus.nativeEngineLinked else {
            GTAReference.present("Native engine unavailable",
                                 message: "This IPA has no linked native GTA V engine.",
                                 from: self)
            return
        }
        openEngineReport()
    }
    @objc private func validatePressed() {
        guard USBStorageManager.shared.root != nil else { browsePressed(); return }
        NativeEngineStatus.inspect { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let bytes = ByteCountFormatter.string(fromByteCount: value.byteCount, countStyle: .file)
                self.verifiedRoot = USBStorageManager.shared.root?.standardizedFileURL
                self.lastInspectedBytes = value.byteCount
                self.refresh()
                GTAReference.present("Game files inspected", message:
                    "WebAssembly engine readable: " + bytes +
                    ". Shader index found. This does not establish playable GTA V runtime.", from: self)
            case .failure(let error):
                GTAReference.present("File validation failed", message: error.localizedDescription, from: self)
            }
        }
    }
    @objc private func disconnectPressed() {
        guard USBStorageManager.shared.root != nil else {
            GTAReference.present("No connected library", message:
                "Select a GTA V folder from your external drive first.", from: self)
            return
        }
        let alert = UIAlertController(title: "Disconnect GTA V Library?",
            message: "Remove the bookmark and release USB access. No game files will be deleted.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in
            USBStorageManager.shared.disconnect {
                self?.refresh()
            }
        })
        present(alert, animated: true)
    }
    @objc private func exportPressed() { GTAReference.exportLogs(from: self) }
}

final class GTAReferenceGraphicsController: GTAReferencePage {
    private let metal = GTAReference.label("", size: 11, weight: .semibold)
    private let thermal = GTAReference.label("", size: 11, color: GTAReference.secondary)
    private let readiness = GTAReference.label("", size: 11, color: GTAReference.secondary)
    private var engineButtons: [(UIButton, String)] = []
    private var valueLabels: [(UILabel, String)] = []
    private var presetButton: UIButton?
    private let controlScheme = GTAReference.label("", size: 12, color: GTAReference.green)
    private let outputRoute = GTAReference.label("", size: 12, color: GTAReference.secondary)

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.addArrangedSubview(GTAReference.section("Game Settings"))

        let performance = GTAReference.panelView(11)
        performance.addArrangedSubview(GTAReference.label("Performance Monitor", size: 18, weight: .bold))
        performance.addArrangedSubview(GTAReference.label(
            "Real iPhone hardware status · gameplay telemetry is unavailable", size: 11,
            color: GTAReference.secondary))
        performance.addArrangedSubview(metal)
        performance.addArrangedSubview(thermal)
        performance.addArrangedSubview(readiness)
        stack.addArrangedSubview(performance)

        let display = GTAReference.panelView(9)
        display.addArrangedSubview(GTAReference.label("Graphics", size: 19, weight: .bold))
        let preset = GTAReference.settingsRow("Graphics Preset", symbol: "camera.filters",
            value: GTALaunchPreferences.text("preset", fallback: "Custom"))
        preset.accessibilityIdentifier = "graphics-preset"
        preset.addTarget(self, action: #selector(showPresets), for: .touchUpInside)
        display.addArrangedSubview(preset)
        display.addArrangedSubview(GTAReference.hairline())
        presetButton = preset
        addScale(to: display)
        addSwitch(to: display, title: "VSync", detail: "Preference saved; game renderer pending",
                  symbol: "arrow.triangle.2.circlepath", key: "vsync", fallback: true)
        for id in ["textureQuality", "shadowQuality", "reflectionQuality", "particleQuality", "grassQuality"] {
            addEngineOption(id, to: display)
        }
        let aa = GTAReference.settingsRow("Anti-Aliasing", symbol: "circle.hexagongrid",
            value: GTALaunchPreferences.text("antiAliasing", fallback: "Off") + " · pending")
        aa.accessibilityIdentifier = "staged-anti-aliasing"
        aa.addAction(UIAction { [weak self, weak aa] _ in
            guard let self, let aa else { return }
            let sheet = UIAlertController(title: "Anti-Aliasing",
                message: "Stored for future GTA V renderer integration; not yet an active shader setting.",
                preferredStyle: .actionSheet)
            for quality in ["Off", "FXAA", "TAA"] {
                sheet.addAction(UIAlertAction(title: quality, style: .default) { _ in
                    GTALaunchPreferences.setText("antiAliasing", value: quality)
                    GTAReference.updateSetting(aa, value: quality + " · pending")
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = aa
            self.present(sheet, animated: true)
        }, for: .touchUpInside)
        display.addArrangedSubview(GTAReference.hairline())
        display.addArrangedSubview(aa)
        stack.addArrangedSubview(display)

        let controls = GTAReference.panelView(9)
        controls.addArrangedSubview(GTAReference.label("Controls", size: 19, weight: .bold))
        let scheme = GTAReference.settingsRow("Control Scheme", symbol: "gamecontroller.fill",
            value: GTALaunchPreferences.text("controlScheme", fallback: "Automatic"))
        scheme.addAction(UIAction { [weak self, weak scheme] _ in
            guard let self, let scheme else { return }
            let sheet = UIAlertController(title: "Control Scheme",
                message: "Selects real touch/controller input mode in the native preview. GTA V engine is pending.",
                preferredStyle: .actionSheet)
            for value in ["Automatic", "Touch", "Controller"] {
                sheet.addAction(UIAlertAction(title: value, style: .default) { _ in
                    GTALaunchPreferences.setText("controlScheme", value: value)
                    GTAReference.updateSetting(scheme, value: value)
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = scheme
            self.present(sheet, animated: true)
        }, for: .touchUpInside)
        controls.addArrangedSubview(scheme)
        controlScheme.numberOfLines = 2
        controls.addArrangedSubview(controlScheme)
        addSwitch(to: controls, title: "Vibration", detail: "Real connected-controller haptic test",
                  symbol: "dot.radiowaves.left.and.right", key: "controllerVibration", fallback: true)
        addFraction(to: controls, title: "Touch Control Opacity", symbol: "hand.tap",
                    key: "touchOpacity", fallback: 0.7,
                    footnote: "Applied to the native touch overlay")
        addFraction(to: controls, title: "Aim Sensitivity", symbol: "scope",
                    key: "aimSensitivity", fallback: (1.0 - 0.25) / 2.75,
                    footnote: "Applied to the native controller camera-stick input")
        let mapping = GTAReference.control("Controller Mapping & Deadzone", symbol: "slider.horizontal.3")
        mapping.addAction(UIAction { [weak self] _ in
            self?.tabBarController?.selectedIndex = 2
        }, for: .touchUpInside)
        controls.addArrangedSubview(mapping)
        stack.addArrangedSubview(controls)

        let advanced = GTAReference.panelView(9)
        advanced.addArrangedSubview(GTAReference.label("Advanced", size: 19, weight: .bold))
        addEngineOption("fps", to: advanced)
        stack.addArrangedSubview(advanced)

        let audio = GTAReference.panelView(9)
        audio.addArrangedSubview(GTAReference.label("Audio & Haptics", size: 19, weight: .bold))
        let route = UIStackView()
        route.axis = .horizontal
        route.spacing = 8
        route.alignment = .center
        route.addArrangedSubview(GTAReference.label("Audio Output", size: 13, weight: .semibold))
        route.addArrangedSubview(UIView())
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 45, height: 45))
        picker.tintColor = GTAReference.blue
        picker.activeTintColor = GTAReference.green
        picker.widthAnchor.constraint(equalToConstant: 45).isActive = true
        picker.heightAnchor.constraint(equalToConstant: 45).isActive = true
        route.addArrangedSubview(picker)
        audio.addArrangedSubview(route)
        audio.addArrangedSubview(outputRoute)
        addFraction(to: audio, title: "Master Volume", symbol: "speaker.wave.2",
                    key: "masterVolume", fallback: 1.0,
                    footnote: "Live native PCM mixer gain")
        addFraction(to: audio, title: "Music Volume", symbol: "music.note",
                    key: "musicVolume", fallback: 0.6,
                    footnote: "Staged until the game engine exposes music streams")
        addFraction(to: audio, title: "Dialogue Volume", symbol: "text.bubble",
                    key: "dialogueVolume", fallback: 0.8,
                    footnote: "Staged until the game engine exposes dialogue streams")
        stack.addArrangedSubview(audio)

        let note = GTAReference.panelView()
        note.addArrangedSubview(GTAReference.label(
            "Controls marked staged are saved, not simulated. Real GTA V graphics and separate audio " +
            "mixing require the unlinked native game engine.", size: 11,
            color: GTAReference.secondary))
        stack.addArrangedSubview(note)

        let reset = GTAReference.control("Reset All Preferences", symbol: "arrow.counterclockwise")
        reset.addTarget(self, action: #selector(resetPressed), for: .touchUpInside)
        stack.addArrangedSubview(reset)
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private func refresh() {
        metal.text = MTLCreateSystemDefaultDevice().map { "Metal GPU: " + $0.name }
            ?? "Metal GPU: unavailable"
        let thermals = ["Nominal", "Fair", "Serious", "Critical"]
        let state = ProcessInfo.processInfo.thermalState.rawValue
        thermal.text = "Device thermal state: " +
            (state >= 0 && state < thermals.count ? thermals[state] : "Unknown")
        readiness.text = NativeEngineStatus.nativeEngineLinked ?
            "Native engine linked · game FPS must be measured inside gameplay" :
            "GTA V engine not linked · game FPS / shader usage unavailable"
        controlScheme.text = GCController.controllers().first(where: { $0.extendedGamepad != nil })
            .flatMap { $0.vendorName }.map { "Hardware detected: " + $0 } ??
            "Hardware detected: none"
        outputRoute.text = "Current audio route: " +
            (AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "Unavailable")
        if let presetButton {
            GTAReference.updateSetting(presetButton, value:
                GTALaunchPreferences.text("preset", fallback: "Custom"))
        }
        for (button, id) in engineButtons {
            if let spec = EngineOptions.option(id) {
                GTAReference.updateSetting(button, value: EngineOptions.display(id))
            }
        }
        for (label, id) in valueLabels where id == "scale" {
            label.text = EngineOptions.display("scale")
        }
    }

    @objc private func showPresets(_ sender: UIButton) {
        let sheet = UIAlertController(title: "Graphics Preset",
            message: "Presets write actual engine-option configuration; they are not proof of playable GTA V.",
            preferredStyle: .actionSheet)
        for name in ["Low", "Balanced", "High"] {
            sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                GTALaunchPreferences.applyPreset(name)
                self?.refresh()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sender
        present(sheet, animated: true)
    }

    private func addEngineOption(_ id: String, to panel: UIStackView) {
        guard let spec = EngineOptions.option(id) else { return }
        let symbol: String
        switch id {
        case "fps": symbol = "speedometer"
        case "textureQuality": symbol = "square.3.layers.3d"
        case "shadowQuality": symbol = "sun.horizon"
        case "reflectionQuality": symbol = "sparkles"
        case "particleQuality": symbol = "circle.dotted"
        case "grassQuality": symbol = "leaf"
        default: symbol = "slider.horizontal.3"
        }
        let button = GTAReference.settingsRow(spec.title, symbol: symbol,
            value: EngineOptions.display(id))
        button.accessibilityIdentifier = "engine-option-" + id
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            let sheet = UIAlertController(title: spec.title,
                message: spec.subtitle + "\nSaved for the native engine; effective in-game state pending.",
                preferredStyle: .actionSheet)
            for (label, value) in spec.choices {
                sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                    EngineOptions.set(id, value: value)
                    GTALaunchPreferences.setText("preset", value: "Custom")
                    GTAReference.updateSetting(button, value: EngineOptions.display(id))
                    self?.refresh()
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = button
            self.present(sheet, animated: true)
        }, for: .touchUpInside)
        panel.addArrangedSubview(GTAReference.hairline())
        panel.addArrangedSubview(button)
        engineButtons.append((button, id))
    }

    private func addScale(to panel: UIStackView) {
        let row = UIStackView()
        row.axis = .vertical
        row.spacing = 7
        row.addArrangedSubview(GTAReference.label("Resolution Scale", size: 13, weight: .semibold))
        let track = UIStackView()
        track.axis = .horizontal
        track.spacing = 10
        track.alignment = .center
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 4
        slider.tintColor = GTAReference.green
        let choices = EngineOptions.option("scale")?.choices ?? []
        slider.value = Float(choices.firstIndex(where: { $0.1 == EngineOptions.value("scale") }) ?? 0)
        let value = GTAReference.label(EngineOptions.display("scale"), size: 12,
                                      color: GTAReference.green)
        value.widthAnchor.constraint(equalToConstant: 49).isActive = true
        slider.addAction(UIAction { _ in
            let index = Int(slider.value.rounded())
            guard choices.indices.contains(index) else { return }
            slider.value = Float(index)
            EngineOptions.set("scale", value: choices[index].1)
            GTALaunchPreferences.setText("preset", value: "Custom")
            value.text = EngineOptions.display("scale")
        }, for: .valueChanged)
        track.addArrangedSubview(slider)
        track.addArrangedSubview(value)
        row.addArrangedSubview(track)
        panel.addArrangedSubview(row)
        panel.addArrangedSubview(GTAReference.hairline())
        valueLabels.append((value, "scale"))
    }

    private func addSwitch(to panel: UIStackView, title: String, detail: String,
                           symbol: String, key: String, fallback: Bool) {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 9
        row.alignment = .center
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = GTAReference.blue
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        row.addArrangedSubview(icon)
        let text = UIStackView()
        text.axis = .vertical
        text.spacing = 3
        text.addArrangedSubview(GTAReference.label(title, size: 13, weight: .semibold))
        text.addArrangedSubview(GTAReference.label(detail, size: 10, color: GTAReference.secondary))
        row.addArrangedSubview(text)
        let toggle = UISwitch()
        toggle.onTintColor = GTAReference.green
        toggle.isOn = GTALaunchPreferences.enabled(key, fallback: fallback)
        toggle.addAction(UIAction { _ in
            GTALaunchPreferences.setEnabled(key, value: toggle.isOn)
            if key == "controllerVibration" && toggle.isOn {
                _ = ControllerManager.shared.testRumble()
            }
        }, for: .valueChanged)
        row.addArrangedSubview(toggle)
        panel.addArrangedSubview(row)
        panel.addArrangedSubview(GTAReference.hairline())
    }

    private func addFraction(to panel: UIStackView, title: String, symbol: String,
                             key: String, fallback: Double, footnote: String) {
        let group = UIStackView()
        group.axis = .vertical
        group.spacing = 6
        let heading = UIStackView()
        heading.axis = .horizontal
        heading.spacing = 7
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = GTAReference.blue
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        heading.addArrangedSubview(icon)
        heading.addArrangedSubview(GTAReference.label(title, size: 13, weight: .semibold))
        group.addArrangedSubview(heading)
        let controls = UIStackView()
        controls.axis = .horizontal
        controls.spacing = 9
        controls.alignment = .center
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = Float(GTALaunchPreferences.fraction(key, fallback: fallback))
        slider.tintColor = GTAReference.green
        let value = GTAReference.label(String(Int(slider.value * 100)) + "%", size: 12,
                                       color: GTAReference.green)
        value.widthAnchor.constraint(equalToConstant: 40).isActive = true
        slider.addAction(UIAction { _ in
            GTALaunchPreferences.setFraction(key, value: Double(slider.value))
            value.text = String(Int(slider.value * 100)) + "%"
            if key == "masterVolume" { NativePCMOutput.shared.setMasterVolume(slider.value) }
            if key == "aimSensitivity" {
                UserDefaults.standard.set(0.25 + Double(slider.value) * 2.75,
                    forKey: ControllerManager.sensitivityKey)
            }
        }, for: .valueChanged)
        controls.addArrangedSubview(slider)
        controls.addArrangedSubview(value)
        group.addArrangedSubview(controls)
        group.addArrangedSubview(GTAReference.label(footnote, size: 10,
                                                    color: GTAReference.secondary))
        panel.addArrangedSubview(group)
        panel.addArrangedSubview(GTAReference.hairline())
    }

    @objc private func resetPressed() {
        let sheet = UIAlertController(title: "Reset All Settings?",
            message: "Restore all graphics, controls and audio preferences to defaults.",
            preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            EngineOptions.resetAll()
            GTALaunchPreferences.reset()
            NativePCMOutput.shared.setMasterVolume(1)
            guard let self else { return }
            // Recreate only the settings controller; calling viewDidLoad
            // a second time caused stacked duplicate views and observers.
            if let nav = self.navigationController {
                var controllers = nav.viewControllers
                if !controllers.isEmpty {
                    controllers[controllers.count - 1] = GTAReferenceGraphicsController()
                    nav.setViewControllers(controllers, animated: false)
                }
            }
        })
        present(sheet, animated: true)
    }
}

final class GTAReferenceMoreController: GTAReferencePage {
    private let controllerStatus = GTAReference.label("", size: 12, color: GTAReference.secondary)
    private let recentRows = UIStackView()
    private var recentGeneration = 0
    override func viewDidLoad() {
        super.viewDidLoad()
        stack.addArrangedSubview(GTAReference.section("More"))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let about = GTAReference.panelView()
        about.addArrangedSubview(GTAReference.label("GTA V iOS Launcher", size: 19, weight: .bold))
        about.addArrangedSubview(GTAReference.label("Version " + version + " · Build " + build,
                                                       size: 12, color: GTAReference.secondary))
        about.addArrangedSubview(controllerStatus)
        stack.addArrangedSubview(about)
        stack.addArrangedSubview(GTAReference.section("GTAiOS Developer"))

        let developerCard = GTAReference.panelView(15)
        let creator = UIStackView()
        creator.axis = .horizontal
        creator.alignment = .center
        creator.spacing = 14
        let avatar = GTAContributorAvatarView(frame: .zero)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 84),
            avatar.heightAnchor.constraint(equalToConstant: 84)
        ])
        creator.addArrangedSubview(avatar)
        let authorDetails = UIStackView()
        authorDetails.axis = .vertical
        authorDetails.spacing = 5
        authorDetails.addArrangedSubview(GTAReference.label("NightVibes33", size: 19, weight: .bold))
        authorDetails.addArrangedSubview(GTAReference.label(
            "GTAiOS project creator & iOS app developer",
            size: 12, color: GTAReference.secondary))
        authorDetails.addArrangedSubview(GTAReference.label(
            "@NightVibes33 · GitHub",
            size: 12, weight: .semibold, color: GTAReference.green))
        creator.addArrangedSubview(authorDetails)
        developerCard.addArrangedSubview(creator)
        let profileButton = GTAReference.control("Visit My GitHub Profile",
                                                  symbol: "arrow.up.right.square")
        profileButton.accessibilityIdentifier = "credits-creator-profile"
        profileButton.addTarget(self, action: #selector(openCreatorProfile),
                                for: .touchUpInside)
        developerCard.addArrangedSubview(profileButton)
        stack.addArrangedSubview(developerCard)

        stack.addArrangedSubview(GTAReference.section("Local Tools"))
        let operations: [(String, String, Selector)] = [
            ("Game Files / Home", "externaldrive", #selector(library)),
            ("Graphics", "display", #selector(graphics)),
            ("Controls", "gamecontroller.fill", #selector(controls)),
            ("Native Runtime Checks", "cpu", #selector(engine)),
            ("Export Diagnostic Logs", "square.and.arrow.up", #selector(logs))
        ]
        for (title, icon, handler) in operations {
            let button = GTAReference.control(title, symbol: icon)
            button.addTarget(self, action: handler, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        // Actual on-device events, not a scripted list of successful launches.
        let eventsPanel = GTAReference.panelView(12)
        let eventHeader = UIStackView()
        eventHeader.axis = .horizontal
        eventHeader.alignment = .center
        eventHeader.addArrangedSubview(GTAReference.label("Recent Diagnostic Events",
                                                           size: 17, weight: .bold))
        eventHeader.addArrangedSubview(UIView())
        let refreshButton = UIButton(type: .system)
        refreshButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refreshButton.tintColor = GTAReference.green
        refreshButton.accessibilityLabel = "Refresh actual diagnostic events"
        refreshButton.addTarget(self, action: #selector(reloadEvents), for: .touchUpInside)
        eventHeader.addArrangedSubview(refreshButton)
        eventsPanel.addArrangedSubview(eventHeader)
        recentRows.axis = .vertical
        recentRows.spacing = 7
        eventsPanel.addArrangedSubview(recentRows)
        stack.addArrangedSubview(eventsPanel)
        stack.addArrangedSubview(GTAReference.label(
            "All operations are local. No storefront, cloud sync, updates, save progress or gameplay " +
            "statistics are claimed without corresponding implementations.",
            size: 12, color: GTAReference.secondary))
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Query the actual iOS hardware inventory, not a manager that may
        // have been stopped when the Controls tab disappeared.
        let name = GCController.controllers().first?.vendorName
        controllerStatus.text = name.map { "Controller: " + $0 } ??
            "Controller: not connected"
        reloadEvents()
    }
    @objc private func reloadEvents() {
        recentGeneration += 1
        let generation = recentGeneration
        LogStore.shared.recentEvents(limit: 5) { [weak self] events in
            guard let self, self.recentGeneration == generation else { return }
            self.recentRows.arrangedSubviews.forEach { row in
                self.recentRows.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            if events.isEmpty {
                self.recentRows.addArrangedSubview(GTAReference.label(
                    "No diagnostic events recorded", size: 12, color: GTAReference.secondary))
                return
            }
            for (timestamp, detail) in events {
                let item = UIStackView()
                item.axis = .vertical
                item.spacing = 3
                item.addArrangedSubview(GTAReference.label(
                    timestamp.replacingOccurrences(of: "T", with: " "),
                    size: 10, color: GTAReference.green))
                let message = GTAReference.label(detail, size: 11, color: GTAReference.secondary)
                message.numberOfLines = 2
                item.addArrangedSubview(message)
                self.recentRows.addArrangedSubview(item)
                self.recentRows.addArrangedSubview(GTAReference.hairline())
            }
        }
    }
    @objc private func openCreatorProfile() {
        guard let url = URL(string: "https://github.com/NightVibes33") else { return }
        UIApplication.shared.open(url)
    }
    @objc private func library() { switchTab(0) }
    @objc private func graphics() { switchTab(1) }
    @objc private func controls() { switchTab(2) }
    @objc private func engine() { openEngineReport() }
    @objc private func logs() { GTAReference.exportLogs(from: self) }
}