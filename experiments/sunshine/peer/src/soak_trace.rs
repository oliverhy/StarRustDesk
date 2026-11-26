//! Opt-in diagnostics for the owned 600-second benchmark only. The asynchronous
//! file contains frame numbers and counters, never media, addresses or keys.
use sha2::{Digest, Sha256};
use std::{
    fs::OpenOptions,
    io::{BufWriter, Write},
    sync::mpsc::{sync_channel, SyncSender},
    thread::{self, JoinHandle},
    time::Instant,
};

type Record = [u8; 25];
// 600 s can exceed 350k packets. Each packet has a source AND a wire row.
const MAX_ROWS: u64 = 1_600_000;
const HIGH_LAN_ROWS: u64 = 4_000_000; // 10 min at 20 Mbps: bounded 100 MB of numeric metadata.

pub(crate) struct TraceSink {
    sender: SyncSender<Record>,
    worker: Option<JoinHandle<()>>,
    salt: [u8; 16],
    start: Instant,
    cached_epoch: Option<([u8; 4], u64)>,
    rows: u64,
    limit: u64,
    missed: u64,
}

impl TraceSink {
    pub fn open(start: Instant) -> Option<Self> {
        let path = std::path::PathBuf::from(std::env::var_os("SESAME_COMPANION_SOAK_TRACE")?);
        let tag = std::env::var("SESAME_COMPANION_SOAK_TAG").ok()?;
        if !path.is_absolute() || path.extension()?.to_str()? != "ssmeta" ||
            tag.len() != 32 || !tag.bytes().all(|b| b.is_ascii_hexdigit()) { return None; }
        let mut salt = [0;16];
        for (i, b) in salt.iter_mut().enumerate() {
            *b = u8::from_str_radix(&tag[2*i..2*i+2],16).ok()?;
        }
        // Do not overwrite any file. The controller selects a unique test path.
        let file = OpenOptions::new().write(true).create_new(true).open(path).ok()?;
        let (sender, receiver) = sync_channel::<Record>(4096);
        let worker = thread::Builder::new().name("companion-soak-trace".into()).spawn(move || {
            let mut stream = BufWriter::with_capacity(64 * 1024, file);
            while let Ok(row) = receiver.recv() {
                if stream.write_all(&row).is_err() { break; }
                if row[0] == 255 {
                    let _ = stream.flush();
                    break;
                }
            }
        }).ok()?;
        let limit=if std::env::var("SESAME_COMPANION_MANAGED_LAN").as_deref()==Ok("1"){HIGH_LAN_ROWS}else{MAX_ROWS};
        Some(Self { sender, worker: Some(worker), salt, start, cached_epoch: None, rows: 0, missed: 0, limit })
    }

    fn record(&mut self, kind: u8, frame: u32, epoch: u64, counter: u64) {
        if self.rows >= self.limit { self.missed += 1; return; }
        self.rows += 1;
        let row = encode(kind,frame,self.start.elapsed().as_millis() as u32,epoch,counter);
        if self.sender.try_send(row).is_err() { self.missed += 1; }
    }

    // Source rows carry an estimated wire cost, not the packet itself.
    pub fn source(&mut self, frame: u32, wire_cost: usize) { self.record(0,frame,wire_cost as u64,0); }

    pub fn wire(&mut self, frame: u32, data: &[u8]) {
        if data.len()<16 || !data.starts_with(&[4,0,0,0]) { return; }
        let index: [u8;4] = data[4..8].try_into().unwrap();
        let epoch = match self.cached_epoch {
            Some((old, tag)) if old == index => tag,
            _ => {
                let mut h=Sha256::new();
                h.update(self.salt);
                h.update(index);
                let tag=u64::from_le_bytes(h.finalize()[..8].try_into().unwrap());
                self.cached_epoch=Some((index,tag));
                tag
            }
        };
        self.record(1,frame,epoch,u64::from_le_bytes(data[8..16].try_into().unwrap()));
    }
}

fn encode(kind:u8,frame:u32,ms:u32,epoch:u64,counter:u64) -> Record {
    let mut row=[0;25];
    row[0]=kind;
    row[1..5].copy_from_slice(&frame.to_le_bytes());
    row[5..9].copy_from_slice(&ms.to_le_bytes());
    row[9..17].copy_from_slice(&epoch.to_le_bytes());
    row[17..25].copy_from_slice(&counter.to_le_bytes());
    row
}

impl Drop for TraceSink {
    fn drop(&mut self) {
        // Commit the completeness marker only after the media loop has stopped.
        let _ = self.sender.send(encode(255,0,0,self.rows,self.missed));
        if let Some(worker)=self.worker.take() { let _ = worker.join(); }
    }
}
