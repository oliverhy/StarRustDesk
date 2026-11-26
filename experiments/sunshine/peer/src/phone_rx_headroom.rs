//! A single bounded response to measured short bursts, not a general buffer tuning knob.
// Only call after peer authentication and encrypted bandwidth-probe parsing.
// The standard 20-Mbit LAN grant includes FEC/tunnel overhead. This is an offer,
// not a measurement of either available bandwidth or delivered picture bytes.
pub(super) fn standard_lan_offer(local: bool, cap: u32) -> bool {
    local && cap == 34_000
}
#[derive(Default)]
pub(super) struct Admission {
    pub cause: u8, // 0: not armed, 1: observed >=16 Mbps, 2: negotiated standard LAN
    pub high_rate_seen: bool,
}
impl Admission {
    pub fn offer(&mut self, standard: bool) -> bool {
        if standard && self.cause == 0 { self.cause = 2; true } else { false }
    }
    pub fn observe(&mut self, bytes: u64, ms: u64) -> bool {
        if ms < 500 || bytes.saturating_mul(8) < 16_000u64.saturating_mul(ms) { return false; }
        self.high_rate_seen = true;
        if self.cause == 0 { self.cause = 1; true } else { false }
    }
}
#[derive(Clone, Copy, Default)]
pub(super) struct Pressure {
    #[cfg(feature="phone-burst-margin")]
    pub with_spare:bool,
    pub packets: u64,
    pub stamped: u64,
    pub aged: u64,
    pub burst: u32,
    pub age_us: u64,
}
#[derive(Debug, PartialEq)]
pub(super) enum Action {
    Hold,
    Grow,
    Restore,
}
#[derive(Default)]
pub(super) struct Policy {
    last: Option<u32>,
    expanded: bool,
    finished: bool,
    chronic: u8,
}
impl Policy {
    pub fn seed(&mut self, current: Option<u32>) {
        self.last = current;
    }
    #[cfg(any(test,feature="phone-rx-trial"))]
    pub fn preopened(&mut self, base:u32, actual:u32) {
        // Same existing ceiling; continue to watch packet age and revert to the
        // original base if the extra room becomes chronic latency. No sysctl.
        self.expanded=actual>base;
    }
    pub fn step(&mut self, current: Option<u32>, p: Pressure) -> Action {
        if self.finished {
            return Action::Hold;
        }
        let Some(d) = current else {
            self.chronic = 0;
            return Action::Hold;
        };
        let Some(old) = self.last.replace(d) else {
            return Action::Hold;
        };
        if d < old {
            self.chronic = 0;
            return Action::Hold;
        }
        if p.packets < 256 || p.stamped * 10 < p.packets * 9 {
            self.chronic = 0;
            return Action::Hold;
        } // insufficient evidence
        if self.expanded {
            // Persistent stale backlog matters more than a lower loss counter.
            let chronic = p.aged * 2 > p.stamped || (p.aged * 4 > p.stamped && p.age_us > 80_000);
            self.chronic = if chronic {
                self.chronic.saturating_add(1)
            } else {
                0
            };
            if self.chronic >= 3 {
                self.finished = true;
                return Action::Restore;
            }
        } else if d - old >= 8
            && p.burst >= 16
            && (2_000..=100_000).contains(&p.age_us)
            && p.aged * 4 <= p.stamped
        {
            // Most datagrams are fresh; a dense short burst actually overflowed this socket.
            self.expanded = true;
            return Action::Grow;
        }
        Action::Hold
    }
    pub fn refused(&mut self) {
        self.finished = true;
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn low_mean_standard_lan_is_armed_before_media_without_claiming_actual_throughput() {
        assert!(standard_lan_offer(true, 34_000));
        for cap in [0, 1_800, 8_000, 25_000, 30_000, 33_999, 34_001, 72_000] {
            assert!(!standard_lan_offer(true, cap));
        }
        assert!(!standard_lan_offer(false, 34_000));
        let mut a = Admission::default();
        assert!(a.offer(true));
        assert!(!a.observe(1_000_000, 2000) && !a.high_rate_seen);
        assert!(!a.observe(4_000_000, 2000) && a.high_rate_seen && a.cause == 2);
        assert!(!a.offer(true)); // no second baseline or loss-counter reset
    }
    #[test]
    fn other_high_lan_offers_keep_the_measured_threshold_once() {
        let mut a = Admission::default();
        assert!(!a.offer(false));
        assert!(!a.observe(1_000_000, 499));
        assert!(!a.observe(3_999_999, 2000) && !a.high_rate_seen && a.cause == 0);
        assert!(a.observe(4_000_000, 2000) && a.high_rate_seen && a.cause == 1);
        assert!(!a.observe(5_000_000, 2000));
    }
    fn rush() -> Pressure {
        Pressure {
            packets: 4000,
            stamped: 4000,
            aged: 100,
            burst: 33,
            age_us: 30_000,
            #[cfg(feature="phone-burst-margin")]
            with_spare:false,
        }
    }
    #[test]
    fn only_this_sockets_new_loss_and_a_short_measured_burst_allow_growth() {
        let mut p = Policy::default();
        p.seed(Some(200));
        assert_eq!(p.step(Some(200), rush()), Action::Hold);
        assert_eq!(
            p.step(
                Some(240),
                Pressure {
                    stamped: 0,
                    ..rush()
                }
            ),
            Action::Hold
        );
        assert_eq!(
            p.step(Some(260), Pressure { burst: 2, ..rush() }),
            Action::Hold
        );
        assert_eq!(
            p.step(
                Some(300),
                Pressure {
                    aged: 3000,
                    ..rush()
                }
            ),
            Action::Hold
        );
        assert_eq!(p.step(Some(350), rush()), Action::Grow);
        assert_eq!(p.step(Some(400), rush()), Action::Hold);
    }
    #[test]
    fn chronic_backlog_reverts_once_not_on_one_spike() {
        let mut p = Policy::default();
        p.seed(Some(0));
        assert_eq!(p.step(Some(10), rush()), Action::Grow);
        let stale = Pressure {
            aged: 3000,
            ..rush()
        };
        assert_eq!(p.step(Some(12), stale), Action::Hold);
        assert_eq!(p.step(Some(13), rush()), Action::Hold);
        for _ in 0..2 {
            assert_eq!(p.step(Some(13), stale), Action::Hold);
        }
        assert_eq!(p.step(Some(13), stale), Action::Restore);
        assert_eq!(p.step(Some(80), rush()), Action::Hold);
    }
    #[test]
    fn preopened_standard_socket_rolls_back_but_a_refused_offer_does_not_fake_growth() {
        let mut p=Policy::default();p.seed(Some(0));p.preopened(524288,1048576);
        let stale=Pressure{aged:3000,..rush()};
        assert_eq!(p.step(Some(60),rush()),Action::Hold);
        for _ in 0..2 {assert_eq!(p.step(Some(60),stale),Action::Hold);}
        assert_eq!(p.step(Some(60),stale),Action::Restore);
        let mut clamped=Policy::default();clamped.seed(Some(0));clamped.preopened(524288,524288);
        assert_eq!(clamped.step(Some(12),rush()),Action::Grow);
    }
}
