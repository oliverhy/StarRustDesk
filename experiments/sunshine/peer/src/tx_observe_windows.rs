//! Per-socket Winsock observations and isolated, opt-in recovery experiments.
//! Never reads SO_ERROR (which can clear pending errors) or sends probes on
//! the media socket. Only the separate WAN trial may limit SO_SNDBUF.
use std::net::{Ipv4Addr, UdpSocket};
use std::os::windows::io::AsRawSocket;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const SOL_SOCKET: i32 = 0xffff;
const SO_SNDBUF: i32 = 0x1001;
const SO_RCVBUF: i32 = 0x1002;
const SOURCE_VIDEO_RCVBUF: u32 = 256 * 1024;
const POLLWRNORM: i16 = 0x0010;
const POLL_ERRORS: i16 = 0x0007;
const CHECK_GAP: Duration = Duration::from_millis(2);
const REPORT_GAP: Duration = Duration::from_millis(125);
const PROLONGED: Duration = Duration::from_millis(100);
const FORCED_RETRY_GAP: Duration = Duration::from_millis(64);
const TRIAL_SNDBUF: u32 = 8192;
const MIN_SAFE_SNDBUF: u32 = 4096;

#[repr(C)]
struct PollFd {
    socket: usize,
    events: i16,
    revents: i16,
}

#[link(name = "ws2_32")]
extern "system" {
    fn getsockopt(socket: usize, level: i32, opt: i32, value: *mut i32, len: *mut i32) -> i32;
    fn setsockopt(socket: usize, level: i32, opt: i32, value: *const i32, len: i32) -> i32;
    fn WSAGetLastError() -> i32;
    fn WSAPoll(fds: *mut PollFd, count: u32, timeout_ms: i32) -> i32;
}

fn buffer_setting(s: &UdpSocket) -> u32 {
    read_buffer(s, SO_SNDBUF)
}
fn read_buffer(s: &UdpSocket, option: i32) -> u32 {
    let mut value = 0;
    let mut len = 4;
    let rc = unsafe { getsockopt(s.as_raw_socket() as usize, SOL_SOCKET, option, &mut value, &mut len) };
    if rc == 0 && len == 4 { value.max(0) as u32 } else { 0 }
}

fn set_buffer(s: &UdpSocket, desired: u32) -> Result<(), u32> {
    write_buffer(s, SO_SNDBUF, desired)
}
fn write_buffer(s: &UdpSocket, option: i32, desired: u32) -> Result<(), u32> {
    let value = desired as i32;
    let rc = unsafe { setsockopt(s.as_raw_socket() as usize, SOL_SOCKET, option, &value, 4) };
    if rc == 0 { Ok(()) } else { Err(unsafe { WSAGetLastError() }.unsigned_abs()) }
}

// Only for the connected *local* video ingress, not the peer/wire socket.
pub(super) fn source_buffer(s: &UdpSocket, tune: bool) -> (u32, u32, u32) {
    if !s.local_addr().is_ok_and(|a|a.ip().is_loopback()) ||
       !s.peer_addr().is_ok_and(|a|a.ip().is_loopback() && a.port()==47998) {return (0,0,1);}
    let before=read_buffer(s,SO_RCVBUF);
    if !tune || before==0 || before>=SOURCE_VIDEO_RCVBUF {return (before,before,0);}
    if let Err(err)=write_buffer(s,SO_RCVBUF,SOURCE_VIDEO_RCVBUF) {return (before,read_buffer(s,SO_RCVBUF),err);}
    let actual=read_buffer(s,SO_RCVBUF);
    if actual>=SOURCE_VIDEO_RCVBUF {return (before,actual,0);}
    // If a provider did not honor the request, do not silently run at a
    // smaller/unknown size. Restore only this socket and mark unverified.
    let err=write_buffer(s,SO_RCVBUF,before).err().unwrap_or(1);
    (before,read_buffer(s,SO_RCVBUF),err)
}

fn cap_send_buffer(s: &UdpSocket, original: u32, desired:u32) -> (u32, u32, bool) {
    if original == 0 { return (0, 0, false); }
    if original <= desired {
        return (original, 0, original >= MIN_SAFE_SNDBUF);
    }
    if let Err(code) = set_buffer(s, desired) { return (original, code, false); }
    let actual = buffer_setting(s);
    if (MIN_SAFE_SNDBUF..=desired).contains(&actual) { return (actual, 0, true); }
    // A surprising provider readback is not a successful trial.
    let error = set_buffer(s, original).err().unwrap_or(0);
    (buffer_setting(s), error, false)
}

pub(super) fn trial_relay_buffer(s:&UdpSocket, kbps:u32, report:&impl Fn(String)) {
    if !(1801..=8000).contains(&kbps) { return; }
    // At most ~12 ms of the negotiated wire budget (8 KiB minimum).
    // Never increase the provider's own limit or change any other socket.
    let desired=(kbps*125*12).div_ceil(1_024_000).clamp(8,12)*1024;
    let original=buffer_setting(s);
    let (actual,errno,ok)=cap_send_buffer(s,original,desired);
    report(format!("wan_trial_sndbuf before={original} actual={actual} requested={desired} capped={} errno={errno}",u8::from(ok)));
}

// 0 = not writable, 1 = writable, 2 = unavailable/error. Diagnostic
// readiness is an additional observation, not a guarantee of UDP delivery.
fn writable(s: &UdpSocket) -> (u8, u16) {
    let mut fd = PollFd { socket: s.as_raw_socket() as usize, events: POLLWRNORM, revents: 0 };
    let r = unsafe { WSAPoll(&mut fd, 1, 0) };
    let state = if r < 0 || fd.revents & POLL_ERRORS != 0 { 2 }
        else { u8::from(fd.revents & POLLWRNORM != 0) };
    (state, fd.revents as u16)
}

fn utc_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis())
}

struct Busy {
    from: Instant,
    last_report: Instant,
    next_check: Instant,
    fallback_at: Instant,
    observed_blocked: bool,
    attempts: u64,
    errno: u32,
}

#[derive(PartialEq, Eq, Debug)]
pub(super) enum RetryDecision { Normal, Writable, HoldUntil(Instant) }

impl Busy {
    fn decide(&mut self, now: Instant, guard: bool, poll: impl FnOnce() -> u8) -> RetryDecision {
        if !self.observed_blocked { return RetryDecision::Normal; }
        if now >= self.next_check {
            self.next_check = now + CHECK_GAP;
            match poll() {
                0 => {}
                1 => {
                    self.observed_blocked = false;
                    return RetryDecision::Writable;
                }
                _ => {
                    self.observed_blocked = false;
                    return RetryDecision::Normal;
                }
            }
        }
        if guard && now.saturating_duration_since(self.from) >= PROLONGED && now < self.fallback_at {
            return RetryDecision::HoldUntil(self.next_check.min(self.fallback_at));
        }
        RetryDecision::Normal
    }
}

pub(super) struct TxObservation {
    start: Instant,
    busy: Option<Busy>,
    readiness_wakes: u64,
    hold_checks: u64,
    guard: bool,
    passive: bool,
    lan_ready: bool,
    ready_at: Option<Instant>,
    ready_refused: u32,
}

impl TxObservation {
    pub fn new(s: &UdpSocket, source: Ipv4Addr, media_kbps: u32, start: Instant,
               guard: bool, report: &impl Fn(String)) -> Self {
        let same_source = s.local_addr().is_ok_and(|a| a.ip() == source);
        let original = buffer_setting(s);
        let (actual, code, limited) = if guard { cap_send_buffer(s, original, TRIAL_SNDBUF) } else { (original, 0, false) };
        if guard {
            report(format!("wan_tx_guard before={} actual={} requested={} capped={} errno={}",
                original, actual, TRIAL_SNDBUF, u8::from(limited), code));
        }
        report(format!("wan_tx_setup version=1 sndbuf={} same_source={} media_kbps={}",
                       actual, u8::from(same_source), media_kbps));
        Self { start, busy: None, readiness_wakes: 0, hold_checks: 0, guard, passive: false,
            lan_ready: false, ready_at: None, ready_refused: 0 }
    }

    // LAN traces observe API failures but must never accelerate or hold the
    // next send just because a diagnostic file was requested.
    pub fn passive(mut self) -> Self { self.passive=true; self }

    // Separate from the WAN SO_SNDBUF trial. Only the caller's expressly enabled,
    // authenticated high-rate LAN experiment calls this. No socket option changes.
    pub fn lan_writable_trial(mut self) -> Self {
        self.lan_ready=true; self.passive=false; self
    }

    pub fn clock_anchor(&self,phase:u8,report:&impl Fn(String)) {
        let a=self.start.elapsed().as_micros();let utc=utc_ms();let b=self.start.elapsed().as_micros();
        report(format!("lan_tx_clock phase={phase} elapsed_us={} utc_ms={utc} bracket_us={}",(a+b)/2,b-a));
    }

    pub fn blocked(&mut self, s: &UdpSocket, errno: u32, queued: usize, bytes: usize,
                   report: &impl Fn(String)) {
        let now = Instant::now();
        let first = self.busy.is_none();
        let b = self.busy.get_or_insert(Busy { from: now, last_report: now,
            next_check: now, fallback_at: now, observed_blocked: false, attempts: 0, errno });
        if first { self.hold_checks = 0; self.ready_at=None; self.ready_refused=0; }
        else if self.ready_at.take().is_some() { self.ready_refused=self.ready_refused.saturating_add(1); }
        b.attempts += 1;
        b.errno = errno;
        let (state, flags) = writable(s);
        // Only accelerate on a demonstrated not-writable -> writable
        // transition. Providers that continue to advertise ready after
        // a failed send keep the old bounded retry backoff.
        b.observed_blocked = state == 0;
        b.next_check = now + CHECK_GAP;
        b.fallback_at = now + FORCED_RETRY_GAP;
        if first || now.duration_since(b.last_report) >= REPORT_GAP {
            b.last_report = now;
            let phase = if first { 1 } else { 2 };
            report(format!("wan_tx_event phase={} utc_ms={} elapsed_ms={} busy_ms={} errno={} ready={} flags={} attempts={} queue={} packet={} wakes={} holds={}",
                phase, utc_ms(), now.duration_since(self.start).as_millis(), now.duration_since(b.from).as_millis(),
                errno, state, flags, b.attempts, queued, bytes, self.readiness_wakes, self.hold_checks));
        }
    }

    pub fn retry_decision(&mut self, s: &UdpSocket, now: Instant, legacy_pending: bool) -> RetryDecision {
        if self.passive { return RetryDecision::Normal; }
        let Some(b) = self.busy.as_mut() else { return RetryDecision::Normal; };
        // A provider can report writable even though an individual send was refused.
        // Require a positive WSAEWOULDBLOCK and an actual not-writable observation.
        if self.lan_ready && b.errno!=10035 {return RetryDecision::Normal;}
        let guarded=self.guard || self.lan_ready;
        if !guarded && !legacy_pending { return RetryDecision::Normal; }
        let result = b.decide(now, guarded, || writable(s).0);
        match result {
            RetryDecision::Writable => {self.readiness_wakes += 1; if self.lan_ready {self.ready_at=Some(now);}},
            RetryDecision::HoldUntil(_) => self.hold_checks += 1,
            RetryDecision::Normal => {},
        }
        result
    }

    pub fn sent(&mut self, s: &UdpSocket, report: &impl Fn(String)) {
        if let Some(b) = self.busy.take() {
            let now = Instant::now();
            let (state, flags) = writable(s);
            if self.lan_ready && now.duration_since(b.from)>=PROLONGED {
                report(format!("lan_tx_resume elapsed_ms={} busy_us={} ready_seen={} noticed_us={} to_send_us={} false_ready={} attempts={} holds={}",
                    now.duration_since(self.start).as_millis(),now.duration_since(b.from).as_micros(),u8::from(self.ready_at.is_some()),
                    self.ready_at.map_or(0,|t|t.duration_since(b.from).as_micros()),
                    self.ready_at.map_or(0,|t|now.duration_since(t).as_micros()),self.ready_refused,b.attempts,self.hold_checks));
            }
            report(format!("wan_tx_event phase=3 utc_ms={} elapsed_ms={} busy_ms={} errno={} ready={} flags={} attempts={} queue=0 packet=0 wakes={} holds={}",
                utc_ms(), now.duration_since(self.start).as_millis(), now.duration_since(b.from).as_millis(),
                b.errno, state, flags, b.attempts, self.readiness_wakes, self.hold_checks));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration { Duration::from_millis(n) }

    #[test]
    fn guard_waits_for_writable_but_allows_a_bounded_fallback_and_unknown() {
        let start = Instant::now();
        let mut b = Busy { from: start, last_report: start, next_check: start, fallback_at: start + ms(164),
            observed_blocked: true, attempts: 1, errno: 10035 };
        assert_eq!(b.decide(start + ms(98), true, || 0), RetryDecision::Normal);
        assert_eq!(b.decide(start + ms(100), true, || 0), RetryDecision::HoldUntil(start + ms(102)));
        let between = b.decide(start + ms(101), true, || panic!("no redundant socket poll"));
        assert_eq!(between, RetryDecision::HoldUntil(start + ms(102)));
        assert_eq!(b.decide(start + ms(164), true, || 0), RetryDecision::Normal);
        assert_eq!(b.decide(start + ms(166), true, || 1), RetryDecision::Writable);
        assert_eq!(b.decide(start + ms(167), true, || panic!("not in a blocked state")), RetryDecision::Normal);
        b.observed_blocked = true;
        b.fallback_at = start + ms(240);
        assert_eq!(b.decide(start + ms(180), true, || 2), RetryDecision::Normal);
        b.observed_blocked = true;
        assert_eq!(b.decide(start + ms(190), false, || 0), RetryDecision::Normal);
    }

    #[test]
    fn buffer_limit_applies_only_to_one_socket() {
        let s = UdpSocket::bind("127.0.0.1:0").unwrap();
        let other = UdpSocket::bind("127.0.0.1:0").unwrap();
        let before = buffer_setting(&other);
        set_buffer(&s, 65_536).unwrap();
        let (actual, _, enabled) = cap_send_buffer(&s, buffer_setting(&s), TRIAL_SNDBUF);
        assert!(enabled && (MIN_SAFE_SNDBUF..=TRIAL_SNDBUF).contains(&actual));
        assert_eq!(buffer_setting(&other), before);
    }

    #[test]
    fn high_relay_socket_trial_is_scoped_and_never_increases_an_existing_limit() {
        let socket=UdpSocket::bind("127.0.0.1:0").unwrap();
        let other=UdpSocket::bind("127.0.0.1:0").unwrap();
        let other_size=buffer_setting(&other);
        set_buffer(&socket,65_536).unwrap();
        trial_relay_buffer(&socket,1800,&|_|panic!("low fallback must be untouched"));
        assert_eq!(buffer_setting(&socket),65_536);
        trial_relay_buffer(&socket,7300,&|_|{});
        assert_eq!(buffer_setting(&socket),11*1024);
        set_buffer(&socket,6144).unwrap();
        trial_relay_buffer(&socket,8000,&|_|{});
        assert_eq!(buffer_setting(&socket),6144);
        assert_eq!(buffer_setting(&other),other_size);
    }

    #[test]
    fn lan_diagnostics_do_not_change_the_socket_or_bypass_the_real_retry_deadline() {
        let s=UdpSocket::bind("127.0.0.1:0").unwrap();
        let now=Instant::now();
        let before=buffer_setting(&s);
        let mut observation=TxObservation::new(&s,Ipv4Addr::LOCALHOST,11200,now,false,&|_|{}).passive();
        observation.busy=Some(Busy { from: now,last_report: now,next_check: now,fallback_at: now,
            observed_blocked: true,attempts: 1,errno: 10055 });
        assert_eq!(observation.retry_decision(&s,now,true),RetryDecision::Normal);
        assert!(observation.busy.as_ref().unwrap().observed_blocked);
        assert_eq!(before,buffer_setting(&s));
    }

    #[test]
    fn lan_writable_trial_never_resizes_the_socket_or_suppresses_an_unrelated_error() {
        let s=UdpSocket::bind("127.0.0.1:0").unwrap();
        set_buffer(&s,65_536).unwrap();
        let now=Instant::now();
        let mut o=TxObservation::new(&s,Ipv4Addr::LOCALHOST,34_000,now,false,&|_|{}).lan_writable_trial();
        o.busy=Some(Busy { from:now,last_report:now,next_check:now,fallback_at:now+ms(180),
            observed_blocked:true,attempts:1,errno:10055 });
        assert_eq!(o.retry_decision(&s,now+ms(120),true),RetryDecision::Normal);
        assert!(o.busy.as_ref().unwrap().observed_blocked);
        assert_eq!((o.hold_checks,o.readiness_wakes,buffer_setting(&s)),(0,0,65_536));
    }

    #[test]
    fn long_not_writable_episode_retries_boundedly_and_wakes_on_first_positive_poll() {
        let start=Instant::now();
        let mut b=Busy {from:start,last_report:start,next_check:start,fallback_at:start+ms(64),
            observed_blocked:true,attempts:1,errno:10035};
        let mut retries=0;let mut wake=None;
        for m in 0..2540 {
            let now=start+ms(m);
            match b.decide(now,true,||u8::from(m>=2529)) {
                RetryDecision::Normal if m%16==0 => {retries+=1;b.fallback_at=now+FORCED_RETRY_GAP;},
                RetryDecision::Writable => {wake=Some(m);break;},
                _ => {}
            }
        }
        assert!((36..=50).contains(&retries));
        assert!(matches!(wake,Some(2529..=2531)));
    }
}
