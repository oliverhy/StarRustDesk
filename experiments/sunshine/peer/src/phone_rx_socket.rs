//! Only the already authenticated, high-throughput LAN media socket on HarmonyOS.
//! No sysctl, privileged option, per-packet logging or change to the relay queue.
use super::phone_rx_headroom::{Action, Admission, Policy, Pressure};
use std::{mem::size_of_val, net::UdpSocket, os::fd::AsRawFd, time::Instant};

fn read_words<const N: usize>(socket: &UdpSocket, option: i32) -> Option<[u32; N]> {
    let mut words = [0u32; N];
    let mut length = size_of_val(&words) as libc::socklen_t;
    let ok = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            option,
            words.as_mut_ptr().cast(),
            &mut length,
        )
    };
    (ok == 0 && length as usize == size_of_val(&words)).then_some(words)
}

fn capacity(socket: &UdpSocket) -> Option<u32> {
    read_words::<1>(socket, libc::SO_RCVBUF).map(|w| w[0])
}
pub(super) fn drops(socket: &UdpSocket) -> Option<u32> {
    // OHOS NDK linux/sock_diag.h: SK_MEMINFO_DROPS is word 8; older kernels may decline.
    read_words::<9>(socket, libc::SO_MEMINFO).map(|w| w[8])
}
#[cfg(feature="phone-rx-trial")]
pub(super) fn usage_and_drops(socket:&UdpSocket)->Option<(Option<u32>,u32)> {
    let w=read_words::<9>(socket,libc::SO_MEMINFO)?;
    // Same sample as the counter. Report charged memory, never payload or peers.
    let pct=(w[1]!=0).then(||(u64::from(w[0])*100/u64::from(w[1])).min(100) as u32);
    Some((pct,w[8]))
}
pub(super) fn resident(socket: &UdpSocket) -> Option<(u32, u32)> {
    let w = read_words::<9>(socket, libc::SO_MEMINFO)?;
    (w[1] > 0).then_some((w[0], w[1])) // SK_MEMINFO_RMEM_ALLOC/RCVBUF, not bytes of useful video.
}
fn request_effective(socket: &UdpSocket, want: u32) -> Option<u32> {
    let request = libc::c_int::try_from(want / 2).ok()?;
    if unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            (&request as *const libc::c_int).cast(),
            size_of_val(&request) as libc::socklen_t,
        )
    } != 0
    {
        return None;
    }
    capacity(socket)
}
fn grow(socket: &UdpSocket, before: u32, want: u32) -> u32 {
    let actual = request_effective(socket, want).unwrap_or(before);
    if actual < before {
        request_effective(socket, before).unwrap_or(actual)
    } else {
        actual
    }
}

pub(super) struct Window {
    before: u32,
    effective: u32,
    initial_drops: Option<u32>,
    admission: Admission,
    since: Instant,
    bytes: u64,
    base: u32,
    policy: Policy,
    #[cfg(feature="phone-burst-margin")]
    margin:super::phone_burst_margin::Policy,
}
impl Window {
    pub fn qualified(&self) -> bool {
        self.admission.cause != 0
    }
    pub fn current_drops(&self, socket: &UdpSocket) -> Option<u32> {
        drops(socket)
    }
    pub fn new(socket: &UdpSocket, standard: bool) -> Option<Self> {
        let before = capacity(socket)?;
        let mut w = Self {
            before,
            effective: before,
            initial_drops: drops(socket),
            admission: Admission::default(),
            since: Instant::now(),
            bytes: 0,
            base: before,
            policy: Policy::default(),
            #[cfg(feature="phone-burst-margin")]
            margin:super::phone_burst_margin::Policy::default(),
        };
        if w.admission.offer(standard) { w.arm(socket); }
        #[cfg(feature="phone-rx-trial")]
        if standard && w.qualified() && w.initial_drops.is_some() && w.base < 1024*1024 {
            // The exact 20 Mbps paired LAN benchmark has overflowed its initial
            // half-MiB in repeated baselines. Start at its existing adaptive cap.
            w.effective=grow(socket,w.base,1024*1024);
            w.policy.preopened(w.base,w.effective);
        }
        Some(w)
    }
    fn arm(&mut self, socket: &UdpSocket) {
        // Linux reports twice the requested buffer. Never reduce an existing
        // larger buffer and do not override OS limits. Only the owned socket.
        if self.before < 512 * 1024 {
            self.effective = grow(socket, self.before, 512 * 1024);
        }
        self.base = self.effective;
        self.policy.seed(drops(socket));
    }
    pub fn received(&mut self, bytes: usize) {
        if !self.admission.high_rate_seen {
            self.bytes = self.bytes.saturating_add(bytes as u64);
        }
    }
    pub fn sample(&mut self, socket: &UdpSocket, emit: &impl Fn(String)) {
        let now = Instant::now();
        let ms = now.duration_since(self.since).as_millis() as u64;
        if !self.admission.high_rate_seen && ms >= 500 {
            if self.admission.observe(self.bytes, ms) { self.arm(socket); }
            self.since = now;
            self.bytes = 0;
        }
        let lost = drops(socket)
            .zip(self.initial_drops)
            .and_then(|(end, start)| end.checked_sub(start));
        emit(format!(
            "rx_ledger_socket before={} effective={} qualified={} drops={}",
            self.before,
            self.effective,
            u8::from(self.admission.high_rate_seen),
            lost.map(i64::from).unwrap_or(-1)
        ));
        if self.qualified() {
            emit(format!("rx_ledger_admission reason={} base={}", self.admission.cause, self.base));
        }
    }
    pub fn pressure(&mut self, socket: &UdpSocket, p: Pressure, sampled_drops: Option<u32>, emit: &impl Fn(String)) {
        #[cfg(feature="phone-burst-margin")]
        {
            use super::phone_burst_margin::{BASE,LIMIT,Decision};
            let old=self.effective;
            #[cfg(feature="phone-margin-comparison")]
            let action=if sampled_drops.is_some() && self.margin.offer_comparison(self.admission.cause==2,old,p) {
                emit("rx_ledger_margin_comparison=1".to_owned());
                Decision::Expand
            } else {self.margin.step(self.admission.cause==2,old,p,false)};
            #[cfg(not(feature="phone-margin-comparison"))]
            let action=self.margin.step(self.admission.cause==2,old,p,p.with_spare && sampled_drops.is_some());
            match action {
                Decision::Expand=>{
                    let mut value=grow(socket,old,LIMIT);
                    if value!=LIMIT && value!=old{
                        value=request_effective(socket,old).or_else(||capacity(socket)).unwrap_or(value);
                    }
                    self.effective=value;
                    self.margin.readback(true,value);
                    emit(format!("rx_ledger_margin state={} before={old} effective={value}",if value==LIMIT{1}else{3}));
                    if value!=LIMIT && value!=old {
                        // Do not continue this measurement with an unverified socket limit.
                        unsafe { libc::shutdown(socket.as_raw_fd(),libc::SHUT_RDWR); }
                    }
                    return
                }
                Decision::Revert=>{
                    self.effective=request_effective(socket,BASE).or_else(||capacity(socket)).unwrap_or(old);
                    self.margin.readback(false,self.effective);
                    emit(format!("rx_ledger_margin state={} before={old} effective={}",if self.effective==BASE{2}else{4},self.effective));
                    if self.effective!=BASE { unsafe { libc::shutdown(socket.as_raw_fd(),libc::SHUT_RDWR); } }
                    return
                }
                Decision::Keep if self.margin.active()=>return,
                Decision::Keep=>{}
            }
        }
        let action = self.policy.step(sampled_drops, p);
        let target = match action {
            Action::Grow if self.base < 1024 * 1024 => 1024 * 1024,
            Action::Restore if self.effective > self.base => self.base,
            Action::Hold => return,
            _ => {
                self.policy.refused();
                return;
            }
        };
        let old = self.effective;
        self.effective = if action == Action::Grow {
            grow(socket, old, target)
        } else {
            request_effective(socket, target).unwrap_or(old)
        };
        let state = if (action == Action::Grow && self.effective <= old)
            || (action == Action::Restore && self.effective != self.base)
        {
            self.policy.refused();
            3
        } else if action == Action::Grow {
            1
        } else {
            2
        };
        emit(format!(
            "rx_ledger_headroom state={state} base={} effective={}",
            self.base, self.effective
        ));
    }
}
