//! One view-only 20 Mbps LAN experiment, never a global socket setting.
use super::phone_rx_headroom::Pressure;
pub const BASE: u32 = 1 << 20;
pub const LIMIT: u32 = BASE + BASE / 2;
#[derive(Default)]
pub struct Policy {
    tried: bool,
    active: bool,
    stale: u8,
    unknown: u8,
}
#[derive(PartialEq, Debug)]
pub enum Decision {
    Keep,
    Expand,
    Revert,
}
impl Policy {
    // Explicit comparison build only. A real sealed comparison run is required by
    // its builder. Exercise one socket, even on a path that happens not to lose.
    #[cfg(any(test, feature = "phone-margin-comparison"))]
    pub fn offer_comparison(&mut self, standard: bool, bytes: u32, p: Pressure) -> bool {
        if self.tried || self.active || !standard || bytes != BASE || p.packets < 256
            || p.stamped * 10 < p.packets * 9 || p.aged * 4 > p.stamped || p.age_us >= 40_000 {
            return false;
        }
        self.tried = true;
        true
    }
    pub fn active(&self) -> bool {
        self.active
    }
    pub fn readback(&mut self, requested: bool, actual: u32) {
        self.active = requested && actual == LIMIT;
    }
    pub fn step(&mut self, standard: bool, bytes: u32, p: Pressure, burst: bool) -> Decision {
        let reliable = p.packets >= 256 && p.stamped * 10 >= p.packets * 9;
        if self.active {
            self.unknown = if reliable {
                0
            } else {
                self.unknown.saturating_add(1)
            };
            let stale = reliable && p.age_us >= 40_000 && p.aged * 4 > p.stamped;
            self.stale = if stale {
                self.stale.saturating_add(1)
            } else {
                0
            };
            if !standard
                || bytes != LIMIT
                || (reliable && p.age_us >= 80_000)
                || self.stale >= 2
                || self.unknown >= 2
            {
                return Decision::Revert;
            }
        } else if !self.tried
            && standard
            && bytes == BASE
            && reliable
            && burst
            && p.burst >= 16
            && (2_000..=60_000).contains(&p.age_us)
            && p.aged * 4 <= p.stamped
        {
            self.tried = true;
            return Decision::Expand;
        }
        Decision::Keep
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fresh() -> Pressure {
        Pressure {
            packets: 1000,
            stamped: 999,
            aged: 20,
            age_us: 42000,
            burst: 80,
            ..Pressure::default()
        }
    }
    #[test]
    fn exact_target_and_evidence_required() {
        for (s, b, proof) in [
            (false, BASE, true),
            (true, BASE / 2, true),
            (true, LIMIT, true),
            (true, BASE, false),
        ] {
            assert_eq!(Policy::default().step(s, b, fresh(), proof), Decision::Keep);
        }
    }
    #[test]
    fn controlled_comparison_is_one_shot_and_never_opens_an_already_old_queue() {
        let mut p=Policy::default();
        let fresh=Pressure {age_us:18_000,..fresh()};
        assert!(!p.offer_comparison(false,BASE,fresh));
        assert!(!p.offer_comparison(true,BASE/2,fresh));
        assert!(!p.offer_comparison(true,BASE,Pressure{age_us:40_000,..fresh}));
        assert!(!p.offer_comparison(true,BASE,Pressure::default()));
        assert!(p.offer_comparison(true,BASE,fresh));
        p.readback(true,LIMIT);
        assert_eq!(p.step(true,LIMIT,Pressure{age_us:82_000,..fresh},false),Decision::Revert);
        p.readback(false,BASE);
        assert!(!p.offer_comparison(true,BASE,fresh));
    }
    #[test]
    fn refused_request_is_never_retried_and_a_bad_age_is_reverted() {
        let mut p = Policy::default();
        assert_eq!(p.step(true, BASE, fresh(), true), Decision::Expand);
        p.readback(true, BASE);
        assert!(!p.active());
        assert_eq!(p.step(true, BASE, fresh(), true), Decision::Keep);
        let mut p = Policy::default();
        p.step(true, BASE, fresh(), true);
        p.readback(true, LIMIT);
        assert!(p.active());
        assert_eq!(
            p.step(
                true,
                LIMIT,
                Pressure {
                    age_us: 80000,
                    ..fresh()
                },
                false
            ),
            Decision::Revert
        );
        p.readback(false, BASE);
        assert_eq!(p.step(true, BASE, fresh(), true), Decision::Keep);
    }
    #[test]
    fn two_unverifiable_or_persistently_old_windows_revert() {
        for stale in [
            Pressure::default(),
            Pressure {
                aged: 500,
                ..fresh()
            },
        ] {
            let mut p = Policy::default();
            p.step(true, BASE, fresh(), true);
            p.readback(true, LIMIT);
            assert_eq!(p.step(true, LIMIT, stale, false), Decision::Keep);
            assert_eq!(p.step(true, LIMIT, stale, false), Decision::Revert);
        }
    }
}
