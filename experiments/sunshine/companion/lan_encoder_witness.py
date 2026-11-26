"""Numeric-only, time-matched encoder/decoder witness; never retain raw Sunshine or phone logs."""
import bisect
from datetime import datetime
import re
import subprocess
import time

from long_metrics import RECORD

NUMBER=r'(\d{1,4}(?:\.\d{1,4})?)'
SIZE=re.compile(r'\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\]: Debug: NvEnc: encoded frame sizes in kB \(min/max/avg\): '+('/'.join([NUMBER]*3)))
ANCHOR=re.compile(r'lan_tx_clock phase=([12]) elapsed_us=(\d{1,11}) utc_ms=(\d{13}) bracket_us=(\d{1,7})')


def frame_stat(line,received_ms):
    m=SIZE.fullmatch(line.strip()) if len(line)<220 else None
    if not m:return None
    try: stamp=round(datetime.strptime(m[1],'%Y-%m-%d %H:%M:%S.%f').timestamp()*1000)
    except (ValueError,OSError,OverflowError):return None
    lo,hi,avg=map(float,m.groups()[1:])
    if not (0<=lo<=avg<=hi<=3000 and -20<=received_ms-stamp<=1500):return None
    return dict(utc_ms=stamp,mean_kb=avg,min_kb=lo,max_kb=hi)


def phone_clock(phone):
    best=None
    for _ in range(3):
        a=time.time_ns()/1e6; mono=time.monotonic_ns()/1e6
        try: m=re.fullmatch(r'(\d{13}) ([+-])(\d{2})(\d{2})',phone.shell("date '+%s%3N %z'").strip())
        except (RuntimeError,OSError,subprocess.TimeoutExpired):continue
        b=time.time_ns()/1e6; elapsed=time.monotonic_ns()/1e6-mono
        if not m or not 0<=b-a<=400 or abs((b-a)-elapsed)>30 or int(m[3])>14 or int(m[4])>=60:continue
        mid=(a+b)/2
        sample=dict(host_ms=round(mid),offset_ms=round(int(m[1])-mid),
                    radius_ms=int((b-a)/2)+2,tz_min=(1 if m[2]=='+' else -1)*(60*int(m[3])+int(m[4])))
        if best is None or sample['radius_ms']<best['radius_ms']:best=sample
    return best


def opening_clock(preflight,immediate,now_ms):
    # Either bracket must belong to this test's pre-playback phase. A slow
    # USB UI query must not force reusing the clock from a different run.
    for value in (immediate,preflight):
        if value and 0<=now_ms-value['host_ms']<=120000 and value['radius_ms']<=202:return value
    return None


def frame_times(path):
    if not path.is_file():return None
    n=path.stat().st_size
    if not 3*RECORD.size<=n<=100_000_025 or n%RECORD.size:return None
    times=[]; prior=None
    with path.open('rb') as f:
        f.seek(-RECORD.size,2)
        if RECORD.unpack(f.read())!=(255,0,0,n//RECORD.size-1,0):return None
        f.seek(0);left=n-RECORD.size
        while left:
            buf=f.read(min(left,16384*RECORD.size))
            if not buf or len(buf)%RECORD.size:return None
            left-=len(buf)
            for kind,frame,ms,_,_ in RECORD.iter_unpack(buf):
                if kind not in (0,1):return None
                if kind or frame==prior:continue
                if prior is not None and (frame!=prior+1 or ms<times[-1]):return None
                times.append(ms);prior=frame
    return times if len(times)>=2 else None


def utc_base(lines):
    pairs=[]
    for line in lines:
        m=ANCHOR.fullmatch(line)
        if m:
            phase,us,utc,bracket=map(int,m.groups())
            if bracket>2000:return None
            pairs.append((phase,us,utc-us/1000))
    if [v[0] for v in pairs]!=[1,2] or pairs[1][1]<=pairs[0][1] or abs(pairs[0][2]-pairs[1][2])>40:return None
    return sum(v[2] for v in pairs)/2


def same_windows(stats,lines,trace,epochs,clocks):
    def missing(why):return dict(status='unavailable',reason=why,windows=[])
    if len(stats)<2:return missing('encoder_size_statistics_absent')
    if any(b['utc_ms']<=a['utc_ms'] for a,b in zip(stats,stats[1:])):return missing('non_monotonic_encoder_reports')
    base=utc_base(lines)
    if base is None:return missing('unverified_sender_clock')
    if len(clocks)!=2 or not all(clocks):return missing('missing_phone_clock')
    a,b=clocks
    if a['tz_min']!=b['tz_min'] or b['host_ms']<=a['host_ms'] or abs(a['offset_ms']-b['offset_ms'])>a['radius_ms']+b['radius_ms']+50:return missing('unstable_phone_clock')
    if len(epochs)!=1:return missing('non_unique_decoder')
    frames=frame_times(trace)
    if frames is None:return missing('unsealed_or_noncontiguous_source')
    stamps=epochs[0]['sample_stamps'];samples=epochs[0]['samples']
    if len(stamps)!=len(samples) or len(samples)<2:return missing('insufficient_phone_samples')
    phone=[];day=86400000;offset=(a['offset_ms']+b['offset_ms'])/2
    for i,(s,r) in enumerate(zip(stamps,samples)):
        if i and any(r[k]<samples[i-1][k] for k in (0,3,4,5)):return missing('non_monotonic_phone_counters')
        m=re.fullmatch(r'(\d\d):(\d\d):(\d\d)\.(\d{3,6})',s)
        if not m:return missing('invalid_phone_time')
        h,mi,sec=map(int,m.groups()[:3])
        if h>23 or mi>59 or sec>59:return missing('invalid_phone_time')
        millis=((h*60+mi)*60+sec)*1000+int(m[4][:3])-a['tz_min']*60000-offset
        t=millis+round((base-millis)/day)*day
        if t<a['host_ms']-300 or t>b['host_ms']+300 or (phone and (t<=phone[-1] or abs((t-phone[0])-(r[0]-samples[0][0]))>300)):return missing('phone_clock_discontinuity')
        phone.append(t)
    def nearest(t):
        i=bisect.bisect_left(phone,t)
        return min((j for j in (i-1,i) if 0<=j<len(phone)),key=lambda j:abs(phone[j]-t))
    out=[];source_bits=0;phone_bits=0;host_ms=0;phone_ms=0
    for p,q in zip(stats,stats[1:]):
        u,v=p['utc_ms'],q['utc_ms'];dt=v-u
        if not 19000<=dt<=22000 or u-base<frames[0] or v-base>frames[-1]:continue
        l,r=nearest(u),nearest(v);err=max(abs(phone[l]-u),abs(phone[r]-v))
        if l>=r or err>650:continue
        n=bisect.bisect_left(frames,v-base)-bisect.bisect_left(frames,u-base)
        delta=samples[r][4]-samples[l][4];pdt=samples[r][0]-samples[l][0]
        if not 0<n<=dt*.121 or delta<0 or pdt<=0:continue
        bits=q['mean_kb']*1000*8*n
        source_bits+=bits;phone_bits+=delta*8;host_ms+=dt;phone_ms+=pdt
        out.append(dict(frames=n,duration_ms=dt,encoder_mbps_est=round(bits/dt/1000,3),
                        decoder_input_mbps=round(delta*8/pdt/1000,3),boundary_error_ms=round(err),
                        frame_gap_delta=samples[r][5]-samples[l][5]))
    if not out:return missing('no_complete_matched_window')
    return dict(status='matched',count=len(out),seconds=round(host_ms/1000,2),
                encoder_mbps_est=round(source_bits/host_ms/1000,3),decoder_input_mbps=round(phone_bits/phone_ms/1000,3),
                max_boundary_error_ms=max(x['boundary_error_ms'] for x in out),
                clock_radius_ms=max(a['radius_ms'],b['radius_ms']),windows=out)
