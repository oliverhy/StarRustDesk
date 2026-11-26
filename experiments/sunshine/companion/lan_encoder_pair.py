"""Local-only paired NVENC control. A single physical capture, never a recording.

Not a substitute for Sunshine/phone measurements. Only picture slices reach
the null muxer; the parent process sees numeric packet sizes and timestamps.
"""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE=Path(__file__).resolve().parent
NAMES=('stock','vbv50','vbv100')
PRESETS=('stock','quality4','fullpass')
FULLPASS_BUDGETS=('fullpass','fullpass50','fullpass100')
TARGETS=(12000,16000,20000)
TARGET_NAMES=tuple(f'kbps{kbps}' for kbps in TARGETS)
SWEEPS=('target-sweep','target-sweep-lite')
# The lab's installed WinGet FFmpeg 8.1.2. Refuse an unexpected PATH shadow
# before giving a binary access to the real desktop. No download or upgrade.
OBSERVED_FFMPEG='ad8f211bc894755e0061c55ab280ae00e8d3d4f15a8cc4372b24cfa247b5942e'


def primary():
    from display_targets import geometry
    screens=[s for s in geometry() if s.primary]
    if len(screens)!=1 or screens[0].rect!=(0,0,1920,1080):raise ValueError('physical_primary_missing')
    shell=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    # Wi-Fi, virtual displays and Desktop Duplication itself can all expose a
    # monitor handle. Cross-check the elected monitor against an active wired
    # monitor, without printing or persisting its identifier.
    class DisplayDevice(ctypes.Structure):
        _fields_=[('cb',wintypes.DWORD),('name',ctypes.c_wchar*32),('desc',ctypes.c_wchar*128),
                  ('flags',wintypes.DWORD),('ident',ctypes.c_wchar*128),('key',ctypes.c_wchar*128)]
    dd=DisplayDevice();dd.cb=ctypes.sizeof(dd)
    if not ctypes.windll.user32.EnumDisplayDevicesW(screens[0].name,0,ctypes.byref(dd),1):
        raise ValueError('monitor_interface_unknown')
    identity=dd.ident.upper().split('#')
    if len(identity)!=4:raise ValueError('monitor_interface_unknown')
    instance='\\'.join(['DISPLAY',identity[1],identity[2]])
    probe=subprocess.run([str(shell),'-NoProfile','-NonInteractive','-Command',
        'if (Get-Process -Name sunshine -ErrorAction SilentlyContinue) {exit 7}; '
        'Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop | '
        'Where-Object Active | Select-Object InstanceName,VideoOutputTechnology | ConvertTo-Json -Compress'],
        capture_output=True,text=True,timeout=10,creationflags=subprocess.CREATE_NO_WINDOW)
    if probe.returncode==7:raise ValueError('do_not_share_gpu_with_sunshine_test')
    rows=json.loads(probe.stdout) if probe.returncode==0 and probe.stdout.strip() else []
    if isinstance(rows,dict):rows=[rows]
    if not any(re.sub(r'_\d+$','',r['InstanceName'].upper())==instance and
               r['VideoOutputTechnology'] in (0,4,5,6,10,11,15,2147483648) for r in rows):
        raise ValueError('physical_primary_connection_unverified')
    p=subprocess.run([str(shell),'-NoProfile','-NonInteractive','-File',str(HERE/'capture_activity_windows.ps1'),
                      '-PrimaryOutput'],capture_output=True,text=True,timeout=12,creationflags=subprocess.CREATE_NO_WINDOW)
    m=re.fullmatch(r'capture_primary (\d{1,2}) (\d{1,2}) 1920 1080',p.stdout.strip())
    if p.returncode or not m:raise ValueError('primary_not_full_hd')
    return (*map(int,m.groups()),instance)


def command(ffmpeg,adapter,output,seconds,study='reservoir',quality_stats='pipe:2',motion=False):
    if study not in ('reservoir','quality','fullpass-budgets',*SWEEPS):raise ValueError('unknown_encoder_study')
    scores=study not in ('reservoir','target-sweep-lite')
    names=TARGET_NAMES if study in SWEEPS else FULLPASS_BUDGETS if study=='fullpass-budgets' else PRESETS
    graph=f'ddagrab=output_idx={output}:framerate=60:draw_mouse=0:dup_frames=0:output_fmt=bgra,split=3[a][b][c]'
    if scores:
        # All three encoders and all three reference images get the exact same
        # 4:2:0 pixels. Do the conversion once; do not compare to a separately
        # captured or differently matrix-converted desktop image.
        graph=graph.replace('split=3[a][b][c]','hwdownload,format=bgra,format=yuv420p,split=6[a][b][c][ra][rb][rc]')
    if motion:
        if not scores:raise ValueError('motion_requires_same_pixel_reference')
        graph=graph.replace('split=6','split=7')+'[m];[m]scale=160:90:flags=area,format=yuv420p,signalstats,metadata=mode=print:key=lavfi.signalstats.YDIF:file=motion-luma.txt,nullsink'
    args=[str(ffmpeg),'-nostdin','-hide_banner','-nostats','-loglevel','info' if scores else 'error',
            '-init_hw_device',f'd3d11va=desk:{adapter}','-filter_hw_device','desk','-filter_complex',graph,
            '-map','[a]','-map','[b]','-map','[c]','-c:v','h264_nvenc','-preset','p1','-tune','ull',
            '-rc','cbr','-multipass','fullres' if study=='fullpass-budgets' else 'qres','-bf','0','-rc-lookahead','0','-zerolatency','1',
            '-spatial-aq','0','-g','1073741824','-b:v','20M','-maxrate:v','20M',
            '-bufsize:v:0','333333','-bufsize:v:1','333333' if study=='quality' else '500000',
            '-bufsize:v:2','333333' if study=='quality' else '666666']
    if study in SWEEPS:
        # Stock profile and one frame of VBV at each requested rate, as on the host.
        # Set every output explicitly; avoid hidden global overrides in FFmpeg.
        args=args[:args.index('-b:v')]
        for i,k in enumerate(TARGETS):
            args.extend([f'-b:v:{i}',f'{k}k',f'-maxrate:v:{i}',f'{k}k',
                         f'-bufsize:v:{i}',str(k*1000//60)])
    if scores:
        # Loopback decoders also get the codec parameters when the measurement
        # muxer removes everything except picture slices.
        args+=['-flags:v','+global_header']
        if study=='quality':args+=['-preset:v:1','p4','-multipass:v:2','fullres']
    args+=['-fps_mode:v','passthrough','-enc_time_base:v','1:60000','-bsf:v','filter_units=pass_types=1-5',
            '-stats_mux_pre','pipe:1','-stats_mux_pre_fmt','pic {sidx} {n} {t} {size}',
            '-t',str(seconds),'-f','null',os.devnull]
    if scores:
        for i in range(3):args+=['-threads','2','-dec',f'0:{i}']
        graph=';'.join(f'[dec:{i}][r{ch}]ssim@{name}=shortest=1:repeatlast=0[q{ch}]'
                       for i,(ch,name) in enumerate(zip('abc',names)))
        args+=['-filter_complex',graph,'-map','[qa]','-map','[qb]','-map','[qc]','-fps_mode:v','passthrough',
               '-enc_time_base:v','1:60000','-stats_mux_pre',quality_stats,'-stats_mux_pre_fmt','ssim {sidx} {n} {t}',
               '-t',str(seconds),'-f','null',os.devnull]
    return args


def compare(lines,seconds,names=NAMES):
    streams=[[] for _ in names]
    for row in lines:
        m=re.fullmatch(r'pic ([012]) (\d{1,6}) (\d{1,3}(?:\.\d{1,9})?(?:e-\d{1,2})?) (\d{1,7})',row)
        if not m:raise ValueError('unexpected_stats_format')
        i,n=int(m[1]),int(m[2]); ts=round(float(m[3])*1_000_000); size=int(m[4])
        data=streams[i]
        if n!=len(data) or (data and ts<=data[-1][0]) or not 0<size<=2_000_000 or ts>(seconds+1)*1e6:
            raise ValueError('invalid_picture_counter')
        data.append((ts,size))
    timelines=[[t for t,_ in s] for s in streams]
    if (not timelines[0] or not timelines[0]==timelines[1]==timelines[2] or
            timelines[0][0]>1e6 or timelines[0][-1]<(seconds-1)*1e6):
        raise ValueError('unmatched_or_incomplete_capture')
    # Omit the initial IDR and start-up; compare only complete ten-second windows.
    windows=[]
    for start in range(3,seconds-10,10):
        w={'start_s':start,'frames':0}
        for name,s in zip(names,streams):
            sizes=[size for t,size in s if start*1e6<=t<(start+10)*1e6]
            if not sizes:raise ValueError('missing_picture_window')
            w['frames']=len(sizes)
            w[name]={'vcl_mbps':round(sum(sizes)*8/10_000_000,4),'max_kb':max(sizes)/1000,
                     'p95_kb':sorted(sizes)[math.ceil(len(sizes)*.95)-1]/1000}
        windows.append(w)
    if not windows:raise ValueError('no_comparable_windows')
    target=({'target_kbps_by_branch':dict(zip(names,TARGETS))} if tuple(names)==TARGET_NAMES else {'target_kbps':20000})
    return {'source':'physical_primary','same_presentations':True,**target,
            'measurement':'H.264 VCL only; no headers, padding, repeat or network','frames_per_branch':len(timelines[0]),
            'measured_fps':round(sum(w['frames'] for w in windows)/(10*len(windows)),2),'windows':windows,
            'mean_vcl_mbps':{name:round(sum(w[name]['vcl_mbps'] for w in windows)/len(windows),3) for name in names}}


def quality_report(lines,stderr,seconds,names=PRESETS):
    pictures=[s for s in lines if s.startswith('pic ')]
    checks=[s for s in lines if s.startswith('ssim ')]
    # Verify every SSIM result maps to the very same encoded presentation in
    # order on that stream. No repeating the last reference after EOF.
    if len(pictures)+len(checks)!=len(lines) or not pictures:
        raise ValueError(f'unexpected_quality_trace pictures={len(pictures)} scores={len(checks)} rows={len(lines)}')
    for i in range(3):
        expected=[s.split()[2:4] for s in pictures if s.startswith(f'pic {i} ')]
        actual=[s.split()[2:] for s in checks if s.startswith(f'ssim {i} ')]
        if actual!=expected:raise ValueError(f'unmatched_quality_presentations stream={i} expected={len(expected)} observed={len(actual)}')
    out=compare(pictures,seconds,names)
    for name in names:
        vals=re.findall(r'\[ssim@'+name+r' @ [a-fA-F0-9x]+\] SSIM Y:[^\r\n]{0,140}?All:(0\.\d+|1\.0+) ',stderr)
        if len(vals)!=1:raise ValueError('ssim_summary_unavailable')
        out.setdefault('mean_ssim',{})[name]=float(vals[0])
    return out


def motion_windows(report,pictures,counters):
    """Downsampled real-frame luma change, not a label for the active app/video."""
    pts=[float(row.split()[3]) for row in pictures if row.startswith('pic 0 ')]
    if not pts or len(counters)%2 or len(counters)//2<len(pts):raise ValueError('incomplete_motion_witness')
    motion=[];prev=None;start=None
    for i in range(0,len(counters),2):
        m=re.fullmatch(r'frame:(\d+)\s+pts:\s*-?\d+\s+pts_time:\s*([-+.eE\d]+)\s*',counters[i])
        d=re.fullmatch(r'lavfi\.signalstats\.YDIF=([-+.eE\d]+)',counters[i+1])
        if not m or not d or int(m[1])!=i//2:raise ValueError('invalid_motion_counter')
        t=float(m[2]);v=float(d[1])
        if not math.isfinite(t) or not 0<=v<=255 or (prev is not None and t<=prev):raise ValueError('invalid_motion_sample')
        if start is None:start=t
        prev=t
        if i//2<len(pts):
            if abs(t-start-(pts[i//2]-pts[0]))>.0012:raise ValueError('motion_timeline_not_matched')
            motion.append(v)
    for w in report['windows']:
        vals=[v for t,v in zip(pts,motion) if w['start_s']<=t<w['start_s']+10]
        if len(vals)!=w['frames']:raise ValueError('motion_window_not_matched')
        w['luma_change_mean_0_255']=round(sum(vals)/len(vals),4)
        w['luma_change_p90_0_255']=round(sorted(vals)[math.ceil(len(vals)*.9)-1],4)
    report['motion']={'matched_frames':len(pts),'sample_size':[160,90],'full_scale':255,
                      'meaning':'mean absolute luma difference between consecutive real presentations; not a content identity'}


def run(seconds,study,motion=False):
    adapter,output,identity=primary()
    exe=shutil.which('ffmpeg')
    if not exe:raise ValueError('ffmpeg_missing')
    with Path(exe).open('rb') as binary:
        if hashlib.file_digest(binary,'sha256').hexdigest()!=OBSERVED_FFMPEG:
            raise ValueError('unrecognized_local_ffmpeg')
    env=dict(os.environ);env.pop('FFREPORT',None);env['AV_LOG_FORCE_NOCOLOR']='1'
    # Each output has its own stats writer. Sharing one byte pipe between
    # independent muxers permits buffered writes to split a numeric line.
    with tempfile.TemporaryDirectory(prefix='sesame-encoder-counters-') as tmp:
        counter=Path(tmp)/'quality-pts.txt'
        p=subprocess.run(command(exe,adapter,output,seconds,study,str(counter),motion),capture_output=True,
                         timeout=seconds+18,env=env,cwd=tmp,creationflags=subprocess.CREATE_NO_WINDOW)
        score_lines=counter.read_text('ascii').splitlines() if counter.is_file() else []
        delta=Path(tmp)/'motion-luma.txt'
        motion_lines=delta.read_text('ascii').splitlines() if motion and delta.is_file() else []
    if p.returncode:
        # Only report whitelisted failure classes; no raw diagnostics from the desktop.
        for token,code in [(b'OpenEncodeSessionEx', 'nvenc_open'),(b'NvEncInitializeEncoder','nvenc_init'),
                           (b'Error setting option','option'),(b'Impossible to convert','pixel_format'),
                           (b'CreateDevice','d3d_device'),(b'No capable devices','no_encoder')]:
            if token in p.stderr:raise ValueError(code)
        raise ValueError('encoder_pair_failed')
    if (adapter,output,identity)!=primary():raise ValueError('primary_changed')
    lines=p.stdout.decode('ascii').splitlines()
    report=(quality_report(lines+score_lines,p.stderr.decode('utf-8','replace'),seconds,
                           TARGET_NAMES if study in SWEEPS else FULLPASS_BUDGETS if study=='fullpass-budgets' else PRESETS)
            if study not in ('reservoir','target-sweep-lite') else compare(lines,seconds,TARGET_NAMES if study in SWEEPS else NAMES))
    if motion:motion_windows(report,lines,motion_lines)
    folder=HERE.parent/'.generated'/'lan-compare'/datetime.now().strftime('%Y%m%d-%H%M%S-encoder-paired-'+study+('-motion' if motion else ''))
    folder.mkdir(parents=True)
    (folder/'encoder-pair.json').write_text(json.dumps(report,indent=2),'ascii')
    print(folder.name,report['measured_fps'],report['mean_vcl_mbps'],report.get('mean_ssim',{}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds',type=int,choices=(16,36,66,96),default=66)
    parser.add_argument('--study',choices=('reservoir','quality','fullpass-budgets',*SWEEPS),default='reservoir')
    parser.add_argument('--motion',action='store_true',help='For a quality study, correlate anonymous luma differences with the same encoded frames')
    args=parser.parse_args()
    try:run(args.seconds,args.study,args.motion)
    except subprocess.TimeoutExpired:raise SystemExit('physical_source_timed_out')
