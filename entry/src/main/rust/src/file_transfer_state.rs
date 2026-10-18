use std::time::{Duration, Instant};

pub const TRANSFER_IDLE_TIMEOUT: Duration = Duration::from_secs(60);
pub const UPLOAD_ACK_TIMEOUT: Duration = Duration::from_secs(30);

pub struct TransferWatchdog {
    last_progress: Instant,
    last_report: Instant,
    bytes: u64,
}

impl TransferWatchdog {
    pub fn new(now: Instant) -> Self {
        Self { last_progress: now, last_report: now, bytes: 0 }
    }

    pub fn progress(&mut self, bytes: u64, now: Instant) {
        if bytes != self.bytes {
            self.bytes = bytes;
            self.last_progress = now;
        }
    }

    pub fn restart(&mut self, now: Instant) {
        self.last_progress = now;
        self.last_report = now;
    }

    pub fn idle(&self, now: Instant) -> Duration {
        now.saturating_duration_since(self.last_progress)
    }

    pub fn should_report(&mut self, now: Instant) -> bool {
        if now.saturating_duration_since(self.last_report) < Duration::from_secs(10) {
            return false;
        }
        self.last_report = now;
        true
    }
}

pub struct UploadTransferState {
    pub id: i32,
    pub total: u64,
    pub transferred: u64,
    pub waiting_confirmation: bool,
    pub watchdog: TransferWatchdog,
}

impl UploadTransferState {
    pub fn new(id: i32, total: u64, now: Instant) -> Self {
        Self { id, total, transferred: 0, waiting_confirmation: false,
            watchdog: TransferWatchdog::new(now) }
    }

    pub fn data_sent(&mut self, now: Instant) {
        self.waiting_confirmation = true;
        self.watchdog.restart(now);
    }

    pub fn expired(&self, now: Instant) -> bool {
        self.watchdog.idle(now) >= if self.waiting_confirmation {
            UPLOAD_ACK_TIMEOUT
        } else {
            TRANSFER_IDLE_TIMEOUT
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_timeout_measures_progress_not_unrelated_packets() {
        let now = Instant::now();
        let mut state = UploadTransferState::new(12, 1024, now);
        state.watchdog.progress(512, now + Duration::from_secs(55));
        assert!(!state.expired(now + Duration::from_secs(110)));
        assert!(state.expired(now + Duration::from_secs(115)));
        state.data_sent(now + Duration::from_secs(116));
        assert!(!state.expired(now + Duration::from_secs(145)));
        assert!(state.expired(now + Duration::from_secs(146)));
    }

    #[test]
    fn empty_upload_still_waits_for_peer_ack() {
        let now = Instant::now();
        let mut state = UploadTransferState::new(13, 0, now);
        state.data_sent(now);
        assert!(state.waiting_confirmation);
        assert!(!state.expired(now));
        assert!(state.expired(now + UPLOAD_ACK_TIMEOUT));
    }
}
