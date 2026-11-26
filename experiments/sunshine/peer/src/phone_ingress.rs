use super::{phone_rx_batch::Batch, phone_rx_headroom::Pressure, MediaSocket};
use std::{io, net::UdpSocket};

pub(super) enum Reader {
    Inline(Batch),
    #[cfg(feature = "phone-rx-trial")]
    Ahead(ahead::Ahead),
}
impl Reader {
    pub fn new(s: &UdpSocket, drops: Option<u32>, _standard: bool) -> Self {
        #[cfg(feature = "phone-rx-trial")]
        if _standard {
            if let Ok(a) = ahead::Ahead::start(s, drops) {
                return Self::Ahead(a);
            }
        }
        Self::Inline(Batch::new(s, drops))
    }
    pub fn next<'a>(&'a mut self, s: &UdpSocket, buf: &'a mut [u8; 2048],
        #[cfg(feature="phone-rx-trial")] stamp:&mut Option<super::phone_gap_pair::Stamp>) -> io::Result<&'a [u8]> {
        match self {
            Self::Inline(b) => b.next(s, buf),
            #[cfg(feature = "phone-rx-trial")]
            Self::Ahead(a) => a.pool.next_stamped(stamp),
        }
    }
    pub fn wait(&mut self, s: &UdpSocket, p: &[MediaSocket]) -> bool {
        match self {
            Self::Inline(b) => b.wait(s, p),
            #[cfg(feature = "phone-rx-trial")]
            Self::Ahead(a) => {
                a.pool.wait();
                true
            }
        }
    }
    pub fn report(
        &mut self,
        s: &UdpSocket,
        emit: &impl Fn(String),
    ) -> Option<(Pressure, Option<u32>)> {
        match self {
            Self::Inline(b) => Some((b.report(emit), super::phone_rx_socket::drops(s))),
            #[cfg(feature = "phone-rx-trial")]
            Self::Ahead(a) => a.report(emit),
        }
    }
}

#[cfg(feature = "phone-rx-trial")]
mod ahead {
    use super::super::phone_ingress_pool::{Block, Pool, Source, SLOTS};
    use super::*;
    use std::{
        os::fd::AsRawFd,
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc, Mutex,
        },
        time::Instant,
    };
    #[derive(Default)]
    struct Audit {
        request: AtomicBool,
        sample: Mutex<Option<(String, String, Pressure, Option<u32>)>>,
    }
    struct Socket {
        s: UdpSocket,
        batch: Batch,
        audit: Arc<Audit>,
        base_drops: Option<u32>,
        probe:super::super::phone_reader_probe::Probe,
    }
    impl Socket {
        fn receive(&mut self, b: &mut Block) -> io::Result<()> {
            let mut scratch = [0; 2048];
            // One ready syscall's worth, not "wait for 24". Do not pull the next batch
            // while holding these packets or decrypt anything on the ingress thread.
            for i in 0..SLOTS {
                let p = match self.batch.next(&self.s, &mut scratch) {
                    Ok(p) => p,
                    Err(e)
                        if i > 0
                            && matches!(
                                e.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) =>
                    {
                        break
                    }
                    Err(e) => return Err(e),
                };
                if i == 0 {
                    b.at = Instant::now();
                }
                b.bytes[i][..p.len()].copy_from_slice(p);
                b.sizes[i] = p.len() as u16;
                b.stamps[i]=self.batch.last_stamp();
                b.len += 1;
                if self.batch.remaining() == 0 {
                    break;
                }
            }
            Ok(())
        }
    }
    impl Source for Socket {
        fn read(&mut self,b:&mut Block)->io::Result<()>{
            let start=self.probe.begin(&self.s);
            self.batch.oldest_arrival=None;
            self.batch.read_call_us=None;
            let r=self.receive(b);
            self.probe.finish(start,b.free_lo,b.free_hi,self.batch.oldest_arrival,self.batch.read_call_us);
            r
        }
        fn idle(&mut self) {
            let mut p = libc::pollfd {
                fd: self.s.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            unsafe {
                libc::poll(&mut p, 1, 4);
            } // bounded join, readiness wakes immediately
        }
        fn audit(&mut self) {
            if self.audit.request.swap(false, Ordering::AcqRel) {
                let line = std::cell::RefCell::new(String::new());
                let pressure = self.batch.report(&|s| {
                    line.replace(s);
                });
                let drops = super::super::phone_rx_socket::drops(&self.s);
                #[cfg(feature="phone-burst-margin")]
                let pressure={let mut p=pressure;p.with_spare=self.probe.fresh_overflow_with_spare();p};
                if let Ok(mut sample) = self.audit.sample.lock() {
                    let delta = drops
                        .zip(self.base_drops)
                        .and_then(|(b, a)| b.checked_sub(a));
                    let mut row = line.into_inner();
                    use std::fmt::Write;
                    let _ = write!(row, " socket_drops={}", delta.map(i64::from).unwrap_or(-1));
                    *sample = Some((row,self.probe.roll(), pressure, drops));
                }
            }
        }
    }
    pub(in crate::media) struct Ahead {
        pub pool: Pool,
        audit: Arc<Audit>,
    }
    impl Ahead {
        pub fn start(s: &UdpSocket, drops: Option<u32>) -> io::Result<Self> {
            let s = s.try_clone()?;
            let audit = Arc::new(Audit::default());
            let a = audit.clone();
            let pool = Pool::start(move || {
                let batch = Batch::new(&s, drops);
                Socket {
                    s,
                    batch,
                    audit: a,
                    base_drops: drops,
                    probe:super::super::phone_reader_probe::Probe::new(),
                }
            })?;
            Ok(Self { pool, audit })
        }
        pub fn report(&mut self, emit: &impl Fn(String)) -> Option<(Pressure, Option<u32>)> {
            let sample = self.audit.sample.lock().ok().and_then(|mut x| x.take());
            self.audit.request.store(true, Ordering::Release);
            emit(format!(
                "rx_ledger_ahead packets={} blocks={} oldest_us={}",
                self.pool.delivered, self.pool.batches, self.pool.oldest_us
            ));
            self.pool.delivered = 0;
            self.pool.batches = 0;
            self.pool.oldest_us = 0;
            sample.map(|(line, dispatch, p, d)| {
                emit(line);
                emit(dispatch);
                (p, d)
            })
        }
    }
}
