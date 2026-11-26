"""Compare real NVENC size windows, relative to each run's playback cue. No captured media."""
import json, statistics
from pathlib import Path

def confirmed_start(o):
    delta=o.get('absolute_delta_ms')
    return (o.get('displayed_start')=='06:07' and o.get('was_paused') is True and
            o.get('media_quality_1080p60') is True and type(delta) is int and 0<=delta<=250)

def read(folder):
    def obj(name):return json.loads((Path(folder)/name).read_text('utf-8-sig'))
    r=obj('result.json');p=r['encoder_trial'];expected=r['sunshine_rate_witness']['encoder_kbps']
    if not (expected==20000 and r['encrypted_video_audio'] and r['primary_capture_confirmed'] and
            r['windows_medium_at_boundaries']==['ethernet']*2 and r['route']=='lan' and r['host_refuses_input'] and
            not r['usb_forward'] and r['full_hd']['observed_pictures']==[[1920,1080]] and
            r['playback']['rates']==[[20000,20000]] and r['playback']['segments']==1 and
            p['effective'] and p['verified'] and p['process_configuration_observed'] and
            all(s['filler'] is False for s in p['effective'])):raise ValueError('unverified_session')
    if not confirmed_start(obj('player-start-observed.json')):raise ValueError('unconfirmed_playback_start')
    cue=obj('playback-cue.json')['utc_ms'];sz=obj('encoder-size-numeric.json')['sizes']
    matched=obj('encoder-phone-windows.json')
    if matched['status']!='matched' or len(sz)-1!=len(matched['windows']):raise ValueError('partial_encoder_intervals')
    out=[]
    for a,b,m in zip(sz,sz[1:],matched['windows']):
        start,end=a['utc_ms']-cue,b['utc_ms']-cue
        if not 19000<=end-start<=21000 or end-start!=m['duration_ms'] or not start>=0:raise ValueError('encoder_interval_not_aligned')
        if not 0<b['min_kb']<=b['mean_kb']<=b['max_kb']:raise ValueError('invalid_encoded_frame_sizes')
        out.append(dict(start=start,end=end,rate=m['encoder_mbps_est'],phone=m['decoder_input_mbps'],fps=m['frames']*1000/(end-start),
                        mean=b['mean_kb'],peak=b['max_kb'],low=b['min_kb']))
    return out

def compare(a,b):
    matches=[];used=set()
    for x in a:
        choices=[]
        for i,y in enumerate(b):
            overlap=max(0,min(x['end'],y['end'])-max(x['start'],y['start']))
            ratio=overlap/max(x['end']-x['start'],y['end']-y['start'])
            if ratio>=.75 and x['fps']>=58.2 and y['fps']>=58.2: choices.append((i,y,ratio))
        if len(choices)>1:raise ValueError('ambiguous_source_timing')
        if choices:
            i,y,ratio=choices[0]
            if i in used:raise ValueError('window_reused')
            used.add(i);matches.append((x,y,ratio))
    if len(matches)<8:raise ValueError('not_enough_common_material')
    x,y,ratios=zip(*matches);one=lambda d:[u['rate'] for u in d]
    l,r=one(x),one(y);delta=[v-u for u,v in zip(l,r)]
    std=statistics.pstdev(l)*statistics.pstdev(r)
    corr=statistics.correlation(l,r) if std>1e-8 else None
    def desc(z):
        return dict(encoder_mean=round(statistics.mean(one(z)),3),range_mbps=[round(min(one(z)),3),round(max(one(z)),3)],
             median_frame_mean_kb=round(statistics.median(u['mean'] for u in z),3),
             median_frame_peak_kb=round(statistics.median(u['peak'] for u in z),3),
             min_frame_low_kb=min(u['low'] for u in z),max_frame_peak_kb=max(u['peak'] for u in z))
    return dict(matched=len(matches),minimum_overlap=round(min(ratios),3),first=desc(x),second=desc(y),
        encoder_pattern_r=round(corr,4) if corr is not None else None,
        mean_delta_mbps=round(statistics.mean(delta),3),median_abs_delta_mbps=round(statistics.median(map(abs,delta)),3),
        increased=sum(v>0 for v in delta),decreased=sum(v<0 for v in delta))

if __name__=='__main__':
    import sys
    if len(sys.argv)!=3:raise SystemExit('two sealed sessions required')
    print(json.dumps(compare(read(sys.argv[1]),read(sys.argv[2])),indent=2))
