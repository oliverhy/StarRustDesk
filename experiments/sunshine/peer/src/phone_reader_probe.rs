// All per-read evidence stays on the *reader thread*. Emit type-checked numeric
// totals once per reporting window, not one log record per packet.
use super::{
    phone_ingress_watch::{split, tick, Stats},
    phone_reader_phase::{LossPhases, Prior},
    phone_rx_socket,
};
use std::{fs::File, net::UdpSocket, os::unix::fs::FileExt};
#[cfg(feature = "phone-reader-qos")]
extern "C" {
    fn sesame_reader_begin_qos(previous: *mut i32) -> i32;
    fn sesame_reader_restore_qos(previous: i32) -> i32;
}
#[cfg(feature = "phone-reader-qos")]
struct Lease {
    status: i32,
    old: i32,
}
#[cfg(feature = "phone-reader-qos")]
impl Lease {
    fn new() -> Self {
        let mut old = -1;
        let status = unsafe { sesame_reader_begin_qos(&mut old) };
        Self { status, old }
    }
}
#[cfg(feature = "phone-reader-qos")]
impl Drop for Lease {
    fn drop(&mut self) {
        if self.status == 1 {
            unsafe { sesame_reader_restore_qos(self.old) };
        }
    }
}
fn cpu() -> Option<u64> {
    let mut t: libc::timespec = unsafe { std::mem::zeroed() };
    (unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut t) } == 0
        && t.tv_sec >= 0
        && (0..1_000_000_000).contains(&t.tv_nsec))
    .then(|| t.tv_sec as u64 * 1_000_000 + t.tv_nsec as u64 / 1000)
}
fn delay(f: &File) -> Option<u64> {
    let mut b = [0; 128];
    let n = f.read_at(&mut b, 0).ok()?;
    let t = std::str::from_utf8(&b[..n]).ok()?;
    let mut fields = t.split_ascii_whitespace();
    fields.next()?.parse::<u64>().ok()?;
    let d = fields.next()?.parse::<u64>().ok()?;
    fields.next()?.parse::<u64>().ok()?;
    if fields.next().is_some() {
        return None;
    }
    Some(d / 1000)
}
pub(super) struct Start {
    now: u64,
    counter: Option<u32>,
    memory: Option<u32>,
    end_sample: u64,
    cpu: Option<u64>,
    rq: Option<(u64, u64, u64)>,
}
pub(super) struct Probe {
    #[cfg(feature = "phone-reader-qos")]
    qos: Lease,
    fd: Option<File>,
    sched_prev: Option<(u64, u64)>,
    sched_when: u64,
    previous: Option<(u64, Option<u32>)>,
    done: u64,
    cpu_done: Option<u64>,
    stats: Stats,
    overhead: u64,
    samples_us: u64,
    prior: Prior,
    phases: LossPhases,
}
impl Probe {
    pub fn new() -> Self {
        Self {
            #[cfg(feature = "phone-reader-qos")]
            qos: Lease::new(),
            fd: File::open("/proc/thread-self/schedstat").ok(),
            sched_prev: None,
            sched_when: 0,
            previous: None,
            done: 0,
            cpu_done: None,
            stats: Stats::default(),
            overhead: 0,
            samples_us: 0,
            prior: Prior::default(),
            phases: LossPhases::default(),
        }
    }
    pub fn begin(&mut self, s: &UdpSocket) -> Start {
        let now = tick();
        let state = phone_rx_socket::usage_and_drops(s);
        let counter = state.map(|v| v.1);
        let memory = state.and_then(|v| v.0);
        let mut rq = None;
        if now.saturating_sub(self.sched_when) >= 4000 {
            self.sched_when = now;
            let r = self.fd.as_ref().and_then(delay);
            if let (Some((start, old)), Some(n)) = (self.sched_prev, r) {
                if let Some(d) = n.checked_sub(old) {
                    rq = Some((start, tick(), d))
                }
            }
            if r.is_none() {
                self.fd = None;
            }
            self.sched_prev = r.map(|d| (now, d));
        }
        let c = cpu();
        let end_sample = tick();
        self.overhead = self.overhead.max(end_sample - now);
        self.samples_us += end_sample - now;
        Start {
            now,
            counter,
            memory,
            end_sample,
            cpu: c,
            rq,
        }
    }
    pub fn finish(&mut self, b: Start, lo: u64, hi: u64, arrival: Option<u64>, call: Option<u64>) {
        let c = b.cpu.zip(self.cpu_done).and_then(|(n, o)| n.checked_sub(o));
        let p = split(self.done, b.now, arrival, lo, hi, c, b.rq);
        let span = self
            .previous
            .map_or(0, |(s, _)| b.end_sample.saturating_sub(s));
        let lost = self
            .previous
            .and_then(|(_, v)| b.counter.zip(v).and_then(|(n, o)| n.checked_sub(o)));
        self.stats.add(
            p,
            arrival.is_some(),
            c.is_some(),
            b.rq.is_some(),
            lost,
            span,
        );
        if let Some(n) = lost {
            self.phases
                .record(n, self.prior, b.now, b.end_sample, lo, hi, b.memory)
        }
        self.previous = Some((b.now, b.counter));
        self.cpu_done = cpu();
        self.done = tick();
        self.prior = Prior {
            sample_start: b.now,
            after_sample: b.end_sample,
            read_done: self.done,
            recv_us: call,
            read_cpu: self.cpu_done.zip(b.cpu).and_then(|(n, o)| n.checked_sub(o)),
            memory_pct: b.memory,
        };
    }
    pub fn roll(&mut self) -> String {
        let s = std::mem::take(&mut self.stats).line(tick() / 1000);
        let s = format!(
            "{s} overhead={} probe_us={}",
            std::mem::take(&mut self.overhead),
            std::mem::take(&mut self.samples_us)
        );
        #[cfg(feature = "phone-reader-qos")]
        let s = format!("{s} reader_qos={}", self.qos.status);
        format!("{s}{}", std::mem::take(&mut self.phases).suffix())
    }
    #[cfg(feature = "phone-burst-margin")]
    pub fn fresh_overflow_with_spare(&self) -> bool {
        self.phases.fresh_overflow_with_spare()
    }
}
