//! Observation at the owned Sunshine->helper loopback boundary, BEFORE the
//! path ledger, pacer and WireGuard. Only the last ordinal is kept in memory
//! to compute differences. Never log the ordinal, an IV, or the payload.
use std::net::UdpSocket;

// The ordinary helper adjusts one socket once. Per-packet statistics and the
// old-buffer control require the explicit numeric acceptance experiment.
pub(super) fn plan(
    local: bool,
    physical: bool,
    phone: bool,
    sideband: bool,
    wire: Option<u32>,
    managed: bool,
    trial: bool,
    mode: Option<&str>,
) -> Option<(bool, bool)> {
    if !local || !physical || phone || sideband || wire != Some(34_000) || !managed {
        return None;
    }
    let normal = (true, false);
    match mode {
        None => Some(normal),
        Some("auto") if trial => Some((normal.0, true)),
        Some("stock") if trial => Some((false, true)),
        Some("bounded") if trial => Some((true, true)),
        _ => None,
    }
}
#[derive(Default)]
pub(super) struct Observation {
    high: Option<u64>,
    last_frame: u32,
    packets: u64,
    skipped: u64,
    breaks: u64,
    backwards: u64,
    invalid: u64,
    jumps: u64,
}
impl Observation {
    pub(super) fn setup(s: &UdpSocket, tune: bool, log: &impl Fn(String)) -> Self {
        let (before, effective, error) = super::tx_observe_windows::source_buffer(s, tune);
        log(format!(
            "lan_source_rx_setup tuned={} before={before} effective={effective} error={error}",
            u8::from(tune)
        ));
        Self::default()
    }
    pub(super) fn note(&mut self, bytes: &[u8]) -> Option<(u32, u32, u64)> {
        // Pinned Sunshine stream.cpp: counter advances once per encrypted
        // video/FEC shard, including packets lost before recv_from. Observe
        // relative continuity only, never use it for authentication or input.
        if bytes.len() <= 32 || bytes[11] != b'V' {
            self.invalid += 1;
            return None;
        }
        let seq = u64::from_le_bytes(bytes[..8].try_into().unwrap());
        let frame = u32::from_le_bytes(bytes[12..16].try_into().unwrap());
        let mut event = None;
        self.packets += 1;
        if let Some(high) = self.high {
            if seq <= high {
                self.backwards += 1;
                return None;
            }
            let skip = seq - high - 1;
            if skip > 65_536 {
                self.jumps += 1;
            } else if skip > 0 {
                self.skipped += skip;
                self.breaks += 1;
                if self.breaks <= 1024 {
                    event = Some((self.last_frame, frame, skip));
                }
            }
        }
        self.high = Some(seq);
        self.last_frame = frame;
        event
    }
    pub(super) fn report(&self, final_sample: bool, log: &impl Fn(String)) {
        log(format!("lan_source_rx_seq finish={} packets={} holes={} breaks={} backwards={} invalid={} jumps={}",
                    u8::from(final_sample),self.packets,self.skipped,self.breaks,self.backwards,self.invalid,self.jumps));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn packet(seq: u64) -> [u8; 33] {
        let mut p = [0; 33];
        p[11] = b'V';
        p[..8].copy_from_slice(&seq.to_le_bytes());
        p
    }
    #[test]
    fn default_is_scoped_to_managed_physical_standard_lan_without_packet_logging() {
        let choose = |trial, mode| plan(true, true, false, false, Some(34000), true, trial, mode);
        assert_eq!(choose(false, None), Some((true, false)));
        assert_eq!(choose(true, Some("auto")), Some((true, true)));
        assert_eq!(choose(true, Some("stock")), Some((false, true)));
        assert_eq!(choose(false, Some("stock")), None);
        for (local, physical, phone, side, rate, managed) in [
            (false, true, false, false, 34000, true),
            (true, false, false, false, 34000, true),
            (true, true, true, false, 34000, true),
            (true, true, false, true, 34000, true),
            (true, true, false, false, 34100, true),
            (true, true, false, false, 11200, true),
            (true, true, false, false, 34000, false),
        ] {
            assert_eq!(
                plan(
                    local,
                    physical,
                    phone,
                    side,
                    Some(rate),
                    managed,
                    true,
                    Some("auto")
                ),
                None
            );
        }
    }
    #[test]
    fn holes_are_relative_and_disorder_is_flagged() {
        let mut o = Observation::default();
        for seq in [37, 38, 44, 45, 43, 45, 2_000_000] {
            o.note(&packet(seq));
        }
        o.note(&[0; 32]);
        o.note(&[0; 40]);
        assert_eq!(
            (
                o.packets,
                o.skipped,
                o.breaks,
                o.backwards,
                o.jumps,
                o.invalid
            ),
            (7, 5, 1, 2, 1, 2)
        );
    }
    #[test]
    fn only_owned_video_receive_buffer_changes() {
        use super::super::tx_observe_windows::source_buffer;
        let s = UdpSocket::bind("127.0.0.1:0").unwrap();
        s.connect("127.0.0.1:47999").unwrap();
        assert_eq!(source_buffer(&s, true), (0, 0, 1));
        s.connect("127.0.0.1:47998").unwrap();
        let (old, same, err) = source_buffer(&s, false);
        assert!(old > 0 && old == same && err == 0);
        let (before, new, err) = source_buffer(&s, true);
        assert!(before == old && new >= old.max(262144) && err == 0);
    }
}
