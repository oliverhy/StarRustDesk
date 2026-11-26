//! Fixed-session UDP GameStream conduit over WireGuard. Only the two test
//! addresses and four local fixture ports are routable. No generic proxy.
use super::{key, public_endpoint, DirectReport, Params, Peer, HOST, PHONE, OBSERVER_PORT};
#[cfg(unix)]
use super::observer_endpoint;
use boringtun::noise::TunnResult;
use std::io::ErrorKind;
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant};
#[cfg(feature = "companion-wan")]
use crate::companion_tcp::{Sideband, PACER_INDEX};

#[path = "media_pace.rs"]
mod media_pace;
use media_pace::{wire_bytes, Pacer};
#[path = "media_timing.rs"]
mod media_timing;
use media_timing::{encrypted_frame_hint, timing_ms, VideoClock};
pub(crate) use media_timing::VideoPathSample;
#[cfg(all(unix, feature = "companion-wan"))]
pub(crate) use bandwidth::Estimate as CompanionEstimate;
#[path = "bandwidth.rs"]
mod bandwidth;
use bandwidth::Estimate;
#[cfg(all(windows, feature = "lan-bench"))]
#[path = "short_wait_windows.rs"]
mod short_wait;
#[cfg(all(windows, feature = "companion-soak"))]
#[path = "tx_observe_windows.rs"]
mod tx_observe_windows;
#[cfg(all(windows, feature = "companion-soak"))]
#[path = "source_rx_windows.rs"]
mod source_rx;
#[cfg(feature = "companion-soak")]
#[path = "phone_frames.rs"]
mod phone_frames;
#[cfg(all(target_env="ohos",feature="companion-soak"))]
#[path = "phone_rx_socket.rs"]
mod phone_rx_socket;
#[cfg(any(test,all(target_env="ohos",feature="companion-soak")))]
#[path = "phone_rx_evidence.rs"]
mod phone_rx_evidence;
#[cfg(any(test,all(target_env="ohos",feature="companion-soak")))]
#[path = "phone_rx_headroom.rs"]
mod phone_rx_headroom;
#[cfg(all(target_env="ohos",feature="companion-soak"))]
#[path = "phone_rx_batch.rs"]
mod phone_rx_batch;
#[cfg(any(test,all(target_env="ohos",feature="phone-rx-trial")))]
#[path = "phone_ingress_pool.rs"]
mod phone_ingress_pool;
#[cfg(any(test,all(target_env="ohos",feature="phone-rx-trial")))]
#[path = "phone_gap_pair.rs"]
mod phone_gap_pair;
#[cfg(any(test,all(target_env="ohos",feature="phone-rx-trial")))]
#[path = "phone_ingress_watch.rs"]
mod phone_ingress_watch;
#[cfg(any(test,all(target_env="ohos",feature="phone-rx-trial")))]
#[path = "phone_reader_phase.rs"]
mod phone_reader_phase;
#[cfg(any(test,all(target_env="ohos",feature="phone-burst-margin")))]
#[path = "phone_burst_margin.rs"]
mod phone_burst_margin;
#[cfg(all(target_env="ohos",feature="phone-rx-trial"))]
#[path = "phone_reader_probe.rs"]
mod phone_reader_probe;
#[cfg(all(target_env="ohos",feature="companion-soak"))]
#[path = "phone_ingress.rs"]
mod phone_ingress;

fn next_media_packet<'a>(s:&UdpSocket,buf:&'a mut [u8;2048],
    #[cfg(all(target_env="ohos",feature="companion-soak"))] batch:&'a mut Option<phone_ingress::Reader>,
    #[cfg(all(target_env="ohos",feature="phone-rx-trial"))] stamp:&mut Option<phone_gap_pair::Stamp>,
)->std::io::Result<&'a [u8]>{
    #[cfg(all(target_env="ohos",feature="companion-soak"))]
    if let Some(b)=batch.as_mut(){return b.next(s,buf,#[cfg(feature="phone-rx-trial")] stamp);}
    s.recv(buf).map(|n|&buf[..n])
}

const SERVICE: [(u16, u16); 4] = [(47998, 33498), (47999, 33499), (48000, 33500), (48002, 33502)];
const MAX: usize = 1220;
const HDR: usize = 28;
const DIRECT_TIMEOUT: Duration = Duration::from_millis(4800);
const MAX_TEST_WIRE_KBPS: u32 = 1800;
const LINK_LEASE_SECS: u64 = if cfg!(feature = "long-bench") { 1010 } else { 120 };
// Renewed only over the private owner pipe (PC) / after a pinned TLS ACK (phone).
#[cfg(feature="companion-wan")]
static LIVE: std::sync::OnceLock<(Instant,std::sync::atomic::AtomicU64)> = std::sync::OnceLock::new();
#[cfg(feature="companion-wan")]
#[no_mangle]
pub extern "C" fn sesame_companion_live_renew() {
    let (base,last)=LIVE.get_or_init(|| (Instant::now(),std::sync::atomic::AtomicU64::new(0)));
    last.store(1+base.elapsed().as_millis() as u64,std::sync::atomic::Ordering::Release);
}
#[cfg(feature="companion-wan")]
pub(crate) fn live_since(start:Instant, now:Instant) -> bool {
    let Some((base,last))=LIVE.get() else {return false};
    let v=last.load(std::sync::atomic::Ordering::Acquire);
    let seen=*base+Duration::from_millis(v.saturating_sub(1));
    v!=0 && seen>=start && now.saturating_duration_since(seen)<Duration::from_secs(45) &&
        now.saturating_duration_since(start)<Duration::from_secs(4*3600+120)
}

#[cfg(feature = "lan-bench")]
fn lan_endpoint(s: &str) -> Option<SocketAddr> {
    let a: std::net::SocketAddrV4 = s.parse().ok()?;
    let o = a.ip().octets();
    (a.ip().is_private() && !matches!(o[3], 0 | 255) && a.port() >= 1024).then_some(a.into())
}

#[cfg(feature = "lan-bench")]
fn same_lan(a: SocketAddr, b: SocketAddr) -> bool {
    match (a, b) {
        (SocketAddr::V4(a), SocketAddr::V4(b)) => a.ip() != b.ip() &&
            a.ip().octets()[..3] == b.ip().octets()[..3],
        _ => false,
    }
}

pub fn announce(socket: &UdpSocket, token: &[u8; 32], observer: SocketAddr) -> std::io::Result<()> {
    if observer.port() != OBSERVER_PORT { return Err(ErrorKind::InvalidInput.into()); }
    announce_to(socket, token, observer)
}

// USB diagnostic only. A second endpoint on the same authorized test VPS
// checks whether outbound mappings change with the destination port; it
// is never used as a relay candidate or to accept peer data.
pub fn announce_mapping(socket: &UdpSocket, token: &[u8; 32], mut observer: SocketAddr) -> std::io::Result<()> {
    if observer.port() != OBSERVER_PORT { return Err(ErrorKind::InvalidInput.into()); }
    observer.set_port(23389);
    announce_to(socket, token, observer)
}

fn announce_to(socket: &UdpSocket, token: &[u8; 32], observer: SocketAddr) -> std::io::Result<()> {
    let mut packet = [0u8; 36];
    packet[..4].copy_from_slice(b"SRV1");
    packet[4..].copy_from_slice(token);
    // One-use observations are returned to the controller over its pinned SSH
    // session. No unauthenticated responses or addresses are accepted here.
    for _ in 0..4 {
        socket.send_to(&packet, observer)?;
        std::thread::sleep(Duration::from_millis(80));
    }
    Ok(())
}

fn digest(input: &[u8]) -> u16 {
    let mut s = input.chunks_exact(2)
        .map(|x| u32::from(u16::from_be_bytes([x[0], x[1]]))).sum::<u32>();
    while s > 65535 { s = (s & 65535) + (s >> 16); }
    !(s as u16)
}

fn wrap<'a>(out: &'a mut [u8; HDR + MAX], src: [u8; 4], dst: [u8; 4],
           service: u16, bytes: &[u8]) -> Option<&'a [u8]> {
    if bytes.is_empty() || bytes.len() > MAX { return None; }
    let size = HDR + bytes.len();
    out[..HDR].fill(0);
    out[0] = 0x45;
    out[2..4].copy_from_slice(&(size as u16).to_be_bytes());
    out[6] = 0x40;
    out[8] = 64;
    out[9] = 17;
    out[12..16].copy_from_slice(&src);
    out[16..20].copy_from_slice(&dst);
    let sum = digest(&out[..20]);
    out[10..12].copy_from_slice(&sum.to_be_bytes());
    out[20..22].copy_from_slice(&service.to_be_bytes());
    out[22..24].copy_from_slice(&service.to_be_bytes());
    out[24..26].copy_from_slice(&((8 + bytes.len()) as u16).to_be_bytes());
    out[28..size].copy_from_slice(bytes);
    Some(&out[..size])
}

fn unpack(p: &[u8], src: [u8; 4], dst: [u8; 4]) -> Option<(u16, &[u8])> {
    if p.len() <= HDR || p.len() > HDR + MAX || p[0] != 0x45 || p[9] != 17
        || p[6] & 0xBF != 0 || p[7] != 0 || p[12..16] != src || p[16..20] != dst
        || usize::from(u16::from_be_bytes([p[2], p[3]])) != p.len()
        || usize::from(u16::from_be_bytes([p[24], p[25]])) != p.len() - 20
        || digest(&p[..20]) != 0 || p[20..22] != p[22..24] { return None; }
    Some((u16::from_be_bytes([p[20], p[21]]), &p[HDR..]))
}

fn unwrap(p: &[u8], src: [u8; 4], dst: [u8; 4]) -> Option<(usize, &[u8])> {
    let (port, bytes) = unpack(p, src, dst)?;
    SERVICE.iter().position(|x| x.0 == port).map(|i| (i, bytes))
}

struct MediaSocket {
    udp: UdpSocket,
    local: Option<SocketAddr>,
    sent: u64,
    recv: u64,
    drops: u64,
}

impl MediaSocket {
    fn bind(side_phone: bool, device_port: u16, guest_port: u16) -> Result<Self, &'static str> {
        let udp = UdpSocket::bind((Ipv4Addr::LOCALHOST, if side_phone { device_port } else { 0 }))
            .map_err(|_| "media_local_bind_failed")?;
        if !side_phone {
            udp.connect((Ipv4Addr::LOCALHOST, guest_port)).map_err(|_| "media_guest_connect_failed")?;
        }
        udp.set_nonblocking(true).map_err(|_| "media_nonblock_failed")?;
        Ok(Self { udp, local: None, sent: 0, recv: 0, drops: 0 })
    }

    fn deliver(&mut self, msg: &[u8], phone: bool) -> bool {
        let r = if phone {
            if let Some(dst) = self.local { self.udp.send_to(msg, dst) } else { return false; }
        } else { self.udp.send(msg) };
        if r.is_ok_and(|n| n == msg.len()) { self.recv += 1; true }
        else { self.drops += 1; false }
    }
}

#[derive(Default)]
struct SendStats {
    foreign: u64,
    size: u64,
    tunnel: u64,
    socket: u64,
    wire: u64,
    socket_errno: u32,
    offer_video_wire: u64,
    offer_video_packets: u64,
    #[cfg(all(windows, feature = "companion-soak"))]
    trace: Option<crate::soak_trace::TraceSink>,
    #[cfg(all(windows, feature = "companion-soak"))]
    tx: Option<tx_observe_windows::TxObservation>,
}

#[cfg(all(windows, feature = "companion-soak"))]
#[derive(Default)]
struct DispatchStats {
    waits: u32,
    busy_waits: u32,
    timeouts: u32,
    fallback: u32,
    wait_late: u32,
    work_late: u32,
    wait_peak_us: u128,
    wait_late_peak_us: u128,
    work_peak_us: u128,
    queue_peak: usize,
}

#[cfg(all(windows, feature = "companion-soak"))]
impl DispatchStats {
    fn work(&mut self, elapsed: Duration, queue: usize) {
        self.queue_peak = self.queue_peak.max(queue);
        self.work_peak_us = self.work_peak_us.max(elapsed.as_micros());
        if elapsed >= Duration::from_millis(8) { self.work_late += 1; }
    }

    fn wait(&mut self, requested: Duration, elapsed: Duration, pending: bool, wake: short_wait::Wake) {
        let late = elapsed.saturating_sub(requested);
        self.waits += 1;
        if pending { self.busy_waits += 1; }
        self.timeouts += u32::from(matches!(wake, short_wait::Wake::TimedOut));
        self.fallback += u32::from(matches!(wake, short_wait::Wake::Failed));
        if late >= Duration::from_millis(8) { self.wait_late += 1; }
        self.wait_peak_us = self.wait_peak_us.max(elapsed.as_micros());
        self.wait_late_peak_us = self.wait_late_peak_us.max(late.as_micros());
    }

    fn sample(&mut self, ms: u32) -> String {
        let s = std::mem::take(self);
        format!("wan_pacer_timing ms={} waits={} busy_waits={} timeouts={} fallback={} wait_late={} work_late={} wait_peak_us={} wait_late_peak_us={} work_peak_us={} queue_peak={}",
                ms, s.waits, s.busy_waits, s.timeouts, s.fallback, s.wait_late, s.work_late,
                s.wait_peak_us, s.wait_late_peak_us, s.work_peak_us, s.queue_peak)
    }
}

enum SendOutcome {
    Sent,
    Backpressure(u32),
    Dropped,
}

fn send_media(peer: &mut Peer, socket: &mut MediaSocket, packet: &[u8],
              out: &mut [u8], stats: &mut SendStats,
              retry: Option<&mut Option<Box<[u8]>>>) -> SendOutcome {
    if let Some(data) = retry.as_ref().and_then(|r| r.as_deref()) {
        return transmit(peer, socket, packet, data, stats);
    }
    match peer.tunnel.encapsulate(packet, out) {
        TunnResult::WriteToNetwork(data) => {
            let result = transmit(peer, socket, packet, data, stats);
            if matches!(result, SendOutcome::Backpressure(_)) {
                // The socket did not accept this datagram. Keep the original
                // ciphertext/counter until its queue deadline; a busy socket
                // must not consume new encryption counters on each retry.
                if let Some(saved) = retry { *saved = Some(data.into()); }
            }
            result
        }
        _ => { stats.tunnel += 1; SendOutcome::Dropped }
    }
}

fn transmit(peer: &Peer, socket: &mut MediaSocket, packet: &[u8], data: &[u8],
            stats: &mut SendStats) -> SendOutcome {
    let media = data.starts_with(&[4, 0, 0, 0]); // WireGuard data, not a handshake
    match peer.socket.send(data) {
        Ok(n) if n == data.len() => {
            if media {
                #[cfg(all(windows, feature = "companion-soak"))]
                if let Some(trace) = &mut stats.trace {
                    if packet.get(20..22) == Some(SERVICE[0].0.to_be_bytes().as_slice()) {
                        if let Some(frame)=encrypted_frame_hint(&packet[HDR..]) { trace.wire(frame,data); }
                    }
                }
                socket.sent += 1;
                stats.wire += wire_bytes(packet.len() - HDR) as u64;
                return SendOutcome::Sent;
            }
            stats.tunnel += 1;
        }
        Err(e) => {
            let errno = e.raw_os_error().unwrap_or(0).unsigned_abs();
            if media && retryable_udp_send(e.kind(),errno,cfg!(windows)) {
                return SendOutcome::Backpressure(errno);
            }
            stats.socket += 1;
            stats.socket_errno = errno;
        }
        Ok(_) => stats.socket += 1,
    }
    SendOutcome::Dropped
}

// A full Winsock send buffer rejected the datagram; this is not a permanent
// packet loss. Retry the same ciphertext within the existing queue deadline,
// regardless of whether any socket instrumentation is running.
fn retryable_udp_send(kind:ErrorKind, errno:u32, windows:bool)->bool {
    (windows && errno==10055) || matches!(kind,ErrorKind::WouldBlock | ErrorKind::Interrupted)
}

fn record_path(clock: &mut VideoClock, stage: u32, data: &[u8], start: Instant,
               loop_peak: u32, video_report: &impl Fn(&VideoPathSample)) {
    let Some(frame) = encrypted_frame_hint(data) else { return; };
    record_path_at(clock, stage, frame, start, loop_peak, video_report, Instant::now());
}
fn record_path_at(clock: &mut VideoClock, stage:u32, frame:u32,start:Instant,loop_peak:u32,
                  video_report:&impl Fn(&VideoPathSample), now:Instant) {
    if let Some(event) = clock.record(now, frame) {
        if let Some(s) = clock.sample(stage, timing_ms(now,start), loop_peak, Some(event)) {
            video_report(&s);
        }
    }
}

fn flush_paced(
    pacer: &mut Pacer, peer: &mut Peer, ports: &mut [MediaSocket],
    src: [u8; 4], dst: [u8; 4], wire: &mut [u8; HDR + MAX], out: &mut [u8],
    stats: &mut SendStats, path: &mut VideoClock, start: Instant, loop_peak: u32,
    video_report: &impl Fn(&VideoPathSample), _host_stat: &impl Fn(String),
) -> bool {
    let mut moved = false;
    #[cfg(all(windows, feature = "companion-soak"))]
    {
        let now = Instant::now();
        if let Some(o) = &mut stats.tx {
            use tx_observe_windows::RetryDecision;
            match o.retry_decision(&peer.socket, now, pacer.socket_retry_pending(now)) {
                RetryDecision::HoldUntil(next) => pacer.gate_socket_until(Some(next)),
                RetryDecision::Writable => {
                    pacer.gate_socket_until(None);
                    pacer.retry_after_writable(now);
                }
                RetryDecision::Normal => pacer.gate_socket_until(None),
            }
        }
    }
    for _ in 0..32 {
        let Some(mut item) = pacer.take(Instant::now()) else { break };
        let (packet, counter) = if item.port == SERVICE.len() {
            // Reliable setup/RTSP stays in the same low-bandwidth bucket.
            (Some(item.payload.as_ref()), 1)
        } else {
            (wrap(wire, src, dst, SERVICE[item.port].0, &item.payload), item.port)
        };
        if let Some(packet) = packet {
            match send_media(peer, &mut ports[counter], packet, out, stats, Some(&mut item.encrypted)) {
                SendOutcome::Sent => {
                    #[cfg(all(windows, feature = "companion-soak"))]
                    if let Some(o) = stats.tx.as_mut() { o.sent(&peer.socket, _host_stat); }
                    pacer.sent_packet(Instant::now(), &item);
                    if item.port == 0 {
                        record_path(path, 1, &item.payload, start, loop_peak, video_report);
                    }
                }
                SendOutcome::Backpressure(errno) => {
                    stats.socket_errno = errno;
                    #[cfg(all(windows, feature = "companion-soak"))]
                    if let Some(o) = stats.tx.as_mut() {
                        o.blocked(&peer.socket, errno, pacer.pending_video_bytes(), item.payload.len(), _host_stat);
                    }
                    pacer.defer_full_socket(item, Instant::now());
                    break;
                }
                SendOutcome::Dropped => {}
            }
            moved = true;
        }
    }
    moved
}

fn run(
    udp: UdpSocket, cfg: Params, phone: bool, wire_kbps: Option<u32>, ready: impl FnOnce(),
    stop: impl Fn() -> bool, hand_timeout: Duration, direct: bool, report: impl FnOnce(&DirectReport),
    video_report: impl Fn(&VideoPathSample), host_stat: impl Fn(String), native_desktop: bool,
    local_budget: bool, bandwidth_report: impl Fn(&Estimate), media_epoch: impl Fn(u32) -> u32,
) -> Result<String, &'static str> {
    let idx = if phone { 302 } else { 301 };
    let peer = if direct {
        let mut diag = DirectReport::default();
        let outcome = Peer::punch(udp, cfg, idx, hand_timeout, &stop, &mut diag);
        report(&diag);
        outcome?
    } else {
        let mut peer = Peer::connect(udp, cfg, idx).map_err(|_| "media_peer_connect_failed")?;
        peer.handshake_for(hand_timeout, &stop).map_err(|e| match e.kind() {
            ErrorKind::TimedOut => "media_peer_handshake_timeout",
            ErrorKind::Interrupted => "media_cancelled",
            _ => "media_peer_handshake_failed",
        })?;
        peer
    };
    run_authenticated(peer, phone, wire_kbps, ready, stop, video_report, host_stat, native_desktop,
        local_budget, bandwidth_report, media_epoch, #[cfg(feature = "companion-wan")] None,
        #[cfg(feature = "companion-wan")] false, #[cfg(feature = "companion-wan")] None)
}

pub(crate) fn run_authenticated(
    mut peer: Peer, phone: bool, wire_kbps: Option<u32>, ready: impl FnOnce(),
    stop: impl Fn() -> bool, video_report: impl Fn(&VideoPathSample), host_stat: impl Fn(String),
    native_desktop: bool, local_budget: bool, bandwidth_report: impl Fn(&Estimate), media_epoch: impl Fn(u32) -> u32,
    #[cfg(feature = "companion-wan")] mut side: Option<Sideband>,
    #[cfg(feature = "companion-wan")] relay_route: bool,
    #[cfg(feature = "companion-wan")] mut refresh: Option<crate::companion_wan::RelayRefresh>,
) -> Result<String, &'static str> {
    let src = if phone { PHONE } else { HOST };
    let dst = if phone { HOST } else { PHONE };
    let mut ports = Vec::with_capacity(SERVICE.len());
    for (device, guest) in SERVICE {
        ports.push(MediaSocket::bind(phone, device, if native_desktop { device } else { guest })?);
    }
    #[cfg(all(windows, feature="companion-soak"))]
    let mut source_rx=match source_rx::plan(local_budget,native_desktop,phone,side.is_some(),wire_kbps,
        std::env::var("SESAME_COMPANION_MANAGED_LAN").as_deref()==Ok("1"),
        std::env::var("SESAME_COMPANION_LAN_READY_TRIAL").as_deref()==Ok("1"),
        std::env::var("SESAME_COMPANION_LAN_SOURCE_RX").ok().as_deref()) {
        Some((tune,true))=>Some(source_rx::Observation::setup(&ports[0].udp,tune,&host_stat)),
        Some((tune,false))=>{let _=tx_observe_windows::source_buffer(&ports[0].udp,tune);None},
        None=>None,
    };
    peer.socket.set_read_timeout(None).map_err(|_| "media_peer_timeout_setup_failed")?;
    peer.socket.set_nonblocking(true).map_err(|_| "media_peer_nonblock_failed")?;
    #[cfg(all(windows, feature = "lan-bench"))]
    // The narrow WAN token bucket also needs sub-quantum wakes. With an
    // ordinary Windows sleep a two-packet burst can starve the approved
    // budget and expire healthy queued packets; keep its rate and size.
    let short_wait = short_wait::ShortWait::new(!phone && wire_kbps.is_some());
    #[cfg(all(windows, feature = "lan-bench"))]
    if short_wait.is_some() {
        host_stat(if local_budget { "lan_pacer_precise_idle=1" } else { "wan_pacer_precise_idle=1" }.to_owned());
    }
    let nap = || {
        #[cfg(all(windows, feature = "lan-bench"))]
        { short_wait::pace_one_ms::<false>(short_wait.as_ref()); }
        #[cfg(not(all(windows, feature = "lan-bench")))]
        std::thread::sleep(Duration::from_millis(1));
    };
    // Probes use the selected authenticated route before the first stream.
    // Normal media never forwards packets addressed to the probe service.
    #[cfg(feature="companion-wan")]
    let high_route=cfg!(feature="companion-soak") && !local_budget && relay_route && side.is_some();
    #[cfg(not(feature="companion-wan"))]
    let high_route=false;
    #[cfg(feature="companion-wan")]
    let paired_wan=cfg!(feature="companion-soak") && !local_budget && side.is_some();
    #[cfg(not(feature="companion-wan"))]
    let paired_wan=false;
    #[cfg(all(windows, feature="companion-soak"))]
    let high_trial = high_route && wire_kbps == Some(bandwidth::HIGH_RELAY);
    let mut wire_kbps=wire_kbps;
    #[cfg(feature="companion-soak")]
    let mut audit_high_lan=false;
    #[cfg(all(target_env="ohos",feature="companion-soak"))]
    let mut standard_lan_offer=false;
    if phone {
        bandwidth_report(&Estimate { state: bandwidth::PENDING, ..Estimate::default() });
        let sample=bandwidth::receive_samples(&mut peer,src,dst,local_budget,high_route,paired_wan,&stop,&nap);
        #[cfg(feature="companion-soak")]
        { audit_high_lan=local_budget && sample.cap>=25000; }
        #[cfg(all(target_env="ohos",feature="companion-soak"))]
        { standard_lan_offer=phone_rx_headroom::standard_lan_offer(local_budget,sample.cap); }
        bandwidth_report(&sample);
    } else if let Some(cap)=wire_kbps {
        #[cfg(all(windows,feature="companion-soak"))]
        let measured_nap=|| short_wait::pace_one_ms::<true>(short_wait.as_ref());
        #[cfg(all(windows,feature="companion-soak"))]
        let witness:Option<(&dyn Fn(String),&dyn Fn()->bandwidth::ProbeWait)>=if local_budget
            && std::env::var("SESAME_COMPANION_LAN_READY_TRIAL").as_deref()==Ok("1") {Some((&host_stat,&measured_nap))} else {None};
        #[cfg(not(all(windows,feature="companion-soak")))]
        let witness=None;
        let sample=bandwidth::sample_downlink(&mut peer,src,dst,cap,local_budget,&stop,&nap,witness);
        host_stat(format!("bandwidth_result state={} good_kbps={} unstable_kbps={} cap_kbps={}",
                    sample.state,sample.good,sample.upper,sample.cap));
        if (high_route && cap==bandwidth::HIGH_RELAY) || (paired_wan && cap==bandwidth::STANDARD_WIRE) {
            let (wire,video)=bandwidth::relay_plan(sample);
            wire_kbps=Some(wire);
            host_stat(format!("relay_capacity_plan wire_kbps={wire} video_cap_kbps={video}"));
        }
    }
    if stop() { return Err("media_cancelled"); }
    #[cfg(all(target_env="ohos",feature="companion-soak"))]
    let mut rx_window=if phone && audit_high_lan {phone_rx_socket::Window::new(&peer.socket,standard_lan_offer)} else {None};
    #[cfg(all(target_env="ohos",feature="companion-soak"))]
    let mut rx_batch=rx_window.as_ref().filter(|w|w.qualified())
        .map(|w|phone_ingress::Reader::new(&peer.socket,w.current_drops(&peer.socket),standard_lan_offer));
    ready();
    let start = Instant::now();
    let mut next = Instant::now();
    let mut emit_tick = Instant::now();
    let mut path_tick = start;
    let mut path_in = VideoClock::default();
    #[cfg(all(target_env="ohos",feature="phone-rx-trial"))]
    let mut gap_pairs=phone_gap_pair::Pairs::default();
    let mut path_out = VideoClock::default();
    let mut last_loop = start;
    let mut loop_peak = 0;
    let mut buf = [0; 2048];
    let mut out = [0; 2048];
    let mut wire = [0; HDR + MAX];
    let mut rejected: u64 = 0;
    let mut stats = SendStats::default();
    #[cfg(all(windows, feature = "companion-soak"))]
    if !phone && (side.is_some() || (local_budget && native_desktop &&
            std::env::var("SESAME_COMPANION_MANAGED_LAN").as_deref()==Ok("1"))) {
        stats.trace = crate::soak_trace::TraceSink::open(start);
    }
    #[cfg(all(windows, feature = "companion-soak"))]
    // Input/IME and foreground changes can create a sharp burst even at
    // 540p30. This is a property of the capped *route*, not of 360p capture.
    let wan_even_dispatch = !phone && native_desktop && !local_budget && side.is_some() &&
        (wire_kbps == Some(MAX_TEST_WIRE_KBPS) || (paired_wan && wire_kbps.is_some_and(|x| x>bandwidth::HIGH_RELAY && x<=bandwidth::STANDARD_WIRE)) ||
         (high_route && wire_kbps.is_some_and(|x| (MAX_TEST_WIRE_KBPS..=bandwidth::HIGH_RELAY).contains(&x))));
    #[cfg(all(windows, feature = "companion-soak"))]
    let even_dispatch = wan_even_dispatch || (!phone && local_budget && native_desktop && side.is_none() &&
        wire_kbps.is_some_and(|x| x>=11_200 && x<=72_000) && std::env::var("SESAME_COMPANION_MANAGED_LAN").as_deref()==Ok("1"));
    #[cfg(not(all(windows, feature = "companion-soak")))]
    let even_dispatch = false;
    #[cfg(all(windows, feature = "companion-soak"))]
    let diagnostic_source: Option<Ipv4Addr> = if wan_even_dispatch {
        std::env::var("SESAME_COMPANION_TX_SOURCE").ok().and_then(|value| value.parse().ok())
    } else { None };
    // The independent broker challenge costs <2 kbps uplink (maximum
    // two 124-byte IPv4 datagrams/s). Reserve that in this trial only.
    #[cfg(all(windows, feature = "companion-soak"))]
    let media_kbps = wire_kbps.map(|rate| rate - if diagnostic_source.is_some() { 2 } else { 0 });
    #[cfg(not(all(windows, feature = "companion-soak")))]
    let media_kbps = wire_kbps;
    let mut pacer = media_kbps.map(|rate| Pacer::new(rate, start));
    let managed_lan = cfg!(windows) && local_budget && native_desktop && !phone && pacer.is_some()
        && std::env::var("SESAME_COMPANION_MANAGED_LAN").as_deref()==Ok("1");
    let fresh_recovery = managed_lan || (even_dispatch &&
        std::env::var("SESAME_COMPANION_FRESH_RECOVERY").as_deref() == Ok("1"));
    if fresh_recovery {
        pacer.as_mut().unwrap().enable_fresh_recovery();
        host_stat(if managed_lan {"lan_fresh_recovery=1"} else {"wan_fresh_recovery=1"}.into());
    }
    #[cfg(all(windows, feature = "companion-soak"))]
    if let Some(source) = diagnostic_source {
        let guard = !high_trial && std::env::var("SESAME_COMPANION_TX_GUARD").as_deref() == Ok("1");
        if high_trial && std::env::var("SESAME_COMPANION_RELAY_SOCKET_TRIAL").as_deref()==Ok("1") {
            tx_observe_windows::trial_relay_buffer(&peer.socket,wire_kbps.unwrap(),&host_stat);
        }
        let observation = tx_observe_windows::TxObservation::new(&peer.socket, source,
            media_kbps.unwrap(), start, guard, &host_stat);
        // Measure the high offer, including its safe fallback, with the same
        // retry deadlines; the separate explicit SO_SNDBUF trial changes
        // only this socket and only if the high offer was actually accepted.
        let passive_hd = !guard && std::env::var("SESAME_COMPANION_TX_PASSIVE").as_deref()==Ok("1");
        stats.tx = Some(if high_trial || passive_hd { observation.passive() } else { observation });
    }
    #[cfg(all(windows,feature="companion-soak"))]
    if managed_lan && stats.trace.is_some() {
        if let Ok(SocketAddr::V4(a))=peer.socket.local_addr() {
            let obs=tx_observe_windows::TxObservation::new(&peer.socket,*a.ip(),media_kbps.unwrap(),start,false,&host_stat);
            obs.clock_anchor(1,&host_stat);
            let trial=side.is_none() && even_dispatch && media_kbps.is_some_and(|rate|(30_000..=72_000).contains(&rate))
                && std::env::var("SESAME_COMPANION_LAN_READY_TRIAL").as_deref()==Ok("1");
            stats.tx=Some(if trial {
                host_stat("lan_tx_writable_trial=1".into());obs.lan_writable_trial()
            } else {obs.passive()});
        }
    }
    if even_dispatch {
        pacer.as_mut().unwrap().enable_even_dispatch(start);
        if (managed_lan || paired_wan) && media_kbps.is_some_and(|rate| rate>=25000) {
            pacer.as_mut().unwrap().enable_standard_quantum();
            host_stat("standard_pacer_bounded_catchup=1".into());
        }
        host_stat(if managed_lan {"lan_pacer_even_dispatch=1"} else {"wan_pacer_even_dispatch=1"}.into());
    }
    #[cfg(feature = "companion-wan")]
    if even_dispatch && relay_route &&
        std::env::var("SESAME_COMPANION_RELAY_SPACING").as_deref() == Ok("1") {
        pacer.as_mut().unwrap().enable_relay_spacing();
        host_stat("wan_relay_spacing=1".into());
        #[cfg(all(windows,feature="companion-soak"))]
        if !phone && native_desktop && !local_budget && !high_trial && side.is_some() &&
            diagnostic_source.is_some() && stats.trace.is_some() && wire_kbps==Some(MAX_TEST_WIRE_KBPS) &&
            std::env::var("SESAME_COMPANION_COMPACT_HEAD").as_deref()==Ok("1") &&
            pacer.as_mut().unwrap().enable_compact_head_trial() {
            host_stat("wan_compact_head_enabled=1".into());
        }
        #[cfg(all(windows, feature="companion-soak"))]
        if high_route && media_kbps.is_some_and(|rate|rate>MAX_TEST_WIRE_KBPS) &&
            std::env::var("SESAME_COMPANION_FRAME_SPREAD").as_deref()==Ok("1") {
            pacer.as_mut().unwrap().enable_frame_spread();
            if std::env::var("SESAME_COMPANION_SPREAD_FPS").as_deref()==Ok("60") {
                pacer.as_mut().unwrap().use_sixty_fps_spread();
                host_stat("wan_relay_spread_60fps=1".into());
            }
            host_stat("wan_relay_frame_spread=1".into());
        }
    }
    #[cfg(feature = "companion-soak")]
    let mut phone_frames = (phone && (side.is_some() || audit_high_lan)).then(phone_frames::PhoneFrames::new);
    #[cfg(all(windows, feature = "companion-soak"))]
    let _dispatch_schedule = if even_dispatch {
        let guard = short_wait::DispatchSchedule::enter();
        host_stat(format!("wan_pacer_deadline_policy=1 mmcss={} precise={}",
            u8::from(guard.is_some()), u8::from(short_wait.is_some())));
        guard
    } else { None };
    #[cfg(all(windows, feature = "companion-soak"))]
    let mut dispatch_stats = DispatchStats::default();
    let mut check_stop = start;
    let mut epoch = 0;
    #[cfg(all(windows, feature = "long-bench"))]
    let quality_trial = !phone && local_budget && native_desktop &&
        std::env::var("SESAME_PHYSICAL_QUALITY_TRIAL").as_deref() == Ok("1");
    #[cfg(all(windows, feature = "long-bench"))]
    let mut test_budget = wire_kbps.unwrap_or(0);
    #[cfg(feature = "companion-wan")]
    let lease = if side.is_some() {
        LINK_LEASE_SECS.min(if cfg!(feature = "companion-soak") { 725 } else { 95 })
    } else { LINK_LEASE_SECS };
    #[cfg(not(feature = "companion-wan"))]
    let lease = LINK_LEASE_SECS;
    loop {
        let tick = Instant::now();
        if tick.duration_since(start)>=Duration::from_secs(lease) {
            #[cfg(feature="companion-wan")]
            if !live_since(start,tick) {break}
            #[cfg(not(feature="companion-wan"))]
            break;
        }
        #[cfg(feature="companion-wan")]
        if let Some(r)=refresh.as_mut() { r.tick(&peer.socket,start,tick); }
        let desired_epoch = media_epoch(epoch);
        if phone && desired_epoch != epoch {
            if desired_epoch != epoch + 1 || desired_epoch > (if cfg!(feature="companion-wan") { 16 } else { 4 }) {
                return Err("media_replacement_epoch_rejected");
            }
            // The old decoder/control stack is closed before requesting
            // rebinding. Drain old local traffic, not the authenticated
            // peer, before telling the new stack it can use these sockets.
            for port in &mut ports {
                port.local = None;
                for _ in 0..96 {
                    match port.udp.recv_from(&mut buf) {
                        Ok(_) => continue,
                        Err(_) => break,
                    }
                }
            }
            epoch = desired_epoch;
            // The numeric packet ledger is only for one fixed video stream.
            #[cfg(feature = "companion-soak")]
            if let Some(audit) = phone_frames.take() { audit.invalidate(&host_stat); }
            media_epoch(epoch);
        }
        #[cfg(all(windows, feature = "long-bench"))]
        if quality_trial {
            let budget = wire_kbps.unwrap();
            let elapsed = tick.duration_since(start).as_secs();
            let next_budget = if (12..28).contains(&elapsed) { budget.min(2200) } else { budget };
            if test_budget != next_budget {
                pacer.as_mut().unwrap().set_trial_budget(next_budget, tick);
                host_stat(format!("quality_test_pacer_kbps={} seconds={}", next_budget, elapsed));
                test_budget = next_budget;
            }
        }
        loop_peak = loop_peak.max(timing_ms(tick,last_loop));
        last_loop = tick;
        if check_stop.elapsed() >= Duration::from_millis(50) {
            if stop() { break; }
            check_stop = Instant::now();
        }
        let mut moved = false;
        for _ in 0..96 {
            #[cfg(all(target_env="ohos",feature="phone-rx-trial"))]
            let mut stamp=None;
            let mut packet = match next_media_packet(&peer.socket,&mut buf,
                #[cfg(all(target_env="ohos",feature="companion-soak"))] &mut rx_batch,
                #[cfg(all(target_env="ohos",feature="phone-rx-trial"))] &mut stamp) {
                Ok(p) => p,
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) => break,
                Err(_) => return Err("media_peer_receive_failed"),
            };
            moved = true;
            #[cfg(feature="companion-wan")]
            if packet.starts_with(b"SCB1") {
                if let Some(r)=refresh.as_mut(){r.receive(&peer.socket,packet,start,tick);}
                continue;
            }
            for _ in 0..8 {
                match peer.tunnel.decapsulate(Some(peer.hub_ip), packet, &mut out) {
                    TunnResult::WriteToNetwork(o) => { let _ = peer.socket.send(o); }
                    TunnResult::WriteToTunnelV4(o, _) => {
                        #[cfg(feature = "companion-wan")]
                        if side.as_mut().is_some_and(|tcp| tcp.admit(o, dst, src)) { break; }
                        if let Some((i, data)) = unwrap(o, dst, src) {
                            if phone && i == 0 {
                                #[cfg(all(target_env="ohos",feature="companion-soak"))]
                                if let Some(w)=&mut rx_window {w.received(data.len());}
                                if let Some(f)=encrypted_frame_hint(data) {
                                    let at=Instant::now();
                                    record_path_at(&mut path_in,2,f,start,loop_peak,&video_report,at);
                                    #[cfg(all(target_env="ohos",feature="phone-rx-trial"))]
                                    if standard_lan_offer {
                                        gap_pairs.video(f,packet,stamp,at,start,&host_stat);
                                    }
                                }
                            }
                            let delivered = ports[i].deliver(data, phone);
                            if delivered && phone && i == 0 {
                                record_path(&mut path_out, 3, data, start, loop_peak, &video_report);
                            }
                            #[cfg(feature = "companion-soak")]
                            if phone && i == 0 {
                                if let (Some(audit), Some(frame)) = (&mut phone_frames, encrypted_frame_hint(data)) {
                                    audit.mark(frame, delivered);
                                }
                            }
                        }
                        else if !matches!(unpack(o, dst, src), Some((bandwidth::PORT, _))) {
                            rejected += 1;
                        }
                        break;
                    }
                    TunnResult::Done => break,
                    _ => { rejected += 1; break; }
                }
                packet = &[];
            }
        }
        #[cfg(feature = "companion-wan")]
        if let Some(tcp) = &mut side {
            tcp.tick();
            for _ in 0..8 {
                let Some(packet) = tcp.pop() else { break; };
                if let Some(p) = &mut pacer {
                    p.push(PACER_INDEX, &packet, Instant::now());
                } else {
                    let _ = send_media(&mut peer, &mut ports[1], &packet, &mut out, &mut stats, None);
                }
                moved = true;
            }
        }
        // On the paced desktop side, collect pending control first and spend
        // existing wire credit before ingesting a new video burst. Otherwise
        // a scheduling pause can make the backlog reject new packets even
        // when older, still-live packets are immediately sendable.
        let port_order = if phone { [0, 1, 2, 3] } else { [1, 2, 3, 0] };
        for i in port_order {
            if i == 0 {
                if let Some(p) = &mut pacer {
                    moved |= flush_paced(p, &mut peer, &mut ports, src, dst, &mut wire, &mut out,
                        &mut stats, &mut path_out, start, loop_peak, &video_report, &host_stat);
                }
            }
            for index in 0..56 {
                if even_dispatch && i == 0 && index != 0 && index % 8 == 0 {
                    if let Some(p) = &mut pacer {
                        moved |= flush_paced(p, &mut peer, &mut ports, src, dst, &mut wire, &mut out,
                            &mut stats, &mut path_out, start, loop_peak, &video_report, &host_stat);
                    }
                }
                let socket = &mut ports[i];
                let (n, from) = match socket.udp.recv_from(&mut buf) {
                    Ok(v) => v,
                    Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted |
                                         ErrorKind::ConnectionReset | ErrorKind::ConnectionRefused) => break,
                    Err(_) => return Err("media_local_receive_failed"),
                };
                if !from.ip().is_loopback() || (phone && socket.local.is_some_and(|s| s != from)) {
                    stats.foreign += 1;
                    continue;
                }
                if n == 0 || n > MAX {
                    stats.size += 1;
                    continue;
                }
                if phone { socket.local = Some(from); }
                moved = true;
                if let Some(p) = &mut pacer {
                    if i == 0 {
                        if even_dispatch {
                            stats.offer_video_wire += wire_bytes(n) as u64;
                            stats.offer_video_packets += 1;
                        }
                        let frame=encrypted_frame_hint(&buf[..n]);
                        #[cfg(all(windows, feature="companion-soak"))]
                        if let Some((prev,next,missing))=source_rx.as_mut().and_then(|o|o.note(&buf[..n])) {
                            host_stat(format!("lan_source_rx_gap prev={prev} next={next} missing={missing}"));
                        }
                        record_path(&mut path_in, 0, &buf[..n], start, loop_peak, &video_report);
                        #[cfg(all(windows, feature = "companion-soak"))]
                        if let Some(trace) = &mut stats.trace {
                            if let Some(frame)=frame { trace.source(frame,wire_bytes(n)); }
                        }
                        p.push_video(&buf[..n], Instant::now(), frame);
                    } else {
                        p.push(i, &buf[..n], Instant::now());
                    }
                } else if let Some(packet) = wrap(&mut wire, src, dst, SERVICE[i].0, &buf[..n]) {
                    if let SendOutcome::Backpressure(errno) =
                        send_media(&mut peer, socket, packet, &mut out, &mut stats, None)
                    {
                        stats.socket += 1;
                        stats.socket_errno = errno;
                    }
                }
            }
        }
        if let Some(p) = &mut pacer {
            // The two drains share one token bucket and the same age limit.
            moved |= flush_paced(p, &mut peer, &mut ports, src, dst, &mut wire, &mut out,
                &mut stats, &mut path_out, start, loop_peak, &video_report, &host_stat);
        }
        if Instant::now() >= next {
            if let TunnResult::WriteToNetwork(bytes) = peer.tunnel.update_timers(&mut out) {
                let _ = peer.socket.send(bytes);
            }
            next = Instant::now() + Duration::from_millis(100);
        }
        if path_tick.elapsed() >= Duration::from_secs(2) {
            let n = Instant::now();
            for (i, clock) in [&path_in, &path_out].into_iter().enumerate() {
                if let Some(s) = clock.sample(i as u32 + if phone { 2 } else { 0 },
                    timing_ms(n,start), loop_peak, None) { video_report(&s); }
            }
            path_tick=n;
            #[cfg(all(windows, feature="companion-soak"))]
            if let Some(o)=&source_rx{o.report(false,&host_stat);}
            #[cfg(all(target_env="ohos",feature="companion-soak"))]
            if let Some(w)=&mut rx_window {
                w.sample(&peer.socket,&host_stat);
                if let Some(b)=&mut rx_batch {if let Some((p,d))=b.report(&peer.socket,&host_stat){w.pressure(&peer.socket,p,d,&host_stat);}}
                else if w.qualified(){rx_batch=Some(phone_ingress::Reader::new(&peer.socket,w.current_drops(&peer.socket),standard_lan_offer));}
            }
            #[cfg(feature = "companion-soak")]
            if let Some(audit) = &mut phone_frames { audit.flush(false, &host_stat); }
        }
        if let Some(p) = pacer.as_ref() {
            if emit_tick.elapsed() >= Duration::from_secs(1) {
                #[cfg(all(windows,feature="companion-soak"))]
                if let Some(n)=p.compact_head_saves() {host_stat(format!("wan_compact_head saves={n}"));}
                host_stat(format!("wan_media_host video_to_phone={} phone_video_probes={} control_to_phone={} drop_foreign={} drop_size={} drop_tunnel={} drop_socket={} drop_local={} drop_queue_full={} drop_queue_stale={} rejected={} queue_max_ms={} wire_bytes={} socket_errno={} abandon_frames={} abandon_tail={}",
                         ports[0].sent, ports[0].recv, ports[1].sent, stats.foreign, stats.size,
                         stats.tunnel, stats.socket, ports.iter().map(|x| x.drops).sum::<u64>(),
                         p.full, p.stale, rejected, p.max_delay_ms, stats.wire, stats.socket_errno,
                         p.abandoned_frames, p.abandoned_tail));
                let (retries, recoveries, max_busy_ms) = p.backpressure(Instant::now());
                if retries != 0 {
                    host_stat(format!("wan_media_backpressure retries={retries} recoveries={recoveries} max_busy_ms={max_busy_ms}"));
                }
                if even_dispatch {
                    host_stat(format!("wan_media_offer video_wire={} video_packets={} instant_ms={}",
                        stats.offer_video_wire, stats.offer_video_packets, timing_ms(Instant::now(),start)));
                }
                if fresh_recovery && p.recovery_video_drops()>0 {
                    host_stat(format!("{}_fresh_video instant_ms={} discarded={} age_ms=36",
                        if managed_lan {"lan"} else {"wan"},timing_ms(Instant::now(),start),p.recovery_video_drops()));
                }
                let (audio,control)=p.recovery_audio_and_control();
                if audio>0 {
                    host_stat(format!("wan_recovery_queue instant_ms={} audio_discarded={} control_admitted={}",
                        timing_ms(Instant::now(),start),audio,control));
                }
                #[cfg(all(windows, feature = "companion-soak"))]
                if even_dispatch {
                    host_stat(dispatch_stats.sample(timing_ms(Instant::now(),start)));
                }
                emit_tick = Instant::now();
            }
        }
        #[cfg(all(windows, feature = "companion-soak"))]
        if even_dispatch {
            let p = pacer.as_ref().unwrap();
            dispatch_stats.work(tick.elapsed(), p.pending_video_bytes());
            if !moved {
                let now = Instant::now();
                let pending = p.dispatch_wait(now);
                let requested = pending.unwrap_or(Duration::from_millis(1)).min(Duration::from_millis(1));
                if requested.is_zero() { continue; }
                let wake = short_wait.as_ref().map_or(short_wait::Wake::Failed, |wait| wait.wait_for(requested));
                // A timed-out kernel wait already gave the thread a chance
                // to be rescheduled. Recheck the deadline now, not after
                // a second, potentially coarse, Windows sleep.
                if matches!(wake, short_wait::Wake::Failed) {
                    std::thread::sleep(Duration::from_millis(1));
                }
                dispatch_stats.wait(requested, now.elapsed(), pending.is_some(), wake);
            }
            continue;
        }
        if !moved {
            #[cfg(all(target_env="ohos",feature="companion-soak"))]
            if rx_batch.as_mut().is_some_and(|b|b.wait(&peer.socket,&ports)){continue;}
            nap();
        }
    }
    #[cfg(feature = "companion-soak")]
    if let Some(audit) = &mut phone_frames { audit.flush(true, &host_stat); }
    #[cfg(all(windows,feature="companion-soak"))]
    if let Some(o)=&source_rx{o.report(true,&host_stat);}
    #[cfg(all(target_env="ohos",feature="phone-rx-trial"))]
    if standard_lan_offer {host_stat(format!("rx_ledger_gap_pair_end gaps={} matched={}",gap_pairs.gaps,gap_pairs.matched));}
    #[cfg(all(windows,feature="companion-soak"))]
    if managed_lan && stats.trace.is_some() {if let Some(o)=&stats.tx {o.clock_anchor(2,&host_stat);}}
    #[cfg(all(target_env="ohos",feature="companion-soak"))]
    if let Some(w)=&mut rx_window {w.sample(&peer.socket,&host_stat);}
    #[cfg(all(target_env="ohos",feature="companion-soak"))]
    if let Some(b)=&mut rx_batch {b.report(&peer.socket,&host_stat);}
    Ok(format!("stage=media_finished video_from_host={} control_from_host={} drops={} rejected={}",
               ports[0].recv, ports[1].recv, ports.iter().map(|x| x.drops).sum::<u64>(), rejected))
}

pub(crate) fn video_path_text(s: &VideoPathSample) -> String {
    format!("video_path stage={} ms={} packets={} event_gap={} peak_gap={} previous_frame={} frame={} loop_peak={}",
        s.stage,s.ms,s.packets,s.event_gap,s.peak_gap,s.previous_frame,s.frame,s.loop_peak)
}

pub(crate) fn host_logger() -> std::sync::mpsc::SyncSender<String> {
    // Never stall video pacing on a pipe or an unread diagnostic consumer.
    let (tx, rx) = std::sync::mpsc::sync_channel::<String>(96);
    std::thread::spawn(move || {
        while let Ok(row) = rx.recv() { println!("{row}"); }
    });
    tx
}

pub fn host(cfg: Params, wire_kbps: u32, native_desktop: bool) -> Result<String, &'static str> {
    if !(900..=MAX_TEST_WIRE_KBPS).contains(&wire_kbps) { return Err("media_wire_budget_rejected"); }
    let udp = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).map_err(|_| "media_host_bind_failed")?;
    let log = host_logger();
    run(udp, cfg, false, Some(wire_kbps), || println!("stage=host_media_wireguard_authenticated"),
        || false, Duration::from_secs(9), false, |_| {},
        |s| { let _ = log.try_send(video_path_text(s)); }, |row| { let _ = log.try_send(row); }, native_desktop,
        false, |_| {}, |epoch| epoch)
}

pub fn direct_host(udp: UdpSocket, endpoint: &str, private: [u8;32], public: &str,
                   wire_kbps: u32, native_desktop: bool) -> Result<String, &'static str> {
    if !(900..=MAX_TEST_WIRE_KBPS).contains(&wire_kbps) { return Err("media_wire_budget_rejected"); }
    let remote = public_endpoint(endpoint).ok_or("media_direct_endpoint_rejected")?;
    let hub = key(public).ok_or("media_direct_key_rejected")?;
    let log = host_logger();
    run(udp, Params { remote, private, hub }, false, Some(wire_kbps),
        || println!("stage=host_media_direct_authenticated"), || false, DIRECT_TIMEOUT, true,
        |s| println!("direct_path_diag tx={} tx_errors={} rx={} source_filtered={} non_handshake={} candidate_rx={} receive_network_errors={} authenticated={}",
            s.tx, s.tx_errors, s.rx, s.source_filtered, s.non_handshake, s.candidate_rx,
            s.receive_network_errors, s.authenticated),
        |s| { let _ = log.try_send(video_path_text(s)); }, |row| { let _ = log.try_send(row); }, native_desktop,
        false, |_| {}, |epoch| epoch)
}

#[cfg(feature = "lan-bench")]
pub fn lan_host(local: &str, remote: &str, secret: &str, public: &str, wire_kbps: u32, native_desktop: bool)
    -> Result<String, &'static str>
{
    lan_host_until(local,remote,secret,public,wire_kbps,native_desktop,||false)
}

#[cfg(feature = "lan-bench")]
pub fn lan_host_until(local: &str, remote: &str, secret: &str, public: &str, wire_kbps: u32, native_desktop: bool,
    stop:impl Fn()->bool) -> Result<String, &'static str>
{
    if !(1800..=72000).contains(&wire_kbps) { return Err("lan_wire_budget_rejected"); }
    let local = lan_endpoint(local).ok_or("lan_local_rejected")?;
    let remote = lan_endpoint(remote).filter(|r| same_lan(local, *r)).ok_or("lan_remote_rejected")?;
    let private = key(secret).ok_or("lan_key_rejected")?;
    let hub = key(public).ok_or("lan_key_rejected")?;
    let udp = UdpSocket::bind(local).map_err(|_| "lan_interface_bind_failed")?;
    let log = host_logger();
    run(udp, Params { remote, private, hub }, false, Some(wire_kbps),
        || println!("stage=host_media_lan_authenticated"), stop, Duration::from_secs(8),
        true, |_| {},
        |s| { let _ = log.try_send(video_path_text(s)); }, |row| { let _ = log.try_send(row); }, native_desktop,
        true, |_| {}, |epoch| epoch)
}

#[cfg(unix)]
#[no_mangle]
pub unsafe extern "C" fn sesame_direct_announce(fd: i32, token: *const [u8; 32], observer: *const std::ffi::c_char) -> i32 {
    use std::os::fd::FromRawFd;
    if fd < 0 || token.is_null() || observer.is_null() { return 2; }
    let Some(observer) = std::ffi::CStr::from_ptr(observer).to_str().ok().and_then(observer_endpoint) else { return 2; };
    let socket = std::mem::ManuallyDrop::new(UdpSocket::from_raw_fd(fd));
    if announce(&socket, &*token, observer).is_ok() { 0 } else { 2 }
}

#[cfg(unix)]
#[no_mangle]
pub unsafe extern "C" fn sesame_mapping_announce(fd: i32, token: *const [u8; 32], observer: *const std::ffi::c_char) -> i32 {
    use std::os::fd::FromRawFd;
    if fd < 0 || token.is_null() || observer.is_null() { return 2; }
    let Some(observer) = std::ffi::CStr::from_ptr(observer).to_str().ok().and_then(observer_endpoint) else { return 2; };
    let socket = std::mem::ManuallyDrop::new(UdpSocket::from_raw_fd(fd));
    if announce_mapping(&socket, &*token, observer).is_ok() { 0 } else { 2 }
}

#[cfg(unix)]
#[no_mangle]
pub(crate) unsafe extern "C" fn sesame_auto_media_phone(
    fd: i32, secret: *const [u8;32], public: *const std::ffi::c_char,
    endpoint: *const std::ffi::c_char, direct: i32, context: *const std::ffi::c_char,
    when_ready: extern "C" fn(*const std::ffi::c_char),
    cancelled: extern "C" fn() -> i32,
    report: extern "C" fn(*const DirectReport),
    video_report: extern "C" fn(*const VideoPathSample),
    bandwidth_report: extern "C" fn(*const Estimate),
    media_epoch: extern "C" fn(u32) -> u32,
    frame_counts: Option<extern "C" fn(*const std::ffi::c_char)>,
) -> i32 {
    use std::ffi::CStr;
    use std::os::fd::FromRawFd;
    if fd < 0 { return 2; }
    let socket = UdpSocket::from_raw_fd(fd);
    if secret.is_null() || public.is_null() || endpoint.is_null() || context.is_null() { return 2; }
    let Some(hub) = CStr::from_ptr(public).to_str().ok().and_then(key) else { return 2 };
    let Ok(endpoint) = CStr::from_ptr(endpoint).to_str() else { return 2; };
    let remote = match direct {
        0 | 1 => public_endpoint(endpoint),
        #[cfg(feature = "lan-bench")]
        2 => lan_endpoint(endpoint).filter(|r| socket.local_addr().is_ok_and(|l| {
            lan_endpoint(&l.to_string()).is_some() && same_lan(l, *r)
        })),
        _ => None,
    };
    let Some(remote) = remote else { return 2; };
    if direct == 0 && remote.port() != OBSERVER_PORT { return 2; }
    let timeout = match direct { 0 => Duration::from_secs(9), 2 => Duration::from_secs(8), _ => DIRECT_TIMEOUT };
    let cfg = Params { remote, private: *secret, hub };
    match run(socket, cfg, true, None, || when_ready(context), || cancelled() != 0, timeout, direct != 0,
              |s| report(s), |s| video_report(s), |row| {
                  if direct==2 && cfg!(feature="companion-soak") && row.starts_with("rx_ledger") {
                      if let Some(callback)=frame_counts {
                          if let Ok(line)=std::ffi::CString::new(row) { callback(line.as_ptr()); }
                      }
                  }
              }, false, direct==2, |s| bandwidth_report(s),
              |epoch| media_epoch(epoch)) {
        Ok(_) => 0,
        Err("media_peer_handshake_timeout") => 3,
        Err("media_cancelled") => 4,
        Err("media_direct_no_candidate_handshake") => 5,
        Err("media_direct_peer_unconfirmed") => 6,
        Err(_) => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn winsock_buffer_pressure_is_retryable_without_instrumentation() {
        assert!(retryable_udp_send(ErrorKind::Other,10055,true));
        assert!(retryable_udp_send(ErrorKind::WouldBlock,10035,true));
        assert!(retryable_udp_send(ErrorKind::Interrupted,4,false));
        assert!(!retryable_udp_send(ErrorKind::Other,10055,false));
        assert!(!retryable_udp_send(ErrorKind::NetworkUnreachable,10051,true));
    }
    #[test]
    fn packets_match_two_exact_endpoints_and_ports() {
        let mut wire = [0; HDR+MAX];
        let test = [88; MAX];
        let p = wrap(&mut wire, HOST, PHONE, 47998, &test).unwrap();
        assert_eq!(unwrap(p, HOST, PHONE), Some((0, test.as_slice())));
        assert!(unwrap(p, PHONE, HOST).is_none());
        assert!(unwrap(p, [0,0,0,0], PHONE).is_none());
        assert!(unwrap(&p[..HDR], HOST, PHONE).is_none());
        let unknown = wrap(&mut wire, HOST, PHONE, 53, &[1]).unwrap();
        assert!(unwrap(unknown, HOST, PHONE).is_none());
        assert!(wrap(&mut wire, HOST, PHONE, 47998, &[0; MAX+1]).is_none());
    }
    #[test]
    fn direct_endpoint_only_accepts_routable_ipv4() {
        for address in ["127.0.0.1:1245","192.168.0.1:2388","169.254.1.4:2388","100.64.2.3:2400",
                        "239.200.16.1:2388","192.0.2.12:2388","[::1]:2990","198.51.100.2:24"] {
            assert!(public_endpoint(address).is_none(), "{address}");
        }
    }
}
#[cfg(unix)]
#[no_mangle]
pub unsafe extern "C" fn sesame_valid_sunshine_endpoint(endpoint: *const std::ffi::c_char, direct: i32) -> i32 {
    if endpoint.is_null() { return 0; }
    let addr = std::ffi::CStr::from_ptr(endpoint).to_str().ok().and_then(public_endpoint);
    i32::from(addr.is_some_and(|p| direct != 0 || p.port() == OBSERVER_PORT))
}
