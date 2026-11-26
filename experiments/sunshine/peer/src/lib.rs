use boringtun::noise::{Packet, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use std::io;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

pub mod media;
#[cfg(feature = "companion-wan")]
mod companion_tcp;
#[cfg(feature = "companion-wan")]
pub mod companion_wan;
#[cfg(all(windows, feature = "companion-soak"))]
mod soak_trace;

const HOST: [u8; 4] = [198, 18, 20, 2];
const PHONE: [u8; 4] = [198, 18, 20, 3];
pub struct Params {
    remote: SocketAddr,
    private: [u8; 32],
    hub: [u8; 32],
}

fn key(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 || !s.bytes().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut out = [0; 32];
    for (i, p) in out.iter_mut().enumerate() {
        *p = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

pub fn params(value: &str) -> Option<Params> {
    let mut lines = value.lines();
    let remote = observer_endpoint(lines.next()?)?;
    let private = key(lines.next()?)?;
    let hub = key(lines.next()?)?;
    if lines.next().is_some() {
        return None;
    }
    Some(Params { remote, private, hub })
}

struct Peer {
    tunnel: Tunn,
    socket: UdpSocket,
    hub_ip: IpAddr,
}

#[repr(C)]
#[derive(Default)]
pub(crate) struct DirectReport {
    tx: u32,
    tx_errors: u32,
    rx: u32,
    source_filtered: u32,
    non_handshake: u32,
    candidate_rx: u32,
    receive_network_errors: u32,
    authenticated: u32,
}

// A datagram is not evidence of a handshake just because its first byte is
// 1 or 2. Use the WireGuard parser (size and reserved fields) before classifying
// a failure as a real candidate handshake that did not authenticate.
fn direct_candidate(bytes: &[u8], awaiting_confirmation: bool) -> bool {
    match Tunn::parse_incoming_packet(bytes) {
        Ok(Packet::HandshakeInit(_) | Packet::HandshakeResponse(_)) => true,
        Ok(Packet::PacketData(_)) => awaiting_confirmation,
        _ => false,
    }
}

fn direct_send(socket: &UdpSocket, bytes: &[u8], remote: SocketAddr,
               diag: &mut DirectReport) -> io::Result<usize> {
    let sent = socket.send_to(bytes, remote);
    if sent.is_ok() { diag.tx += 1; } else { diag.tx_errors += 1; }
    sent
}

impl Peer {
    fn connect(socket: UdpSocket, cfg: Params, index: u32) -> io::Result<Self> {
        socket.connect(cfg.remote)?;
        socket.set_read_timeout(Some(Duration::from_millis(80)))?;
        let tunnel = Tunn::new(StaticSecret::from(cfg.private), PublicKey::from(cfg.hub), None, None, index, None);
        Ok(Self { tunnel, socket, hub_ip: cfg.remote.ip() })
    }

    fn read(&mut self) -> io::Result<()> {
        let mut bytes = [0; 2048];
        let mut out = [0; 2048];
        let n = match self.socket.recv(&mut bytes) {
            Ok(n) => n,
            Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut |
                io::ErrorKind::Interrupted) => return Ok(()),
            Err(e) => return Err(e),
        };
        if let TunnResult::WriteToNetwork(p) = self.tunnel.decapsulate(Some(self.hub_ip), &bytes[..n], &mut out) {
            self.socket.send(p)?;
        }
        Ok(())
    }

    fn handshake_for(&mut self, limit: Duration, stop: impl Fn() -> bool) -> io::Result<()> {
        let start = Instant::now();
        let mut next = Duration::ZERO;
        let mut out = [0; 256];
        while start.elapsed() < limit {
            if stop() { return Err(io::ErrorKind::Interrupted.into()); }
            if start.elapsed() >= next {
                if let TunnResult::WriteToNetwork(p) = self.tunnel.format_handshake_initiation(&mut out, true) {
                    match self.socket.send(p) {
                        Err(e) if !matches!(e.kind(), io::ErrorKind::ConnectionReset | io::ErrorKind::ConnectionRefused) => return Err(e),
                        _ => (),
                    }
                }
                next += Duration::from_secs(2);
            }
            match self.read() {
                Err(e) if matches!(e.kind(), io::ErrorKind::ConnectionReset | io::ErrorKind::ConnectionRefused) =>
                    std::thread::sleep(Duration::from_millis(35)),
                Err(e) => return Err(e),
                Ok(_) => (),
            }
            if self.tunnel.time_since_last_handshake().is_some() {
                return Ok(());
            }
        }
        Err(io::ErrorKind::TimedOut.into())
    }

    // The observed public port can change for the same NAT peer when its
    // destination changes from the observer to us. Accept a changed source
    // port only after WireGuard authenticates the previously pinned peer key.
    // This tries one observed IP/port; it neither scans nor follows new IPs.
    fn punch(socket: UdpSocket, cfg: Params, index: u32, limit: Duration,
             stop: impl Fn() -> bool, diag: &mut DirectReport) -> Result<Self, &'static str> {
        socket.set_read_timeout(Some(Duration::from_millis(80)))
            .map_err(|_| "media_direct_socket_failed")?;
        let ip = cfg.remote.ip();
        let mut remote = cfg.remote;
        let mut tunnel = Tunn::new(StaticSecret::from(cfg.private), PublicKey::from(cfg.hub),
            None, None, index, None);
        let mut packet = [0; 1496];
        let mut out = [0; 2048];
        let start = Instant::now();
        let mut next = Duration::ZERO;
        let mut responder = None;
        while start.elapsed() < limit {
            if stop() { return Err("media_cancelled"); }
            if start.elapsed() >= next {
                if let TunnResult::WriteToNetwork(response) = tunnel.format_handshake_initiation(&mut out, true) {
                    match direct_send(&socket, response, remote, diag) {
                        Ok(_) => (),
                        Err(e) if matches!(e.kind(), io::ErrorKind::ConnectionRefused
                            | io::ErrorKind::ConnectionReset | io::ErrorKind::NetworkUnreachable
                            | io::ErrorKind::HostUnreachable) => (),
                        Err(_) => return Err("media_direct_socket_failed"),
                    }
                }
                next += Duration::from_millis(760);
            }
            let (n, source) = match socket.recv_from(&mut packet) {
                Ok(value) => value,
                Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    | io::ErrorKind::Interrupted) => continue,
                Err(e) if matches!(e.kind(), io::ErrorKind::ConnectionRefused | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::NetworkUnreachable | io::ErrorKind::HostUnreachable) => {
                    diag.receive_network_errors += 1;
                    continue;
                }
                Err(_) => return Err("media_direct_socket_failed"),
            };
            diag.rx += 1;
            if source.ip() != ip || source.port() < 1024 {
                diag.source_filtered += 1;
                continue;
            }
            // No forwarding is active yet. Decrypt/authenticate only the
            // handshake packet from the candidate IP, never its input data.
            if !direct_candidate(&packet[..n], responder == Some(source)) {
                diag.non_handshake += 1;
                continue;
            }
            diag.candidate_rx += 1;
            let result = tunnel.decapsulate(Some(ip), &packet[..n], &mut out);
            let proved = match result {
                // On the responding side BoringTun sets the active session
                // only once it decrypts the peer's confirmation keepalive.
                TunnResult::WriteToNetwork(response) if response.first() == Some(&2) => {
                    direct_send(&socket, response, source, diag).map_err(|_| "media_direct_socket_failed")?;
                    responder = Some(source);
                    false
                }
                TunnResult::WriteToNetwork(response) if response.first() == Some(&4) => {
                    direct_send(&socket, response, source, diag).map_err(|_| "media_direct_socket_failed")?;
                    true
                }
                TunnResult::Done | TunnResult::WriteToTunnelV4(_, _) if packet[0] == 4 => true,
                _ => false,
            };
            if proved && tunnel.time_since_last_handshake().is_some() {
                if source != remote {
                    remote = source;
                }
                socket.connect(remote).map_err(|_| "media_direct_socket_failed")?;
                diag.authenticated = 1;
                return Ok(Self { tunnel, socket, hub_ip: ip });
            }
        }
        Err(if diag.candidate_rx != 0 { "media_direct_peer_unconfirmed" } else { "media_direct_no_candidate_handshake" })
    }
}

#[cfg(test)]
mod direct_handshake_tests {
    use super::*;
    use std::sync::{Arc, Barrier};
    use std::thread;

    #[test]
    fn simultaneous_pinned_udp_handshake() {
        check_pair(false);
    }

    #[test]
    fn changed_source_port_needs_valid_wireguard_peer() {
        check_pair(true);
    }

    #[test]
    fn truncated_or_non_wireguard_data_does_not_count_as_peer_handshake() {
        assert!(!direct_candidate(&[1, 0, 0, 0], false));
        assert!(!direct_candidate(&[2, 0, 0, 0], false));
        assert!(!direct_candidate(&[4, 0, 0, 0], true));
        assert!(!direct_candidate(&[0; 148], false));
    }

    #[test]
    fn a_different_peer_key_cannot_open_direct() {
        let a = UdpSocket::bind("127.0.0.1:0").unwrap();
        let b = UdpSocket::bind("127.0.0.1:0").unwrap();
        let intended = StaticSecret::from([94;32]);
        let mut other = Tunn::new(StaticSecret::from([19;32]),
            PublicKey::from(&StaticSecret::from([17;32])), None, None, 11, None);
        let mut out = [0;256];
        let TunnResult::WriteToNetwork(handshake) = other.format_handshake_initiation(&mut out, true)
            else { panic!("test peer could not construct a handshake") };
        b.send_to(handshake, a.local_addr().unwrap()).unwrap();
        let cfg = Params { remote: b.local_addr().unwrap(), private: [17;32],
                           hub: *PublicKey::from(&intended).as_bytes() };
        let mut diag = DirectReport::default();
        assert!(matches!(
            Peer::punch(a, cfg, 10, Duration::from_millis(275), || false, &mut diag),
            Err("media_direct_peer_unconfirmed")
        ));
        assert_eq!(diag.candidate_rx, 1);
        assert_eq!(diag.authenticated, 0);
    }

    fn check_pair(changed: bool) {
        let a = UdpSocket::bind("127.0.0.1:0").unwrap();
        let b = UdpSocket::bind("127.0.0.1:0").unwrap();
        let stale = UdpSocket::bind("127.0.0.1:0").unwrap();
        let a_endpoint = a.local_addr().unwrap();
        let b_endpoint = b.local_addr().unwrap();
        let observed = if changed { stale.local_addr().unwrap() } else { b_endpoint };
        let pair = |remote, private, pub_seed| Params {
            remote, private,
            hub: *PublicKey::from(&StaticSecret::from(pub_seed)).as_bytes(),
        };
        let barrier = Arc::new(Barrier::new(2));
        let b_barrier = barrier.clone();
        let handle = thread::spawn(move || {
            b_barrier.wait();
            Peer::punch(b, pair(a_endpoint,[11;32],[23;32]), 22, Duration::from_secs(2), || false,
                &mut DirectReport::default()).is_ok()
        });
        barrier.wait();
        let mut diag = DirectReport::default();
        let peer = Peer::punch(a, pair(observed,[23;32],[11;32]), 21, Duration::from_secs(2), || false, &mut diag);
        assert_eq!(peer.unwrap_or_else(|e| panic!("{e}")).socket.peer_addr().unwrap(), b_endpoint);
        assert!(handle.join().unwrap());
        assert_eq!(diag.authenticated, 1);
        assert!(diag.tx != 0 && diag.rx != 0);
    }
}

const OBSERVER_PORT: u16 = 23388;

fn public_endpoint(value: &str) -> Option<SocketAddr> {
    let endpoint: std::net::SocketAddrV4 = value.parse().ok()?;
    let ip = endpoint.ip();
    let [a,b,_,_] = ip.octets();
    (endpoint.port() >= 1024 && a != 0 && a < 224 && !(a == 100 && (64..=127).contains(&b))
        && !(a == 198 && (b == 18 || b == 19)) && !ip.is_private() && !ip.is_link_local()
        && !ip.is_loopback() && !ip.is_documentation() && !ip.is_unspecified())
        .then_some(SocketAddr::V4(endpoint))
}

pub fn observer_endpoint(value: &str) -> Option<SocketAddr> {
    public_endpoint(value).filter(|addr| addr.port() == OBSERVER_PORT)
}

#[cfg(unix)]
#[no_mangle]
pub unsafe extern "C" fn sesame_wan_phone_public(private: *const [u8; 32], out: *mut [u8; 32]) -> i32 {
    if private.is_null() || out.is_null() { return 1; }
    *out = *PublicKey::from(&StaticSecret::from(*private)).as_bytes();
    0
}
