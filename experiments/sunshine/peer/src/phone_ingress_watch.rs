//! A reader-owned observation. All times are monotonic microseconds. No payload,
//! IP, device id, process name or absolute kernel timestamp crosses this boundary.
use std::{sync::OnceLock, time::Instant};
pub(super) fn tick() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    1 + START.get_or_init(Instant::now).elapsed().as_micros() as u64
}
#[derive(Default, Debug, PartialEq)]
pub(super) struct Parts {
    pub pool: u64,
    pub ready: u64,
    pub off: u64,
    pub runq: u64,
}
// The oldest surviving datagram proves data was waiting only AFTER its stamp.
// The FIFO's earliest free block was published between lo and hi. The grey
// time between the two is deliberately credited to neither category.
pub(super) fn split(
    done: u64,
    now: u64,
    arrival: Option<u64>,
    lo: u64,
    hi: u64,
    cpu: Option<u64>,
    rq: Option<(u64, u64, u64)>,
) -> Parts {
    let mut p = Parts::default();
    let Some(a) = arrival else { return p };
    if done == 0 || done > now || lo > hi || now - done > 2_000_000 {
        return p;
    }
    let begin = done.max(a);
    p.pool = lo.min(now).saturating_sub(begin);
    let free = begin.max(hi);
    p.ready = now.saturating_sub(free);
    p.off = cpu.map_or(0, |c| p.ready.saturating_sub(c + 5));
    if let Some((s, e, d)) = rq {
        // schedstat interval is a SUPERSET of the ready and queued interval.
        // All dispatch delay outside that interval must be subtracted.
        if s <= free && e >= now && e >= s && d <= e - s + 5 {
            p.runq = d
                .saturating_sub((e - s).saturating_sub(p.ready) + 5)
                .min(p.ready);
        }
    }
    p
}
#[derive(Default)]
pub(super) struct Stats {
    pub checks: u64,
    pub stamped: u64,
    pub slow: u64,
    pub pool: u64,
    pub ready: u64,
    pub off: u64,
    pub runq: u64,
    pub rqvalid: u64,
    pub cpvalid: u64,
    pub counted: u64,
    pub lost: [u64; 4],
    pub look: u64,
    pub dwpool: u64,
    pub dwready: u64,
    pub dwoff: u64,
    pub dwrq: u64,
    pub maxbracket: u64,
}
impl Stats {
    pub fn add(
        &mut self,
        p: Parts,
        stamp: bool,
        cpu: bool,
        rq: bool,
        drop: Option<u32>,
        span: u64,
    ) {
        self.checks += 1;
        self.stamped += u64::from(stamp);
        self.cpvalid += u64::from(cpu);
        self.rqvalid += u64::from(rq);
        self.pool = self.pool.max(p.pool);
        self.ready = self.ready.max(p.ready);
        self.off = self.off.max(p.off);
        self.runq = self.runq.max(p.runq);
        self.slow += u64::from(p.pool.max(p.ready) >= 2000);
        if let Some(d) = drop {
            self.counted += 1;
            if d == 0 {
                return;
            }
            self.look += 1;
            self.maxbracket = self.maxbracket.max(span);
            self.dwpool = self.dwpool.max(p.pool);
            self.dwready = self.dwready.max(p.ready);
            self.dwoff = self.dwoff.max(p.off);
            self.dwrq = self.dwrq.max(p.runq);
            // These describe a dominant measured interval, not a timestamp on
            // a dropped packet. Short or partly unobserved brackets stay other.
            let k = if !(1000..=2_000_000).contains(&span) {
                3
            } else if p.pool * 4 >= 3 * span {
                0
            } else if p.ready * 4 >= 3 * span {
                1
            } else if p.pool + p.ready >= 1000 && (p.pool + p.ready) * 4 >= 3 * span {
                2
            } else {
                3
            };
            self.lost[k] += u64::from(d);
        }
    }
    pub fn line(&self, t: u64) -> String {
        format!("rx_ledger_dispatch t={t} reads={} stamps={} cp={} rq={} cnt={} slow={} pool={} ready={} off={} runq={} inc={} dp={} dr={} dm={} du={} wp={} wr={} wo={} wq={} span={}",self.checks,self.stamped,self.cpvalid,self.rqvalid,self.counted,self.slow,self.pool,self.ready,self.off,self.runq,self.look,self.lost[0],self.lost[1],self.lost[2],self.lost[3],self.dwpool,self.dwready,self.dwoff,self.dwrq,self.maxbracket)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arriving_while_empty_then_worker_delayed() {
        let v = split(
            100,
            18100,
            Some(5100),
            12100,
            13100,
            Some(495),
            Some((3100, 18200, 12905)),
        );
        assert_eq!(
            v,
            Parts {
                pool: 7000,
                ready: 5000,
                off: 4500,
                runq: 2800
            }
        );
    }
    #[test]
    fn idle_poll_or_missing_stamp_is_not_scheduling() {
        assert_eq!(
            split(100, 16000, Some(16001), 0, 0, None, None),
            Parts::default()
        );
        assert_eq!(split(100, 16000, None, 0, 0, None, None), Parts::default());
    }
    #[test]
    fn no_cpu_or_schedstat_is_never_proof_of_preemption() {
        let p = split(100, 10100, Some(50), 1, 2, None, None);
        assert_eq!(p.ready, 10000);
        assert_eq!((p.off, p.runq), (0, 0));
    }
    #[test]
    fn loss_buckets_partition_and_short_brackets_remain_unattributed() {
        let mut s = Stats::default();
        for (x, y, n) in [
            (8000, 1000, 2),
            (1000, 8000, 3),
            (4000, 4000, 4),
            (500, 300, 6),
        ] {
            s.add(
                Parts {
                    pool: x,
                    ready: y,
                    off: 0,
                    runq: 0,
                },
                true,
                false,
                false,
                Some(n),
                10000,
            )
        }
        assert_eq!(s.lost, [2, 3, 4, 6]);
    }
}
