//! One SO_MEMINFO call gives both charged receive memory and the drop counter.
//! A surviving datagram need not be one of the packets that were dropped. Check
//! buffer continuity independently of its stamp, and time the previous read.
#[derive(Clone, Copy, Default)]
pub(super) struct Prior {
    pub sample_start: u64,
    pub after_sample: u64,
    pub read_done: u64,
    pub recv_us: Option<u64>,
    pub read_cpu: Option<u64>,
    pub memory_pct: Option<u32>,
}
#[derive(Default)]
pub(super) struct LossPhases {
    pub packets: u64,
    pub continuous: u64,
    pub exposed: u64,
    pub unknown: u64,
    pub syscall: u64,
    pub read_work: u64,
    pub between: u64,
    pub short: u64,
    pub mixed: u64,
    pub peak_call: u64,
    pub peak_work: u64,
    pub peak_off: u64,
    pub peak_between: u64,
    pub peak_blind: u64,
    pub high_before: u64,
    pub high_after: u64,
    pub max_before: u32,
    pub max_after: u32,
}
impl LossPhases {
    #[cfg(any(test, feature = "phone-burst-margin"))]
    pub fn fresh_overflow_with_spare(&self) -> bool {
        let n = self.packets;
        n >= 8
            && self.continuous == n
            && self.high_before == n
            && self.high_after == n
            && (self.syscall + self.short) * 4 >= n * 3
    }
    pub fn record(
        &mut self,
        d: u32,
        old: Prior,
        next: u64,
        after: u64,
        lo: u64,
        hi: u64,
        mem: Option<u32>,
    ) {
        if d == 0 {
            return;
        }
        let n = u64::from(d);
        self.packets += n;
        if old.sample_start == 0
            || !(old.sample_start <= old.after_sample
                && old.after_sample <= old.read_done
                && old.read_done <= next
                && next <= after
                && lo <= hi
                && hi <= next)
        {
            self.unknown += n;
            self.mixed += n;
            return;
        }
        // The first block was already held at the earlier counter read. The
        // next block was definitely published by hi. If hi <= read_done, the
        // union covers the two snapshots even if no packet survived that period.
        if hi <= old.read_done {
            self.continuous += n
        } else if lo > old.read_done {
            self.exposed += n
        } else {
            self.unknown += n
        }
        let span = after - old.sample_start;
        let work = old.read_done - old.after_sample;
        let between = next - old.read_done;
        let syscall = old.recv_us.unwrap_or(0).min(work);
        let other_work = work - syscall;
        self.peak_call = self.peak_call.max(syscall);
        self.peak_work = self.peak_work.max(work);
        self.peak_between = self.peak_between.max(between);
        self.peak_blind = self.peak_blind.max(span - work - between);
        if let Some(cpu) = old.read_cpu {
            self.peak_off = self.peak_off.max(work.saturating_sub(cpu + 5));
        }
        if let Some(v) = old.memory_pct {
            self.max_before = self.max_before.max(v);
            if v >= 75 {
                self.high_before += n
            }
        }
        if let Some(v) = mem {
            self.max_after = self.max_after.max(v);
            if v >= 75 {
                self.high_after += n
            }
        }
        // Disjoint buckets accounting for the dominant part of the entire
        // interval, not the instant any specific discarded packet arrived.
        if span < 1000 {
            self.short += n
        } else if span > 2_000_000 {
            self.mixed += n
        } else if old.recv_us.is_some() && syscall * 4 >= span * 3 {
            self.syscall += n
        } else if old.recv_us.is_some() && other_work * 4 >= span * 3 {
            self.read_work += n
        } else if between * 4 >= span * 3 {
            self.between += n
        } else {
            self.mixed += n
        }
    }
    pub fn suffix(&self) -> String {
        format!(" phase_v=1 ph={} bc={} be={} bu={} dc={} dw={} db={} ds={} dx={} mc={} mw={} mo={} mb={} mx={} hb={} ha={} pb={} pa={}",self.packets,self.continuous,self.exposed,self.unknown,self.syscall,self.read_work,self.between,self.short,self.mixed,self.peak_call,self.peak_work,self.peak_off,self.peak_between,self.peak_blind,self.high_before,self.high_after,self.max_before,self.max_after)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn old() -> Prior {
        Prior {
            sample_start: 1000,
            after_sample: 1100,
            read_done: 5500,
            recv_us: Some(4100),
            read_cpu: Some(200),
            memory_pct: Some(80),
        }
    }
    #[test]
    fn two_buffers_cover_entire_counter_interval_including_previous_read() {
        let mut p = LossPhases::default();
        p.record(7, old(), 5900, 6000, 2000, 4700, Some(99));
        assert_eq!(
            (
                p.continuous,
                p.syscall,
                p.peak_off,
                p.high_before,
                p.high_after
            ),
            (7, 7, 4195, 7, 7)
        );
    }
    #[test]
    fn late_recycle_is_only_an_opportunity_not_proof_of_pressure() {
        let mut p = LossPhases::default();
        p.record(2, old(), 30500, 30600, 14000, 15000, None);
        assert_eq!((p.continuous, p.exposed, p.between), (0, 2, 2));
    }
    #[test]
    fn a_fallback_read_does_not_count_as_user_space_work() {
        let mut p = LossPhases::default();
        let o = Prior {
            recv_us: None,
            ..old()
        };
        p.record(4, o, 5900, 6000, 0, 0, None);
        assert_eq!((p.continuous, p.read_work, p.mixed), (4, 0, 4));
    }
    #[test]
    fn no_extra_room_for_unobserved_mixed_low_or_buffer_starved_intervals() {
        let mut p = LossPhases {
            packets: 40,
            continuous: 40,
            high_before: 40,
            high_after: 40,
            short: 12,
            syscall: 18,
            ..LossPhases::default()
        };
        assert!(p.fresh_overflow_with_spare());
        p.high_before = 39;
        assert!(!p.fresh_overflow_with_spare());
        p.high_before = 40;
        p.continuous = 39;
        assert!(!p.fresh_overflow_with_spare());
        p.continuous = 40;
        p.short = 11;
        assert!(!p.fresh_overflow_with_spare());
    }
    #[test]
    fn crossing_uncertainty_and_submillisecond_intervals_are_not_assigned_to_worker() {
        let mut p = LossPhases::default();
        let o = Prior {
            sample_start: 1000,
            after_sample: 1001,
            read_done: 1008,
            ..Prior::default()
        };
        p.record(4, o, 1500, 1502, 1003, 1100, Some(30));
        p.record(3, o, 1500, 1502, 2000, 2500, None);
        assert_eq!((p.unknown, p.short, p.mixed, p.packets), (7, 4, 3, 7));
    }
}
