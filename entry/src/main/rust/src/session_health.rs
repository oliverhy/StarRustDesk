use std::sync::Mutex;
use std::time::{Duration, Instant};

pub type DisplayInfo = (i32, i32, i32, i32, bool);

pub fn display_rect(current: &Mutex<i32>, displays: &Mutex<Vec<DisplayInfo>>) -> Option<(i32, i32, i32, i32)> {
    // These are short state-copy locks, never held across FFI/network/decoder
    // calls. Contention is not evidence of a new 1920x1080 display.
    let index = (*current.lock().ok()?).max(0) as usize;
    let guard = displays.lock().ok()?;
    guard.get(index).filter(|d| d.2 > 0 && d.3 > 0).map(|d| (d.0, d.1, d.2, d.3))
}

pub struct PeerHealth {
    last_packet: Instant,
    last_tick: Instant,
    lifecycle_epoch: u64,
}

impl PeerHealth {
    pub fn new(now: Instant, lifecycle_epoch: u64) -> Self {
        Self { last_packet: now, last_tick: now, lifecycle_epoch }
    }
    pub fn received(&mut self, now: Instant) { self.last_packet = now; }

    pub fn timed_out(&mut self, now: Instant, lifecycle_epoch: u64, background: bool,
                     heartbeat_observed: bool) -> bool {
        // Give a suspended process / foreground transition a fresh grace period.
        if now.duration_since(self.last_tick) > Duration::from_secs(10) ||
            lifecycle_epoch != self.lifecycle_epoch || background {
            self.last_packet = now;
        }
        self.last_tick = now;
        self.lifecycle_epoch = lifecycle_epoch;
        // Do not use video FPS as a liveness signal: a static desktop can send
        // no frames. Only enforce the deadline for peers with proven heartbeat support.
        heartbeat_observed && !background &&
            now.duration_since(self.last_packet) >= Duration::from_secs(45)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, mpsc};
    use std::thread;

    #[test]
    fn contended_display_keeps_real_resolution() {
        let current = Arc::new(Mutex::new(1));
        let displays = Arc::new(Mutex::new(vec![(0,0,800,600,false), (800,0,1920,1200,false)]));
        let guard = displays.lock().unwrap();
        let (tx, rx) = mpsc::channel();
        let (c, d) = (current.clone(), displays.clone());
        let worker = thread::spawn(move || tx.send(display_rect(&c, &d)).unwrap());
        assert!(rx.recv_timeout(Duration::from_millis(30)).is_err());
        drop(guard);
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), Some((800,0,1920,1200)));
        worker.join().unwrap();
        *current.lock().unwrap() = 3;
        assert_eq!(display_rect(&current, &displays), None);
    }

    #[test]
    fn heartbeat_not_fps_controls_timeout() {
        let start = Instant::now();
        let mut health = PeerHealth::new(start, 0);
        for second in 1..120 {
            let now = start + Duration::from_secs(second);
            if second % 5 == 0 { health.received(now); }
            assert!(!health.timed_out(now, 0, false, true));
        }
        for second in 120..159 {
            assert!(!health.timed_out(start + Duration::from_secs(second), 0, false, true));
        }
        assert!(health.timed_out(start + Duration::from_secs(160), 0, false, true));
    }

    #[test]
    fn suspended_background_legacy_peers_have_grace() {
        let start = Instant::now();
        let mut health = PeerHealth::new(start, 0);
        for second in 1..90 {
            assert!(!health.timed_out(start + Duration::from_secs(second), 0, false, false));
        }
        assert!(!health.timed_out(start + Duration::from_secs(91), 0, true, true));
        assert!(!health.timed_out(start + Duration::from_secs(300), 0, false, true));
        assert!(!health.timed_out(start + Duration::from_secs(301), 1, false, true));
    }
}
