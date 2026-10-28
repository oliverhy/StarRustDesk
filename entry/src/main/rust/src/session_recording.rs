//! Video-only WebM recording of received VP9/VP8 packets. No screen capture,
//! microphone or credentials. Disk I/O never runs on the receive/decode thread.
use std::{fs::OpenOptions, io::{Write, BufWriter}, sync::{Mutex, atomic::{AtomicI32, Ordering}, mpsc::{sync_channel, SyncSender}}, thread::{self, JoinHandle}, time::Instant};
struct Packet { data: Vec<u8>, key: bool, width: i32, height: i32, codec: u8, ms: u64 }
struct Recording { sender: SyncSender<Packet>, worker: JoinHandle<()>, started: Instant }
static RECORDING: Mutex<Option<Recording>> = Mutex::new(None);
static STATUS: AtomicI32 = AtomicI32::new(0);

fn element(id: &[u8], data: &[u8]) -> Vec<u8> {
    let mut n = 1;
    while data.len() as u64 >= (1u64 << (7 * n)) - 1 { n += 1; }
    let encoded = (data.len() as u64) | (1u64 << (7 * n));
    let mut out = id.to_vec(); out.extend_from_slice(&encoded.to_be_bytes()[8-n..]); out.extend_from_slice(data); out
}
fn uint(id: &[u8], value: u64) -> Vec<u8> {
    let b = value.to_be_bytes(); let first = b.iter().position(|v| *v != 0).unwrap_or(7); element(id, &b[first..])
}
fn header(codec: u8, width: i32, height: i32) -> Vec<u8> {
    let ebml = [uint(&[0x42,0x86], 1), uint(&[0x42,0xF7], 1), uint(&[0x42,0xF2], 4), uint(&[0x42,0xF3], 8),
        element(&[0x42,0x82], b"webm"), uint(&[0x42,0x87], 4), uint(&[0x42,0x85], 2)].concat();
    let info = [uint(&[0x2A,0xD7,0xB1], 1_000_000), element(&[0x4D,0x80], "芝麻远控".as_bytes()), element(&[0x57,0x41], "芝麻远控".as_bytes())].concat();
    let video = [uint(&[0xB0], width as u64), uint(&[0xBA], height as u64)].concat();
    let track = [uint(&[0xD7], 1), uint(&[0x73,0xC5], 1), uint(&[0x83], 1), uint(&[0x9C], 0),
        element(&[0x86], if codec == b'V' { b"V_VP9" } else { b"V_VP8" }), element(&[0xE0], &video)].concat();
    [element(&[0x1A,0x45,0xDF,0xA3], &ebml), vec![0x18,0x53,0x80,0x67,0x01,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF],
        element(&[0x15,0x49,0xA9,0x66], &info), element(&[0x16,0x54,0xAE,0x6B], &element(&[0xAE], &track))].concat()
}
pub fn start(path: &str) -> i32 {
    let Ok(mut guard) = RECORDING.lock() else { return -1; };
    if guard.is_some() { return -2; }
    let Ok(file) = OpenOptions::new().write(true).create_new(true).open(path) else { return -3; };
    let (sender, receiver) = sync_channel::<Packet>(16);
    STATUS.store(1, Ordering::SeqCst);
    let worker = thread::spawn(move || {
        let mut out = BufWriter::new(file); let mut format: Option<(u8,i32,i32)> = None;
        let mut first_ms = 0; let mut last_ms = 0; let mut total = 0u64;
        for p in receiver {
            if STATUS.load(Ordering::SeqCst) < 0 { break; }
            if format.is_none() {
                if !p.key { continue; }
                if out.write_all(&header(p.codec, p.width, p.height)).is_err() { STATUS.store(-1, Ordering::SeqCst); break; }
                format = Some((p.codec, p.width, p.height)); first_ms = p.ms;
                if STATUS.compare_exchange(1, 2, Ordering::SeqCst, Ordering::SeqCst).is_err() { break; }
            }
            if format != Some((p.codec,p.width,p.height)) { STATUS.store(-2, Ordering::SeqCst); break; }
            let ms = p.ms.saturating_sub(first_ms).max(last_ms); last_ms = ms;
            let mut block = vec![0x81,0,0,if p.key {0x80} else {0}]; block.extend_from_slice(&p.data);
            let cluster = [uint(&[0xE7], ms), element(&[0xA3], &block)].concat();
            if out.write_all(&element(&[0x1F,0x43,0xB6,0x75], &cluster)).is_err() { STATUS.store(-1, Ordering::SeqCst); break; }
            total += p.data.len() as u64;
            if total > 4 * 1024 * 1024 * 1024 { STATUS.store(-3, Ordering::SeqCst); break; }
        }
        if out.flush().is_err() { STATUS.store(-1, Ordering::SeqCst); }
    });
    *guard = Some(Recording { sender, worker, started: Instant::now() }); 0
}
pub fn frame(data: &[u8], codec: u8, key: bool, width: i32, height: i32) {
    if STATUS.load(Ordering::Relaxed) <= 0 { return; }
    // This lock only protects the queue handle; disk writes and join run outside it.
    // Do not silently discard a predictive frame when status() briefly owns it.
    let Ok(guard) = RECORDING.lock() else { STATUS.store(-1, Ordering::SeqCst); return; };
    let Some(rec) = guard.as_ref() else { return; };
    if codec != b'V' && codec != b'8' {
        if rec.started.elapsed().as_secs() > 10 { STATUS.store(-4, Ordering::SeqCst); }
        return;
    }
    if data.len() > 2 * 1024 * 1024 || width <= 0 || height <= 0 { STATUS.store(-1, Ordering::SeqCst); return; }
    if rec.sender.try_send(Packet { data: data.to_vec(), key, width, height, codec, ms: rec.started.elapsed().as_millis() as u64 }).is_err() {
        // Never drop predicted frames and pretend the output is intact.
        STATUS.store(-1, Ordering::SeqCst);
    }
}
pub fn status() -> i32 {
    if STATUS.load(Ordering::SeqCst) == 1 {
        if let Ok(guard) = RECORDING.try_lock() {
            if guard.as_ref().is_some_and(|r| r.started.elapsed().as_secs() >= 15) {
                let _ = STATUS.compare_exchange(1, -4, Ordering::SeqCst, Ordering::SeqCst);
            }
        }
    }
    STATUS.load(Ordering::SeqCst)
}
pub fn stop() -> i32 {
    let recording = RECORDING.lock().ok().and_then(|mut r| r.take());
    if let Some(rec) = recording { drop(rec.sender); let _ = rec.worker.join(); }
    STATUS.swap(0, Ordering::SeqCst)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn ebml_size_and_header() {
        assert_eq!(element(&[0x80], &[1,2]), vec![0x80,0x82,1,2]);
        assert_eq!(&element(&[0x80], &[0;127])[..3], &[0x80,0x40,0x7F]);
        let h = header(b'V', 1920, 1080);
        assert!(h.windows(5).any(|v| v == b"V_VP9"));
        assert_eq!(&h[..4], &[0x1A,0x45,0xDF,0xA3]);
    }
    #[test] fn real_vp9_webm_can_be_decoded_when_ffmpeg_is_available() {
        use std::{process::Command, fs};
        if Command::new("ffmpeg").arg("-version").output().is_err() { return; }
        let stem = format!("starrustdesk-recording-test-{}", std::process::id());
        let ivf = std::env::temp_dir().join(format!("{stem}.ivf"));
        let webm = std::env::temp_dir().join(format!("{stem}.webm"));
        let output = Command::new("ffmpeg").args(["-v","error","-y","-f","lavfi","-i",
            "testsrc=size=64x48:rate=5","-t","1","-c:v","libvpx-vp9","-f","ivf"])
            .arg(&ivf).output().unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let input = fs::read(&ivf).unwrap();
        let _ = fs::remove_file(&webm);
        assert_eq!(start(webm.to_str().unwrap()), 0);
        let mut at = 32usize; let mut index = 0;
        while at + 12 <= input.len() {
            let size = u32::from_le_bytes(input[at..at+4].try_into().unwrap()) as usize;
            at += 12;
            let guard = RECORDING.lock().unwrap(); let r = guard.as_ref().unwrap();
            r.sender.send(Packet { data: input[at..at+size].to_vec(), key:index==0,
                width:64,height:48,codec:b'V',ms:index*200 }).unwrap();
            at += size; index += 1;
        }
        assert_eq!(stop(), 2);
        let output = Command::new("ffmpeg").args(["-v","error","-i"]).arg(&webm)
            .args(["-f","null","-"]).output().unwrap();
        assert!(output.status.success() && output.stderr.is_empty(), "{}", String::from_utf8_lossy(&output.stderr));
        assert_eq!(index, 5);
        fs::remove_file(ivf).unwrap(); fs::remove_file(webm).unwrap();
    }
}
