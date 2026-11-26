"""Measure the same public clip in a disposable, sandboxed, headed Edge test window.

Never attach to the personal profile. No cookies imported, no remote debug listener,
no screenshots, network recording or raw errors. Not proof of what happened in K5.
"""
import argparse
import json
from pathlib import Path
import re
from statistics import median
import time
from lan_player_timeline import FILENAME, live_binding


def summarize(rows):
    if len(rows)<2: return {'state':'insufficient'}
    worst=0
    gaps=[]
    skipped=0
    media_steps=[]
    for a,b in zip(rows,rows[1:]):
        step=b[3]-a[3]
        if step<=0 or b[1]<a[1] or b[0]<a[0] or b[2]<a[2]:
            return {'state':'discontinuous'}
        if step>1:
            skipped+=step-1  # callbacks not observed, not lost video frames
            continue
        dt=round(b[1]-a[1],1)
        if b[2]>a[2]:media_steps.append(b[2]-a[2])
        worst=max(worst,dt)
        if dt>=80:
            gaps.append(dict(start_utc_ms=a[1],end_utc_ms=b[1],duration_ms=dt,
                             from_media_ms=a[2],to_media_ms=b[2]))
    return dict(state='ok',samples=len(rows),missed_callbacks=skipped,
                median_adjacent_media_ms=median(media_steps) if media_steps else None,
                longest_observed_adjacent_ms=worst,gaps=gaps)


def run(url, start, seconds, dimensions, save=None, binding=None):
    from playwright.sync_api import sync_playwright, Error
    with sync_playwright() as pw:
        browser=pw.chromium.launch(channel='msedge',headless=False,chromium_sandbox=True,
                                   args=['--window-position=0,0','--start-maximized'] if binding else ['--start-maximized'])
        try:
            ctx=browser.new_context(no_viewport=True,accept_downloads=False)
            if url.startswith('file:///'): ctx.set_offline(True)
            page=ctx.new_page()
            stage='navigation'
            try:
                page.goto(url, wait_until='domcontentloaded', timeout=20000)
                # No login, verification challenge, quality bypass or background-tab instrumentation.
                stage='visible_video'
                video=page.locator('video:visible')
                video.first.wait_for(timeout=12000)
                if video.count()!=1:return dict(state='ambiguous_player')
                page.wait_for_function("document.querySelector('video')?.readyState >= 1",timeout=7000)
                dims=video.evaluate('v => [v.videoWidth,v.videoHeight]')
                if dims!=dimensions:return dict(state='noncomparable_source',dimensions=dims)
                if binding and not video.evaluate('v=>Number.isFinite(v.duration)&&Math.abs(v.duration-1591)<=2'):
                    return dict(state='different_reference_duration')
                stage='seek_and_play'
                if binding:
                    video.evaluate('v=>v.pause()')
                    if not video.evaluate('v=>v.requestFullscreen().then(()=>document.fullscreenElement===v,()=>false)'):
                        return dict(state='fullscreen_not_verified')
                video.evaluate('(v,s) => { v.currentTime=s; }',start)
                if binding:
                    page.wait_for_function("(()=>{const v=document.fullscreenElement;return v&&!v.seeking&&v.paused&&v.readyState>=3})()",timeout=5000)
                    remaining=binding['cue_utc_ms']/1000-time.time()
                    if not 0<=remaining<=36:return dict(state='missed_playback_cue')
                    time.sleep(remaining)
                    if abs(time.time()*1000-binding['cue_utc_ms'])>250:return dict(state='missed_playback_cue')
                # User-authorized playback in this test window only. Respect autoplay policy.
                if video.evaluate('v=>v.paused'):
                    if not video.evaluate('v=>Promise.race([v.play().then(()=>true,()=>false),new Promise(r=>setTimeout(()=>r(false),4000))])'):
                        return dict(state='test_player_unavailable',stage='playback')
                page.wait_for_function("(()=>{const v=document.querySelector('video');return v&&!v.paused&&!v.seeking&&v.readyState>=3})()",timeout=5000)
                if not video.evaluate('(v,s)=>Math.abs(v.currentTime-s)<3',start):
                    return dict(state='wrong_media_position')
                stage='frame_observation'
                witness=page.evaluate(Path(__file__).with_name('observe_test_player.js').read_text('utf-8'),
                                      dict(seconds=seconds,requireFullscreen=bool(binding)))
                report={k:v for k,v in witness.items() if k!='rows'}
                if report['state']=='complete':
                    report['submission']=summarize(witness['rows'])
                    if save and report['submission']['state']=='ok' and [report['width'],report['height']]==dimensions:
                        with save.open('x',encoding='ascii') as f:
                            record=dict(schema=2 if binding else 1,**report,rows=witness['rows'])
                            if binding:record['binding']=binding
                            json.dump(record,f,separators=(',',':'))
                return report
            except Error:
                return dict(state='test_player_unavailable',stage=stage)
        finally:
            browser.close()


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('public_clip_id',nargs='?')
    p.add_argument('--local-video',type=Path,help='user-supplied local MP4/WebM; never uploaded')
    p.add_argument('--save-numeric',type=Path,help='new file only: timestamps, dimensions and frame counts')
    p.add_argument('--bind-lan-run',type=Path,help='new LAN trial directory with a pending playback cue; local reference clip only')
    p.add_argument('--source-size',required=True,help='actual decoded video size in the reference player, e.g. 1920x864')
    p.add_argument('--start',type=int,default=712);p.add_argument('--seconds',type=int,default=35)
    args=p.parse_args()
    if bool(args.public_clip_id)==bool(args.local_video) or not (0<=args.start<=7200 and 1<=args.seconds<=660):
        p.error('invalid test scope')
    if args.local_video:
        path=args.local_video.resolve()
        if not path.as_uri().startswith('file:///') or path.suffix.lower() not in ('.mp4','.webm') or not path.is_file():
            p.error('local MP4/WebM required')
        url=path.as_uri()
    else:
        if not re.fullmatch(r'BV[A-Za-z0-9]{10}',args.public_clip_id):p.error('invalid public clip id')
        url='https://www.bilibili.com/video/'+args.public_clip_id+'/'
    if not re.fullmatch(r'[1-9]\d{1,3}x[1-9]\d{1,3}',args.source_size):
        p.error('invalid reference dimensions')
    binding=None
    if args.bind_lan_run:
        if not args.local_video or args.save_numeric or args.start!=367 or args.source_size!='1920x864' or args.seconds<600:
            p.error('bound LAN comparison needs local 1920x864 reference clip, start 367 and at least 600 seconds')
        try:binding=live_binding(args.bind_lan_run,time.time()*1000)
        except (ValueError,OSError,TypeError,AttributeError):p.error('no pending LAN comparison cue')
        args.save_numeric=args.bind_lan_run/FILENAME
    print(json.dumps(run(url,args.start,args.seconds,list(map(int,args.source_size.split('x'))),args.save_numeric,binding),separators=(',',':')))
