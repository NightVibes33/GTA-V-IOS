// Veltrix / GTAiOS: bounded USB range cache. Never writes to the selected game folder.
// Standalone std-only module so it can be tested with rustc --test.
use std::collections::HashMap;
use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::{self, Write};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const BLOCK: u64 = 256 * 1024;
const MAGIC: &[u8; 8] = b"GTAIOv01";
const HEADER: usize = 20;

struct RamBlock { bytes: Vec<u8>, last: u64 }
struct DiskBlock { size: u64, last: u128 }

pub struct RangeCache {
    directory: PathBuf,
    ram_limit: usize,
    disk_limit: u64,
    ram_used: usize,
    disk_used: u64,
    ram: HashMap<String, RamBlock>,
    disk: HashMap<String, DiskBlock>,
    identities: HashMap<PathBuf, String>,
    clock: u64,
}

fn signature(data: &[u8]) -> u64 {
    // Stable FNV-1a checksum detects incomplete/corrupt local cache blocks.
    let mut hash = 0xcbf29ce484222325_u64;
    for b in data { hash ^= *b as u64; hash = hash.wrapping_mul(0x100000001b3); }
    hash
}

fn modified_stamp(t: SystemTime) -> u128 {
    t.duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos()
}

impl RangeCache {
    pub fn new(kind: &str, ram_limit: usize, disk_limit: u64) -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        Self::with_directory(PathBuf::from(home).join("Library/Caches/GTAiOS/USBRangeCache").join(kind), ram_limit, disk_limit)
    }

    fn with_directory(directory: PathBuf, ram_limit: usize, disk_limit: u64) -> Self {
        let mut result = Self {
            directory, ram_limit, disk_limit, ram_used: 0, disk_used: 0,
            ram: HashMap::new(), disk: HashMap::new(),
            identities: HashMap::new(), clock: 0,
        };
        if fs::create_dir_all(&result.directory).is_ok() {
            if let Ok(entries) = fs::read_dir(&result.directory) {
                for item in entries.flatten() {
                    let path = item.path();
                    if path.extension().is_none_or(|e| e != "blk") { continue; }
                    if !item.file_type().is_ok_and(|t| t.is_file()) { continue; }
                    if let Ok(meta) = item.metadata() {
                        let name = item.file_name().to_string_lossy().into_owned();
                        let size = meta.len();
                        result.disk_used = result.disk_used.saturating_add(size);
                        result.disk.insert(name, DiskBlock {
                            size, last: modified_stamp(meta.modified().unwrap_or(UNIX_EPOCH)),
                        });
                    }
                }
            }
        }
        result.evict_disk(0);
        result
    }

    fn file_identity(&mut self, source: &Path, expected_size: u64) -> io::Result<String> {
        if let Some(id) = self.identities.get(source) { return Ok(id.clone()); }
        // First successful stat is required. Never blindly reuse persistent
        // blocks for an unverified file after an app restart or library switch.
        let mut meta = fs::metadata(source);
        for delay in [30_u64, 60, 120, 240, 480, 960] {
            if meta.is_ok() { break; }
            std::thread::sleep(std::time::Duration::from_millis(delay));
            meta = fs::metadata(source);
        }
        let meta = meta?;
        let mut h = std::collections::hash_map::DefaultHasher::new();
        source.hash(&mut h);
        expected_size.hash(&mut h);
        meta.len().hash(&mut h);
        meta.modified().unwrap_or(UNIX_EPOCH).duration_since(UNIX_EPOCH)
            .unwrap_or_default().as_nanos().hash(&mut h);
        let id = format!("{:016x}", h.finish());
        self.identities.insert(source.to_path_buf(), id.clone());
        Ok(id)
    }

    fn tick(&mut self) -> u64 {
        self.clock = self.clock.wrapping_add(1);
        self.clock
    }

    fn evict_ram(&mut self, required: usize) {
        while self.ram_used.saturating_add(required) > self.ram_limit && !self.ram.is_empty() {
            let key = self.ram.iter().min_by_key(|(_, v)| v.last).map(|(k, _)| k.clone()).unwrap();
            if let Some(old) = self.ram.remove(&key) {
                self.ram_used = self.ram_used.saturating_sub(old.bytes.len());
            }
        }
    }

    fn evict_disk(&mut self, required: u64) {
        while self.disk_used.saturating_add(required) > self.disk_limit && !self.disk.is_empty() {
            let key = self.disk.iter().min_by_key(|(_, v)| v.last).map(|(k, _)| k.clone()).unwrap();
            if fs::remove_file(self.directory.join(&key)).is_err() { break; }
            if let Some(old) = self.disk.remove(&key) {
                self.disk_used = self.disk_used.saturating_sub(old.size);
            }
        }
    }

    fn ram_get(&mut self, key: &str, expected: usize) -> Option<Vec<u8>> {
        let now = self.tick();
        let entry = self.ram.get_mut(key)?;
        if entry.bytes.len() != expected { return None; }
        entry.last = now;
        Some(entry.bytes.clone())
    }

    fn remember(&mut self, key: &str, bytes: &[u8]) {
        if bytes.len() > self.ram_limit { return; }
        if let Some(old) = self.ram.remove(key) {
            self.ram_used = self.ram_used.saturating_sub(old.bytes.len());
        }
        self.evict_ram(bytes.len());
        let now = self.tick();
        self.ram_used += bytes.len();
        self.ram.insert(key.into(), RamBlock { bytes: bytes.to_vec(), last: now });
    }

    fn drop_bad_disk(&mut self, name: &str) {
        if let Some(old) = self.disk.remove(name) {
            self.disk_used = self.disk_used.saturating_sub(old.size);
        }
        let _ = fs::remove_file(self.directory.join(name));
    }

    fn load(&mut self, key: &str, expected: usize) -> Option<Vec<u8>> {
        if let Some(value) = self.ram_get(key, expected) { return Some(value); }
        let name = format!("{key}.blk");
        if !self.disk.contains_key(&name) { return None; }
        let bytes = fs::read(self.directory.join(&name)).ok()?;
        if bytes.len() != HEADER + expected || &bytes[..8] != MAGIC ||
           u32::from_le_bytes(bytes[8..12].try_into().ok()?) as usize != expected ||
           u64::from_le_bytes(bytes[12..20].try_into().ok()?) != signature(&bytes[HEADER..]) {
            self.drop_bad_disk(&name);
            eprintln!("[cache] discarded corrupt USB range block {name}");
            return None;
        }
        if let Some(entry) = self.disk.get_mut(&name) { entry.last = modified_stamp(SystemTime::now()); }
        self.remember(key, &bytes[HEADER..]);
        Some(bytes[HEADER..].to_vec())
    }

    fn persist(&mut self, key: &str, bytes: &[u8]) {
        self.remember(key, bytes);
        let name = format!("{key}.blk");
        if self.disk.contains_key(&name) { return; }
        let required = (bytes.len() + HEADER) as u64;
        if required > self.disk_limit { return; }
        self.evict_disk(required);
        if self.disk_used.saturating_add(required) > self.disk_limit { return; }
        let dest = self.directory.join(&name);
        let stamp = self.tick();
        let temporary = self.directory.join(format!("{key}-{stamp}.tmp"));
        let write = (|| -> io::Result<()> {
            let mut f = File::create(&temporary)?;
            f.write_all(MAGIC)?;
            f.write_all(&(bytes.len() as u32).to_le_bytes())?;
            f.write_all(&signature(bytes).to_le_bytes())?;
            f.write_all(bytes)?;
            f.sync_data()?;
            fs::rename(&temporary, &dest)?;
            Ok(())
        })();
        if write.is_err() { let _ = fs::remove_file(&temporary); return; }
        self.disk_used += required;
        self.disk.insert(name, DiskBlock { size: required, last: modified_stamp(SystemTime::now()) });
    }

    /// Cache only complete, checksum-valid blocks. On a prefetch failure, fall
    /// back to the exact requested slice without caching partial data.
    pub fn read_at<F>(&mut self, source: &Path, size: u64, off: u64, dst: &mut [u8], mut fetch: F) -> io::Result<()>
    where F: FnMut(u64, &mut [u8]) -> io::Result<()> {
        if off.checked_add(dst.len() as u64).is_none_or(|end| end > size) {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "range exceeds manifest size"));
        }
        if dst.is_empty() { return Ok(()); }
        let identity = self.file_identity(source, size)?;
        let mut done = 0;
        while done < dst.len() {
            let at = off + done as u64;
            let start = (at / BLOCK) * BLOCK;
            let within = (at - start) as usize;
            let block_len = (size - start).min(BLOCK) as usize;
            let take = (dst.len() - done).min(block_len - within);
            let key = format!("{identity}-{:016x}", start / BLOCK);
            if let Some(block) = self.load(&key, block_len) {
                dst[done..done + take].copy_from_slice(&block[within..within + take]);
            } else {
                let mut block = vec![0u8; block_len];
                match fetch(start, &mut block) {
                    Ok(()) => {
                        dst[done..done + take].copy_from_slice(&block[within..within + take]);
                        self.persist(&key, &block);
                    }
                    Err(prefetch_error) => {
                        // A 256 KiB prefetch may cross an unavailable area.
                        // The game's smaller exact read can still succeed.
                        if let Err(exact_error) = fetch(at, &mut dst[done..done + take]) {
                            eprintln!("[cache] prefetch {start}+{block_len}: {prefetch_error}; exact {at}+{take}: {exact_error}");
                            return Err(exact_error);
                        }
                    }
                }
            }
            done += take;
        }
        Ok(())
    }
}

struct ShaderCache { cache: RangeCache, sizes: HashMap<PathBuf, u64> }
static SHADERS: OnceLock<Mutex<ShaderCache>> = OnceLock::new();

pub fn read_cached_shader(path: &Path) -> io::Result<String> {
    let shared = SHADERS.get_or_init(|| Mutex::new(ShaderCache {
        cache: RangeCache::new("shaders", 8 << 20, 16 << 20),
        sizes: HashMap::new(),
    }));
    let mut guard = shared.lock().unwrap_or_else(|p| p.into_inner());
    let size = match fs::metadata(path) {
        Ok(meta) => {
            let len = meta.len();
            guard.sizes.insert(path.to_path_buf(), len);
            len
        }
        Err(e) => *guard.sizes.get(path).ok_or(e)?,
    };
    if size > 16 << 20 { return fs::read_to_string(path); }
    let mut bytes = vec![0u8; size as usize];
    let mut file: Option<File> = None;
    guard.cache.read_at(path, size, 0, &mut bytes, |at, dst| {
        let mut last = None;
        for delay in [0_u64, 30, 60, 120, 240, 480, 960] {
            if delay != 0 { std::thread::sleep(std::time::Duration::from_millis(delay)); }
            if file.is_none() {
                match File::open(path) {
                    Ok(f) => file = Some(f),
                    Err(e) => { last = Some(e); continue; }
                }
            }
            match file.as_ref().unwrap().read_exact_at(dst, at) {
                Ok(()) => return Ok(()),
                Err(e) => { last = Some(e); file = None; }
            }
        }
        Err(last.unwrap_or_else(|| io::Error::other("USB shader unavailable")))
    })?;
    String::from_utf8(bytes).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!("gtaios-cache-test-{}-{:?}", std::process::id(), std::thread::current().id()));
        fs::create_dir_all(&dir).unwrap();
        let src = dir.join("source.rpf");
        let data: Vec<u8> = (0..700_000).map(|i| (i % 251) as u8).collect();
        fs::write(&src, data).unwrap();
        (dir, src)
    }
    #[test]
    fn persistence_exact_bytes_and_offline_hits() {
        let (dir, src) = fixture();
        let mut cache = RangeCache::with_directory(dir.join("cache"), 512 * 1024, 1024 * 1024);
        let mut buf = vec![0; 19_000];
        cache.read_at(&src, 700_000, 253_000, &mut buf, |off, out| {
            File::open(&src)?.read_exact_at(out, off)
        }).unwrap();
        let expected = fs::read(&src).unwrap();
        assert_eq!(&buf[..], &expected[253_000..272_000]);
        // The same cached blocks must work if the provider read now fails.
        cache.read_at(&src, 700_000, 253_000, &mut buf, |_off, _out| {
            Err(io::Error::other("USB unplugged"))
        }).unwrap();
        let mut other = RangeCache::with_directory(dir.join("cache"), 512 * 1024, 1024 * 1024);
        other.read_at(&src, 700_000, 253_000, &mut buf, |_off, _out| {
            Err(io::Error::other("USB unplugged"))
        }).unwrap();
        assert_eq!(&buf[..], &expected[253_000..272_000]);
        let _ = fs::remove_dir_all(dir);
    }
    #[test]
    fn bounded_eviction_and_uncached_failure() {
        let (dir, src) = fixture();
        let mut cache = RangeCache::with_directory(dir.join("cache"), 256 * 1024, 280 * 1024);
        for at in [0, 262_144, 524_288] {
            cache.read_at(&src, 700_000, at, &mut vec![0; 32], |off, out| {
                File::open(&src)?.read_exact_at(out, off)
            }).unwrap();
        }
        assert!(cache.ram_used <= 256 * 1024);
        assert!(cache.disk_used <= 280 * 1024);
        let mut out = [0_u8; 12];
        let result = cache.read_at(&src, 700_000, 0, &mut out, |_at, _out| Err(io::Error::other("offline")));
        assert!(result.is_err());
        let _ = fs::remove_dir_all(dir);
    }
}
