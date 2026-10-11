// Muguet engine I/O adapter for external GTA V library.
// Archive-range cache serves exact bytes before requiring an open USB handle.
// The source tree is pinned; this file is installed by prepare_muguet.py.
use crate::mem_base_len;
use crate::usb_range_cache::RangeCache;
use std::collections::HashMap;
use std::fs::File;
use std::io;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::Duration;
use wasmtime::SharedMemory;

static STARTED: AtomicBool = AtomicBool::new(false);
const MAX_OPEN: usize = 1024;

pub fn data_dir() -> PathBuf {
    PathBuf::from(std::env::var("MUGUET_DATA").unwrap_or_default())
}

fn manifest_files() -> Vec<(String, u64)> {
    let text = std::fs::read_to_string(data_dir().join("manifest.json")).expect("manifest.json");
    let v: serde_json::Value = serde_json::from_str(&text).expect("manifest json");
    v["files"]
        .as_array()
        .expect("files")
        .iter()
        .map(|f| (f[0].as_str().unwrap_or("").to_string(), f[1].as_u64().unwrap_or(0)))
        .collect()
}

fn atomic_i32(mem: &SharedMemory, addr: u64) -> &AtomicI32 {
    let (base, len) = mem_base_len(mem);
    assert!((addr as usize) + 4 <= len && addr % 4 == 0);
    unsafe { &*(base.add(addr as usize) as *const AtomicI32) }
}

pub fn start(mem: &SharedMemory, table: u64) {
    if STARTED.swap(true, Ordering::SeqCst) { return; }
    let mem = mem.clone();
    std::thread::Builder::new()
        .name("io".into())
        .spawn(move || serve_loop(mem, table))
        .expect("spawn io thread");
    eprintln!("[io] native I/O thread started (table=0x{table:x})");
}

fn transient(e: &io::Error, provider_backed: bool) -> bool {
    matches!(e.raw_os_error(), Some(5 | 6 | 9))
        || (provider_backed && e.raw_os_error() == Some(2))
        || matches!(e.kind(), io::ErrorKind::Interrupted
             | io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
}

// Existing security-scoped folder access is retained by USBStorageManager in
// Swift. Short File Provider outages may recover with reopen + bounded backoff.
// If iOS permanently revokes the security scope (-2001), only a new Files picker
// grant can restore it: NEVER fabricate data or report a successful short read.
fn usb_exact(
    handles: &mut HashMap<i32, File>, id: i32, path: &Path,
    off: u64, dest: &mut [u8], provider_backed: bool,
) -> io::Result<()> {
    let delays = [0_u64, 30, 60, 120, 240, 480, 960, 1500, 2000, 3000, 4000];
    let mut last: Option<io::Error> = None;
    for (attempt, delay) in delays.into_iter().enumerate() {
        if delay != 0 { std::thread::sleep(Duration::from_millis(delay)); }
        if !handles.contains_key(&id) {
            if handles.len() >= MAX_OPEN { handles.clear(); }
            match File::open(path) {
                Ok(f) => { handles.insert(id, f); }
                Err(e) => {
                    let retryable = transient(&e, provider_backed);
                    if attempt == 0 { eprintln!("[io] USB open {path:?}: {e}; reconnect wait starting"); }
                    last = Some(e);
                    if retryable { continue; }
                    break;
                }
            }
        }
        match handles.get(&id).unwrap().read_exact_at(dest, off) {
            Ok(()) => {
                if attempt != 0 {
                    eprintln!("[io] USB read recovered {path:?}@{off}+{} after attempt={}", dest.len(), attempt);
                }
                return Ok(());
            }
            Err(e) => {
                let retryable = transient(&e, provider_backed);
                if attempt == 0 { eprintln!("[io] USB read {path:?}@{off}+{}: {e}; reopen pending", dest.len()); }
                last = Some(e);
                handles.remove(&id);
                if !retryable { break; }
            }
        }
    }
    let e = last.unwrap_or_else(|| io::Error::other("USB archive unavailable"));
    eprintln!("[io] USB read unavailable after bounded reconnect attempts: {path:?}@{off}+{}: {e}", dest.len());
    Err(e)
}

fn serve_loop(mem: SharedMemory, table: u64) {
    let files = manifest_files();
    let root = data_dir();
    let provider_backed = root.to_string_lossy().contains("/Library/LiveFiles/");
    let mut cache = RangeCache::new("archives", 120 << 20, 1008 << 20);
    let mut handles: HashMap<i32, File> = HashMap::new();
    let mut served: u64 = 0;
    let mut bytes: u64 = 0;
    eprintln!("[cache] enabled: 256KiB ranges, archives RAM=120MiB disk=1008MiB; shaders RAM=8MiB disk=16MiB");
    loop {
        let seen = atomic_i32(&mem, table).load(Ordering::SeqCst);
        let n = atomic_i32(&mem, table + 4).load(Ordering::SeqCst).max(0) as u64;
        for slot in 0..n {
            let w = table + 64 + 64 * slot;
            if atomic_i32(&mem, w).compare_exchange(1, 3, Ordering::SeqCst, Ordering::SeqCst).is_err() {
                continue;
            }
            let word = |k: u64| atomic_i32(&mem, w + 4 * k).load(Ordering::SeqCst) as u32 as u64;
            let id = word(1) as i32;
            let off = word(2) | (word(3) << 32);
            let dst = word(4) | (word(5) << 32);
            let requested = word(6);
            let result: i64 = match files.get(id as usize) {
                None => -1,
                Some((relative, size)) => {
                    if off >= *size { 0 } else {
                        let len = requested.min(size - off);
                        let (base, mlen) = mem_base_len(&mem);
                        if dst.checked_add(len).is_none_or(|end| end > mlen as u64) {
                            -1
                        } else {
                            let buf = unsafe { std::slice::from_raw_parts_mut(base.add(dst as usize), len as usize) };
                            let path = root.join(relative);
                            // Cached archive blocks must succeed without reopening the
                            // disappearing LiveFiles item. Only missing blocks use USB.
                            match cache.read_at(&path, *size, off, buf, |at, target| {
                                usb_exact(&mut handles, id, &path, at, target, provider_backed)
                            }) {
                                Ok(()) => len as i64,
                                Err(e) => {
                                    handles.remove(&id);
                                    eprintln!("[io] persistent archive range error {relative}@{off}+{len}: {e}");
                                    -1
                                }
                            }
                        }
                    }
                }
            };
            served += 1;
            if result > 0 { bytes += result as u64; }
            if served % 2000 == 0 { eprintln!("[io] {served} reads, {} MiB returned to engine", bytes >> 20); }
            atomic_i32(&mem, w + 28).store(result as i32, Ordering::SeqCst);
            atomic_i32(&mem, w).store(2, Ordering::SeqCst);
            let _ = mem.atomic_notify(w, 1);
        }
        let _ = mem.atomic_wait32(table, seen as u32, Some(Duration::from_millis(20)));
    }
}
