//! Small, bounded sender queue for the bandwidth-limited WAN fixture.
use std::collections::VecDeque;
use std::time::{Duration, Instant};

const BURST_BYTES: usize = 2 * wire_bytes(1220);
const MAX_AGE: Duration = Duration::from_millis(125);
const CONTROL_PACKETS: usize = 12;
const ABANDONED_FRAMES: usize = 32;
const UNIT: u64 = 1_000_000;
const RETRY_MIN: Duration = Duration::from_millis(2);
const RETRY_MAX: Duration = Duration::from_millis(16);
const LONG_SEND_BLOCK: Duration = Duration::from_millis(150);
const RECOVERY_VIDEO_AGE: Duration = Duration::from_millis(36);
const AUDIO_PORT: usize = 2; // SERVICE[2], Sunshine -> client audio
const CONTROL_PORT: usize = 1;
const SETUP_STREAM: usize = super::SERVICE.len(); // companion TCP sideband, after the UDP services
const RECOVERY_AUDIO_AGE: Duration = Duration::from_millis(24);

// Outer IPv4 + UDP, WireGuard data header/tag, and padded inner IPv4 + UDP.
pub(super) const fn wire_bytes(payload: usize) -> usize {
    28 + 32 + ((28 + payload + 15) & !15)
}

pub(super) struct Packet {
    pub port: usize,
    pub payload: Box<[u8]>,
    pub encrypted: Option<Box<[u8]>>,
    at: Instant,
    frame: Option<u32>,
}

#[cfg(any(test,all(windows,feature="companion-soak")))]
#[derive(Default)]
struct CompactHead { started: Option<u32>, saves: u64 }

pub(super) struct Pacer {
    video: VecDeque<Packet>,
    abandoned: VecDeque<(u32, Instant)>,
    control: VecDeque<Packet>,
    video_bytes: usize,
    max_video_bytes: usize,
    burst_bytes: u64,
    credit: u64,
    bytes_per_second: u64,
    updated: Instant,
    busy_since: Option<Instant>,
    retry_at: Instant,
    socket_gate_until: Option<Instant>,
    retry_interval: Duration,
    dispatch_at: Option<Instant>,
    standard_quantum: bool,
    video_at: Option<Instant>,
    relay_spacing: bool,
    frame_spread: bool,
    spread_budget: Duration,
    spread_frame: Option<u32>,
    retries: u64,
    recoveries: u64,
    peak_busy_ms: u128,
    fresh_recovery: bool,
    recovery_video_drops: u64,
    recovery_audio_drops: u64,
    recovery_control_admissions: u64,
    pub full: u64,
    pub stale: u64,
    pub abandoned_frames: u64,
    pub abandoned_tail: u64,
    pub max_delay_ms: u128,
    #[cfg(any(test,all(windows,feature="companion-soak")))]
    compact_head: Option<CompactHead>,
}

impl Pacer {
    pub fn new(kbps: u32, now: Instant) -> Self {
        let bytes_per_second = u64::from(kbps) * 125;
        // WAN retains its two-datagram limit. A faster, separate LAN test
        // permits a bounded 8 ms budget per send wake-up, never unlimited
        // catch-up credit after a scheduling pause.
        #[cfg(feature = "lan-bench")]
        let burst_bytes = (bytes_per_second * 8 / 1000).clamp(BURST_BYTES as u64, 32 * 1024);
        #[cfg(not(feature = "lan-bench"))]
        let burst_bytes = BURST_BYTES as u64;
        Self {
            video: VecDeque::new(),
            abandoned: VecDeque::new(),
            control: VecDeque::new(),
            video_bytes: 0,
            max_video_bytes: (bytes_per_second as usize * MAX_AGE.as_millis() as usize) / 1000,
            burst_bytes,
            credit: burst_bytes * UNIT,
            bytes_per_second,
            updated: now,
            busy_since: None,
            retry_at: now,
            socket_gate_until: None,
            retry_interval: RETRY_MIN,
            dispatch_at: None,
            standard_quantum: false,
            video_at: None,
            relay_spacing: false,
            frame_spread: false,
            spread_budget: Duration::from_millis(27),
            spread_frame: None,
            retries: 0,
            recoveries: 0,
            peak_busy_ms: 0,
            fresh_recovery: false,
            recovery_video_drops: 0,
            recovery_audio_drops: 0,
            recovery_control_admissions: 0,
            full: 0,
            stale: 0,
            abandoned_frames: 0,
            abandoned_tail: 0,
            max_delay_ms: 0,
            #[cfg(any(test,all(windows,feature="companion-soak")))]
            compact_head: None,
        }
    }

    pub fn push(&mut self, port: usize, payload: &[u8], now: Instant) {
        self.push_packet(port, payload, now, None);
    }

    pub fn push_video(&mut self, payload: &[u8], now: Instant, frame: Option<u32>) {
        self.push_packet(0, payload, now, frame);
    }

    fn push_packet(&mut self, port: usize, payload: &[u8], now: Instant, frame: Option<u32>) {
        // Never earn dispatch slots while the stream has nothing to send.
        if self.standard_quantum && self.video.is_empty() && self.control.is_empty() {
            if let Some(due)=self.dispatch_at { self.dispatch_at=Some(due.max(now)); }
        }
        if self.video.front().is_some_and(|p| now.duration_since(p.at) >= MAX_AGE)
            || self.control.front().is_some_and(|p| now.duration_since(p.at) >= MAX_AGE)
        {
            self.expire(now);
        }
        let cost = wire_bytes(payload.len());
        let mut at = now;
        if port == 0 {
            self.forget_abandoned(now);
            if frame.is_some_and(|id| self.abandoned.iter().any(|&(n, _)| n == id)) {
                self.abandoned_tail += 1;
                return;
            }
            // Keep the deadline of the first queued fragment. When the queue
            // cannot hold both frames, discard the oldest frame as a unit,
            // rather than scatter losses across each newly admitted frame.
            while self.video_bytes + cost > self.max_video_bytes {
                let Some(id) = self.video.front().and_then(|p| p.frame) else {
                    self.full += 1;
                    return;
                };
                #[cfg(any(test,all(windows,feature="companion-soak")))]
                if let Some(incoming)=frame.filter(|&f| f!=id && self.can_finish_started(id,now)) {
                    // Drop the successor as a unit, including any fragments
                    // already queued. Do not extend the head's original deadline.
                    self.full+=self.abandon_frame(incoming,now);
                    self.abandoned_tail+=1;
                    if let Some(g)=self.compact_head.as_mut(){g.saves+=1;}
                    return;
                }
                self.full += self.abandon_frame(id, now);
                if frame == Some(id) {
                    self.abandoned_tail += 1;
                    return;
                }
            }
            if let Some(id) = frame {
                if let Some(old) = self.video.iter().find(|p| p.frame == Some(id)) { at = old.at; }
            }
            self.video_bytes += cost;
        } else {
            self.trim_blocked_audio(now);
            if self.control.len() >= CONTROL_PACKETS {
                // Audio and reliable control share a bounded queue. A real
                // socket refusal must not let a queue of audio reject a new
                // control or setup message. Do not reorder surviving control.
                let replace = self.frame_spread && self.fresh_recovery && self.busy_since.is_some()
                    && matches!(port, CONTROL_PORT | SETUP_STREAM);
                if let Some(index) = replace.then(|| self.control.iter().position(|p|p.port==AUDIO_PORT)).flatten() {
                    self.control.remove(index);
                    self.recovery_audio_drops += 1;
                    self.recovery_control_admissions += 1;
                } else {
                    self.full += 1;
                    return;
                }
            }
        }
        let queue = if port == 0 { &mut self.video } else { &mut self.control };
        queue.push_back(Packet { port, payload: payload.into(), encrypted: None, at, frame });
    }

    #[cfg(all(windows, feature = "long-bench"))]
    pub fn set_trial_budget(&mut self, kbps: u32, now: Instant) {
        self.bytes_per_second = u64::from(kbps) * 125;
        self.max_video_bytes = (self.bytes_per_second as usize * MAX_AGE.as_millis() as usize) / 1000;
        self.burst_bytes = (self.bytes_per_second * 8 / 1000).clamp(BURST_BYTES as u64, 32 * 1024);
        self.credit = self.credit.min(self.burst_bytes * UNIT);
        self.updated = now;
    }

    fn forget_abandoned(&mut self, now: Instant) {
        while self.abandoned.front().is_some_and(|&(_, at)| now.duration_since(at) >= MAX_AGE) {
            self.abandoned.pop_front();
        }
    }

    fn abandon_frame(&mut self, id: u32, now: Instant) -> u64 {
        #[cfg(any(test,all(windows,feature="companion-soak")))]
        if let Some(g)=self.compact_head.as_mut() {
            if g.started==Some(id) {g.started=None;}
        }
        self.forget_abandoned(now);
        if self.abandoned.len() == ABANDONED_FRAMES { self.abandoned.pop_front(); }
        self.abandoned.push_back((id, now));
        self.abandoned_frames += 1;
        let mut removed = 0;
        let bytes = &mut self.video_bytes;
        self.video.retain(|p| {
            if p.frame != Some(id) { return true; }
            *bytes -= wire_bytes(p.payload.len());
            removed += 1;
            false
        });
        removed
    }

    fn expire(&mut self, now: Instant) {
        while let Some(p) = self.video.front().filter(|p| now.duration_since(p.at) >= MAX_AGE) {
            if let Some(id) = p.frame { self.stale += self.abandon_frame(id, now); }
            else {
                self.video_bytes -= wire_bytes(self.video.pop_front().unwrap().payload.len());
                self.stale += 1;
            }
        }
        while self.control.front().is_some_and(|p| now.duration_since(p.at) >= MAX_AGE) {
            self.control.pop_front();
            self.stale += 1;
        }
    }

    pub fn enable_fresh_recovery(&mut self) { self.fresh_recovery = true; }

    #[cfg(any(test,all(windows,feature="companion-soak")))]
    pub fn enable_compact_head_trial(&mut self) -> bool {
        if !self.fresh_recovery || !self.relay_spacing || self.frame_spread ||
            !(224_750..=225_000).contains(&self.bytes_per_second) {return false;}
        self.compact_head=Some(CompactHead::default());true
    }

    #[cfg(any(test,all(windows,feature="companion-soak")))]
    fn can_finish_started(&self,id:u32,now:Instant)->bool {
        if self.compact_head.as_ref().and_then(|g|g.started)!=Some(id) || self.busy_since.is_some(){return false;}
        let Some(first)=self.video.front() else {return false};
        let age=now.saturating_duration_since(first.at);
        let remaining:u64=self.video.iter().filter(|p|p.frame==Some(id)).map(|p|wire_bytes(p.payload.len()) as u64).sum();
        // 25% margin plus 5 ms for control/scheduling. Budget already excludes
        // the independent probe. No IDR prediction or plaintext inspection.
        (age.as_micros()+5_000)*u128::from(self.bytes_per_second)+u128::from(remaining)*1_250_000
            < MAX_AGE.as_micros()*u128::from(self.bytes_per_second)
    }

    #[cfg(any(test,all(windows,feature="companion-soak")))]
    pub fn compact_head_saves(&self)->Option<u64>{self.compact_head.as_ref().map(|g|g.saves)}

    fn trim_blocked_audio(&mut self, now: Instant) {
        if !self.frame_spread || !self.fresh_recovery || !self.busy_since
            .is_some_and(|begin| now.saturating_duration_since(begin)>=LONG_SEND_BLOCK) { return; }
        let before=self.control.len();
        self.control.retain(|p|p.port!=AUDIO_PORT || now.saturating_duration_since(p.at)<RECOVERY_AUDIO_AGE);
        self.recovery_audio_drops+=(before-self.control.len()) as u64;
    }

    pub fn recovery_audio_and_control(&self) -> (u64,u64) {
        (self.recovery_audio_drops,self.recovery_control_admissions)
    }

    // Before attempting a send on a long-blocked socket, make the very
    // next video packet come from a recent, still-intact frame. Normal
    // short backpressure, packet credit and the control queue are unchanged.
    fn prefer_recent_after_block(&mut self, now: Instant) {
        if !self.fresh_recovery ||
            !self.busy_since.is_some_and(|begin| now.saturating_duration_since(begin)>=LONG_SEND_BLOCK) {
            return;
        }
        let newest=self.video.back().and_then(|p| p.frame);
        while let Some(p)=self.video.front() {
            if now.saturating_duration_since(p.at)<RECOVERY_VIDEO_AGE && p.frame==newest && newest.is_some() {
                break;
            }
            if let Some(id)=p.frame {
                self.recovery_video_drops+=self.abandon_frame(id,now);
            } else {
                self.video_bytes-=wire_bytes(self.video.pop_front().unwrap().payload.len());
                self.recovery_video_drops+=1;
            }
        }
    }

    pub fn recovery_video_drops(&self) -> u64 { self.recovery_video_drops }

    pub fn take(&mut self, now: Instant) -> Option<Packet> {
        let age = now.duration_since(self.updated).as_micros().min(1_000_000) as u64;
        if age > 0 {
            self.credit = (self.credit + age * self.bytes_per_second)
                .min(self.burst_bytes * UNIT);
            self.updated = if age == 1_000_000 { now } else { self.updated + Duration::from_micros(age) };
        }
        self.expire(now);
        if now < self.retry_at || self.socket_gate_until.is_some_and(|at| now < at) ||
            self.dispatch_at.is_some_and(|at| now < at) { return None; }
        self.prefer_recent_after_block(now);
        self.trim_blocked_audio(now);
        let p = self.control.front().or_else(|| self.video.front())?;
        if self.video_due(p).is_some_and(|due| now<due) { return None; }
        let bytes = wire_bytes(p.payload.len());
        let cost = bytes as u64 * UNIT;
        if cost > self.credit { return None; }
        self.credit -= cost;
        self.max_delay_ms = self.max_delay_ms.max(now.duration_since(p.at).as_millis());
        if p.port == 0 {
            self.video_bytes -= bytes;
            self.video.pop_front()
        } else {
            self.control.pop_front()
        }
    }

    pub fn defer_full_socket(&mut self, packet: Packet, now: Instant) {
        // No UDP datagram was accepted. Return its reservation without
        // minting a second burst; preserve its original queue deadline.
        let bytes = wire_bytes(packet.payload.len());
        self.credit = (self.credit + bytes as u64 * UNIT).min(self.burst_bytes * UNIT);
        self.retries += 1;
        self.busy_since.get_or_insert(now);
        self.retry_at = now + self.retry_interval;
        self.retry_interval = (self.retry_interval * 2).min(RETRY_MAX);
        if now.saturating_duration_since(packet.at) >= MAX_AGE {
            self.stale += 1;
            if let Some(id) = packet.frame { self.stale += self.abandon_frame(id, now); }
        } else if packet.port == 0 {
            self.video_bytes += bytes;
            self.video.push_front(packet);
        } else {
            self.control.push_front(packet);
        }
    }

    pub fn socket_sent(&mut self, now: Instant) {
        self.socket_gate_until = None;
        if let Some(begin) = self.busy_since.take() {
            self.recoveries += 1;
            self.peak_busy_ms = self.peak_busy_ms.max(now.saturating_duration_since(begin).as_millis());
            self.retry_at = now;
            self.retry_interval = RETRY_MIN;
        }
    }

    #[cfg(any(test, all(windows, feature = "companion-soak")))]
    pub fn socket_retry_pending(&self, now: Instant) -> bool {
        self.busy_since.is_some() && now < self.retry_at
    }

    #[cfg(any(test, all(windows, feature = "companion-soak")))]
    pub fn retry_after_writable(&mut self, now: Instant) {
        if self.socket_retry_pending(now) { self.retry_at = now; }
    }

    #[cfg(any(test, all(windows, feature = "companion-soak")))]
    pub fn gate_socket_until(&mut self, next_probe: Option<Instant>) {
        self.socket_gate_until = next_probe;
    }

    // The aggregate token bucket keeps the same wire limit. On the narrow
    // WAN route also serialize packet starts: a delayed wake must not
    // spend saved credit on a back-to-back burst.
    pub fn enable_even_dispatch(&mut self, now: Instant) { self.dispatch_at = Some(now); }

    pub fn enable_standard_quantum(&mut self) {
        if self.dispatch_at.is_some() && self.bytes_per_second>=25_000*125 {
            self.standard_quantum=true;
            // Three full datagrams fit the relay's existing 4 KiB burst.
            self.burst_bytes=self.burst_bytes.min(3*wire_bytes(1220) as u64);
            self.credit=self.credit.min(self.burst_bytes*UNIT);
        }
    }

    // The relay already has a second rate limiter. Do not turn time spent
    // idle or a late sender wake into permission to compress this packet pair.
    pub fn enable_relay_spacing(&mut self) { self.relay_spacing = true; }

    #[cfg(any(test, all(windows, feature = "companion-soak")))]
    pub fn enable_frame_spread(&mut self) {
        self.frame_spread = self.relay_spacing && self.bytes_per_second > 225_000;
    }

    #[cfg(any(test, all(windows, feature = "companion-soak")))]
    pub fn use_sixty_fps_spread(&mut self) {
        if self.frame_spread { self.spread_budget=Duration::from_micros(13_500); }
    }

    fn video_due(&self, p: &Packet) -> Option<Instant> {
        if p.port != 0 { return None; }
        if self.frame_spread && (p.frame != self.spread_frame ||
            self.video.back().is_some_and(|last| last.frame != p.frame)) { return None; }
        self.video_at
    }

    pub fn sent_packet(&mut self, now: Instant, packet: &Packet) {
        #[cfg(any(test,all(windows,feature="companion-soak")))]
        if packet.port==0 {
            if let Some(g)=self.compact_head.as_mut() {
                // Arm only after the OS actually accepted a UDP packet, never
                // on take(), WouldBlock, or for a completed frame.
                g.started=packet.frame.filter(|id| self.video.front().and_then(|p|p.frame)==Some(*id));
            }
        }
        self.dispatched(now,packet.payload.len(),packet.port);
        if !self.frame_spread || packet.port != 0 { return; }
        self.spread_frame=packet.frame;
        self.video_at=None;
        let (Some(id),Some(first),Some(last))=(packet.frame,self.video.front(),self.video.back()) else { return };
        if first.frame!=Some(id) || last.frame!=Some(id) { return; }
        // The old 14-ms size cliff left medium reference pictures at full
        // peak rate. Use at most 81% of ONE negotiated frame interval,
        // leaving time before the next picture. A backed-up queue, a new
        // picture or control traffic never inherits this extra delay.
        let age=now.saturating_duration_since(first.at);
        let remaining=self.spread_budget.saturating_sub(age);
        let drain=Duration::from_nanos((self.video_bytes as u64*1_000_000_000).div_ceil(self.bytes_per_second));
        if age>=self.spread_budget*8/9 || drain>=remaining { return; }
        let slot=Duration::from_nanos((wire_bytes(packet.payload.len()) as u64*1_000_000_000).div_ceil(self.bytes_per_second));
        let gap=(remaining / self.video.len() as u32).min(slot*2);
        if gap>slot { self.video_at=Some(now+gap); }
    }

    pub fn dispatched(&mut self, now: Instant, payload_len: usize, port:usize) {
        if let Some(due) = self.dispatch_at {
            let ns = (wire_bytes(payload_len) as u64 * 1_000_000_000).div_ceil(self.bytes_per_second);
            let slot = Duration::from_nanos(ns);
            // A late wake need not add its entire lateness to the next slot.
            // Recover at most half of one slot; never import a backlog of
            // missed slots. The original token bucket still gates each send.
            let recover = if self.relay_spacing { Duration::ZERO }
                else { now.saturating_duration_since(due).min(slot / 2) };
            self.dispatch_at=Some(if self.standard_quantum {
                // At 27 Mbps a video packet owns ~0.33 ms. Advancing from
                // the actual Windows wake on every packet accumulates timer
                // lateness. Recover only two slots, capped at one millisecond;
                // the unchanged elapsed-time bucket still charges every byte.
                due.max(now.checked_sub((slot*2).min(Duration::from_millis(1))).unwrap_or(now))+slot
            } else {now + (slot - recover)});
            // Spread small video frames over the available headroom. Large
            // frames or an older queue use the negotiated pace immediately;
            // audio/control never wait for this extra video-only interval.
            if port==0 {
                self.video_at=if !self.standard_quantum && self.relay_spacing && self.bytes_per_second>225_000 &&
                    self.video_bytes as u64<=self.bytes_per_second*14/1000 &&
                    !self.video.front().is_some_and(|p|now.saturating_duration_since(p.at)>=Duration::from_millis(10))
                {Some(now+slot+slot/2)}else{None};
            }
        }
        self.socket_sent(now);
    }

    #[cfg(any(test, all(windows, feature = "companion-soak")))]
    pub fn dispatch_wait(&self, now: Instant) -> Option<Duration> {
        let p = self.control.front().or_else(|| self.video.front())?;
        let missing = (wire_bytes(p.payload.len()) as u64 * UNIT).saturating_sub(self.credit);
        let credit_at = self.updated + Duration::from_micros(missing.div_ceil(self.bytes_per_second));
        let mut due = self.dispatch_at?.max(self.retry_at).max(credit_at);
        due=due.max(self.video_due(p).unwrap_or(due));
        Some(due.max(self.socket_gate_until.unwrap_or(due)).saturating_duration_since(now))
    }

    #[cfg(all(windows, feature = "companion-soak"))]
    pub fn pending_video_bytes(&self) -> usize {
        self.video_bytes
    }

    pub fn backpressure(&self, now: Instant) -> (u64, u64, u128) {
        let current = self.busy_since.map_or(0, |begin| now.saturating_duration_since(begin).as_millis());
        (self.retries, self.recoveries, self.peak_busy_ms.max(current))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn frame_spread_stays_inside_one_fresh_frame_and_never_delays_control() {
        let t=Instant::now(); let mut p=Pacer::new(7100,t);
        p.enable_even_dispatch(t);p.enable_relay_spacing();p.enable_frame_spread();
        let slot=Duration::from_nanos((wire_bytes(1024) as u64*1_000_000_000).div_ceil(7100*125));
        for _ in 0..3 {p.push_video(&[0;1024],t,Some(7));}
        let a=p.take(t).unwrap();p.sent_packet(t,&a);
        assert_eq!(p.dispatch_wait(t),Some(slot*2));
        p.push(1,&[0;32],t);
        assert_eq!(p.dispatch_wait(t),Some(slot));
        let ctl=p.take(t+slot).unwrap();assert_eq!(ctl.port,1);p.sent_packet(t+slot,&ctl);
        p.push_video(&[0;1024],t+slot,Some(8));
        assert!(p.dispatch_wait(t+slot).unwrap()<slot);
        let older=p.take(t+slot+slot/2).unwrap();p.sent_packet(t+slot+slot/2,&older);
        assert_eq!(p.dispatch_wait(t+slot+slot/2),Some(slot));
        let mut low=Pacer::new(1800,t); low.enable_relay_spacing(); low.enable_frame_spread();
        assert!(!low.frame_spread);
    }
    #[test]
    fn frame_spread_does_not_stall_a_keyframe_or_an_aging_queue() {
        let t=Instant::now();
        let slot=Duration::from_nanos((wire_bytes(1024) as u64*1_000_000_000).div_ceil(7100*125));
        for (count,age) in [(25,Duration::ZERO),(3,Duration::from_millis(25))] {
            let mut p=Pacer::new(7100,t);
            p.enable_even_dispatch(t);p.enable_relay_spacing();p.enable_frame_spread();
            for _ in 0..count { p.push_video(&[0;1024],t,Some(1)); }
            let first=p.take(t+age).unwrap();p.sent_packet(t+age,&first);
            assert_eq!(p.dispatch_wait(t+age),Some(slot));
        }
    }

    #[test]
    fn medium_reference_picture_is_spread_without_crossing_next_frame() {
        let t=Instant::now(); let mut p=Pacer::new(7100,t);
        p.enable_even_dispatch(t);p.enable_relay_spacing();p.enable_frame_spread();
        for _ in 0..17 { p.push_video(&[0;1024],t,Some(97)); }
        let mut now=t;
        for i in 0..17 {
            let pkt=p.take(now).unwrap(); p.sent_packet(now,&pkt);
            if i<16 { let wait=p.dispatch_wait(now).unwrap();
                if i==0 { assert!(wait>Duration::from_micros(1400)); }
                now+=wait;
            }
        }
        assert!(now-t<=Duration::from_millis(27));
    }

    #[test]
    fn sixty_fps_completes_small_reference_before_next_frame_and_bypasses_a_busy_queue() {
        let t=Instant::now();
        let slot=Duration::from_nanos((wire_bytes(1024) as u64*1_000_000_000).div_ceil(7300*125));
        let mut p=Pacer::new(7300,t);
        p.enable_even_dispatch(t);p.enable_relay_spacing();p.enable_frame_spread();p.use_sixty_fps_spread();
        for _ in 0..8 {p.push_video(&[0;1024],t,Some(10));}
        let mut now=t;
        for i in 0..8 {
            let pkt=p.take(now).unwrap();p.sent_packet(now,&pkt);
            if i<7 { now+=p.dispatch_wait(now).unwrap(); }
        }
        assert!(now-t<=Duration::from_micros(13_500));
        let next=t+Duration::from_micros(16_667);
        for _ in 0..15 {p.push_video(&[0;1024],next,Some(11));}
        let large=p.take(next).unwrap();p.sent_packet(next,&large);
        assert_eq!(p.dispatch_wait(next),Some(slot));
        p.push(1,&[1;20],next);
        assert_eq!(p.take(next+slot).unwrap().port,1);
    }

    #[test]
    fn high_relay_spreads_small_frames_without_holding_control() {
        let now=Instant::now();
        let mut p=Pacer::new(7100,now);
        p.enable_even_dispatch(now);
        p.enable_relay_spacing();
        for _ in 0..3 {p.push_video(&[0;1024],now,Some(1));}
        let a=p.take(now).unwrap(); p.dispatched(now,1024,a.port);
        let slot=Duration::from_nanos((wire_bytes(1024) as u64*1_000_000_000).div_ceil(7100*125));
        assert_eq!(p.dispatch_wait(now),Some(slot+slot/2));
        assert!(p.take(now+slot).is_none());
        p.push(1,&[0;32],now);
        assert_eq!(p.dispatch_wait(now),Some(slot));
        assert_eq!(p.take(now+slot).unwrap().port,1);
        assert!(p.take(now+slot+slot/2).is_some());
    }

    #[test]
    fn standard_dispatch_preserves_rate_on_quantized_wakes_without_unbounded_bursts() {
        let t=Instant::now();
        let mut p=Pacer::new(27800,t);p.enable_even_dispatch(t);p.enable_standard_quantum();p.enable_relay_spacing();
        for i in 0..180 {p.push_video(&[0;1024],t,Some(i/32+1));}
        let mut count=0; let mut max_batch=0;
        for i in 0..51 {
            let now=t+Duration::from_micros(i*700);
            let mut batch=0;
            while let Some(pkt)=p.take(now){p.sent_packet(now,&pkt);batch+=1;}
            count+=batch; max_batch=max_batch.max(batch);
        }
        assert!((103..=112).contains(&count),"sent {count}");
        assert!(max_batch<=4,"batch {max_batch}");
        let late=t+Duration::from_millis(105);
        let mut catchup=0;while let Some(pkt)=p.take(late){p.sent_packet(late,&pkt);catchup+=1;}
        assert!((1..=3).contains(&catchup));
        let mut old=Pacer::new(8000,t); old.enable_even_dispatch(t);old.enable_standard_quantum();
        assert!(!old.standard_quantum);
    }

    #[test]
    fn guard_keeps_existing_pacer_and_expiry_after_a_block() {
        let begin = Instant::now();
        let mut p = Pacer::new(1800, begin);
        p.enable_even_dispatch(begin);
        p.enable_fresh_recovery();
        p.push_video(&[0;768],begin,Some(1));
        let packet = p.take(begin).unwrap();
        p.defer_full_socket(packet,begin);
        let resume=begin+Duration::from_millis(220);
        let now=resume-Duration::from_millis(1);
        p.push_video(&[1;768],now,Some(2));
        p.gate_socket_until(Some(resume));
        assert_eq!(p.dispatch_wait(now),Some(Duration::from_millis(1)));
        assert!(p.take(now).is_none());
        p.gate_socket_until(None);
        p.retry_after_writable(resume);
        assert_eq!(p.take(resume).unwrap().frame,Some(2));
    }

    #[test]
    fn relay_packet_spacing_keeps_full_wire_slot_after_idle_or_late_wake() {
        let start=Instant::now();
        let mut p=Pacer::new(1800,start);
        p.enable_even_dispatch(start);
        p.enable_relay_spacing();
        let now=start+Duration::from_millis(20);
        let len=812;
        let slot=Duration::from_nanos((wire_bytes(len) as u64*1_000_000_000).div_ceil(225_000));
        for _ in 0..3 { p.push_video(&[1;812],now,Some(3)); }
        let a=p.take(now).unwrap();
        p.dispatched(now,a.payload.len(),a.port);
        assert_eq!(p.dispatch_wait(now),Some(slot));
        assert!(p.take(now+slot/2).is_none());
        let late=now+slot+Duration::from_millis(2);
        let a=p.take(late).unwrap();
        p.dispatched(late,a.payload.len(),a.port);
        assert!(p.take(late+slot-Duration::from_nanos(1)).is_none());
        assert!(p.take(late+slot).is_some());
    }

    #[test]
    fn limits_burst_and_paces_wire_bytes() {
        let start = Instant::now();
        let mut p = Pacer::new(1600, start);
        let packet = [0; 1220];
        for _ in 0..4 { p.push(0, &packet, start); }
        assert!(p.take(start).is_some());
        assert!(p.take(start).is_some());
        assert!(p.take(start).is_none());
        assert!(p.take(start + Duration::from_millis(6)).is_none());
        assert!(p.take(start + Duration::from_millis(7)).is_some());
        assert!(p.take(start + Duration::from_millis(7)).is_none());
        assert!(p.take(start + Duration::from_millis(14)).is_some());
    }

    #[test]
    fn long_idle_does_not_allow_repeated_bursts() {
        let start = Instant::now();
        let now = start + Duration::from_secs(20);
        let mut p = Pacer::new(1600, start);
        for _ in 0..3 { p.push(0, &[1; 1220], now); }
        assert!(p.take(now).is_some());
        assert!(p.take(now).is_some());
        assert!(p.take(now).is_none());
    }

    #[test]
    fn narrow_stream_does_not_catch_up_with_a_burst_after_scheduler_delay() {
        let start=Instant::now();
        let mut p=Pacer::new(1800,start);
        p.enable_even_dispatch(start);
        let wake=start+Duration::from_millis(40);
        for _ in 0..3 { p.push_video(&[1;812],wake,Some(9)); }
        let first=p.take(wake).unwrap();
        p.dispatched(wake,first.payload.len(),first.port);
        let spacing=Duration::from_nanos((wire_bytes(812) as u64 * 1_000_000_000).div_ceil(225_000));
        let earliest=wake+(spacing-spacing/2);
        assert!(p.take(earliest-Duration::from_micros(100)).is_none());
        assert_eq!(p.dispatch_wait(earliest-Duration::from_micros(100)), Some(Duration::from_micros(100)));
        let next=p.take(earliest).unwrap();
        p.dispatched(earliest,next.payload.len(),next.port);
        assert!(p.take(earliest).is_none());
        assert!(p.take(earliest+spacing).is_some());
    }

    #[test]
    fn recurring_late_wakes_never_mint_wire_credit() {
        let start=Instant::now();
        let mut p=Pacer::new(1800,start);
        p.enable_even_dispatch(start);
        let bytes=[1;768];
        let mut sent=0;
        let mut last=None;
        for elapsed in 0..1000 {
            let now=start+Duration::from_millis(elapsed);
            p.push_video(&bytes,now,Some(elapsed as u32));
            // Regular scheduling slips, with visible backlog throughout.
            if elapsed % 51 < 11 { continue; }
            if let Some(item)=p.take(now) {
                if let Some(previous)=last { assert!(now - previous >= Duration::from_millis(1)); }
                last=Some(now);
                sent += wire_bytes(item.payload.len());
                p.dispatched(now,item.payload.len(),item.port);
                assert!(p.take(now).is_none());
            }
            assert!(sent <= (elapsed * 225) as usize + p.burst_bytes as usize);
        }
        assert!(sent > 150_000, "avoid accumulating a full slot of debt after every late wake");
    }

    #[test]
    fn dispatch_wait_respects_wire_credit_and_socket_retry() {
        let start=Instant::now();
        let mut p=Pacer::new(1800,start);
        p.enable_even_dispatch(start);
        assert_eq!(p.dispatch_wait(start), None);
        p.push_video(&[1;1220],start,Some(1));
        let packet=p.take(start).unwrap();
        p.defer_full_socket(packet,start);
        assert_eq!(p.dispatch_wait(start), Some(RETRY_MIN));
        assert_eq!(p.dispatch_wait(start+RETRY_MIN), Some(Duration::ZERO));
        p.credit=0;
        assert!(p.dispatch_wait(start+RETRY_MIN).unwrap() > Duration::ZERO);
    }

    #[test]
    fn prioritizes_control_and_bounds_backlog_and_age() {
        let start = Instant::now();
        let mut p = Pacer::new(1000, start);
        let packet = [2; 1220];
        for _ in 0..100 { p.push(0, &packet, start); }
        assert!(p.full > 0);
        p.push(1, &[1], start);
        assert_eq!(p.take(start).unwrap().port, 1);
        assert_eq!(p.take(start).unwrap().port, 0);
        assert!(p.take(start + MAX_AGE).is_none());
        assert!(p.stale > 0);
        assert_eq!(p.video_bytes, 0);
    }

    #[test]
    fn spending_available_credit_before_a_new_burst_avoids_a_false_full_drop() {
        let start = Instant::now();
        let video = [0; 1220];
        let mut p = Pacer::new(1800, start);
        for _ in 0..p.max_video_bytes / wire_bytes(video.len()) { p.push(0, &video, start); }
        let wake = start + Duration::from_millis(25);
        p.push(1, &[1], wake);
        assert_eq!(p.take(wake).unwrap().port, 1);
        assert_eq!(p.take(wake).unwrap().port, 0);
        p.push(0, &video, wake);
        assert_eq!(p.full, 0);
        assert!(p.take(wake).is_none(), "the extra drain must not mint additional wire credit");
    }

    #[test]
    fn busy_socket_keeps_packet_order_and_does_not_spend_extra_wire_credit() {
        let start = Instant::now();
        let mut p = Pacer::new(1800, start);
        for i in 0..3 { p.push(0, &[i; 1220], start); }
        let mut first = p.take(start).unwrap();
        first.encrypted = Some(Box::from([4, 0, 0, 0, 8, 9]));
        p.defer_full_socket(first, start);
        assert!(p.take(start + Duration::from_millis(1)).is_none());
        let retry = start + RETRY_MIN;
        let item = p.take(retry).unwrap();
        assert_eq!(item.payload[0], 0);
        assert_eq!(item.encrypted.as_deref(), Some(&[4, 0, 0, 0, 8, 9][..]));
        p.socket_sent(retry);
        assert_eq!(p.take(retry).unwrap().payload[0], 1);
        assert!(p.take(retry).is_none());
        assert_eq!(p.backpressure(retry), (1, 1, 2));
    }

    #[test]
    fn writable_signal_only_shortens_retry_not_pacing_or_expiry() {
        let start = Instant::now();
        let mut p=Pacer::new(1800,start);
        p.enable_even_dispatch(start);
        p.push_video(&[1;768],start,Some(77));
        let item=p.take(start).unwrap();
        p.defer_full_socket(item,start);
        assert!(p.socket_retry_pending(start));
        let ready=start+Duration::from_millis(1);
        p.retry_after_writable(ready);
        assert!(!p.socket_retry_pending(ready));
        let next=p.take(ready).unwrap();
        assert_eq!(next.frame,Some(77));
        p.dispatched(ready,next.payload.len(),next.port);
        p.push_video(&[1;768],ready,Some(78));
        p.retry_after_writable(ready);
        assert!(p.take(ready).is_none(),"a writable signal cannot skip the packet slot");
        let old=p.take(ready+Duration::from_millis(6)).unwrap();
        let failed=ready+MAX_AGE-Duration::from_millis(1);
        p.defer_full_socket(old,failed);
        p.retry_after_writable(failed+Duration::from_millis(1));
        assert!(p.take(ready+MAX_AGE).is_none(),"do not resend a stale frame on recovery");
    }

    #[test]
    fn long_block_drops_old_frame_groups_even_if_control_wins_first() {
        let begin=Instant::now();
        let mut p=Pacer::new(1800,begin);
        p.enable_fresh_recovery();
        p.push_video(&[0;768],begin,Some(100));
        let first=p.take(begin).unwrap();
        p.defer_full_socket(first,begin);
        p.push_video(&[1;768],begin+Duration::from_millis(120),Some(101));
        p.push_video(&[2;768],begin+Duration::from_millis(152),Some(102));
        p.push_video(&[3;768],begin+Duration::from_millis(153),Some(102));
        let restored=begin+Duration::from_millis(158);
        p.push(1,&[5],restored);
        assert_eq!(p.take(restored).unwrap().port,1);
        p.socket_sent(restored);
        p.push_video(&[1;768],restored,Some(101)); // tail of superseded frame
        let next=p.take(restored).unwrap();
        assert_eq!(next.frame,Some(102));
        assert_eq!(next.payload[0],2);
        assert_eq!(p.recovery_video_drops(),1);
        assert!(p.abandoned_tail>0);
    }

    #[test]
    fn ordinary_short_busy_retry_does_not_throw_away_reference_frames() {
        let begin=Instant::now();
        let mut p=Pacer::new(1800,begin);
        p.enable_fresh_recovery();
        p.push_video(&[0;768],begin,Some(5));
        let first=p.take(begin).unwrap();
        p.defer_full_socket(first,begin);
        let quick=begin+RETRY_MIN;
        p.push_video(&[1;768],quick,Some(6));
        assert_eq!(p.take(quick).unwrap().frame,Some(5));
        assert_eq!(p.recovery_video_drops(),0);
    }

    #[test]
    fn high_relay_keeps_new_control_when_blocked_audio_fills_the_queue() {
        let t=Instant::now();let later=t+RETRY_MIN;
        let mut p=Pacer::new(7300,t);
        p.enable_relay_spacing();p.enable_frame_spread();p.enable_fresh_recovery();
        p.push(1,&[10],t);let ctl=p.take(t).unwrap();p.defer_full_socket(ctl,t);
        for i in 0..CONTROL_PACKETS-1 { p.push(AUDIO_PORT,&[i as u8],t); }
        p.push(4,&[40],later);
        assert_eq!(p.control.len(),CONTROL_PACKETS);
        assert_eq!(p.recovery_audio_and_control(),(1,1));
        assert_eq!(p.take(later).unwrap().payload.as_ref(),&[10]);
        assert_eq!(p.control.back().unwrap().payload.as_ref(),&[40]);
        assert!(p.control.iter().all(|p|p.port!=AUDIO_PORT || p.payload[0]!=0));
        // No reliable message is evicted when all slots already contain control.
        let mut q=Pacer::new(7300,t);q.enable_relay_spacing();q.enable_frame_spread();q.enable_fresh_recovery();
        q.push(1,&[1],t);let ctl=q.take(t).unwrap();q.defer_full_socket(ctl,t);
        for _ in 1..CONTROL_PACKETS {q.push(4,&[1],t);}
        q.push(1,&[2],later);
        assert_eq!((q.full,q.recovery_audio_and_control()),(1,(0,0)));
    }

    #[test]
    fn long_block_expires_only_old_audio_on_the_high_relay() {
        let t=Instant::now();let wake=t+Duration::from_millis(152);
        for cap in [1800,7300] {
            let mut p=Pacer::new(cap,t);
            p.enable_relay_spacing();p.enable_frame_spread();p.enable_fresh_recovery();
            p.push_video(&[1],t,Some(1));let v=p.take(t).unwrap();p.defer_full_socket(v,t);
            p.push(AUDIO_PORT,&[2],wake-Duration::from_millis(25));
            p.push(1,&[3],wake-Duration::from_millis(24));
            p.push(AUDIO_PORT,&[4],wake-Duration::from_millis(6));
            p.push_video(&[5],wake,Some(2));
            let first=p.take(wake).unwrap();
            assert_eq!(first.payload[0],if cap==1800 {2}else{3});
            assert_eq!(p.recovery_audio_and_control(),(u64::from(cap>1800),0));
            if cap>1800 {
                p.socket_sent(wake);
                assert_eq!(p.take(wake).unwrap().payload[0],4);
                assert_eq!(p.take(wake).unwrap().frame,Some(2));
            }
        }
    }

    #[test]
    fn overflowing_video_keeps_newer_frames_and_does_not_requeue_a_lost_tail() {
        let start=Instant::now();
        let mut p=Pacer::new(1000,start);
        let size=wire_bytes(1220);
        let slots=p.max_video_bytes/size;
        for i in 0..slots { p.push_video(&[7;1220],start,Some(if i<5 { 7 } else { 8 })); }
        p.push_video(&[9;1220],start,Some(9));
        p.push_video(&[7;1220],start,Some(7));
        p.push(1,&[1],start);
        assert_eq!(p.full,5);
        assert_eq!(p.abandoned_frames,1);
        assert_eq!(p.abandoned_tail,1);
        assert_eq!(p.video_bytes,(slots-4)*size);
        assert_eq!(p.take(start).unwrap().port,1);
        assert_eq!(p.take(start).unwrap().frame,Some(8));
    }

    #[test]
    fn compact_head_only_on_fresh_narrow_relay_and_accept_precedes_protection() {
        let t=Instant::now();
        for cap in [1400,1798,1800,2000,7300] {
            let mut q=Pacer::new(cap,t);
            assert!(!q.enable_compact_head_trial());
            q.enable_relay_spacing();assert!(!q.enable_compact_head_trial());q.enable_fresh_recovery();
            assert_eq!(q.enable_compact_head_trial(),matches!(cap,1798|1800));
        }
        let mut q=Pacer::new(1798,t);q.enable_fresh_recovery();q.enable_relay_spacing();
        assert!(q.enable_compact_head_trial());
        for _ in 0..10 {q.push_video(&[7;640],t,Some(7));}
        let packet=q.take(t).unwrap();
        assert!(!q.can_finish_started(7,t));
        q.defer_full_socket(packet,t);assert!(!q.can_finish_started(7,t));
        let now=t+Duration::from_millis(5);
        let accepted=q.take(now).unwrap();q.sent_packet(now,&accepted);
        assert!(q.can_finish_started(7,now));
        assert!(!q.can_finish_started(7,t+MAX_AGE-Duration::from_millis(10)));
        let busy=q.take(now+Duration::from_millis(5)).unwrap();
        q.defer_full_socket(busy,now+Duration::from_millis(5));assert!(!q.can_finish_started(7,now+Duration::from_millis(6)));
    }

    #[test]
    fn compact_overflow_drops_entire_successor_never_delays_control_or_keeps_expired_head() {
        let t=Instant::now(); let mut q=Pacer::new(1798,t);q.enable_relay_spacing();q.enable_fresh_recovery();
        assert!(q.enable_compact_head_trial());
        let frames=q.max_video_bytes/wire_bytes(640);
        for _ in 0..12 {q.push_video(&[7;640],t,Some(7));}
        let head=q.take(t).unwrap();q.sent_packet(t,&head);
        let now=t+Duration::from_millis(10);
        for _ in 0..frames {q.push_video(&[8;640],now,Some(8));}
        assert_eq!(q.compact_head_saves(),Some(1));
        assert_eq!(q.video.len(),11);assert!(q.video.iter().all(|p|p.frame==Some(7) && p.at==t));
        assert_eq!(q.video_bytes,11*wire_bytes(640));
        q.push(CONTROL_PORT,&[4],now);
        assert_eq!(q.take(now).unwrap().port,CONTROL_PORT);
        let new=t+MAX_AGE;q.push_video(&[9;640],new,Some(9));
        assert_eq!(q.take(new).unwrap().frame,Some(9));assert_eq!(q.stale,11);
    }

    #[test]
    fn expiry_drops_all_fragments_of_the_frame_but_keeps_fresh_frames() {
        let start=Instant::now();
        let mut p=Pacer::new(1800,start);
        p.push_video(&[1;1220],start,Some(1));
        let later=start+Duration::from_millis(100);
        p.push_video(&[2;1220],later,Some(2));
        p.push_video(&[1;1220],later,Some(1));
        let first_deadline=start+MAX_AGE;
        assert_eq!(p.take(first_deadline).unwrap().frame,Some(2));
        p.push_video(&[1;1220],first_deadline,Some(1));
        assert!(p.take(first_deadline).is_none());
        assert_eq!(p.stale,2);
        assert_eq!(p.abandoned_tail,1);
        assert_eq!(p.video_bytes,0);
    }

    #[test]
    fn prolonged_backpressure_expires_video_without_delaying_control() {
        let start = Instant::now();
        let mut p = Pacer::new(1800, start);
        p.push(0, &[1; 1220], start);
        for elapsed in [0, 2, 6, 14, 30, 46, 62, 78, 94, 110] {
            let now = start + Duration::from_millis(elapsed);
            let item = p.take(now).unwrap();
            p.defer_full_socket(item, now);
        }
        let wake = start + MAX_AGE + Duration::from_millis(1);
        assert!(p.take(wake).is_none());
        assert_eq!(p.stale, 1);
        assert_eq!(p.video_bytes, 0);
        p.push(0, &[2; 1220], wake);
        p.push(1, &[3], wake);
        assert_eq!(p.take(wake).unwrap().port, 1);
        p.socket_sent(wake);
        assert_eq!(p.take(wake).unwrap().payload[0], 2);
        assert_eq!(p.backpressure(wake), (10, 1, 126));
    }
}
