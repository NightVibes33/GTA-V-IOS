// SteamIOS touch-controller transport into Muguet. Virtual touch samples
// preserve the exact XInput masks and signed stick range from SteamIOS.
// This does not load Wine; pad::poll merges the virtual sample into native GTA.
#[derive(Clone, Copy, PartialEq)]
struct SteamIOSPad {
    enabled: bool,
    buttons: u16,
    lt: u8,
    rt: u8,
    lx: i16,
    ly: i16,
    rx: i16,
    ry: i16,
}
static STEAMIOS_PACKETS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);
#[no_mangle]
pub extern "C" fn muguet_steamios_packet_count() -> u64 {
    STEAMIOS_PACKETS.load(Ordering::Relaxed)
}
static STEAMIOS_TOUCH: Mutex<SteamIOSPad> = Mutex::new(SteamIOSPad {
    enabled: false, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0
});
#[no_mangle]
pub extern "C" fn muguet_steamios_pad_update(
    connected: bool, buttons: u16, lt: u8, rt: u8,
    lx: i16, ly: i16, rx: i16, ry: i16
) {
    let mut pad = STEAMIOS_TOUCH.lock().unwrap();
    let next = SteamIOSPad {
        enabled: connected, buttons, lt, rt, lx, ly, rx, ry
    };
    if *pad != next {
        STEAMIOS_PACKETS.fetch_add(1, Ordering::Relaxed);
        if pad.enabled != next.enabled {
            eprintln!("[controls] SteamIOS touch connected={} packets={}",
                      next.enabled, STEAMIOS_PACKETS.load(Ordering::Relaxed));
        }
        *pad = next;
    }
}
#[no_mangle]
pub extern "C" fn muguet_steamios_key(vk: i32, pressed: bool) {
    if (0..=255).contains(&vk) {
        input::steamios_virtual_key(vk as u8, pressed);
    }
}
#[no_mangle]
pub extern "C" fn muguet_steamios_mouse(button: i32, pressed: bool) {
    if button == 0 || button == 2 {
        input::button(button as usize, pressed);
    }
}
#[no_mangle]
pub extern "C" fn muguet_steamios_text(character: u16) {
    input::steamios_text(character);
}
// Swipe movement enters the identical guest mouse delta block as right stick.
static STEAMIOS_SWIPE_PACKETS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);
#[no_mangle]
pub extern "C" fn muguet_steamios_swipe_look(dx: f64, dy: f64) {
    if !dx.is_finite() || !dy.is_finite() { return; }
    if dx == 0.0 && dy == 0.0 { return; }
    STEAMIOS_SWIPE_PACKETS.fetch_add(1, Ordering::Relaxed);
    input::mouse_delta_f(dx.clamp(-140.0, 140.0), dy.clamp(-140.0, 140.0));
}
#[no_mangle]
pub extern "C" fn muguet_steamios_swipe_count() -> u64 {
    STEAMIOS_SWIPE_PACKETS.load(Ordering::Relaxed)
}

fn steamios_apply_touch(
    pad: SteamIOSPad, keys: &mut HashSet<&'static str>,
    buttons: &mut u8, in_car: bool, dt: f64,
    physical_sticks: (f32, f32, f32, f32)
) {
    if !pad.enabled {
        HORN_TOUCH.store(false, Ordering::Relaxed);
        return;
    }
    let held = |bit: u16| pad.buttons & bit != 0;
    let axis = |v: i16| -> f32 {
        if v < 0 { f32::from(v) / 32768.0 } else { f32::from(v) / 32767.0 }
    };
    let (lx, ly) = (axis(pad.lx), axis(pad.ly));
    // SteamIOS's physical/touch arbitration: a physical deflection outside
    // the XInput dead zone wins, rather than combining opposite stick inputs.
    let left_free = physical_sticks.0.hypot(physical_sticks.1) <= 7849.0 / 32768.0;
    let right_free = physical_sticks.2.hypot(physical_sticks.3) <= 8689.0 / 32768.0;
    let (lx, ly) = if left_free { (lx, ly) } else { (0.0, 0.0) };
    if lx < -STICK_DEADZONE { keys.insert("KeyA"); }
    if lx > STICK_DEADZONE { keys.insert("KeyD"); }
    if in_car {
        if ly > STICK_DEADZONE { keys.insert("Numpad8"); }
        if ly < -STICK_DEADZONE { keys.insert("Numpad2"); }
        if pad.rt > 51 { keys.insert("KeyW"); }
        if pad.lt > 51 { keys.insert("KeyS"); }
        if held(0x0200) || held(0x4000) { keys.insert("Space"); }
        HORN_TOUCH.store(held(0x0040), Ordering::Relaxed);
    } else {
        HORN_TOUCH.store(false, Ordering::Relaxed);
        if ly > STICK_DEADZONE { keys.insert("KeyW"); }
        if ly < -STICK_DEADZONE { keys.insert("KeyS"); }
        if pad.rt > 51 { *buttons |= 1; }
        if pad.lt > 51 { *buttons |= 2; }
        // Original GTA V Xbox mapping: A=sprint, X=jump, B=reload/back,
        // Y=enter vehicle. Do not substitute generic controller bindings.
        if held(0x1000) { keys.insert("ShiftLeft"); }
        if held(0x4000) { keys.insert("Space"); }
        if held(0x0200) { keys.insert("KeyQ"); }
        if held(0x0040) { keys.insert("ControlLeft"); }
    }
    if held(0x1000) { keys.insert("Enter"); }
    if held(0x2000) { keys.insert("KeyR"); keys.insert("Backspace"); }
    if held(0x8000) { keys.insert("KeyF"); }
    if held(0x0100) { keys.insert("Tab"); }
    if held(0x0080) { keys.insert("KeyC"); }
    if held(0x0001) { keys.insert("ArrowUp"); }
    if held(0x0002) { keys.insert("ArrowDown"); }
    if held(0x0004) { keys.insert("ArrowLeft"); }
    if held(0x0008) { keys.insert("ArrowRight"); }
    if held(0x0010) || held(0x0400) { keys.insert("Escape"); }
    if held(0x0020) { keys.insert("KeyV"); }
    let curve = |v: i16| -> f64 {
        let v = axis(v);
        let magnitude = v.abs();
        if magnitude < LOOK_DEADZONE { return 0.0; }
        (((magnitude - LOOK_DEADZONE) / (1.0 - LOOK_DEADZONE)) as f64)
            .powf(1.8).copysign(v as f64)
    };
    let (dx, dy) = if right_free {
        (curve(pad.rx), -curve(pad.ry))
    } else { (0.0, 0.0) };
    if dx != 0.0 || dy != 0.0 {
        let gain = input::native_stick_gain();
        input::mouse_delta_f(dx * LOOK_SPEED * dt * gain, dy * LOOK_SPEED * dt * gain);
    }
}

pub fn steamios_overlay_active() -> bool {
    STEAMIOS_TOUCH.lock().unwrap().enabled
}
