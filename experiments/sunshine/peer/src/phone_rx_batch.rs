//! Nonblocking, bounded drain of the paired phone's connected LAN socket.
//! It only supplies ciphertext to the existing WireGuard verifier. It neither decrypts nor routes it.
use super::phone_rx_evidence::Evidence;
use std::{
    io,
    mem::{size_of, size_of_val, zeroed},
    net::UdpSocket,
    os::fd::AsRawFd,
    ptr,
    time::Instant,
};

const N: usize = 24;
#[repr(align(8))]
#[derive(Clone, Copy)]
struct Control([u8; 64]);

fn micros(t: libc::timespec) -> Option<u64> {
    if t.tv_sec < 0 || !(0..1_000_000_000).contains(&t.tv_nsec) {
        return None;
    }
    (t.tv_sec as u64)
        .checked_mul(1_000_000)?
        .checked_add((t.tv_nsec as u64) / 1000)
}
fn clock(id: libc::clockid_t) -> Option<u64> {
    let mut t = unsafe { zeroed() };
    (unsafe { libc::clock_gettime(id, &mut t) } == 0)
        .then(|| micros(t))
        .flatten()
}
fn enable(s: &UdpSocket, option: i32) -> bool {
    let one = 1i32;
    unsafe {
        libc::setsockopt(
            s.as_raw_fd(),
            libc::SOL_SOCKET,
            option,
            (&one as *const i32).cast(),
            size_of_val(&one) as _,
        ) == 0
    }
}
fn metadata(h: &libc::msghdr, c: &Control) -> (Option<u64>, Option<u32>) {
    let mut stamp = None;
    let mut loss = None;
    if h.msg_flags & libc::MSG_CTRUNC != 0 {
        return (stamp, loss);
    }
    let used = (h.msg_controllen as usize).min(c.0.len());
    let align = size_of::<usize>();
    let align_up = |len: usize| (len + align - 1) & !(align - 1);
    let span = align_up(size_of::<libc::cmsghdr>());
    let mut at = 0;
    while used - at >= span {
        // Both lengths are kernel output; verify the complete object lies within our own array.
        let header = unsafe { ptr::read_unaligned(c.0.as_ptr().add(at).cast::<libc::cmsghdr>()) };
        let len = header.cmsg_len as usize;
        if len < span || len > used - at {
            break;
        }
        let body = unsafe { c.0.as_ptr().add(at + span) };
        if header.cmsg_level == libc::SOL_SOCKET {
            if header.cmsg_type == libc::SO_TIMESTAMPNS && len - span == size_of::<libc::timespec>()
            {
                stamp = micros(unsafe { ptr::read_unaligned(body.cast::<libc::timespec>()) });
            } else if header.cmsg_type == libc::SO_RXQ_OVFL && len - span == size_of::<u32>() {
                loss = Some(unsafe { ptr::read_unaligned(body.cast::<u32>()) });
            }
        }
        let step = align_up(len);
        if step > used - at {
            break;
        }
        at += step;
    }
    (stamp, loss)
}

pub(super) struct Batch {
    #[cfg(feature="phone-rx-trial")]
    stamps: [Option<super::phone_gap_pair::Stamp>; N],
    #[cfg(feature="phone-rx-trial")]
    pub(super) oldest_arrival:Option<u64>,
    #[cfg(feature="phone-rx-trial")]
    pub(super) read_call_us:Option<u64>,
    // Separate stable allocations; raw pointers in msgs refer only to these boxes, on this thread.
    data: Box<[[u8; 2048]]>,
    ctrl: Box<[Control]>,
    _iov: Box<[libc::iovec]>,
    msgs: Box<[libc::mmsghdr]>,
    next: usize,
    len: usize,
    disabled: bool,
    stamp_ok: bool,
    overflow_ok: bool,
    origin: Instant,
    last_check: Instant,
    measuring: Option<(Instant, Option<u64>)>,
    e: Evidence,
}
impl Batch {
    #[cfg(feature="phone-rx-trial")]
    pub fn last_stamp(&self)->Option<super::phone_gap_pair::Stamp> {
        if self.disabled {None} else {self.next.checked_sub(1).and_then(|i|self.stamps[i])}
    }
    #[cfg(feature="phone-rx-trial")]
    pub fn remaining(&self) -> usize { self.len - self.next }
    pub fn new(socket: &UdpSocket, initial_drops: Option<u32>) -> Self {
        let mut data = vec![[0; 2048]; N].into_boxed_slice();
        let mut ctrl = vec![Control([0; 64]); N].into_boxed_slice();
        let mut iov = (0..N)
            .map(|i| libc::iovec {
                iov_base: data[i].as_mut_ptr().cast(),
                iov_len: 2048,
            })
            .collect::<Vec<_>>()
            .into_boxed_slice();
        let msgs = (0..N)
            .map(|i| {
                // mmsghdr is plain C storage; no source address is requested on this connected socket.
                let mut h: libc::mmsghdr = unsafe { zeroed() };
                h.msg_hdr.msg_iov = &mut iov[i];
                h.msg_hdr.msg_iovlen = 1;
                h.msg_hdr.msg_control = ctrl[i].0.as_mut_ptr().cast();
                h.msg_hdr.msg_controllen = 64;
                h
            })
            .collect::<Vec<_>>()
            .into_boxed_slice();
        let mut e = Evidence::new();
        e.seed_drop(initial_drops);
        let now = Instant::now();
        Self {
            #[cfg(feature="phone-rx-trial")]
            stamps:[None;N],
            #[cfg(feature="phone-rx-trial")]
            oldest_arrival:None,
            #[cfg(feature="phone-rx-trial")]
            read_call_us:None,
            data,
            ctrl,
            _iov: iov,
            msgs,
            next: 0,
            len: 0,
            disabled: false,
            stamp_ok: enable(socket, libc::SO_TIMESTAMPNS),
            overflow_ok: enable(socket, libc::SO_RXQ_OVFL),
            origin: now,
            last_check: now,
            measuring: None,
            e,
        }
    }
    fn finish_work(&mut self) {
        if let Some((t, cpu)) = self.measuring.take() {
            self.e.work(
                t.elapsed().as_micros() as u64,
                cpu.and_then(|old| clock(libc::CLOCK_THREAD_CPUTIME_ID)?.checked_sub(old)),
            );
        }
    }
    pub fn next<'a>(
        &'a mut self,
        s: &UdpSocket,
        scratch: &'a mut [u8; 2048],
    ) -> io::Result<&'a [u8]> {
        loop {
            if self.next < self.len {
                let i = self.next;
                self.next += 1;
                let len = self.msgs[i].msg_len as usize;
                if self.msgs[i].msg_hdr.msg_flags & libc::MSG_TRUNC != 0 || len > 2048 {
                    continue;
                } // never pass a partial datagram
                return Ok(&self.data[i][..len]);
            }
            self.finish_work();
            if self.disabled {
                return s.recv(scratch).map(|n| &scratch[..n]);
            }
            for h in self.msgs.iter_mut().take(self.len) {
                h.msg_hdr.msg_controllen = 64;
                h.msg_hdr.msg_flags = 0;
                h.msg_len = 0;
            }
            self.next = 0;
            self.len = 0;
            let now = Instant::now();
            let gap = now.duration_since(self.last_check).as_micros() as u64;
            self.last_check = now;
            self.e.awake_gap = self.e.awake_gap.max(gap);
            // MSG_DONTWAIT + null timeout returns whatever is ready; NEVER wait for a full batch.
            #[cfg(feature="phone-rx-trial")]
            let io_start=super::phone_ingress_watch::tick();
            let n = unsafe {
                libc::recvmmsg(
                    s.as_raw_fd(),
                    self.msgs.as_mut_ptr(),
                    N as _,
                    libc::MSG_DONTWAIT as _,
                    ptr::null_mut(),
                )
            };
            // Preserve errno before obtaining a timestamp through another API.
            let read_error=(n<0).then(io::Error::last_os_error);
            #[cfg(feature="phone-rx-trial")]
            {self.read_call_us=Some(super::phone_ingress_watch::tick().saturating_sub(io_start));}
            if let Some(err)=read_error {
                if matches!(
                    err.raw_os_error(),
                    Some(libc::ENOSYS | libc::EOPNOTSUPP | libc::EPERM | libc::EINVAL)
                ) {
                    self.disabled = true;
                    continue;
                }
                return Err(err);
            }
            if n == 0 {
                return Err(io::ErrorKind::WouldBlock.into());
            }
            self.len = n as usize;
            self.e.calls += 1;
            self.e.full += u64::from(self.len == N);
            #[cfg(feature="phone-rx-trial")]
            let read_mark=Instant::now();
            let rtc = clock(libc::CLOCK_REALTIME).filter(|r| {
                self.e
                    .clock_ok(*r, self.origin.elapsed().as_micros() as u64)
            });
            #[cfg(feature="phone-rx-trial")]
            let timed_rtc=rtc.filter(|_| read_mark.elapsed().as_micros()<=250);
            if self.len >= 8 {
                self.measuring = Some((Instant::now(), clock(libc::CLOCK_THREAD_CPUTIME_ID)));
            }
            let loss_before = self.e.drop_signal;
            #[cfg(feature="phone-rx-trial")]
            let mono_after=super::phone_ingress_watch::tick();
            for i in 0..self.len {
                let (stamp, loss) = metadata(&self.msgs[i].msg_hdr, &self.ctrl[i]);
                #[cfg(feature="phone-rx-trial")]
                {self.stamps[i]=timed_rtc.zip(stamp).filter(|(r,s)|*s>0 && *s<=*r && r-s<=2_000_000)
                    .map(|(read_wall,kernel)|super::phone_gap_pair::Stamp{kernel,read_wall,read:read_mark});}
                #[cfg(feature="phone-rx-trial")]
                if let Some(age)=rtc.zip(stamp).and_then(|(r,s)|if s>0 {r.checked_sub(s)}else{None}).filter(|&n|n<=2_000_000) {
                    let a=mono_after.saturating_sub(age).saturating_add(10);
                    self.oldest_arrival=Some(self.oldest_arrival.map_or(a,|x|x.min(a)));
                }
                self.e.packet(stamp, rtc, loss, gap);
            }
            // Sample the remaining kernel queue AFTER draining; inherently a lower bound on the peak.
            if (self.len == N && self.e.full % 8 == 1) || self.e.drop_signal != loss_before {
                if let Some((used, limit)) = super::phone_rx_socket::resident(s) {
                    self.e.mem_samples += 1;
                    self.e.mem_peak = self.e.mem_peak.max(used);
                    self.e.mem_percent = self
                        .e
                        .mem_percent
                        .max((u64::from(used) * 100 / u64::from(limit)) as u32);
                }
            }
        }
    }
    pub fn wait(&mut self, s: &UdpSocket, ports: &[super::MediaSocket]) -> bool {
        if self.disabled || self.next < self.len {
            return false;
        }
        let mut fds = [libc::pollfd {
            fd: -1,
            events: libc::POLLIN,
            revents: 0,
        }; 5];
        fds[0].fd = s.as_raw_fd();
        for (d, p) in fds[1..].iter_mut().zip(ports) {
            d.fd = p.udp.as_raw_fd();
        }
        let t = Instant::now();
        let res = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, 1) };
        self.e.waited(t.elapsed().as_micros() as u64);
        res >= 0
            && fds
                .iter()
                .all(|f| f.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) == 0)
    }
    pub fn report(&mut self, emit: &impl Fn(String)) -> super::phone_rx_headroom::Pressure {
        let e = self.e.roll();
        emit(format!("rx_ledger_burst t={} active={} ts={} ov={} packets={} stamped={} calls={} full={} burst={} age={} aged={} bad={} loss={} lossburst={} lossage={} lossgap={} turn={} probes={} service={} cpu={} offcpu={} slowwait={} waitover={} mem={} mempeak={} mempct={}",
            self.origin.elapsed().as_millis(),u8::from(!self.disabled),self.stamp_ok as u8,self.overflow_ok as u8,
            e.packets,e.stamps,e.calls,e.full,e.peak_burst,e.peak_age,e.aged,e.bad,e.drop_signal,e.step_burst,e.step_age,
            e.step_last_gap,e.awake_gap,e.probes,e.service_wall,e.service_cpu,e.offcpu,e.slow_polls,e.poll_over,
            e.mem_samples,e.mem_peak,e.mem_percent));
        super::phone_rx_headroom::Pressure {
            #[cfg(feature="phone-burst-margin")]
            with_spare:false,
            packets: e.packets,
            stamped: e.stamps,
            aged: e.aged,
            burst: e.peak_burst,
            age_us: e.peak_age,
        }
    }
}
