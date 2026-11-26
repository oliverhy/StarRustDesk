"""Match numeric authenticated-receive/local-handoff progress to decoder stalls on one phone clock."""
import re

DAY=86400000
GUARD=20
STAMP=re.compile(r'(\d\d):(\d\d):(\d\d)\.(\d{3,6})')
PATH=re.compile(r'video_path stage=([23]) ms=(\d+) packets=(\d+) event_gap=0 peak_gap=(\d+) previous_frame=0 frame=(\d+) loop_peak=\d+')


def stamp(text):
    if not isinstance(text,str):return None
    m=STAMP.fullmatch(text)
    if not m:return None
    h,mi,s=map(int,m.groups()[:3])
    return ((h*60+mi)*60+s)*1000+int(m[4][:3]) if h<24 and mi<60 and s<60 else None


def relative(t,end):
    return (t-end+DAY//2)%DAY-DAY//2


def calibrated(rows):
    # Device hilog timestamps vs each producer's monotonic clock. A clock
    # step, reordering or a delayed log => do not pair that neighbourhood.
    return len(rows)>=2 and all(0<b[0]-a[0] and 0<b[1]-a[1] and
        abs((b[0]-a[0])-(b[1]-a[1]))<=GUARD//2 for a,b in zip(rows,rows[1:]))


def correlate(epoch, path):
    gs=epoch.get('gap_stamps',[]); ge=epoch['gap_events']
    ss=epoch.get('sample_stamps',[]); sm=epoch.get('samples',[])
    if len(gs)!=len(ge) or len(ss)!=len(sm):return {}
    gaps=[(stamp(t),r) for t,r in zip(gs,ge) if len(r)==9]
    received={2:[],3:[]}
    for t,line in path:
        m=PATH.fullmatch(line); dt=stamp(t)
        if m and dt is not None:
            stage,ms,n,peak,frame=map(int,m.groups())
            received[stage].append((dt,ms,n,peak,frame))
    decoded=[(stamp(t),r[0],tuple(r[1:4])) for t,r in zip(ss,sm) if len(r)>=4 and stamp(t) is not None]
    out={}
    for end,r in gaps:
        if end is None or r[4]<140 or not (r[1]<r[2] and r[2]-r[1]-1==r[3]):continue
        gap=r[4]
        if not calibrated([(relative(t,end),v[0]) for t,v in gaps if t is not None
                           and abs(relative(t,end))<=30000]):continue
        def neighbourhood(rows):
            return [(relative(v[0],end),*v[1:]) for v in rows if -gap-5000<=relative(v[0],end)<=5000]
        def interior(rows):
            xs=neighbourhood(rows)
            return [v for v in xs if -gap+GUARD<=v[0]<=-GUARD] if calibrated(xs) else []
        auth,local=interior(received[2]),interior(received[3])
        # Require both stages reporting the same frame and counters in the
        # same sampler tick, not two nearby events from different frames.
        ticks=[]
        for v in local:
            match=[u for u in auth if u[2]==v[2] and u[4]==v[4] and abs(u[0]-v[0])<=8 and abs(u[1]-v[1])<=8]
            if len(match)==1:ticks.append((v[0],v[2],v[4],match[0][3]))
        if not ticks:continue
        progressed=max((v for v in ticks if r[1]<v[2]<r[2]),key=lambda v:v[2],default=None)
        unchanged=max((b[0]-a[0] for a,b in zip(ticks,ticks[1:]) if b[1:3]==a[1:3]),default=0)
        dec=interior(decoded)
        flat=max((b[0]-a[0] for a,b in zip(dec,dec[1:]) if a[2]==b[2] and b[0]-a[0]<=1400),default=0)
        out[r[1],r[2]]=dict(paired_ticks=len(ticks),local_frame_before_resume=progressed[2] if progressed else None,
                   local_progress_lead_ms=-progressed[0] if progressed else None,
                   auth_peak_gap_so_far_ms=progressed[3] if progressed else None,
                   unchanged_receive_and_handoff_ms=unchanged or None,decoded_counters_flat_ms=flat or None)
    return out


def socket_brackets(epoch,bursts):
    """Bound socket counter change around a unit stall; clocks 't' and video-path 'ms' do not share an origin."""
    out={}
    gs=epoch.get('gap_stamps',[]); ge=epoch['gap_events']
    if len(gs)!=len(ge):return out
    for text,g in zip(gs,ge):
        end=stamp(text)
        if end is None or len(g)!=9 or g[4]<140:continue
        gap=g[4]
        xs=[]
        for row in bursts:
            t=stamp(row.get('log_time'))
            if t is None:continue
            d=relative(t,end)
            if -gap-5000<=d<=5000:
                xs.append((d,row['t'],row.get('socket_counter')))
        if not calibrated(xs):continue
        left=[x for x in xs if x[0]<=-gap-GUARD]
        right=[x for x in xs if x[0]>=GUARD]
        if not left or not right:continue
        a,b=left[-1],right[0]
        if -gap-a[0]>2300 or b[0]>2300:continue
        inner=[x for x in xs if a[0]<=x[0]<=b[0]]
        if (any(type(x[2]) is not int or x[2]<0 for x in inner) or
                any(y[2]<x[2] or y[0]-x[0]>2300 for x,y in zip(inner,inner[1:]))):continue
        out[g[1],g[2]]=dict(counter_before=a[2],counter_after=b[2],increase=b[2]-a[2],
                             before_margin_ms=-gap-a[0],after_margin_ms=b[0])
    return out
