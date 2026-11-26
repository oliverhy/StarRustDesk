//! Bounded, FIFO handoff of entire ciphertext datagrams. Exactly one socket reader,
//! one verifier, and a fixed number of reusable blocks. No channel carries keys.
use std::{
    io,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

pub(super) const SLOTS: usize = 24;
const BLOCKS: usize = 8;
pub(super) struct Block {
    slot: usize,
    pub free_lo:u64,
    pub free_hi:u64,
    pub bytes: Box<[[u8; 2048]]>,
    pub sizes: [u16; SLOTS],
    pub stamps: [Option<super::phone_gap_pair::Stamp>; SLOTS],
    pub len: usize,
    pub at: Instant,
}
impl Block {
    fn new(slot:usize) -> Self {
        Self {
            slot,free_lo:0,free_hi:0,
            bytes: vec![[0; 2048]; SLOTS].into_boxed_slice(),
            sizes: [0; SLOTS],
            stamps: [None; SLOTS],
            len: 0,
            at: Instant::now(),
        }
    }
}
pub(super) trait Source {
    fn read(&mut self, block: &mut Block) -> io::Result<()>;
    fn idle(&mut self);
    fn audit(&mut self) {}
}
pub(super) struct Pool {
    ready: Receiver<Block>,
    recycle: SyncSender<Block>,
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
    current: Option<Block>,
    pos: usize,
    published:Arc<[AtomicU64;BLOCKS]>,
    pub delivered: u64,
    pub batches: u64,
    pub oldest_us: u64,
}
impl Pool {
    // Construct the source on its owner thread: its mmsghdr pointers never cross threads.
    pub fn start<S: Source>(make: impl FnOnce() -> S + Send + 'static) -> io::Result<Self> {
        let (tx, ready) = mpsc::sync_channel(BLOCKS);
        let (recycle, spare) = mpsc::sync_channel(BLOCKS);
        let published=Arc::new(std::array::from_fn(|_|AtomicU64::new(0)));
        let marks=published.clone();
        for slot in 0..BLOCKS {
            recycle
                .try_send(Block::new(slot))
                .map_err(|_| io::ErrorKind::InvalidData)?;
        }
        let stop = Arc::new(AtomicBool::new(false));
        let done = stop.clone();
        let join = thread::Builder::new()
            .name("sesame-lan-rx".into())
            .spawn(move || {
                let mut s = make();
                let mut spare_block = None;
                while !done.load(Ordering::Acquire) {
                    s.audit();
                    let mut b = match spare_block.take() {
                        Some(b) => b,
                        None => match spare.recv_timeout(Duration::from_millis(2)) {
                            Ok(mut b) => {
                                let acquired=super::phone_ingress_watch::tick();
                                let published=marks[b.slot].load(Ordering::Acquire);
                                b.free_hi=if b.free_lo==0 {0} else if published>=b.free_lo {published.min(acquired)}else{acquired};
                                b
                            },
                            Err(mpsc::RecvTimeoutError::Timeout) => continue,
                            Err(_) => break,
                        },
                    };
                    b.len = 0;
                    match s.read(&mut b) {
                        Ok(()) if b.len > 0 && b.len <= SLOTS => {
                            // The consumer may hold one block. Hence at most BLOCKS-1 others
                            // can be queued when we own b. Never block joining on a full FIFO.
                            if tx.try_send(b).is_err() {
                                break;
                            }
                        }
                        Err(ref e)
                            if matches!(
                                e.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) =>
                        {
                            spare_block = Some(b);
                            s.idle();
                        }
                        _ => break,
                    }
                }
            })?;
        Ok(Self {
            ready,
            recycle,
            stop,
            join: Some(join),
            current: None,
            pos: 0,
            published,
            delivered: 0,
            batches: 0,
            oldest_us: 0,
        })
    }
    fn acquire(&mut self, wait: bool) -> io::Result<()> {
        if self.current.as_ref().is_some_and(|b| self.pos < b.len) {
            return Ok(());
        }
        if let Some(mut b) = self.current.take() {
            let slot=b.slot;
            self.published[slot].store(0,Ordering::Release);
            b.free_lo=super::phone_ingress_watch::tick();
            if self.recycle.try_send(b).is_ok(){
                self.published[slot].store(super::phone_ingress_watch::tick(),Ordering::Release);
            }
        }
        let block = if wait {
            self.ready
                .recv_timeout(Duration::from_millis(1))
                .map_err(|e| match e {
                    mpsc::RecvTimeoutError::Timeout => io::ErrorKind::WouldBlock,
                    _ => io::ErrorKind::BrokenPipe,
                })?
        } else {
            self.ready.try_recv().map_err(|e| match e {
                mpsc::TryRecvError::Empty => io::ErrorKind::WouldBlock,
                _ => io::ErrorKind::BrokenPipe,
            })?
        };
        self.pos = 0;
        self.batches += 1;
        self.current = Some(block);
        Ok(())
    }
    pub fn next(&mut self) -> io::Result<&[u8]> {
        self.next_stamped(&mut None)
    }
    pub fn next_stamped(&mut self, stamp:&mut Option<super::phone_gap_pair::Stamp>) -> io::Result<&[u8]> {
        *stamp=None;
        self.acquire(false)?;
        let b = self.current.as_ref().unwrap();
        let i = self.pos;
        *stamp=b.stamps[i];
        self.pos += 1;
        self.delivered += 1;
        if self.pos == b.len {
            self.oldest_us = self.oldest_us.max(b.at.elapsed().as_micros() as u64);
        }
        Ok(&b.bytes[i][..usize::from(b.sizes[i])])
    }
    pub fn wait(&mut self) {
        let _ = self.acquire(true);
    }
}
impl Drop for Pool {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Sequence {
        n: u16,
        end: u16,
    }
    impl Source for Sequence {
        fn read(&mut self, b: &mut Block) -> io::Result<()> {
            if self.n == self.end {
                return Err(io::ErrorKind::WouldBlock.into());
            }
            b.at = Instant::now();
            b.len = (usize::from(self.end - self.n)).min(if self.n % 3 == 0 { SLOTS } else { 1 });
            for i in 0..b.len {
                b.bytes[i][..2].copy_from_slice(&self.n.to_be_bytes());
                b.sizes[i] = 2;
                self.n += 1;
            }
            Ok(())
        }
        fn idle(&mut self) {
            thread::sleep(Duration::from_millis(1));
        }
    }
    #[test]
    fn bursts_partials_and_full_backpressure_preserve_every_datagram_in_order() {
        let mut r = Pool::start(|| Sequence { n: 0, end: 2000 }).unwrap();
        thread::sleep(Duration::from_millis(15));
        let end = Instant::now() + Duration::from_secs(3);
        for n in 0..2000u16 {
            loop {
                assert!(Instant::now() < end);
                match r.next() {
                    Ok(x) => {
                        assert_eq!(x, &n.to_be_bytes());
                        break;
                    }
                    Err(e) => {
                        assert_eq!(e.kind(), io::ErrorKind::WouldBlock);
                        r.wait();
                    }
                }
            }
        }
        assert_eq!(r.delivered, 2000);
        assert!(matches!(r.next(),Err(e) if e.kind()==io::ErrorKind::WouldBlock));
    }
    #[test]
    fn one_connected_udp_datagram_does_not_wait_for_a_second_packet_or_a_full_batch() {
        use std::net::UdpSocket;
        struct Socket(UdpSocket);
        impl Source for Socket {
            fn read(&mut self, b: &mut Block) -> io::Result<()> {
                b.sizes[0] = self.0.recv(&mut b.bytes[0])? as u16;
                b.at = Instant::now();
                b.len = 1;
                Ok(())
            }
            fn idle(&mut self) {
                thread::sleep(Duration::from_millis(1));
            }
        }
        let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
        let rx = UdpSocket::bind("127.0.0.1:0").unwrap();
        tx.connect(rx.local_addr().unwrap()).unwrap();
        rx.connect(tx.local_addr().unwrap()).unwrap();
        rx.set_nonblocking(true).unwrap();
        let mut pool = Pool::start(move || Socket(rx)).unwrap();
        for n in [1, 33, 1024, 1500] {
            let bytes = vec![0xa5; n];
            assert_eq!(tx.send(&bytes).unwrap(), n);
            let until = Instant::now() + Duration::from_secs(1);
            loop {
                assert!(Instant::now() < until);
                match pool.next() {
                    Ok(p) => {
                        assert_eq!(p, bytes);
                        break;
                    }
                    Err(e) => {
                        assert_eq!(e.kind(), io::ErrorKind::WouldBlock);
                        pool.wait();
                    }
                }
            }
        }
    }
    #[test]
    fn exit_with_full_empty_or_failed_socket_never_needs_a_consumer() {
        for end in [0, 6000] {
            let r = Pool::start(move || Sequence { n: 0, end }).unwrap();
            thread::sleep(Duration::from_millis(10));
            let t = Instant::now();
            drop(r);
            assert!(t.elapsed() < Duration::from_secs(1));
        }
        struct Failed;
        impl Source for Failed {
            fn read(&mut self, _: &mut Block) -> io::Result<()> {
                Err(io::ErrorKind::ConnectionReset.into())
            }
            fn idle(&mut self) {}
        }
        let mut r = Pool::start(|| Failed).unwrap();
        let end = Instant::now() + Duration::from_secs(1);
        loop {
            assert!(Instant::now() < end);
            match r.next() {
                Err(e) if e.kind() == io::ErrorKind::BrokenPipe => break,
                _ => r.wait(),
            }
        }
    }
}
