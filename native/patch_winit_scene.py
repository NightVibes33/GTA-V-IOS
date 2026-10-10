#!/usr/bin/env python3
"""Bind pinned winit 0.30.13 Metal UIWindow to UIKit UIScene on iOS 27."""
from pathlib import Path
import subprocess

muguet = Path(__file__).resolve().parent / "Muguet"
vendor = muguet / "vendor/winit"
pinned_commit = "e9809ef54b18499bb4f2cac945719ecc2a61061b"

def replace_once(path, before, after):
    text = path.read_text(encoding="utf-8")
    if text.count(before) != 1:
        raise RuntimeError(f"Unexpected pinned source at {path}: {text.count(before)} matches")
    path.write_text(text.replace(before, after), encoding="utf-8")

if not vendor.is_dir():
    subprocess.run(["git", "clone", "--quiet", "--depth", "1", "--branch", "v0.30.13",
                    "https://github.com/rust-windowing/winit.git", str(vendor)], check=True)
actual = subprocess.check_output(["git", "-C", str(vendor), "rev-parse", "HEAD"],
                                 text=True).strip()
if actual != pinned_commit:
    raise RuntimeError(f"winit source drift: {actual}, expected {pinned_commit}")

window = vendor / "src/platform_impl/ios/window.rs"
replace_once(window,
    "        let this: Retained<Self> = unsafe { msg_send_id![mtm.alloc(), initWithFrame: frame] };",
    """        // iOS 27: create the existing native Metal window inside the live scene.
        extern "C" { fn gtaios_active_window_scene() -> *mut AnyObject; }
        let scene = unsafe { gtaios_active_window_scene() };
        assert!(!scene.is_null(), "Metal window requested before UIScene connection");
        let this: Retained<Self> = unsafe {
            msg_send_id![mtm.alloc(), initWithWindowScene: &*scene]
        };""")

replace_once(muguet / "Cargo.toml",
    '[patch.crates-io]\nwgpu-core = { path = "vendor/wgpu-core" }',
    '[patch.crates-io]\nwgpu-core = { path = "vendor/wgpu-core" }\nwinit = { path = "vendor/winit" }')

replace_once(muguet / "ios/Info.plist",
    "  <key>UISupportedInterfaceOrientations</key>",
    """  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key>
    <dict><key>UIWindowSceneSessionRoleApplication</key><array><dict>
      <key>UISceneConfigurationName</key><string>GTAiOS Main Scene</string>
      <key>UISceneClassName</key><string>UIWindowScene</string>
      <key>UISceneDelegateClassName</key><string>GTAIOSSceneDelegate</string>
    </dict></array></dict>
  </dict>
  <key>UISupportedInterfaceOrientations</key>""")

assert "GTAIOSSceneDelegate" in (muguet / "ios/Launcher.swift").read_text()
print("iOS 27 UIScene manifest, Swift scene delegate and pinned winit Metal window ready")
