//! A fixed loopback-to-loopback TCP tunnel inside the authenticated carrier.
//! No system network adapter, requested destinations, or plaintext bypass.
use crate::{HOST, PHONE};
use smoltcp::{
    iface::{Config, Interface, SocketHandle, SocketSet},
    phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken},
    socket::tcp::{self, CongestionControl, State},
    time::{Duration, Instant},
    wire::{HardwareAddress, IpAddress, IpCidr, Ipv4Address},
};
use std::{
    collections::VecDeque,
    io::{self, Read, Write},
    net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream},
    time::{Duration as StdDuration, Instant as WallInstant},
};

const MTU: usize = 1024;
const BASE: u16 = 45100;
const CONNECTIONS: usize = 16;
const CLIENT_BASE: u16 = 51000;
const CLIENT_END: u16 = 61000;
const QUEUE: usize = 32;
pub const PACER_INDEX: usize = 4;

#[derive(Default)]
struct PacketDevice {
    incoming: VecDeque<Vec<u8>>,
    outgoing: VecDeque<Vec<u8>>,
}
struct Incoming(Vec<u8>);
struct Outgoing<'a>(&'a mut VecDeque<Vec<u8>>);
impl RxToken for Incoming {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R { f(&self.0) }
}
impl TxToken for Outgoing<'_> {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut packet = vec![0; len];
        let result = f(&mut packet);
        self.0.push_back(packet);
        result
    }
}
impl Device for PacketDevice {
    type RxToken<'a> = Incoming;
    type TxToken<'a> = Outgoing<'a>;
    fn receive(&mut self, _: Instant) -> Option<(Incoming, Outgoing<'_>)> {
        if self.outgoing.len() >= QUEUE { return None; }
        Some((Incoming(self.incoming.pop_front()?), Outgoing(&mut self.outgoing)))
    }
    fn transmit(&mut self, _: Instant) -> Option<Outgoing<'_>> {
        (self.outgoing.len() < QUEUE).then_some(Outgoing(&mut self.outgoing))
    }
    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = MTU;
        caps.max_burst_size = Some(4);
        caps
    }
}

struct Slot {
    handle: SocketHandle,
    stream: Option<TcpStream>,
    write_closed: bool,
}

pub(crate) struct Sideband {
    iface: Interface,
    device: PacketDevice,
    sockets: SocketSet<'static>,
    slots: Vec<Slot>,
    // The phone listener exists only while a pinned WireGuard lease is valid.
    listener: Option<TcpListener>,
    downstream: SocketAddr,
    next_port: u16,
    next_slot: usize,
    start: WallInstant,
}

impl Sideband {
    pub fn new(phone: bool, backend: u16) -> Result<Self, &'static str> {
        if !phone && backend < 1024 { return Err("companion_tcp_backend_invalid"); }
        let listener = if phone {
            let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|_| "companion_tcp_bind_failed")?;
            listener.set_nonblocking(true).map_err(|_| "companion_tcp_option_failed")?;
            Some(listener)
        } else { None };
        let seed = &mut [0; 8];
        getrandom::getrandom(seed).map_err(|_| "companion_tcp_seed_failed")?;
        let mut config = Config::new(HardwareAddress::Ip);
        config.random_seed = u64::from_le_bytes(*seed);
        let mut device = PacketDevice::default();
        let mut iface = Interface::new(config, &mut device, Instant::ZERO);
        let addr = IpAddress::Ipv4(Ipv4Address::from(if phone { PHONE } else { HOST }));
        iface.update_ip_addrs(|addrs| { let _ = addrs.push(IpCidr::new(addr, 24)); });
        let mut sockets = SocketSet::new(Vec::new());
        let mut slots = Vec::new();
        for index in 0..CONNECTIONS {
            let mut sock = tcp::Socket::new(tcp::SocketBuffer::new(vec![0; 8192]), tcp::SocketBuffer::new(vec![0; 8192]));
            sock.set_timeout(Some(Duration::from_secs(25)));
            sock.set_keep_alive(Some(Duration::from_secs(5)));
            sock.set_nagle_enabled(false);
            sock.set_ack_delay(Some(Duration::from_millis(6)));
            sock.set_congestion_control(CongestionControl::Reno);
            if !phone {
                sock.listen(BASE + index as u16).map_err(|_| "companion_tcp_listen_failed")?;
            }
            slots.push(Slot { handle: sockets.add(sock), stream: None, write_closed: false });
        }
        Ok(Self { iface, device, sockets, slots, listener, downstream: (Ipv4Addr::LOCALHOST, backend).into(),
            next_port: CLIENT_BASE, next_slot: 0, start: WallInstant::now() })
    }

    #[cfg(any(unix,test))]
    pub fn port(&self) -> u16 {
        self.listener.as_ref().and_then(|s| s.local_addr().ok()).map(|s| s.port()).unwrap_or(0)
    }

    pub fn admit(&mut self, raw: &[u8], src: [u8; 4], dst: [u8; 4]) -> bool {
        if raw.len() < 40 || raw.len() > MTU || raw[0] != 0x45 || raw[9] != 6 ||
            raw[6] & 0xBF != 0 || raw[7] != 0 || raw[12..16] != src || raw[16..20] != dst ||
            u16::from_be_bytes([raw[2], raw[3]]) as usize != raw.len() { return false; }
        let (a, b) = (u16::from_be_bytes([raw[20], raw[21]]), u16::from_be_bytes([raw[22], raw[23]]));
        let (client, server) = if self.listener.is_some() { (b, a) } else { (a, b) };
        if !(CLIENT_BASE..CLIENT_END).contains(&client) || !(BASE..BASE + CONNECTIONS as u16).contains(&server) {
            return false;
        }
        if self.device.incoming.len() < QUEUE { self.device.incoming.push_back(raw.to_vec()); }
        true
    }

    fn tune(stream: &TcpStream) -> io::Result<()> {
        stream.set_nonblocking(true)?;
        stream.set_nodelay(true)
    }

    pub fn tick(&mut self) {
        let now = Instant::from_millis(self.start.elapsed().as_millis() as i64);
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        if let Some(listener) = &self.listener {
            // RTSP may open several short-lived sockets back-to-back. Do not
            // immediately pick the same service while the far side is still
            // waiting for that connection's final TCP acknowledgement.
            let first = self.next_slot;
            for offset in 0..CONNECTIONS {
                let index = (first + offset) % CONNECTIONS;
                let slot = &mut self.slots[index];
                let tcp = self.sockets.get_mut::<tcp::Socket>(slot.handle);
                if tcp.is_open() || slot.stream.is_some() { continue; }
                let Ok((stream, addr)) = listener.accept() else { break; };
                if !addr.ip().is_loopback() || Self::tune(&stream).is_err() { continue; }
                let peer = (IpAddress::Ipv4(Ipv4Address::from(HOST)), BASE + index as u16);
                let port = self.next_port;
                self.next_port = CLIENT_BASE + (port + 1 - CLIENT_BASE) % (CLIENT_END - CLIENT_BASE);
                if tcp.connect(self.iface.context(), peer, port).is_ok() {
                    self.next_slot = (index + 1) % CONNECTIONS;
                    slot.stream = Some(stream);
                    slot.write_closed = false;
                }
            }
        }
        for (index, slot) in self.slots.iter_mut().enumerate() {
            let tcp = self.sockets.get_mut::<tcp::Socket>(slot.handle);
            if matches!(tcp.state(), State::Closed | State::TimeWait) {
                slot.stream = None;
                if self.listener.is_none() { let _ = tcp.listen(BASE + index as u16); }
                continue;
            }
            if self.listener.is_none() && slot.stream.is_none() && matches!(tcp.state(), State::Established | State::CloseWait) {
                let client = TcpStream::connect_timeout(&self.downstream, StdDuration::from_millis(80));
                match client {
                    Ok(io) if Self::tune(&io).is_ok() => {
                        slot.stream = Some(io);
                        slot.write_closed = false;
                    }
                    _ => tcp.abort(),
                }
            }
            let Some(stream) = slot.stream.as_mut() else { continue; };
            if tcp.can_send() {
                match tcp.send(|data| {
                    let read = stream.read(data);
                    (read.as_ref().copied().unwrap_or(0), read)
                }) {
                    Ok(Ok(0)) => tcp.close(),
                    Ok(Err(e)) if !recoverable(&e) => tcp.abort(),
                    _ => (),
                }
            }
            if tcp.can_recv() {
                if let Ok(Err(e)) = tcp.recv(|data| {
                    let wrote = stream.write(data);
                    (wrote.as_ref().copied().unwrap_or(0), wrote)
                }) {
                    if !recoverable(&e) { tcp.abort(); }
                }
            } else if !tcp.may_recv() && !slot.write_closed && !matches!(tcp.state(), State::SynSent | State::SynReceived) {
                let _ = stream.shutdown(Shutdown::Write);
                slot.write_closed = true;
            }
            if matches!(tcp.state(), State::Closed | State::TimeWait) { slot.stream = None; }
        }
        let _ = self.iface.poll_egress(now, &mut self.device, &mut self.sockets);
    }

    pub fn pop(&mut self) -> Option<Vec<u8>> { self.device.outgoing.pop_front() }
}

fn recoverable(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tcp_recovers_dropped_segment_and_reconnects_across_slots() {
        const TRIALS: usize = 21; // Cross a full round even with short TCP sessions.
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST,0)).unwrap();
        let mut host = Sideband::new(false,listener.local_addr().unwrap().port()).unwrap();
        let mut phone = Sideband::new(true,0).unwrap();
        let data: Vec<u8> = (0..2304).map(|i| (i % 252) as u8).collect();
        let expected = data.clone();
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let remote = std::thread::spawn(move || for _ in 0..TRIALS {
            let (mut client,_) = listener.accept().unwrap();
            client.set_read_timeout(Some(StdDuration::from_secs(5))).unwrap();
            let mut data = vec![0;2304];
            client.read_exact(&mut data).unwrap();
            client.write_all(&data).unwrap();
        });
        let port = phone.port();
        let local = std::thread::spawn(move || {
            for _ in 0..TRIALS {
                let mut conn = TcpStream::connect((Ipv4Addr::LOCALHOST,port)).unwrap();
                conn.set_read_timeout(Some(StdDuration::from_secs(6))).unwrap();
                conn.write_all(&data).unwrap();
                let mut answer = vec![0; data.len()];
                conn.read_exact(&mut answer).unwrap();
                assert_eq!(answer, data);
            }
            tx.send(data).unwrap();
        });
        let mut dropped = false;
        let end = WallInstant::now()+StdDuration::from_secs(7);
        let mut done = false;
        while WallInstant::now()<end {
            phone.tick();
            host.tick();
            while let Some(p) = phone.pop() {
                if !dropped && p.len()>100 { dropped = true; continue; }
                assert!(host.admit(&p,PHONE,HOST));
            }
            while let Some(p) = host.pop() { assert!(phone.admit(&p,HOST,PHONE)); }
            if let Ok(value) = rx.try_recv() {
                assert_eq!(value, expected);
                done = true;
                break;
            }
            std::thread::sleep(StdDuration::from_millis(2));
        }
        assert!(dropped && done);
        remote.join().unwrap();
        local.join().unwrap();
    }
}
