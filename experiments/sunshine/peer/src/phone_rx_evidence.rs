//! Aggregate arrival/queue evidence only. No packet data, endpoint, or absolute wall clock is logged.
const HISTORY: usize = 256;
pub(super) struct Evidence {
    arrival: [u64; HISTORY],
    next: usize,
    valid: usize,
    last: u64,
    last_rtc: Option<(u64, u64)>,
    pub packets: u64,
    pub stamps: u64,
    pub calls: u64,
    pub full: u64,
    pub peak_burst: u32,
    pub peak_age: u64,
    pub aged: u64,
    pub bad: u64,
    pub drop_signal: u32,
    prev_drop: Option<u32>,
    pub step_burst: u32,
    pub step_age: u64,
    pub service_wall: u64,
    pub service_cpu: u64,
    pub offcpu: u64,
    pub slow_polls: u64,
    pub poll_over: u64,
    pub probes: u64,
    pub step_last_gap: u64,
    pub awake_gap: u64,
    pub mem_samples: u32,
    pub mem_peak: u32,
    pub mem_percent: u32,
}
impl Evidence {
    pub fn new() -> Self {
        Self {
            arrival: [0; HISTORY],
            next: 0,
            valid: 0,
            last: 0,
            last_rtc: None,
            packets: 0,
            stamps: 0,
            calls: 0,
            full: 0,
            peak_burst: 0,
            peak_age: 0,
            aged: 0,
            bad: 0,
            drop_signal: 0,
            prev_drop: None,
            step_burst: 0,
            step_age: 0,
            service_wall: 0,
            service_cpu: 0,
            offcpu: 0,
            slow_polls: 0,
            poll_over: 0,
            probes: 0,
            step_last_gap: 0,
            awake_gap: 0,
            mem_samples: 0,
            mem_peak: 0,
            mem_percent: 0,
        }
    }
    pub fn clock_ok(&mut self, rtc: u64, mono: u64) -> bool {
        let valid = self
            .last_rtc
            .replace((rtc, mono))
            .is_none_or(|(r, m)| rtc >= r && mono >= m && (rtc - r).abs_diff(mono - m) < 5_000);
        if !valid {
            self.valid = 0;
            self.last = 0;
        }
        valid
    }
    pub fn seed_drop(&mut self, old: Option<u32>) {
        self.prev_drop = old;
    }
    pub fn packet(&mut self, stamp: Option<u64>, now: Option<u64>, drops: Option<u32>, gap: u64) {
        self.packets += 1;
        // A datagram already queued when monitoring was armed can carry an older count than
        // getsockopt reported. Never roll the baseline backwards and count the same loss twice.
        let increase = match (self.prev_drop, drops) {
            (Some(old), Some(new)) if new >= old => {
                self.prev_drop = Some(new);
                new - old
            }
            (None, Some(new)) => {
                self.prev_drop = Some(new);
                0
            }
            _ => 0,
        };
        self.drop_signal = self.drop_signal.saturating_add(increase);
        let Some((s, n)) = stamp
            .zip(now)
            .filter(|&(s, n)| s != 0 && s <= n && n - s <= 2_000_000)
        else {
            self.bad += 1;
            return;
        };
        self.stamps += 1;
        if s < self.last {
            self.valid = 0;
        } // out-of-order stamp: start a new contiguous burst
        self.last = s;
        while self.valid > 0
            && s - self.arrival[(self.next + HISTORY - self.valid) % HISTORY] > 1000
        {
            self.valid -= 1;
        }
        self.arrival[self.next] = s;
        self.next = (self.next + 1) % HISTORY;
        self.valid = (self.valid + 1).min(HISTORY);
        let burst = self.valid as u32;
        let age = n - s;
        self.peak_burst = self.peak_burst.max(burst);
        self.peak_age = self.peak_age.max(age);
        if age >= 5_000 {
            self.aged += 1;
        }
        if increase > 0 {
            self.step_burst = self.step_burst.max(burst);
            self.step_age = self.step_age.max(age);
            self.step_last_gap = self.step_last_gap.max(gap);
        }
    }
    pub fn work(&mut self, wall: u64, cpu: Option<u64>) {
        self.probes += 1;
        self.service_wall = self.service_wall.max(wall);
        if let Some(cpu) = cpu {
            self.service_cpu = self.service_cpu.max(cpu);
            self.offcpu = self.offcpu.max(wall.saturating_sub(cpu));
        }
    }
    pub fn waited(&mut self, us: u64) {
        if us > 3_000 {
            self.slow_polls += 1;
        }
        self.poll_over = self.poll_over.max(us.saturating_sub(1_000));
    }
    pub fn roll(&mut self) -> Self {
        let mut next = Self::new();
        next.arrival = self.arrival;
        next.next = self.next;
        next.valid = self.valid;
        next.last = self.last;
        next.prev_drop = self.prev_drop;
        next.last_rtc = self.last_rtc;
        std::mem::replace(self, next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arrival_burst_and_late_application_reads_are_different() {
        let mut e = Evidence::new();
        e.seed_drop(Some(10));
        for i in 0..24 {
            e.packet(
                Some(1_000_000 + i * 20),
                Some(1_010_000),
                Some(if i == 23 { 17 } else { 10 }),
                12_000,
            );
        }
        assert_eq!(
            (
                e.stamps,
                e.peak_burst,
                e.peak_age,
                e.aged,
                e.drop_signal,
                e.step_burst,
                e.step_last_gap
            ),
            (24, 24, 10_000, 24, 7, 24, 12_000)
        );
        e.roll();
        e.packet(Some(1_001_300), Some(1_001_500), Some(17), 0);
        assert!(e.peak_burst < 24);
        assert_eq!(e.drop_signal, 0);
    }
    #[test]
    fn missing_and_clock_step_never_become_fictitious_queue_delays() {
        let mut e = Evidence::new();
        assert!(e.clock_ok(30_000, 1_000));
        assert!(!e.clock_ok(70_000, 2_000));
        e.packet(Some(90_000), Some(70_000), Some(2), 0);
        e.packet(None, None, None, 0);
        assert_eq!((e.stamps, e.bad, e.peak_age, e.drop_signal), (0, 2, 0, 0));
        e.packet(Some(100_000), Some(100_000), Some(0), 0);
        e.packet(Some(100_100), Some(100_100), Some(2), 0);
        assert_eq!(e.drop_signal, 0);
        e.work(8_000, Some(1_200));
        assert_eq!(e.offcpu, 6_800);
    }
}
