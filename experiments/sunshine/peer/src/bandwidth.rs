//! Short downlink sampling on an already authenticated, purpose-limited tunnel.
use super::{unpack, wire_bytes, wrap, Peer, HDR, MAX};
use boringtun::noise::TunnResult;
use std::time::{Duration, Instant};

pub(super) const PORT: u16 = 48119;
const TAG: &[u8; 4] = b"SBW1";
const HEADER: usize = 24;
const DATA_BYTES: usize = 1148;
const PACKET_US: u32 = (wire_bytes(DATA_BYTES) * 8000) as u32;
const STEP_US: u32 = 300_000;
const HELLO: u8 = 1;
const ACK: u8 = 2;
const DATA: u8 = 3;
const END: u8 = 4;
const SAMPLE: u8 = 5;
const DONE: u8 = 6;
const DONE_ACK: u8 = 7;
pub(super) const PENDING: u32 = 1;
const CAPPED: u32 = 2;
const NETWORK_BOUND: u32 = 3;
const SENDER_BOUND: u32 = 4;
const INCONCLUSIVE: u32 = 5;
const WAN_MAX: u32 = 1800;
pub(super) const HIGH_RELAY: u32 = 8000;
pub(super) const STANDARD_WIRE: u32 = 30000;
const LAN_MAX: u32 = 72000;

#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
#[repr(C)]
pub(crate) struct Estimate {
    pub state: u32,
    pub good: u32,
    pub upper: u32,
    pub cap: u32,
}

#[derive(Clone, Copy)]
struct Message { kind: u8, step: u8, n: u16, cap: u32, rate: u32, span: u32, gap: u32 }

impl Message {
    fn new(kind: u8, cap: u32) -> Self { Self {kind,step:0,n:0,cap,rate:0,span:0,gap:0} }

    fn encode(self, out: &mut [u8;DATA_BYTES]) -> &[u8] {
        out[..4].copy_from_slice(TAG);
        out[4] = self.kind;
        out[5] = self.step;
        out[6..8].copy_from_slice(&self.n.to_be_bytes());
        out[8..12].copy_from_slice(&self.cap.to_be_bytes());
        out[12..16].copy_from_slice(&self.rate.to_be_bytes());
        out[16..20].copy_from_slice(&self.span.to_be_bytes());
        out[20..24].copy_from_slice(&self.gap.to_be_bytes());
        &out[..if self.kind == DATA { DATA_BYTES } else { HEADER }]
    }

    fn decode(p: &[u8]) -> Option<Self> {
        if p.len() < HEADER || p.get(..4)? != TAG || !(HELLO..=DONE_ACK).contains(&p[4])
            || p[5] >= 4 || p.len() != if p[4] == DATA { DATA_BYTES } else { HEADER } { return None; }
        let u32_at = |idx| u32::from_be_bytes(p[idx..idx+4].try_into().unwrap());
        Some(Self {kind:p[4], step:p[5], n:u16::from_be_bytes([p[6],p[7]]),
             cap:u32_at(8),rate:u32_at(12),span:u32_at(16),gap:u32_at(20)})
    }

    fn step_ok(self, local:bool) -> bool { self.rate == step_rate(self.cap,self.step,local) && self.rate != 0 }
}

fn cap_ok(cap: u32, local: bool) -> bool {
    if local { (1800..=LAN_MAX).contains(&cap) } else { (900..=WAN_MAX).contains(&cap) }
}
fn accept_probe(cap:u32,local:bool,authorized_relay:bool,paired_standard:bool)->bool {
    cap_ok(cap,local) || (!local && ((authorized_relay && cap==HIGH_RELAY) || (paired_standard && cap==STANDARD_WIRE)))
}
fn rate_at(cap: u32, i: u8) -> u32 { cap * (1 + u32::from(i)) / 4 }
fn step_rate(cap:u32,i:u8,local:bool)->u32 {
    if !local && cap==STANDARD_WIRE { [WAN_MAX,8000,27000,STANDARD_WIRE].get(i as usize).copied().unwrap_or(0) }
    else if !local && cap==HIGH_RELAY && i==0 { WAN_MAX } else { rate_at(cap,i) }
}

// Raise the media ceiling only after a completed, authenticated measurement.
// Missing/inconsistent samples and host timing failures keep the old budget.
pub(super) fn relay_plan(e:Estimate)->(u32,u32) {
    let valid=matches!(e.cap,HIGH_RELAY|STANDARD_WIRE) && e.good>=3600 && e.good<=e.cap &&
        (e.state==CAPPED || (e.state==NETWORK_BOUND && e.upper>e.good && e.upper<=e.cap));
    if !valid { return (WAN_MAX,1400); }
    let wire=(e.good*95/100)/100*100;
    let reserve=if e.cap==STANDARD_WIRE {1012} else {0};
    (wire,(wire*8/10-reserve)/50*50)
}
// The train leaves two percent for its bounded control traffic.
fn train(rate: u32) -> u32 { rate * 98 / 100 }
fn planned(rate: u32) -> u16 {
    (u64::from(STEP_US) * u64::from(train(rate)) / u64::from(PACKET_US)) as u16
}
fn micros(d: Duration) -> u32 { d.as_micros().min(u32::MAX as u128) as u32 }

fn grade(result: &mut Estimate, end: Message, ack: Message, local: bool) -> bool {
    if end.n == 0 || u32::from(end.n) * 100 < u32::from(planned(end.rate)) * 95 ||
        !(STEP_US..=STEP_US+35_000).contains(&end.span) {
        result.state = SENDER_BOUND;
        return false;
    }
    if ack.n > end.n { result.state = INCONCLUSIVE; return false; }
    if u32::from(ack.n) * 100 < u32::from(end.n) * 97 ||
        ack.span > end.span * 5 / 4 || ack.gap > if local { 55_000 } else { 125_000 } {
        result.state = NETWORK_BOUND;
        result.upper = end.rate;
        return false;
    }
    let goodput = u64::from(ack.n) * u64::from(PACKET_US) /
                  u64::from(end.span.max(ack.span).max(STEP_US));
    result.good = result.good.max((goodput as u32).min(end.rate));
    result.state = if end.step == 3 { CAPPED } else { INCONCLUSIVE };
    true
}

struct Link<'a> {
    peer: &'a mut Peer,
    src: [u8;4], dst: [u8;4],
    raw: [u8;2048], out: [u8;2048], wire: [u8; HDR+MAX], message: [u8;DATA_BYTES],
}

// Local trial evidence only. Accumulate duration at native precision; rounding each
// packet to microseconds would hide time spent in fast calls. Never log payloads.
#[derive(Clone,Copy,Default)]
struct Phase { total:Duration, peak:Duration }
impl Phase {
    fn add(&mut self,d:Duration) { self.total+=d; self.peak=self.peak.max(d); }
}
#[derive(Clone,Copy,Default)]
#[repr(usize)]
pub(super) enum WaitEnd { #[default] Signalled, Timeout, ArmFailed, WaitFailed, NoTimer }
#[derive(Clone,Copy,Default)]
pub(super) struct ProbeWait {
    pub end:WaitEnd, pub arm:Duration, pub kernel_wait:Duration, pub sleep:Duration,
}
impl ProbeWait {
    fn total(self)->Duration { self.arm+self.kernel_wait+self.sleep }
}
#[derive(Clone,Copy,Default)]
struct WakeTimes {
    counts:[u32;5], slow:[u32;5], peak:ProbeWait, sleep:Duration,
}
impl WakeTimes {
    fn add(&mut self,w:ProbeWait) {
        let i=w.end as usize;
        self.counts[i]+=1; self.slow[i]+=u32::from(w.total()>Duration::from_millis(5));
        if w.total()>=self.peak.total() {self.peak=w;}
        self.sleep+=w.sleep;
    }
    fn row(self,step:u8)->String {
        let [sig,to,arm,fail,none]=self.counts;
        let [ss,st,sa,sf,sn]=self.slow;
        format!("lan_probe_wake step={step} signal={sig} timeout={to} arm_fail={arm} wait_fail={fail} no_timer={none} slow_signal={ss} slow_timeout={st} slow_arm={sa} slow_fail={sf} slow_none={sn} sleep_us={} peak_kind={} peak_arm={} peak_wait={} peak_sleep={}",
            micros(self.sleep),self.peak.end as usize,micros(self.peak.arm),micros(self.peak.kernel_wait),micros(self.peak.sleep))
    }
}
#[derive(Clone,Copy,Default)]
struct SenderTimes {
    wait:Phase, seal:Phase, udp:Phase, waits:u32, waits_over_5ms:u32, attempts:u32,
    no_data:u32, would_block:u32, no_buffer:u32, other:u32, short:u32,
    wake:WakeTimes,
}
impl SenderTimes {
    fn did_wait(&mut self,d:Duration) {
        self.waits+=1; self.waits_over_5ms+=u32::from(d>Duration::from_millis(5)); self.wait.add(d);
    }
    fn udp_result(&mut self,r:&std::io::Result<usize>,size:usize) {
        match r {
            Ok(n) if *n==size=>(), Ok(_)=>self.short+=1,
            Err(e) if e.kind()==std::io::ErrorKind::WouldBlock=>self.would_block+=1,
            Err(e) if e.raw_os_error()==Some(10055)=>self.no_buffer+=1, // WSAENOBUFS
            Err(_)=>self.other+=1,
        }
    }
    fn row(&self,step:u8)->String {
        format!("lan_probe_sender step={} attempts={} no_data={} block={} no_buffer={} other={} short={} waits={} slow_waits={} wait_us={} wait_max={} seal_us={} seal_max={} udp_us={} udp_max={}",
            step,self.attempts,self.no_data,self.would_block,self.no_buffer,self.other,self.short,
            self.waits,self.waits_over_5ms,micros(self.wait.total),micros(self.wait.peak),
            micros(self.seal.total),micros(self.seal.peak),micros(self.udp.total),micros(self.udp.peak))
    }
}

impl<'a> Link<'a> {
    fn new(peer: &'a mut Peer,src:[u8;4],dst:[u8;4]) -> Self {
        Self {peer,src,dst,raw:[0;2048],out:[0;2048],wire:[0; HDR+MAX],message:[0;DATA_BYTES]}
    }
    fn send(&mut self, m: Message) -> bool {
        self.send_observed(m,None)
    }
    fn send_observed(&mut self,m:Message,mut trace:Option<&mut SenderTimes>)->bool {
        let start=trace.as_ref().map(|_|Instant::now());
        let packet = wrap(&mut self.wire,self.src,self.dst,PORT,m.encode(&mut self.message)).unwrap();
        let sealed=self.peer.tunnel.encapsulate(packet,&mut self.out);
        let before_udp=start.map(|a|{
            let b=Instant::now(); let t=trace.as_deref_mut().unwrap(); t.seal.add(b-a); t.attempts+=1; b
        });
        match sealed {
            TunnResult::WriteToNetwork(o) if o.first()==Some(&4) => {
                let r=self.peer.socket.send(o);
                if let (Some(t),Some(b))=(trace,before_udp) {t.udp.add(b.elapsed()); t.udp_result(&r,o.len());}
                r.is_ok_and(|n|n==o.len())
            }
            _ => { if let Some(t)=trace {t.no_data+=1;} false },
        }
    }
    fn incoming(&mut self) -> Option<Message> {
        for _ in 0..40 {
            let n=self.peer.socket.recv(&mut self.raw).ok()?;
            match self.peer.tunnel.decapsulate(Some(self.peer.hub_ip), &self.raw[..n], &mut self.out) {
                TunnResult::WriteToNetwork(o) => { let _ = self.peer.socket.send(o); }
                TunnResult::WriteToTunnelV4(o,_) => {
                    if let Some((PORT,p))=unpack(o,self.dst,self.src) {
                        if let Some(m)=Message::decode(p) { return Some(m); }
                    }
                }
                _ => {}
            }
        }
        None
    }
}

fn request(l: &mut Link<'_>, m: Message, want: u8, limit: Duration,
           stop: &impl Fn()->bool, nap: &impl Fn()) -> Option<Message> {
    let deadline=Instant::now()+limit;
    let mut send_at=Instant::now();
    while Instant::now()<deadline && !stop() {
        if Instant::now()>=send_at {
            l.send(m);
            send_at=Instant::now()+Duration::from_millis(75);
        }
        if let Some(r)=l.incoming() {
            if r.kind==want && r.cap==m.cap && r.step==m.step && r.rate==m.rate { return Some(r); }
        }
        nap();
    }
    None
}

fn step_observation(end:Message,reply:Option<Message>,state:u32)->String {
    let (received,rx_us,idle_us)=reply.map(|r|(r.n,r.span,r.gap)).unwrap_or_default();
    format!("lan_probe_step step={} rate={} planned={} sent={} tx_us={} ack={} received={} rx_us={} idle_us={} state={}",
            end.step,end.rate,planned(end.rate),end.n,end.span,u8::from(reply.is_some()),received,rx_us,idle_us,state)
}

pub(super) fn sample_downlink(peer:&mut Peer,src:[u8;4],dst:[u8;4],cap:u32,local:bool,
                              stop:&impl Fn()->bool,nap:&impl Fn(),
                              observe:Option<(&dyn Fn(String),&dyn Fn()->ProbeWait)>) -> Estimate {
    let high=!local && matches!(cap,HIGH_RELAY|STANDARD_WIRE);
    let mut cap=cap;
    let mut result=Estimate {state:INCONCLUSIVE,cap,..Estimate::default()};
    if !cap_ok(cap,local) && !high { return result; }
    let mut link=Link::new(peer,src,dst);
    if request(&mut link,Message::new(HELLO,cap),ACK,Duration::from_millis(if high {220} else {520}),stop,nap).is_none() {
        if !high || stop() { return result; }
        // A v1 phone ignores the new ceiling. Negotiate its original HELLO
        // inside the same authenticated tunnel before sending any train.
        cap=WAN_MAX; result.cap=cap;
        if request(&mut link,Message::new(HELLO,cap),ACK,Duration::from_millis(400),stop,nap).is_none() { return result; }
    }
    // Collect at most four completed steps. Do not print/format between paced trains.
    let mut observed=[None;4];
    for step in 0..4 {
        let rate=step_rate(cap,step,local);
        let count=planned(rate);
        let mut times=observe.map(|_|SenderTimes::default());
        let start=Instant::now();
        let mut n=0u16;
        while micros(start.elapsed()) < STEP_US && !stop() {
            let due=((u64::from(micros(start.elapsed())) * u64::from(train(rate))) /
                     u64::from(PACKET_US)) as u16;
            // Do not dump an old, accumulated train into the link on wake.
            let allowed=if local || cap==STANDARD_WIRE { ((train(rate)*2200/PACKET_US)+1).min(if local {22} else {8}) as u16 }
                        else if cap==HIGH_RELAY && rate>=6000 {2} else {1};
            let last=due.min(count).min(n.saturating_add(allowed));
            while n<last {
                if !link.send_observed(Message{kind:DATA,step,n,cap,rate,span:0,gap:0},times.as_mut()) { break; }
                n+=1;
            }
            if let (Some(t),Some((_,wait)))=(times.as_mut(),observe) {
                let w=wait(); t.did_wait(w.total()); t.wake.add(w);
            } else {nap();}
        }
        if stop() { break; }
        let end=Message{kind:END,step,n,cap,rate,span:micros(start.elapsed()),gap:0};
        let reply=request(&mut link,end,SAMPLE,Duration::from_millis(300),stop,nap);
        let pass=match reply {Some(r)=>grade(&mut result,end,r,local),
                              None=>{result.state=INCONCLUSIVE;false}};
        if let Some(t)=times { observed[step as usize]=Some((end,reply,result.state,t)); }
        if !pass { break; }
    }
    if request(&mut link,Message::new(DONE,cap),DONE_ACK,Duration::from_millis(170),stop,nap).is_none() {
        result.state=INCONCLUSIVE;
    }
    if let Some((report,_))=observe {
        for (end,reply,state,t) in observed.into_iter().flatten() {
            report(step_observation(end,reply,state)); report(t.row(end.step)); report(t.wake.row(end.step));
        }
    }
    result
}

#[derive(Default)]
struct Window {
    received: Vec<bool>, unique:u16, first:Option<Instant>, last:Option<Instant>, max_gap:u32,
    end:Option<(Message,Instant)>, reply:Option<Message>,
}

pub(super) fn receive_samples(peer:&mut Peer,src:[u8;4],dst:[u8;4],local:bool, allow_high_relay:bool, paired_standard:bool,
                              stop:&impl Fn()->bool,nap:&impl Fn()) -> Estimate {
    let mut link=Link::new(peer,src,dst);
    let mut result=Estimate {state:INCONCLUSIVE,..Estimate::default()};
    let mut windows: [Window;4]=Default::default();
    let mut deadline=Instant::now()+Duration::from_millis(720);
    let mut next_step=0u8;
    let mut finished=false;
    while Instant::now()<deadline && !stop() {
        while let Some(m)=link.incoming() {
            if Instant::now()>=deadline || stop() { break; }
            let may_lower=matches!(result.cap,HIGH_RELAY|STANDARD_WIRE) && m.cap==WAN_MAX && next_step==0 &&
                windows[0].received.is_empty() && windows[0].end.is_none();
            if m.kind==HELLO && accept_probe(m.cap,local,allow_high_relay,paired_standard) &&
                (result.cap==0 || result.cap==m.cap || may_lower) {
                if may_lower {result.cap=WAN_MAX;}
                if result.cap==0 {
                    result.cap=m.cap;
                    deadline=Instant::now()+Duration::from_millis(3600);
                }
                link.send(Message::new(ACK,m.cap));
                continue;
            }
            if result.cap==0 || m.cap!=result.cap { continue; }
            if m.kind==DONE {
                link.send(Message::new(DONE_ACK,m.cap));
                return result;
            }
            if !m.step_ok(local) { continue; }
            let w=&mut windows[m.step as usize];
            if let Some(r)=w.reply {
                if m.kind==END { link.send(r); }
                continue;
            }
            if finished || m.step!=next_step { continue; }
            let expected=planned(m.rate);
            if m.kind==DATA && m.n<expected {
                if w.received.is_empty() { w.received.resize(expected as usize,false); }
                if w.received[m.n as usize] { continue; }
                w.received[m.n as usize]=true;
                w.unique+=1;
                let now=Instant::now();
                w.first.get_or_insert(now);
                if let Some(last)=w.last { w.max_gap=w.max_gap.max(micros(now-last)); }
                w.last=Some(now);
            }
            if m.kind==END && m.n<=expected && w.end.is_none() {
                w.end=Some((m,Instant::now()+Duration::from_millis(56)));
            }
        }
        if next_step<4 {
            let w=&mut windows[next_step as usize];
            if let Some((end,due))=w.end {
                if w.reply.is_none() && Instant::now()>=due {
                    let span=match (w.first,w.last) { (Some(a),Some(b))=>micros(b-a),_=>0 };
                    let reply=Message {kind:SAMPLE,n:w.unique,span,gap:w.max_gap,..end};
                    let pass=grade(&mut result,end,reply,local);
                    w.reply=Some(reply);
                    link.send(reply);
                    next_step+=1;
                    finished=!pass || next_step==4;
                }
            }
        }
        nap();
    }
    if result.state==CAPPED { result.state=INCONCLUSIVE; }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn worst_wake_keeps_its_own_timer_result_and_fallback_duration() {
        let ms=Duration::from_millis;
        let mut t=WakeTimes::default();
        t.add(ProbeWait{end:WaitEnd::Timeout,arm:ms(1),kernel_wait:ms(4),sleep:ms(8)});
        t.add(ProbeWait{end:WaitEnd::Signalled,arm:ms(1),kernel_wait:ms(17),sleep:ms(0)});
        assert_eq!(t.counts,[1,1,0,0,0]); assert_eq!(t.slow,[1,1,0,0,0]);
        assert!(t.row(1).ends_with("sleep_us=8000 peak_kind=0 peak_arm=1000 peak_wait=17000 peak_sleep=0"));
    }
    #[test]
    fn sender_classifies_calls_without_logging_error_text() {
        let mut t=SenderTimes::default();
        for r in [Ok(10),Ok(3),Err(std::io::ErrorKind::WouldBlock.into()),
                  Err(std::io::Error::from_raw_os_error(10055)),Err(std::io::ErrorKind::Other.into())] {
            t.udp_result(&r,10);
        }
        t.did_wait(Duration::from_micros(5000)); t.did_wait(Duration::from_micros(17000));
        assert_eq!((t.short,t.would_block,t.no_buffer,t.other),(1,1,1,1));
        assert!(t.row(2).contains("waits=2 slow_waits=1 wait_us=22000 wait_max=17000"));
    }
    #[test]
    fn high_tier_is_scoped_and_measurement_gated() {
        assert!(!accept_probe(8000,false,false,true));
        assert!(accept_probe(8000,false,true,false) && accept_probe(1800,false,false,false));
        assert!(!accept_probe(8001,false,true,true));
        assert!(accept_probe(30000,false,false,true) && !accept_probe(30000,false,true,false));
        assert!(!accept_probe(30001,false,true,true));
        assert_eq!([0,1,2,3].map(|i|step_rate(30000,i,false)),[1800,8000,27000,30000]);
        assert_eq!(relay_plan(Estimate{state:CAPPED,cap:30000,good:28500,upper:0}),(27000,20550));
        assert!(relay_plan(Estimate{state:NETWORK_BOUND,cap:30000,good:26800,upper:30000}).1<20000);
        assert_eq!([0,1,2,3].map(|i|step_rate(8000,i,false)),[1800,4000,6000,8000]);
        assert_eq!(step_rate(8000,0,true),2000);
        let e=Estimate{state:CAPPED,good:7800,upper:0,cap:8000};
        assert_eq!(relay_plan(e),(7400,5900));
        assert_eq!(relay_plan(Estimate{state:NETWORK_BOUND,good:3800,upper:6000,..e}),(3600,2850));
        for rejected in [Estimate{state:SENDER_BOUND,..e}, Estimate{cap:1800,..e},
                         Estimate{good:1790,..e},Estimate{state:NETWORK_BOUND,upper:0,..e},
                         Estimate{state:INCONCLUSIVE,..e},Estimate{good:8001,..e}] {
            assert_eq!(relay_plan(rejected),(1800,1400));
        }
    }
    fn endpoint_stats(step: u8, cap: u32) -> (Message, Message) {
        let rate=rate_at(cap,step);
        let e=Message {kind:END,step,n:planned(rate),cap,rate,span:STEP_US,gap:0};
        (e,Message {kind:SAMPLE,gap:9000,..e})
    }

    #[test]
    fn passing_cap_is_lower_bound_not_exact_ceiling() {
        let mut r=Estimate::default();
        let (e,a)=endpoint_stats(3,1800);
        assert!(grade(&mut r,e,a,false));
        assert_eq!((r.state,r.upper),(CAPPED,0));
        assert!(r.good>=1700 && r.good<1800);
    }
    #[test]
    fn step_trace_distinguishes_missing_ack_from_measured_zero() {
        let (e,a)=endpoint_stats(0,34000);
        let absent=step_observation(e,None,INCONCLUSIVE);
        let zero=step_observation(e,Some(Message{n:0,span:0,gap:0,..a}),NETWORK_BOUND);
        assert!(absent.contains("ack=0 received=0 rx_us=0 idle_us=0 state=5"));
        assert!(zero.contains("ack=1 received=0 rx_us=0 idle_us=0 state=3"));
        let ok=step_observation(e,Some(a),INCONCLUSIVE);
        assert!(ok.starts_with("lan_probe_step step=0 rate=8500 planned="));
        assert!(ok.contains("rx_us=300000 idle_us=9000"));
    }
    #[test]
    fn packet_loss_or_spacing_sets_upper_test_rate_but_keeps_confirmed_lower() {
        let mut r=Estimate::default();
        let (e,a)=endpoint_stats(1,1800);
        assert!(grade(&mut r,e,a,false));
        let found=r.good;
        let (e,a)=endpoint_stats(2,1800);
        assert!(!grade(&mut r,e,Message{n:a.n-3,..a},false));
        assert_eq!((r.state,r.good,r.upper),(NETWORK_BOUND,found,1350));
        let (e,a)=endpoint_stats(3,72000);
        assert!(!grade(&mut r,e,Message{gap:60000,..a},true));
    }
    #[test]
    fn sender_underfill_is_not_reported_as_a_network_limit() {
        let mut r=Estimate::default();
        let (e,a)=endpoint_stats(3,40000);
        assert!(!grade(&mut r,Message{n:e.n/2,..e},Message{n:a.n/2,..a},true));
        assert_eq!((r.state,r.upper),(SENDER_BOUND,0));
        assert!(!cap_ok(40000,false));
    }
    #[test]
    fn packets_must_follow_size_and_step_contracts() {
        let mut buf=[0;DATA_BYTES];
        let m=Message{kind:DATA,step:3,rate:1800,..Message::new(DATA,1800)};
        let msg=m.encode(&mut buf);
        assert!(Message::decode(msg).unwrap().step_ok(false));
        assert!(Message::decode(&msg[..HEADER]).is_none());
        assert!(Message::decode(&msg[..HEADER-1]).is_none());
        let e=Message{kind:END,..m}.encode(&mut buf);
        assert!(Message::decode(e).unwrap().step_ok(false));
    }
}
