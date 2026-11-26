//! Bounded diagnostic for the encrypted video lane. Not a routing decision.
use std::time::Instant;

#[repr(C)]
pub(crate) struct VideoPathSample {
    pub stage: u32,
    pub ms: u32,
    pub packets: u32,
    pub event_gap: u32,
    pub peak_gap: u32,
    pub previous_frame: u32,
    pub frame: u32,
    pub loop_peak: u32,
}

pub(super) fn encrypted_frame_hint(video: &[u8]) -> Option<u32> {
    // The pinned Moonlight ENC_VIDEO_HEADER is 12-byte IV, LE frame number,
    // 16-byte tag. Use only its frame hint after the fixed video lane match.
    // This value is never used to receive/decrypt or authorize traffic.
    if video.len() <= 32 { return None; }
    Some(u32::from_le_bytes(video[12..16].try_into().ok()?))
}

#[derive(Default)]
pub(super) struct VideoClock {
    last: Option<(Instant, u32)>,
    packets: u32,
    peak: u32,
}

impl VideoClock {
    pub(super) fn record(&mut self, now: Instant, frame: u32) -> Option<(u32, u32)> {
        self.packets = self.packets.saturating_add(1);
        let previous = self.last.replace((now, frame));
        let Some((when, from)) = previous else { return None; };
        let gap = timing_ms(now, when);
        self.peak = self.peak.max(gap);
        if gap >= 140 { Some((gap, from)) } else { None }
    }

    pub(super) fn sample(&self, stage: u32, ms: u32, loop_peak: u32, event: Option<(u32,u32)>)
        -> Option<VideoPathSample> {
        let (_, frame) = self.last?;
        let (event_gap, previous_frame) = event.unwrap_or((0,0));
        Some(VideoPathSample { stage, ms, packets: self.packets, event_gap, peak_gap: self.peak,
            previous_frame, frame, loop_peak })
    }
}

pub(super) fn timing_ms(now: Instant, since: Instant) -> u32 {
    now.saturating_duration_since(since).as_millis().min(u128::from(u32::MAX)) as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    #[test]
    fn large_gap_and_frames_are_reported_without_touching_payload() {
        let t = Instant::now();
        let mut clock = VideoClock::default();
        let mut packet = [0u8;33];
        packet[12..16].copy_from_slice(&42u32.to_le_bytes());
        assert_eq!(encrypted_frame_hint(&packet), Some(42));
        assert!(encrypted_frame_hint(&packet[..32]).is_none());
        assert!(clock.record(t, 21).is_none());
        assert!(clock.record(t+Duration::from_millis(33), 22).is_none());
        let event=clock.record(t+Duration::from_millis(638),42);
        let s=clock.sample(2,638,6,event).unwrap();
        assert_eq!((s.event_gap,s.peak_gap,s.previous_frame,s.frame,s.packets),(605,605,22,42,3));
    }
}
