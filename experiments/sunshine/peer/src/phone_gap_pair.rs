//! Debug LAN only. Keep the previous authenticated video endpoint, not its data.
use std::time::Instant;

#[derive(Clone, Copy)]
pub(super) struct Stamp {
    pub kernel: u64, // temporary realtime microseconds; never exported
    pub read_wall: u64,
    pub read: Instant, // sampled just after a successful batch read
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, time::Duration};

    fn sample(start: Instant, read_ms: u64, age_ms: u64) -> Stamp {
        let read_wall = 1_000_000 + read_ms * 1000;
        Stamp { kernel: read_wall - age_ms * 1000, read_wall, read: start + Duration::from_millis(read_ms) }
    }
    fn packet(counter:u64)->[u8;16] {
        let mut h=[0;16]; h[0]=4; h[8..16].copy_from_slice(&counter.to_le_bytes()); h
    }
    #[test]
    fn compares_the_same_adjacent_survivors_in_three_clock_domains() {
        let s=Instant::now(); let mut pairs=Pairs::default(); let rows=RefCell::new(Vec::new());
        let emit=|m|rows.borrow_mut().push(m);
        pairs.video(19,&packet(55),Some(sample(s,0,3)),s+Duration::from_millis(2),s,&emit);
        pairs.video(19,&packet(59),Some(sample(s,200,30)),s+Duration::from_millis(205),s,&emit);
        assert_eq!((pairs.gaps,pairs.matched),(1,1));
        assert_eq!(&rows.borrow()[0],"rx_ledger_gap_pair ms=205 f0=19 f1=19 c0=55 c1=59 auth=203000 kernel=173000 read=200000 q0=3000 q1=30000 p0=2000 p1=5000");
    }
    #[test]
    fn neither_skips_an_unstamped_neighbor_nor_accepts_a_clock_step() {
        let s=Instant::now(); let mut pairs=Pairs::default(); let emit=|_|panic!("unexpected pair");
        for (t,ok) in [(0,true),(200,false),(400,true),(600,true)] {
            let mut stamp=sample(s,t,3);
            if t==600 {stamp.read_wall+=2000;stamp.kernel+=2000;}
            pairs.video(1,&packet(t),ok.then_some(stamp),stamp.read,s,&emit);
        }
        assert_eq!((pairs.gaps,pairs.matched),(3,0));
    }
    #[test]
    fn rejects_other_headers_and_bounds_diagnostic_volume() {
        let s=Instant::now(); let mut pairs=Pairs::default();
        for n in 0..70 {
            let stamp=sample(s,150*n,3);
            let h=if n==0 {[1;16]} else {packet(n)};
            pairs.video(8,&h,Some(stamp),stamp.read,s,&|_|());
        }
        assert_eq!((pairs.gaps,pairs.matched),(69,63));
    }
}
#[derive(Clone, Copy)]
struct Endpoint { frame: u32, counter: u64, stamp: Stamp, auth: Instant }
#[derive(Default)]
pub(super) struct Pairs {
    last: Option<Endpoint>,
    last_video: Option<Instant>,
    pub gaps: u32,
    pub matched: u32,
}
impl Pairs {
    pub fn video(&mut self, frame:u32, packet:&[u8], stamp:Option<Stamp>, at:Instant, start:Instant,
                 emit:&impl Fn(String)) {
        let counter=packet.get(..16).filter(|h|h[..4]==[4,0,0,0])
            .map(|h|u64::from_le_bytes(h[8..16].try_into().unwrap()));
        let current=stamp.zip(counter).map(|(stamp,counter)|Endpoint{frame,counter,stamp,auth:at});
        // An unstamped endpoint invalidates the pair; never jump over it.
        let last=std::mem::replace(&mut self.last,current);
        let Some(prev)=self.last_video.replace(at) else {return};
        if at.saturating_duration_since(prev).as_millis()<140 {return}
        self.gaps=self.gaps.saturating_add(1);
        if self.gaps>64 {return}
        let Some((a,b))=last.zip(current) else {return};
        let (x,y)=(a.stamp,b.stamp);
        let Some(q0)=x.read_wall.checked_sub(x.kernel) else {return};
        let Some(q1)=y.read_wall.checked_sub(y.kernel) else {return};
        let Some(kernel)=y.kernel.checked_sub(x.kernel) else {return};
        let Some(wall)=y.read_wall.checked_sub(x.read_wall) else {return};
        let Some(read)=y.read.checked_duration_since(x.read) else {return};
        let (Some(post0),Some(post1))=(a.auth.checked_duration_since(x.read),b.auth.checked_duration_since(y.read)) else {return};
        let read=read.as_micros() as u64;
        // A stepped realtime clock, stale buffer, or extreme stall is unknown.
        if read.abs_diff(wall)>1000 || q0.max(q1)>2_000_000 || kernel>10_000_000 ||
            post0.max(post1).as_micros()>2_000_000 || at.duration_since(prev).as_secs()>=10 {return}
        self.matched+=1;
        emit(format!("rx_ledger_gap_pair ms={} f0={} f1={} c0={} c1={} auth={} kernel={} read={} q0={} q1={} p0={} p1={}",
            at.duration_since(start).as_millis(),a.frame,b.frame,a.counter,b.counter,
            at.duration_since(prev).as_micros(),kernel,read,q0,q1,post0.as_micros(),post1.as_micros()));
    }
}
