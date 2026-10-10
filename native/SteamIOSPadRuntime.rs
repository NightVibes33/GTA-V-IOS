// SteamIOS touch-controller transport into Muguet. Virtual touch samples
// preserve the exact XInput masks and signed stick range from SteamIOS.
// This does not load Wine; pad::poll merges the virtual sample into native GTA.
#[derive(Clone, Copy)]
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
static STEAMIOS_TOUCH: Mutex<SteamIOSPad> = Mutex::new(SteamIOSPad {
    enabled: false, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0
});
#[no_mangle]
pub extern "C" fn muguet_steamios_pad_update(
    connected: bool, buttons: u16, lt: u8, rt: u8,
    lx: i16, ly: i16, rx: i16, ry: i16
) {
    let mut pad = STEAMIOS_TOUCH.lock().unwrap();
    *pad = SteamIOSPad {
        enabled: connected, buttons, lt, rt, lx, ly, rx, ry
    };
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

fn steamios_apply_touch(
    pad: SteamIOSPad, keys: &mut HashSet<&'static str>,
    buttons: &mut u8, in_car: bool, dt: f64
) {
    if !pad.enabled { return; }
    let held = |bit: u16| pad.buttons & bit != 0;
    let axis = |v: i16| -> f32 {
        if v < 0 { f32::from(v) / 32768.0 } else { f32::from(v) / 32767.0 }
    };
    let (lx, ly) = (axis(pad.lx), axis(pad.ly));
    if lx < -STICK_DEADZONE { keys.insert("KeyA"); }
    if lx > STICK_DEADZONE { keys.insert("KeyD"); }
    if in_car {
        if ly > STICK_DEADZONE { keys.insert("Numpad8"); }
        if ly < -STICK_DEADZONE { keys.insert("Numpad2"); }
        if pad.rt > 51 { keys.insert("KeyW"); }
        if pad.lt > 51 { keys.insert("KeyS"); }
        if held(0x0200) || held(0x4000) { keys.insert("Space"); }
        if held(0x0040) { HORN_PAD.store(true, Ordering::Relaxed); }
    } else {
        if ly > STICK_DEADZONE { keys.insert("KeyW"); }
        if ly < -STICK_DEADZONE { keys.insert("KeyS"); }
        if pad.rt > 51 { *buttons |= 1; }
        if pad.lt > 51 { *buttons |= 2; }
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
    let (dx, dy) = (curve(pad.rx), -curve(pad.ry));
    if dx != 0.0 || dy != 0.0 {
        input::mouse_delta_f(dx * LOOK_SPEED * dt, dy * LOOK_SPEED * dt);
    }
}
