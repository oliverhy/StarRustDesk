"""Observe only the local stream info HUD on the authorized view-only phone."""
import json
import re
import secrets
import statistics
import tempfile
import time
from pathlib import Path
from PIL import Image
from toolbar_ui_checks import keyed,node,snapshot
import windows_companion as wc


def match_native(folder,epochs):
    """Match the visible phone clock and all three values to actual decoder samples."""
    rows=json.loads((folder/'monitor-ui.json').read_text('utf-8'))['visible_samples']
    native=[]
    def clock(t):
        h,m,s=t[:8].split(':'); return int(h)*3600+int(m)*60+int(s)
    for epoch in epochs:
        pairs=zip(epoch['samples'],epoch['samples'][1:],epoch['sample_stamps'][1:])
        for a,b,t in pairs:
            elapsed=b[0]-a[0]
            if 800<=elapsed<=1500 and t:
                native.append((clock(t),(b[3]-a[3])*1000/elapsed,(b[4]-a[4])*.008/elapsed,b[9]))
    def matches(row):
        if not all(k in row for k in ('sample','fps','mbps','rtt')): return False
        tick=clock(row['sample'])
        return any(min(abs(tick-t),86400-abs(tick-t))<=1 and abs(row['fps']-fps)<=.16 and
                   abs(row['mbps']-rate)<=.02 and row['rtt']==rtt for t,fps,rate,rtt in native)
    n=sum(matches(row) for row in rows)
    wc.event(f'monitor_matched_native_samples={n} visible={len(rows)}')
    wc.require(n>=min(5,len(rows)) and len(rows)>=5,'monitor_values_not_correlated_to_native_samples')
    return n


def letterbox_colors(phone,points):
    # Only inspect a handful of pixels outside the video, never save the
    # screenshot as a test artifact. Source and transfer temp files expire here.
    remote='/data/local/tmp/sesame-local-hud-'+secrets.token_hex(8)+'.png'
    wc.require(phone.focused_id(),'monitor_capture_lost_focus')
    try:
        with tempfile.TemporaryDirectory() as tmp:
            file=Path(tmp)/'screen.png'
            wc.require('fail' not in phone.shell('uitest screenCap -p '+remote).lower(),'monitor_capture_failed')
            wc.require('FileTransfer finish' in phone.command('file','recv',remote,str(file)),'monitor_capture_transfer_failed')
            with Image.open(file) as raw:
                return [list(raw.getpixel((x,y))[:3]) for x,y in points]
    finally:
        phone.shell('rm -f -- '+remote)


def inspect(phone,d,server,folder,verify):
    wc.require(not server.allow_input and not server.input_fixture,'monitor_test_needs_view_only_lease')
    def tap(key): phone.own_tap(node(phone,key))
    collapsed=bool(keyed(snapshot(phone),'sunshine-remote-control-handle'))
    if collapsed:
        tap('sunshine-remote-control-handle')
        if keyed(snapshot(phone),'sunshine-remote-control-handle'): tap('sunshine-remote-control-handle')
    def open_info():
        tap('sunshine-menu-more'); tap('glass-action-monitor'); node(phone,'sunshine-monitor-close')
    def read():
        rows=snapshot(phone); wc.require(keyed(rows,'sunshine-monitor-close'),'monitor_vanished')
        values={}
        for key,pattern in [('fps',r'实际帧率\s+(\d+(?:\.\d+)?)\s*FPS'),
                            ('mbps',r'画面接收\s+(\d+(?:\.\d+)?)\s*Mbps'),
                            ('rtt',r'网络往返\s+(\d+)\s*ms'),
                            ('gap',r'累计视频帧缺口\s+(\d+)')]:
            for row in rows:
                m=re.fullmatch(pattern,row.get('text',''))
                if m: values[key]=float(m[1]); break
        stamp=keyed(rows,'sunshine-monitor-sample')
        if stamp and (m:=re.search(r'\b\d\d:\d\d:\d\d$',stamp.get('text',''))): values['sample']=m[0]
        return values
    samples=[]
    open_info()
    for _ in range(7):
        samples.append(read()); time.sleep(1.35)
    points=[]; opened=[]
    if verify:
        rows=snapshot(phone); vx,vy,vr,vb=d.box(keyed(rows,'sunshine-touch-surface'))
        x,y,r,b=d.box(keyed(rows,'sunshine-monitor'))
        points=[(x+max(4,(r-x)//35),y+(b-y)*i//8) for i in range(2,7)
                if y+(b-y)*i//8<vy-6 or y+(b-y)*i//8>vb+6 or r<vx-6 or x>vr+6]
        if points: opened=letterbox_colors(phone,points)
    tap('sunshine-monitor-close')
    wc.require(not keyed(snapshot(phone),'sunshine-monitor-close'),'monitor_not_closed')
    ratios=[]
    if points:
        rows=snapshot(phone); vx,vy,vr,vb=d.box(keyed(rows,'sunshine-touch-surface'))
        if all(px<vx-5 or px>vr+5 or py<vy-5 or py>vb+5 for px,py in points):
            closed=letterbox_colors(phone,points)
            ratios=[sum(a)/sum(b) for a,b in zip(opened,closed) if 25<=sum(b)<=100]
    time.sleep(1.6)
    open_info(); reopened=read(); tap('sunshine-monitor-close')
    if collapsed: tap('sunshine-collapse-controls')
    fields={k:len({s[k] for s in samples if k in s}) for k in ('fps','mbps','rtt','gap','sample')}
    transmission=round(statistics.median(ratios),3) if ratios else None
    report=dict(visible_samples=samples,distinct=fields,reopened=reopened,local_backdrop_transmission=transmission)
    (folder/'monitor-ui.json').write_text(json.dumps(report,indent=2),'utf-8')
    wc.event('monitor_ui_distinct '+' '.join(f'{k}={v}' for k,v in fields.items()))
    wc.require(len([s for s in samples if 'fps' in s and 'mbps' in s])>=5,'visible_monitor_fields_missing')
    if verify:
        wc.require(fields['sample']>=3 and fields['mbps']>=2 and (fields['fps']>=2 or fields['rtt']>=2)
                   and reopened.get('mbps',0)>0,'visible_monitor_not_updating')
        if transmission is not None:
            wc.event(f'monitor_local_backdrop_transmission={transmission}')
            wc.require(.25<=transmission<=.60,'visible_monitor_scrim_unexpected')
