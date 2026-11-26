//! Public rendezvous for one pre-paired lab phone and Windows helper.
//! The broker gets only role-specific rendezvous keys, not the root or any
//! media key. Every path must still authenticate WireGuard and pinned TLS.
use crate::{companion_tcp::Sideband, media, observer_endpoint, public_endpoint, DirectReport, Params, Peer};
use boringtun::x25519::{PublicKey, StaticSecret};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::{
    io::{self, ErrorKind},
    net::{Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket},
    time::{Duration, Instant},
};
use zeroize::Zeroize;

const HELLO: u8 = 1;
const PROOF: u8 = 2;
const CHALLENGE: u8 = 3;
const OFFER: u8 = 4;
const DIRECT: u8 = 1;
const RELAY: u8 = 2;
const WIRE_CAP: u32 = 1800;
const SIZE: usize = 96;
type Signature = Hmac<Sha256>;

fn digest(key: &[u8; 32], fields: &[&[u8]]) -> [u8; 32] {
    let mut h = Signature::new_from_slice(key).expect("HMAC accepts fixed key");
    for f in fields { h.update(f); }
    h.finalize().into_bytes().into()
}

fn signed(role: u8, phase: u8, op: u8, nonce: &[u8; 16], cookie: &[u8; 16], cap: &[u8; 32]) -> [u8; SIZE] {
    let mut p = [0; SIZE];
    p[..4].copy_from_slice(b"SCB1");
    p[4..7].copy_from_slice(&[role, phase, op]);
    p[8..24].copy_from_slice(nonce);
    p[24..40].copy_from_slice(cookie);
    let mac = digest(cap, &[&p[..64]]);
    p[64..].copy_from_slice(&mac);
    p
}

struct Offer { peer: SocketAddr, nonce: [u8; 16] }

pub(crate) struct RelayRefresh {
    role:u8, nonce:[u8;16], ticket:zeroize::Zeroizing<[u8;32]>, next:Instant, waiting:Option<Instant>,
}

#[cfg(test)]
mod lease_tests {
    use super::*;
    #[test]
    fn ownership_heartbeat_has_no_credit_in_the_next_media_session() {
        let start=Instant::now()-Duration::from_secs(1);
        media::sesame_companion_live_renew();
        let now=Instant::now();
        assert!(media::live_since(start,now));
        assert!(!media::live_since(now+Duration::from_secs(1),now+Duration::from_secs(2)));
        assert!(!media::live_since(start,now+Duration::from_secs(46)));
    }
    #[test]
    fn relay_refresh_verifies_role_and_mac_without_blocking_media() {
        let server=UdpSocket::bind((Ipv4Addr::LOCALHOST,0)).unwrap();
        let client=UdpSocket::bind((Ipv4Addr::LOCALHOST,0)).unwrap();
        client.connect(server.local_addr().unwrap()).unwrap();
        server.set_nonblocking(true).unwrap();
        media::sesame_companion_live_renew();
        let now=Instant::now();let start=now-Duration::from_secs(1);
        let ticket=[9;32];let nonce=[7;16];
        let mut r=RelayRefresh{role:0,nonce,ticket:zeroize::Zeroizing::new(ticket),next:now,waiting:None};
        r.tick(&client,start,now);let mut buf=[0;SIZE];
        assert_eq!(server.recv_from(&mut buf).unwrap().0,SIZE);
        let mut p=signed(0,RELAY,CHALLENGE,&nonce,&[4;16],&ticket);
        p[64]^=1;r.receive(&client,&p,start,now);assert!(server.recv_from(&mut buf).is_err());
        r.receive(&client,&signed(1,RELAY,CHALLENGE,&nonce,&[4;16],&ticket),start,now);
        assert!(server.recv_from(&mut buf).is_err());
        p[64]^=1;r.receive(&client,&p,start,now);
        assert_eq!(server.recv_from(&mut buf).unwrap().0,SIZE);assert_eq!(buf[6],PROOF);
        r.receive(&client,&p,start,now);assert!(server.recv_from(&mut buf).is_err());
    }
}
impl RelayRefresh {
    pub(crate) fn tick(&mut self,s:&UdpSocket,start:Instant,now:Instant) {
        if now<self.next {return}
        self.next=now+Duration::from_secs(3);
        if !media::live_since(start,now) {return}
        if s.send(&signed(self.role,RELAY,HELLO,&self.nonce,&[0;16],&self.ticket)).is_ok(){
            self.waiting=Some(now); self.next=now+Duration::from_secs(20);
        }
    }
    pub(crate) fn receive(&mut self,s:&UdpSocket,p:&[u8],start:Instant,now:Instant) {
        if !self.waiting.is_some_and(|t|now.saturating_duration_since(t)<Duration::from_secs(3)) ||
            !media::live_since(start,now){return}
        // The socket is connected to the original broker. Also check its
        // role-specific MAC, the original nonce, and the fresh cookie.
        if let Some((CHALLENGE,cookie,None))=reply(p,self.role,RELAY,&self.nonce,&self.ticket) {
            self.waiting=None;
            let _=s.send(&signed(self.role,RELAY,PROOF,&self.nonce,&cookie,&self.ticket));
        }
    }
}

fn reply(p: &[u8], role: u8, phase: u8, nonce: &[u8; 16], cap: &[u8; 32]) -> Option<(u8, [u8; 16], Option<SocketAddr>)> {
    if p.len() != SIZE || &p[..4] != b"SCB1" || p[4..6] != [role, phase] || p[7] != 0 || p[8..24] != nonce[..] ||
        p[46..64].iter().any(|&b| b != 0) { return None; }
    let mut h = Signature::new_from_slice(cap).ok()?;
    h.update(&p[..64]);
    h.verify_slice(&p[64..]).ok()?;
    let data: [u8; 16] = p[24..40].try_into().ok()?;
    if !data.iter().any(|&b| b != 0) { return None; }
    match p[6] {
        CHALLENGE if p[40..46].iter().all(|&b| b == 0) => Some((CHALLENGE, data, None)),
        OFFER => {
            let ip = Ipv4Addr::from(<[u8; 4]>::try_from(&p[40..44]).ok()?);
            let addr = SocketAddrV4::new(ip, u16::from_be_bytes([p[44], p[45]]));
            let validated = public_endpoint(&addr.to_string())?;
            Some((OFFER, data, Some(validated)))
        }
        _ => None,
    }
}

fn temporary(error: &io::Error) -> bool {
    matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted | ErrorKind::TimedOut |
        ErrorKind::ConnectionReset | ErrorKind::ConnectionRefused | ErrorKind::HostUnreachable | ErrorKind::NetworkUnreachable)
}

fn join(socket: &UdpSocket, broker: SocketAddr, role: u8, phase: u8, nonce: &[u8;16], cap: &[u8;32],
        max: Duration, stop: &impl Fn() -> bool) -> Result<Offer, &'static str> {
    socket.set_read_timeout(Some(Duration::from_millis(85))).map_err(|_| "companion_broker_socket_failed")?;
    let start = Instant::now();
    let mut next_send = start;
    let mut cookie = [0; 16];
    let mut cookie_at = start;
    // Once one side learns its candidate it may send a WireGuard datagram
    // before the other side gets its offer. WinSock signals WSAEMSGSIZE for
    // truncated UDP. Ignore the early packet, not the observed socket/port.
    let mut packet = [0; 2048];
    while start.elapsed() < max {
        if stop() { return Err("media_cancelled"); }
        let now = Instant::now();
        if now >= next_send {
            if cookie_at.elapsed() > Duration::from_secs(2) { cookie.fill(0); }
            let op = if cookie == [0; 16] { HELLO } else { PROOF };
            if let Err(e) = socket.send_to(&signed(role, phase, op, nonce, &cookie, cap), broker) {
                if !temporary(&e) { return Err("companion_broker_network_error"); }
            }
            next_send = now + Duration::from_millis(225);
        }
        match socket.recv_from(&mut packet) {
            Ok((size, address)) if address == broker => match reply(&packet[..size], role, phase, nonce, cap) {
                Some((CHALLENGE, received, None)) => {
                    cookie = received;
                    cookie_at = Instant::now();
                    next_send = cookie_at;
                }
                Some((OFFER, fresh, Some(peer))) if cookie != [0;16] && peer != broker => return Ok(Offer { peer, nonce:fresh }),
                _ => (),
            },
            Ok(_) => (),
            Err(e) if e.raw_os_error() == Some(10040) => (), // WinSock oversized datagram
            Err(e) if temporary(&e) => (),
            Err(_) => return Err("companion_broker_network_error"),
        }
    }
    Err("companion_broker_no_peer")
}

fn keys(root: &[u8;32], role: u8, phase: u8, my: &[u8;16], other: &[u8;16]) -> ([u8;32], [u8;32]) {
    let (host, phone) = if role == 0 { (my, other) } else { (other, my) };
    let seed = |n| digest(root, &[b"sesame-companion/wg/v1", &[phase], host, phone, &[n]]);
    let mine = seed(role);
    let mut peer_seed = seed(1-role);
    let peer = PublicKey::from(&StaticSecret::from(peer_seed)).to_bytes();
    peer_seed.zeroize();
    (mine, peer)
}

fn establish(udp: UdpSocket, broker: SocketAddr, root: &[u8;32], role: u8, silent: bool,
             progress: impl Fn(i32), report: impl Fn(&DirectReport), stop: &impl Fn() -> bool)
             -> Result<(Peer, bool, Option<RelayRefresh>), &'static str> {
    let cap = zeroize::Zeroizing::new(digest(root, &[b"sesame-companion/broker/v1", &[role]]));
    let mut nonce = [0;16];
    getrandom::getrandom(&mut nonce).map_err(|_| "companion_rendezvous_random_failed")?;
    progress(1);
    let first = join(&udp, broker, role, DIRECT, &nonce, &cap, Duration::from_secs(if role == 0 { 35 } else { 9 }), stop)?;
    let (private, hub) = keys(root, role, DIRECT, &nonce, &first.nonce);
    let index = 401 + u32::from(role);
    let mut diag = DirectReport::default();
    let outcome = if silent {
        // Explicit acceptance fixture only: retain our real observed endpoint,
        // but simulate an unavailable direct path without touching firewall.
        let until = Instant::now() + Duration::from_millis(5100);
        let mut discard = [0; 1500];
        while Instant::now() < until {
            if stop() { return Err("media_cancelled"); }
            let _ = udp.recv(&mut discard);
        }
        Err("media_direct_no_candidate_handshake")
    } else {
        Peer::punch(udp.try_clone().map_err(|_| "companion_direct_clone_failed")?,
            Params { remote: first.peer, private, hub }, index, Duration::from_millis(4800), stop, &mut diag)
    };
    report(&diag);
    match outcome {
        Ok(peer) => return Ok((peer, false,None)),
        Err("media_direct_no_candidate_handshake") => progress(2),
        Err(e) => return Err(e),
    }
    progress(3);
    let relay = join(&udp, broker, role, RELAY, &nonce, &cap, Duration::from_secs(12), stop)?;
    let (private, hub) = keys(root, role, RELAY, &nonce, &relay.nonce);
    let refresh=RelayRefresh{role,nonce,ticket:cap,next:Instant::now()+Duration::from_secs(20),waiting:None};
    let mut peer = Peer::connect(udp, Params { remote:broker, private, hub }, index)
        .map_err(|_| "companion_relay_socket_failed")?;
    peer.handshake_for(Duration::from_secs(7), stop).map_err(|e| {
        if e.kind() == ErrorKind::Interrupted { "media_cancelled" } else { "companion_relay_not_authenticated" }
    })?;
    Ok((peer, true,Some(refresh)))
}

pub fn windows(broker: &str, root: &[u8;32], backend: u16, silent: bool, stop: impl Fn() -> bool)
    -> Result<String, &'static str> {
    let address = observer_endpoint(broker).ok_or("companion_broker_address_invalid")?;
    let udp = UdpSocket::bind((Ipv4Addr::UNSPECIFIED,0)).map_err(|_| "companion_broker_bind_failed")?;
    let (peer, relay, refresh) = establish(udp, address, root, 0, silent,
        |stage| match stage {
            1 => println!("stage=companion_host_public_wait"),
            2 => println!("stage=companion_host_direct_unreachable"),
            3 => println!("stage=companion_host_relay_attempt"),
            _ => (),
        }, |d| println!("companion_direct_diag tx={} rx={} candidate={} authenticated={}",
            d.tx,d.rx,d.candidate_rx,d.authenticated), &stop)?;
    let side = Sideband::new(false, backend)?;
    let log = media::host_logger();
    // Only this pinned, paired relay trial may request the larger train.
    // A successful public direct connection still uses its original policy.
    let cap=if cfg!(feature="companion-soak") && std::env::var("SESAME_COMPANION_STANDARD_WAN").as_deref()==Ok("1") {30_000}
        else if relay && cfg!(feature="companion-soak") &&
        std::env::var("SESAME_COMPANION_HIGH_RELAY").as_deref()==Ok("1") {8000} else {WIRE_CAP};
    media::run_authenticated(peer, false, Some(cap), || {
         println!("stage=companion_host_{}_authenticated", if relay { "relay" } else { "direct" });
    }, stop, |s| { let _ = log.try_send(media::video_path_text(s)); }, |row| { let _ = log.try_send(row); },
        true, false, |_| {}, |epoch| epoch, Some(side), relay, refresh)
}

#[cfg(unix)]
#[no_mangle]
pub(crate) unsafe extern "C" fn sesame_companion_wan_phone(
    fd: i32, root: *const [u8;32], broker: *const std::ffi::c_char, context: *const std::ffi::c_char,
    stage: extern "C" fn(*const std::ffi::c_char, i32, u16),
    cancelled: extern "C" fn() -> i32, report: extern "C" fn(*const DirectReport),
    video_report: extern "C" fn(*const media::VideoPathSample),
    bandwidth_report: extern "C" fn(*const media::CompanionEstimate), media_epoch: extern "C" fn(u32) -> u32,
    frame_report: extern "C" fn(*const std::ffi::c_char),
) -> i32 {
    use std::os::fd::FromRawFd;
    if fd < 0 { return 2; }
    let udp = UdpSocket::from_raw_fd(fd);
    if root.is_null() || broker.is_null() || context.is_null() { return 2; }
    let Some(server) = std::ffi::CStr::from_ptr(broker).to_str().ok().and_then(observer_endpoint) else { return 2 };
    let stop = || cancelled() != 0;
    let (peer, relay, refresh) = match establish(udp, server, &*root, 1, false, |n| stage(context,n,0),
        |s| report(s), &stop) {
        Ok(value) => value,
        Err("media_cancelled") => return 4,
        Err("media_direct_peer_unconfirmed" | "companion_relay_not_authenticated") => return 6,
        Err("companion_broker_no_peer" | "companion_broker_network_error") => return 5,
        Err(_) => return 2,
    };
    let Ok(side) = Sideband::new(true,0) else { return 2 };
    let port = side.port();
    match media::run_authenticated(peer, true, None, || stage(context, if relay { 5 } else { 4 }, port),
        stop, |s| video_report(s), |row| {
            if cfg!(feature = "companion-soak") && row.starts_with("rx_ledger") {
                if let Ok(line) = std::ffi::CString::new(row) { frame_report(line.as_ptr()); }
            }
        }, false, false, |s| bandwidth_report(s), |epoch| media_epoch(epoch), Some(side), relay, refresh) {
        Ok(_) => 0,
        Err("media_cancelled") => 4,
        Err(_) => 2,
    }
}
