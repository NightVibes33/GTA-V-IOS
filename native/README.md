# GTAiOS native engine integration

This target uses c22dev/Muguet at commit
75d3576bc4e53f514d75f19f2d397c2b7adc9d05 under its GPL-3.0-or-later
license. The pinned source and all modifications are available here; upstream
credits and LICENSE remain in the submodule. This is separate from the existing
UIKit readiness app, whose renderer and host ABI are unfinished.

The user authorized embedding the compiled engine in the IPA. The approximately
20 GB of data archives and shaders remain external. The source engine is fetched
from a private repository at a fixed commit through a read-only deploy key, and
its exact SHA-256 is verified before compilation. No data archives are uploaded.

`Build GTAiOS Native Engine IPA` builds the real engine with upstream's native
Wasmtime/WGPU/Metal runtime. `prepare_muguet.py` replaces the ZIP importer UI
with an external folder picker. Validation runs on a serial background queue;
SwiftUI state and security-scoped URL lifetime are owned by the main actor.
The bookmark is restored on subsequent launches. Keep the drive connected.
Saves and settings stay in the app's Documents directory. The adapter does not
copy, prune, or write the external library.

Select `playgta5.com` (the folder containing `data` and `b`) in the iOS Files
picker. On the supplied Windows PC that folder is
`D:\mirror\mirror\playgta5.com`. The Windows drive letter itself is not an iOS
path: the drive must be connected to the iPhone or its contents exposed by a
Files provider that permits directory access and random reads.

Local read-only validation:

```powershell
python native/verify_external_assets.py --game-root D:\mirror
```

On a Mac, after initializing the submodule:

```sh
python3 native/prepare_muguet.py
cd native/Muguet
BUNDLE_ID=com.nightvibes33.gtaios ./make-ios.sh /authorized/game.wasm --ipa
python3 ../verify_external_assets.py --ipa build/Muguet.ipa
```

The GitHub workflow publishes only `GTAiOS.ipa` (bundle ID `com.nightvibes33.gtaios`) with the project's own five-tab UI, icon and NightVibes33-only developer credits. Upstream engine sources remain under `native/Muguet` with their separate required legal license. The old diagnostic-only IPA workflow is not triggered by `ios-usb-port` pushes.

The output is an unsigned/ad-hoc IPA for re-signing. Upstream recommends
AltStore and its increased-memory entitlement; other signing tools must preserve
the needed entitlements. Building and packaging do not verify gameplay. Only a
physical-device test can verify code signing, memory allocation, external-drive
access, original loading, actual world frames, audio and controller response.
Upstream lists a missing minimap and single-player story missions as limitations.

The local library inspection found all 5,814 manifest entries (20,944,285,552
expected bytes). Two non-final HTML documentation files differ from manifest
sizes by two bytes each. The check reports these differences and does not modify
the library. Engine SHA-256 and shader index presence matched the build input.

## Deployment compatibility

The `ios-usb-port` GTA V iOS build targets iPhone **iOS 18.0 through iOS 27** (minimum deployment target 18.0), using GitHub Actions' **`xcode-27` runner on macOS 27**. The target is applied to native Rust, Swift, the Xcode-generated app, and the Mach-O load command. The pinned Muguet runtime and the external-files model remain unchanged. Version support is a deployment setting; iPhone gameplay and controller functionality require device verification.
