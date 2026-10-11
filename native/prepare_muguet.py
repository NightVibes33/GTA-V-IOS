#!/usr/bin/env python3
"""Apply the external-folder adapter to the pinned, GPL-licensed Muguet source."""
from pathlib import Path
import subprocess
import sys

base = Path(__file__).resolve().parent
source = base / 'Muguet'
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
if revision != '75d3576bc4e53f514d75f19f2d397c2b7adc9d05':
    sys.exit('Unsupported Muguet revision; review the adapter before updating the pin')

def replace(path, old, new):
    p = source / path
    text = p.read_text(encoding='utf-8')
    if new in text:
        return
    if text.count(old) != 1:
        sys.exit(f'Upstream adapter context mismatch: {path}')
    p.write_text(text.replace(old, new), encoding='utf-8')

replace('src/config.rs', 'pub fn game_dir() -> PathBuf {\n    support_dir().join("game")\n}', '''static EXTERNAL_GAME: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

pub fn game_dir() -> PathBuf {
    EXTERNAL_GAME.lock().unwrap().clone().unwrap_or_else(|| support_dir().join("game"))
}

// Read-only mount: never extract, prune, write, or copy the selected library.
pub fn mount_external(selected: &Path) -> anyhow::Result<()> {
    for relative in ["", "playgta5.com", "mirror/playgta5.com", "mirror/mirror/playgta5.com"] {
        let root = selected.join(relative);
        let build = root.join("b/8b0b5899ed");
        if root.join("data/manifest.json").is_file() && build.join("shaders/index.json").is_file() {
            // Validate the manifest before changing the active root.
            let bytes = std::fs::read(root.join("data/manifest.json"))?;
            let manifest: serde_json::Value = serde_json::from_slice(&bytes)?;
            anyhow::ensure!(manifest["files"].is_array(), "Game manifest has no files array");
            let canonical = root.canonicalize()?;
            *EXTERNAL_GAME.lock().unwrap() = Some(canonical);
            return Ok(());
        }
    }
    anyhow::bail!("Select the playgta5.com folder containing data/manifest.json and b/8b0b5899ed/shaders/index.json. Keep the external drive connected.")
}''')
replace('src/import.rs', '    #[no_mangle]\n    pub extern "C" fn muguet_import_error()', '''    #[no_mangle]
    pub extern "C" fn muguet_mount_external(path: *const c_char) -> bool {
        if path.is_null() { return false; }
        let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
        match crate::config::mount_external(std::path::Path::new(&path)) {
            Ok(()) => { *ERROR.lock().unwrap() = None; true },
            Err(e) => { *ERROR.lock().unwrap() = CString::new(format!("{e:#}")).ok(); false }
        }
    }

    #[no_mangle]
    pub extern "C" fn muguet_import_error()''')

swift = (source / 'ios/Launcher.swift').read_text(encoding='utf-8')
start = swift.index('@_silgen_name("muguet_mount_external")') if '@_silgen_name("muguet_mount_external")' in swift else swift.index('@_silgen_name("muguet_import")')
end = swift.index('\nstruct LauncherView: View', start)
adapter = (base / 'ExternalImporter.swift').read_text(encoding='utf-8')
swift = swift[:start] + adapter + swift[end:]
swift = swift.replace('Text("Muguet").font', 'Text("GTAiOS").font')
swift = swift.replace('allowedContentTypes: [.zip]', 'allowedContentTypes: [.folder]')
swift = swift.replace('Text("ImportingÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ \\(Int(p * 100)) %")', 'Text("Checking external game folderÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦")')
swift = swift.replace('Button("Import game data .zip")', 'Button("Select external game folder")')
swift = swift.replace('Button("Import other game dataâ€¦")', 'Button("Choose another game folderâ€¦")')
swift = swift.replace('ProgressView(value: p)', 'ProgressView().accessibilityLabel("Checking game folder")')
swift = swift.replace('This build has no game code: build it with ./make-ios.sh <game.zip>.', 'Compiled engine missing. Install the GTAiOS native engine build.')
(source / 'ios/Launcher.swift').write_text(swift, encoding='utf-8')
replace('ios/Info.plist', '<key>CFBundleDisplayName</key><string>Muguet</string>', '<key>CFBundleDisplayName</key><string>GTAiOS Native</string>')
# Avoid the large optional optimization pass. Original engine input is never changed.
replace('make-ios.sh', 'if command -v wasm-opt >/dev/null; then', 'if [ "${GTAIOS_OPTIMIZE:-0}" = 1 ] && command -v wasm-opt >/dev/null; then')
print('Applied pinned native runtime + external security-scoped folder adapter')

replace('ios/project.yml', '- path: ../assets/muguet.icon', '- path: ../../../ios/Sources/Resources/Assets.xcassets\n      - path: ../../../ios/Sources/Resources/gtav-story-trio.jpg')
replace('ios/project.yml', 'ASSETCATALOG_COMPILER_APPICON_NAME: muguet', 'ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon')
replace('ios/project.yml', 'TARGETED_DEVICE_FAMILY: "1,2"', 'TARGETED_DEVICE_FAMILY: "1"')

replace('ios/Launcher.swift', '            VStack(spacing: 16) {\n                Text("GTAiOS").font(.largeTitle.weight(.bold))', '            ScrollView {\n            VStack(spacing: 16) {\n                Text("GTAiOS").font(.largeTitle.weight(.bold))')
replace('ios/Launcher.swift', '            .padding(24)\n            .frame(maxWidth: .infinity)\n            Form {', '            .padding(24)\n            }\n            .frame(maxWidth: .infinity)\n            Form {')


# Keep the existing five-tab GTAiOS UIKit launcher. Muguet's native Rust
# executable presents it, and the Play action invokes its actual game loop.
# Do not compile or show Muguet's stock SwiftUI launcher.
project = base.parent
launcher = (project / "ios/Sources/UI/GTAFiveTabLauncher.swift").read_text(encoding="utf-8")
launcher = launcher.replace("GameNavigationController(rootViewController: entry.0)",
                            "UINavigationController(rootViewController: entry.0)")
launcher = launcher.replace("ControllerSettingsViewController()", "GTANativeControlsViewController()")
# Native launcher is portrait until Play requests landscape gameplay.
assert 'GTAIOSOrientation.playing ? .landscape : .portrait' in launcher
assert 'GTAIOSOrientation.playing ? .landscapeRight : .portrait' in launcher
old_navigation = """        navigationController?.setNavigationBarHidden(false, animated: true)
        let gameplay = GameViewController()
        gameplay.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(gameplay, animated: true)"""
assert launcher.count(old_navigation) == 1, "Original GTAiOS launch callback changed"
launcher = launcher.replace(old_navigation, "        NativeRuntimeBridge.play()")
launcher = launcher.replace('"Inspected game.wasm: "', '"Inspected game manifest: "')
launcher = launcher.replace('"WebAssembly engine readable: "', '"Game manifest readable: "')
launcher = launcher.replace('". Shader index found. This does not establish playable GTA V runtime."',
                            '". Shaders located. The engine is embedded in the app."')
launcher = launcher.replace('"Native Runtime Checks"', '"Start Native Engine"')
launcher = launcher.replace('"Live native PCM mixer gain"', '"Applied to real native CoreAudio output at launch"')
launcher = launcher.replace(
    '        stack.addArrangedSubview(controls)\n\n        let advanced = GTAReference.panelView(9)',
    '''        stack.addArrangedSubview(controls)
        let multiplayer = GTAReference.control("Multiplayer · Host / Join",
                                               symbol: "person.2.fill")
        multiplayer.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.navigationController?.setNavigationBarHidden(false, animated: true)
            self.navigationController?.pushViewController(
                GTANativeMultiplayerViewController(), animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(multiplayer)

        let advanced = GTAReference.panelView(9)''')
launcher = launcher.replace('        addScale(to: display)',
                            '        addEngineOption("mode", to: display)\n        addEngineOption("newgame", to: display)\n        addScale(to: display)')
# Only Muguet's actually-supported game modes are offered.
options = (project / "ios/Sources/Engine/EngineOptions.swift").read_text(encoding="utf-8")
options = options.replace('("Sandbox · Los Santos", "sandbox5"), ("Sandbox · env_test", "sandbox6")',
                          '("Sandbox · Los Santos", "sandbox5")')
(source / "ios/Launcher.swift").write_text(
    (base / "NativeFiveTabEntry.swift").read_text(encoding="utf-8"), encoding="utf-8")
(source / "ios/GTAFiveTabLauncher.swift").write_text(launcher, encoding="utf-8")
(source / "ios/EngineOptions.swift").write_text(options, encoding="utf-8")
(source / "ios/GTALaunchPreferences.swift").write_text(
    (project / "ios/Sources/UI/GTALaunchPreferences.swift").read_text(encoding="utf-8"), encoding="utf-8")
(source / "ios/LogStore.swift").write_text(
    (project / "ios/Sources/Support/LogStore.swift").read_text(encoding="utf-8"), encoding="utf-8")

# The iOS Swift launcher is statically compiled by Muguet/build.rs rather than
# by XcodeGen's stub target; all five-tab sources must be linked in that archive.
replace("build.rs", '.arg("ios/Launcher.swift")',
        '.args(["ios/Launcher.swift", "ios/GTAFiveTabLauncher.swift",\n'
        '               "ios/EngineOptions.swift", "ios/GTALaunchPreferences.swift",\n'
        '               "ios/LogStore.swift"])')
# Bundle the application icon and developer avatar, never GTA promotional art.
replace("ios/project.yml",
        '- path: ../../../ios/Sources/Resources/gtav-story-trio.jpg',
        '- path: ../../../ios/Sources/Resources/gtaios-developer-avatar.png')
# Detaching the Files provider must also unmount the native Rust game root.
replace("src/config.rs",
        '// Read-only mount: never extract, prune, write, or copy the selected library.',
        '''pub fn unmount_external() {
    *EXTERNAL_GAME.lock().unwrap() = None;
}

// Read-only mount: never extract, prune, write, or copy the selected library.''')
replace("src/import.rs",
        '    #[no_mangle]\n    pub extern "C" fn muguet_import_error()',
        '''    #[no_mangle]
    pub extern "C" fn muguet_unmount_external() {
        crate::config::unmount_external();
    }

    #[no_mangle]
    pub extern "C" fn muguet_import_error()''')

# Native audio uses real CoreAudio output; the user's Master Volume slider
# sets an output gain rather than changing a cosmetic preference.
replace("src/config.rs",
        '    if flag("mute") { set_default("MUGUET_MUTE", "1"); }',
        '''    if flag("mute") { set_default("MUGUET_MUTE", "1"); }
    if let Some(gain) = num("master_volume") {
        set_default("MUGUET_MASTER_VOLUME", gain.clamp(0.0, 1.0).to_string());
    }''')
replace("src/audio.rs",
        '    let (base, _) = crate::mem_base_len(&RT.get().unwrap().mem);',
        '''    let gain = std::env::var("MUGUET_MASTER_VOLUME").ok()
        .and_then(|v| v.parse::<f32>().ok()).unwrap_or(1.0).clamp(0.0, 1.0);
    let (base, _) = crate::mem_base_len(&RT.get().unwrap().mem);''')
replace("src/audio.rs", 'out[2 * i] = *p;', 'out[2 * i] = *p * gain;')
replace("src/audio.rs", 'out[2 * i + 1] = *p.add(1);', 'out[2 * i + 1] = *p.add(1) * gain;')

# Make actual native stdout/stderr available in Files > GTAiOS > GTAiOS-Logs.
replace("src/config.rs",
        '''    if cfg!(target_os = "ios") {
        return;
    }''',
        '''    if cfg!(target_os = "ios") {
        use std::os::fd::IntoRawFd;
        extern "C" { fn dup2(old: i32, new: i32) -> i32; }
        let dir = support_dir().join("GTAiOS-Logs");
        if std::fs::create_dir_all(&dir).is_ok() {
            if let Ok(file) = std::fs::OpenOptions::new()
                .create(true).append(true).open(dir.join("engine.txt")) {
                let fd = file.into_raw_fd();
                unsafe { dup2(fd, 1); dup2(fd, 2); }
            }
        }
        return;
    }''')

replace("ios/Info.plist",
        '<key>CFBundleDisplayName</key><string>GTAiOS Native</string>',
        '<key>CFBundleDisplayName</key><string>GTA V iOS</string>')
replace("ios/Info.plist",
        '<key>CFBundleName</key><string>Muguet</string>',
        '<key>CFBundleName</key><string>GTAiOS</string>')
# Preserve the upstream license within the signed IPA; it is not a
# visible developer-credits entry in the user's GTAiOS interface.
replace("ios/project.yml",
        '- path: ../../../ios/Sources/Resources/Assets.xcassets',
        '- path: ../LICENSE\n      - path: ../../../ios/Sources/Resources/Assets.xcassets')
# Explicitly permit both scene geometries, with a portrait-only launcher.
replace("ios/Info.plist",
        '<key>UISupportedInterfaceOrientations</key>\n  <array><string>UIInterfaceOrientationLandscapeRight</string>',
        '<key>UISupportedInterfaceOrientations</key>\n  <array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeRight</string>')
plist = (source / "ios/Info.plist").read_text(encoding="utf-8")
assert '<string>UIInterfaceOrientationPortrait</string>' in plist
assert '<string>UIInterfaceOrientationLandscapeRight</string>' in plist
assert '<string>UIInterfaceOrientationLandscapeLeft</string>' in plist
print("Native engine uses original GTAiOS five-tab UIKit UI and engine-backed settings")


# Use the exact SteamIOS glass controller, persisted layout, and editor UI.
# Its XInput transport cannot be linked to a native Muguet app; replace ONLY
# that transport with Muguet's native gamepad/keyboard/mouse input.
(source / "ios/SteamIOSControllerOverlay.swift").write_text(
    (base / "SteamIOSControllerOverlay.swift").read_text(encoding="utf-8"), encoding="utf-8")
replace("build.rs",
        '"ios/LogStore.swift"])',
        '"ios/LogStore.swift", "ios/SteamIOSControllerOverlay.swift"])')
# The old hardcoded Muguet touch layout must not coexist with SteamIOS.
replace("src/app.rs",
        'crate::touch::install(&window);',
        'crate::touch::release(); // SteamIOS UIWindow owns all touch controls')
replace("src/pad.rs",
        '''    let Some(gp) = gamepad() else {
        if ACTIVE.swap(false, Ordering::Relaxed) {
            if let Some(st) = STATE.lock().unwrap().take() { release(st); }
            eprintln!("[pad] controller disconnected");
        }
        return false;
    };
    if !ACTIVE.swap(true, Ordering::Relaxed) {
        eprintln!("[pad] controller connected");
    }''',
        '''    let gp = gamepad();
    let steamios = *STEAMIOS_TOUCH.lock().unwrap();
    // Preserve the real SteamIOS merge rule for connected physical pads.
    let physical_sticks = gp.as_ref().map(|g| unsafe {
        let ls = g.leftThumbstick();
        let rs = g.rightThumbstick();
        (ls.xAxis().value(), ls.yAxis().value(),
         rs.xAxis().value(), rs.yAxis().value())
    }).unwrap_or((0.0, 0.0, 0.0, 0.0));
    if gp.is_none() && !steamios.enabled {
        if ACTIVE.swap(false, Ordering::Relaxed) {
            if let Some(st) = STATE.lock().unwrap().take() { release(st); }
            HORN_PAD.store(false, Ordering::Relaxed);
            eprintln!("[pad] controller disconnected");
        } else if let Some(st) = STATE.lock().unwrap().take() {
            release(st);
            HORN_PAD.store(false, Ordering::Relaxed);
        }
        return false;
    }
    if gp.is_some() {
        if !ACTIVE.swap(true, Ordering::Relaxed) {
            eprintln!("[pad] physical controller connected");
        }
    } else {
        ACTIVE.store(false, Ordering::Relaxed);
    }''')
replace("src/pad.rs",
        '''    unsafe {
        let ls = gp.leftThumbstick();''',
        '''    HORN_PAD.store(false, Ordering::Relaxed);
    if let Some(gp) = gp {
    unsafe {
        let ls = gp.leftThumbstick();''')
replace("src/pad.rs",
        '''    }

    if cfg!(target_os = "ios") { input::set_locked(true); }''',
        '''    }
    }
    steamios_apply_touch(steamios, &mut keys, &mut buttons, in_car, dt, physical_sticks);

    // The original Muguet iOS touch::refresh() kept FOCUS asserted for
    // gameplay. The SteamIOS overlay replaces that native touch view and
    // must restore the exact same native engine-input semantics. Without it
    // buttons can navigate menus while the game ignores look/fire/actions.
    if cfg!(target_os = "ios") {
        input::set_locked(true);
        if !crate::gpu::SUSPENDED.load(Ordering::Relaxed) {
            input::set_focus(true);
        }
    }''')
(source / "src/pad.rs").write_text(
    (source / "src/pad.rs").read_text(encoding="utf-8") + "\n" +
    (base / "SteamIOSPadRuntime.rs").read_text(encoding="utf-8"),
    encoding="utf-8")
replace("src/input.rs",
        '''pub fn publish(block: u64) {''',
        '''// Direct VK codes from SteamIOS's mapping editor. This is the same
// guest input block used by native physical-controller mappings.
pub fn steamios_virtual_key(vk: u8, pressed: bool) {
    if vk == 0x0d && pressed { start_menu_key("Enter"); }
    if let Some(value) = key_byte(vk) {
        value.store(if pressed { 0x80 } else { 0 }, Ordering::SeqCst);
    }
}
pub fn steamios_text(character: u16) {
    if let (Some(head), Some(tail), Some(b)) = (word(HEAD), word(TAIL), base()) {
        let h = head.load(Ordering::SeqCst);
        if (h.wrapping_sub(tail.load(Ordering::SeqCst)) as u32) < 64 {
            unsafe {
                std::ptr::write_volatile(
                    b.add(296 + 2 * (h & 63) as usize) as *mut u16, character);
            }
            head.store(h.wrapping_add(1), Ordering::SeqCst);
        }
    }
}

pub fn publish(block: u64) {''')
print("SteamIOS native touch overlay and physical/touch input merge integrated")

# GTA V iOS supports iPhone iOS 18 through iOS 27. The build host is the
# GitHub-hosted Xcode 27 image, which runs macOS 27 (arm64). Apply the same
# minimum to Rust, the statically linked Swift controller, the app bundle,
# and the Mach-O loader command, not merely Info.plist display metadata.
replace("ios/project.yml",
        '    iOS: "15.0"',
        '    iOS: "18.0"')
replace("ios/project.yml",
        'xcrun vtool -set-build-version ios 15.0 26.0 -replace',
        'xcrun vtool -set-build-version ios 18.0 27.0 -replace')
replace("make-ios.sh",
        'IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo',
        'IPHONEOS_DEPLOYMENT_TARGET=18.0 cargo')
replace("build.rs",
        '"-target", "arm64-apple-ios15.0",',
        '"-target", "arm64-apple-ios18.0",')
print("iOS >=18 native target (Rust/Swift/Xcode/Mach-O); macOS 27 Xcode 27 runner")

# UIKit transiently marks the Metal UIWindow unfocused when an auxiliary
# transparent controller window appears. A connected touch gamepad must not
# make the guest release all held buttons on that unrelated focus transition.
# Real background suspension still calls input::set_focus(false).
replace("src/app.rs",
        '''            WindowEvent::Focused(f) => {
                input::set_focus(f);
                if !f { self.unlock(&window); }
            }''',
        '''            WindowEvent::Focused(f) => {
                #[cfg(target_os = "ios")]
                let f = f || crate::pad::steamios_overlay_active();
                input::set_focus(f);
                if !f { self.unlock(&window); }
            },''')
print("SteamIOS native input preserves focus and mouse lock during gameplay")

# Live sensitivity: the old LazyLock cached sensitivity at startup. Sliders
# must update the same native guest input data while gameplay is running.
replace("src/input.rs",
        '''static SENS: LazyLock<f64> = LazyLock::new(|| std::env::var("MUGUET_MOUSE_SENS").ok().and_then(|v| v.parse().ok()).unwrap_or(2.0));''',
        '''static SENS: AtomicU64 = AtomicU64::new(2.0f64.to_bits());
static STICK_GAIN: AtomicU64 = AtomicU64::new(2.0f64.to_bits());
#[no_mangle]
pub extern "C" fn muguet_steamios_set_mouse_sensitivity(value: f64) {
    if value.is_finite() { SENS.store(value.clamp(0.25, 12.0).to_bits(), Ordering::Release); }
}
#[no_mangle]
pub extern "C" fn muguet_steamios_set_stick_gain(value: f64) {
    if value.is_finite() { STICK_GAIN.store(value.clamp(0.25, 12.0).to_bits(), Ordering::Release); }
}
pub fn native_stick_gain() -> f64 { f64::from_bits(STICK_GAIN.load(Ordering::Acquire)) }''')
replace("src/input.rs",
        '''f.0 += dx * *SENS;
        f.1 += dy * *SENS;''',
        '''let sensitivity = f64::from_bits(SENS.load(Ordering::Acquire));
        f.0 += dx * sensitivity;
        f.1 += dy * sensitivity;''')
replace("src/pad.rs", 'const LOOK_SPEED: f64 = 700.0;', 'const LOOK_SPEED: f64 = 1100.0;')
replace("src/pad.rs", 'input::mouse_delta_f(dx * LOOK_SPEED * dt, dy * LOOK_SPEED * dt);',
        'input::mouse_delta_f(dx * LOOK_SPEED * dt * input::native_stick_gain(), dy * LOOK_SPEED * dt * input::native_stick_gain());')
print("Live camera and controller right-stick gain implemented")

# Native stderr used to disappear into the system console on a sideloaded
# iPhone. Stream real Muguet [io], [fs], [pause], [gpu] errors into Files.
# Bounded rotation prevents perpetual engine logging from filling Documents.
replace("src/config.rs",
        '''    if cfg!(target_os = "ios") {
        return;
    }
    let in_bundle''',
        '''    if cfg!(target_os = "ios") {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        let logdir = PathBuf::from(home).join("Documents/GTAiOS-Logs");
        let _ = std::fs::create_dir_all(&logdir);
        let path = logdir.join("engine.txt");
        if std::fs::metadata(&path).is_ok_and(|meta| meta.len() > 8 * 1024 * 1024) {
            let _ = std::fs::rename(&path, logdir.join("engine-previous.txt"));
        }
        if let Ok(f) = std::fs::OpenOptions::new().append(true).create(true).open(&path) {
            use std::os::fd::IntoRawFd;
            let fd = f.into_raw_fd();
            unsafe { dup2(fd, 2); dup2(fd, 1); }
        }
        return;
    }
    let in_bundle''')
print("Native iOS engine stdout/stderr now written to Files/GTA V iOS/GTAiOS-Logs/engine.txt")
