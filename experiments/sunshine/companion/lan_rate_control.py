"""Encoder-only, view-only LAN trial. No paid bandwidth, video payloads or credentials."""
import re
import math

PROFILES={'stock':0,'vbv50':50,'vbv100':100,'quality4':0,'fullpass':0,'fullpass100':100}
_PREFIX=r'\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}\]: '
_CREATED=re.compile(_PREFIX+r'Info: NvEnc: created encoder v[0-9.]{1,12} H\.264 P([1-7])((?: [a-z0-9+=-]{1,32})*)')
_GOAL=re.compile(_PREFIX+r'Debug: NvEnc: requested encoded frame size (\d{1,4}(?:\.\d{1,3})?) kB')


def verify_scope(mode,ready,profile,kbps,monitor):
    if mode not in PROFILES or not (ready and profile=='1080p60' and kbps==20000 and not monitor):
        raise ValueError('encoder_trial_requires_view_only_standard_lan')


def configure(conf,mode):
    if mode not in PROFILES:raise ValueError('unknown_encoder_trial')
    # The average bitrate is negotiated. Change only the encoder configuration,
    # not SDP, FEC, sender pacing, socket buffers or any route budget.
    options={}
    for line in conf.splitlines():
        if '=' in line:
            key,value=(v.strip() for v in line.split('=',1))
            options.setdefault(key,[]).append(value)
    required={'encoder':'nvenc','bind_address':'127.0.0.1','lan_encryption_mode':'2',
              'wan_encryption_mode':'2','upnp':'disabled'}
    if any(k.startswith('nvenc_') for k in options) or any(options.get(k)!=[v] for k,v in required.items()):
        raise ValueError('unverified_isolated_nvenc_config')
    if mode=='stock':return conf
    if mode=='quality4':return conf.rstrip('\n')+'\nnvenc_preset = 4\n'
    if mode=='fullpass':return conf.rstrip('\n')+'\nnvenc_twopass = full_res\n'
    if mode=='fullpass100':return conf.rstrip('\n')+'\nnvenc_twopass = full_res\nnvenc_vbv_increase = 100\n'
    return conf.rstrip('\n')+f'\nnvenc_vbv_increase = {PROFILES[mode]}\n'


def config_witness(text,mode):
    # Return only booleans; never serialize the host config (it contains
    # private paths). Fail on duplicate keys even when the last value matches.
    if mode not in PROFILES:return False
    lines=[line for line in text.splitlines() if re.match(r'\s*nvenc_',line)]
    expected=(['nvenc_twopass = full_res','nvenc_vbv_increase = 100'] if mode=='fullpass100'
              else ['nvenc_twopass = full_res'] if mode=='fullpass' else ['nvenc_preset = 4'] if mode=='quality4'
              else [f'nvenc_vbv_increase = {PROFILES[mode]}'] if PROFILES[mode] else [])
    required={'encoder':'nvenc','bind_address':'127.0.0.1','lan_encryption_mode':'2','wan_encryption_mode':'2','upnp':'disabled'}
    return lines==expected and all([s.split('=',1)[1].strip() for s in text.splitlines() if '=' in s
                                    and s.split('=',1)[0].strip()==k]==[v] for k,v in required.items())


def effective(line):
    if len(line)>220:return None
    if m:=_GOAL.fullmatch(line.strip()):
        return {'requested_frame_kb':float(m[1])}
    m=_CREATED.fullmatch(line.strip())
    if not m:return None
    flags=m[2].split()
    vbv=0
    for v in flags:
        if v.startswith('vbv+'):
            if vbv or not re.fullmatch(r'vbv\+[1-9]\d{0,2}',v):return None
            vbv=int(v[4:])
        elif not (v in ('async','yuv444','10-bit','two-pass','rfi','weighted-prediction','spatial-aq','filler-data')
                  or re.fullmatch(r'qpmin=\d{1,2}',v)):
            return None  # unknown build/options: do not retain text or assume padding is off
    return dict(preset=int(m[1]),vbv_increase_pct=vbv,two_pass='two-pass' in flags,
                filler='filler-data' in flags,min_qp=next((int(v[6:]) for v in flags if v.startswith('qpmin=')),None))


def verified(settings,profile):
    return (profile in PROFILES and 0<len(settings)<=4 and
            all(s.get('vbv_increase_pct')==PROFILES[profile] and s.get('filler') is False
                and s.get('two_pass') is True and s.get('preset')==(4 if profile=='quality4' else 1) and s.get('min_qp') is None
                and s.get('frame_target_kb')==41.67 for s in settings))


class SessionEncoderWitness:
    """Sunshine also creates capability-probe encoders during /launch.

    The actual negotiation anchor is emitted at RTSP ANNOUNCE. Pair each
    subsequent creation with its own immediately preceding numeric frame goal.
    If multiple active creations occur, require all of them to agree.
    """
    def __init__(self):
        self.announced=False
        self.pending=None
        self.settings=[]
        self.preflight=0
        self.invalid=False

    def note(self,line):
        if 'Final adjusted video encoding bitrate is ' in line:
            if re.fullmatch(_PREFIX+r'Debug: Final adjusted video encoding bitrate is \d{1,6} Kbps',line.strip()):
                self.announced=True
                self.pending=None
            return
        if 'NvEnc: requested encoded frame size' in line:
            self.pending=(effective(line) or {}).get('requested_frame_kb')
        elif 'NvEnc: created encoder' in line:
            if not self.announced:self.preflight+=1
            else:
                setting=effective(line)
                if setting is None or self.pending is None or len(self.settings)>=4:self.invalid=True
                else:self.settings.append(dict(setting,frame_target_kb=self.pending))
            self.pending=None

    def report(self,profile):
        return {'profile':profile,'effective':list(self.settings),'pre_negotiation_creations':self.preflight,
                # Pinned Sunshine prints "two-pass", not the first-pass
                # resolution. Don't represent configuration as driver telemetry.
                'requested_first_pass':'full_res' if profile in ('fullpass','fullpass100') else 'default_quarter_res',
                'first_pass_resolution_visible_at_runtime':False,
                'verified':self.announced and not self.invalid and verified(self.settings,profile)}


def diagnose(request_kbps,rates,matched,fps,seconds):
    """Triage only, never a replacement for the unrounded playback acceptance.

    The host estimate comes from NVENC's rounded mean frame size. Don't label a
    small difference or unmatched clocks as packet loss. Loss can coexist with
    under-production: count these independently for the same wall-clock window.
    """
    if rates.get('encoder_kbps')!=request_kbps:
        return {'status':'encoder_target_different' if rates.get('encoder_kbps') else 'encoder_target_unknown'}
    windows=matched.get('windows',[])
    if (matched.get('status')!='matched' or not windows or matched.get('seconds',0)<seconds*.75
            or request_kbps<=0 or fps<=0):
        return {'status':'matched_coverage_insufficient'}
    goal=request_kbps/1000
    counts=dict(slow_source=0,below_at_normal_cadence=0,delivery_deficit_with_frame_gaps=0,
                both=0,delivery_delta_without_frame_gaps=0,frame_gap_windows=0)
    frames=total_encoded_kb=0
    for w in windows:
        host=w['encoder_mbps_est']; phone=w['decoder_input_mbps']
        if (not all(math.isfinite(x) and x>=0 for x in (host,phone)) or
            not 0<w['duration_ms'] or w['frames']<=0 or w['frame_gap_delta']<0):
            return {'status':'invalid_window'}
        total_encoded_kb+=host*w['duration_ms']/8
        frames+=w['frames']
        slow=1000*w['frames']/w['duration_ms']<fps*.97
        under=not slow and host<goal*.95
        gap=w['frame_gap_delta']>0
        deficit=host-phone>goal*.05
        counts['slow_source']+=slow
        counts['below_at_normal_cadence']+=under
        counts['delivery_deficit_with_frame_gaps']+=deficit and gap
        counts['delivery_delta_without_frame_gaps']+=deficit and not gap
        counts['both']+=under and deficit and gap
        counts['frame_gap_windows']+=gap
    # Keep signs. Rounded driver statistics and boundary error can put the
    # decoder slightly above the estimate; that is not negative packet loss.
    return {'status':'matched','request_kbps':request_kbps,'encoder_target_kbps':rates['encoder_kbps'],
            'encoder_mbps_est':matched['encoder_mbps_est'],'decoder_input_mbps':matched['decoder_input_mbps'],
            'target_minus_encoder_mbps_est':round(goal-matched['encoder_mbps_est'],3),
            'encoder_minus_decoder_mbps_est':round(matched['encoder_mbps_est']-matched['decoder_input_mbps'],3),
            'target_mean_kb_per_frame':round(request_kbps/(8*fps),2),
            'encoder_mean_kb_per_frame_est':round(total_encoded_kb/frames,2),
            'seconds':matched['seconds'],'windows':len(windows),'window_counts':counts}


def source_rx_boundary(lines,mode):
    """Attribute only exact internal counter holes on one observed ordered epoch."""
    setup=[];samples=[]
    for line in lines:
        m=re.fullmatch(r'lan_source_rx_setup tuned=([01]) before=(\d+) effective=(\d+) error=(\d+)',line)
        if m:setup.append(tuple(map(int,m.groups())))
        m=re.fullmatch(r'lan_source_rx_seq finish=([01]) packets=(\d+) holes=(\d+) breaks=(\d+) backwards=(\d+) invalid=(\d+) jumps=(\d+)',line)
        if m:samples.append(tuple(map(int,m.groups())))
    if len(setup)!=1 or not samples:return {'verified':False,'status':'no_single_observation'}
    tuned,before,effective,error=setup[0]
    done,packets,holes,breaks,back,invalid,jumps=samples[-1]
    settings=bool(mode in ('stock','bounded','auto') and tuned==(mode!='stock') and before>0 and not error and
                  (effective>=max(before,262144) if tuned else effective==before))
    monotone=all(all(x<=y for x,y in zip(a[1:],b[1:])) and not a[0] for a,b in zip(samples,samples[1:]))
    valid=bool(settings and done and packets and monotone and not (back or jumps or invalid))
    return dict(verified=valid,settings_verified=settings,complete=bool(done),before_bytes=before,effective_bytes=effective,
                observed_packets=packets,internal_missing=holes if valid else None,discontinuities=breaks,
                backwards=back,unrecognized=invalid,large_jumps=jumps)


def windows_udp_counts():
    """Read-only host-wide IPv4 totals. Corroboration, never per-socket proof."""
    import ctypes,os
    if os.name!='nt':return {}
    fields=(ctypes.c_uint32*5)()
    try:
        api=ctypes.WinDLL('iphlpapi',winmode=0x800).GetUdpStatisticsEx
        api.argtypes=(ctypes.c_void_p,ctypes.c_uint32);api.restype=ctypes.c_uint32
        if api(ctypes.byref(fields),2):return {}
    except (OSError,AttributeError):return {}
    return dict(input=int(fields[0]),no_listener=int(fields[1]),input_errors=int(fields[2]),output=int(fields[3]))


def counter_delta(before,after):
    if not before or before.keys()!=after.keys() or any(after[k]<v for k,v in before.items()):return {}
    return {k:after[k]-v for k,v in before.items()}


def receiver_evidence(report):
    """Per-socket evidence only. Never convert a system counter to session
    packet loss, a missing packet to a missing frame, or an absent sample to zero."""
    src=report.get('host_source_rx') or {}
    sock=report.get('phone_authenticated_udp_socket') or {}
    admission=report.get('phone_receive_admission') or {}
    reason=admission.get('cause')
    burst=report.get('phone_burst_receive') or {}
    holes=src.get('internal_missing') if src.get('verified') is True else None
    dropped=sock.get('counted_drops')
    def count(v):
        return v if type(v) is int and 0<=v<=2**64-1 else None
    active=count(burst.get('active_windows'))
    base=count(admission.get('base_bytes'))
    return dict(host_internal_missing_shards=count(holes),phone_socket_dropped_datagrams=count(dropped),
                phone_device_rcvbuf_errors_context=count((report.get('phone_udp_device_wide_delta') or {}).get('RcvbufErrors')),
                admission=reason if reason in ('standard_lan_offer','observed_rate') else None,
                early_policy_read_back=(reason=='standard_lan_offer' and active>0 and
                    base>=512*1024) if reason and active is not None and base is not None else None)


def failed_start_boundary(lines,epochs):
    # Only interpret zero-video samples. This is not a bitrate measurement.
    if len(epochs)!=1 or not epochs[0].get('samples'):return {'status':'unavailable'}
    samples=epochs[0]['samples']
    if any(len(s)<4 or any(s[k] for k in (1,2,3)) for s in samples):return {'status':'not_a_zero_frame_start'}
    media=[s for s in lines if s.startswith('wan_media_host ')]
    last=(re.fullmatch(r'wan_media_host video_to_phone=(\d+) phone_video_probes=(\d+) control_to_phone=(\d+)'
                       r'(?: [a-z_]+=[0-9]+)+',media[-1]) if media else None)
    ends=[s for s in lines if re.fullmatch(r'lan_source_rx_seq finish=1 packets=0 holes=0 breaks=0 backwards=0 invalid=0 jumps=0',s)]
    if len(ends)!=1 or not last:return {'status':'unavailable'}
    sent,probes,control=map(int,last.groups())
    return {'status':'no_video_at_windows_ingress_despite_probes' if probes and control and not sent else 'unresolved',
            'video_packets_sent':sent,'video_probes':probes,'control_packets':control}


def source_rx_gap_overlap(lines,observation,epochs):
    """Correlate the first undecodable frame, not every dependent lost frame.
    A jump *between* two frames cannot locate the missing shard within either.
    """
    if not observation.get('verified') or len(epochs)!=1:return {'status':'unavailable'}
    rows=[]
    for line in lines:
        if m:=re.fullmatch(r'lan_source_rx_gap prev=(\d+) next=(\d+) missing=(\d+)',line):
            prev,nxt,num=map(int,m.groups())
            if not (0<prev<=nxt<=65536 and num>0):return {'status':'invalid_frame_range'}
            rows.append((prev,nxt,num))
    if len(rows)!=observation['discontinuities'] or sum(n for _,_,n in rows)!=observation['internal_missing']:
        return {'status':'incomplete_event_sample'}
    gaps=epochs[0].get('gap_events',[])
    if any(len(g)<4 or (g[3] and not (g[3]>0 and g[1]+g[3]+1==g[2])) for g in gaps):return {'status':'invalid_gap'}
    heads={g[1]+1 for g in gaps if g[3]}; exact={l for l,r,n in rows if l==r}
    possible={h for h in heads if any(l<=h<=r for l,r,n in rows)}
    return dict(status='matched',gap_runs=len(heads),inside_first_frame=len(heads&exact),
                in_or_bordering_first_frame=len(possible),unrelated_first_frames=len(heads-possible))


def phone_boundary(epochs,path):
    """Compare the authenticated/local UDP ledger with the actual decoder
    callback. Only datagrams actually read by the Windows helper are in the
    original ledger. A successful local send is *not* an RTP reassembly receipt.
    """
    if len(epochs)!=1 or not epochs[0].get('samples') or path.get('host_trace_complete')!=1:
        return {'status':'unavailable'}
    samples=epochs[0]['samples']
    if any(len(s)<8 for s in samples):return {'status':'unavailable'}
    # These are independent atomic counters sampled while the player runs.
    # A last rendered frame may still be in flight; never call it lost.
    end=samples[-1]
    if (any(any(row[k]<old[k] for k in (1,2,3,5,6,7)) for old,row in zip(samples,samples[1:])) or
        min(end[1],end[2],end[3],end[5],end[6],end[7])<0):
        return {'status':'unavailable'}
    matched=path.get('phone_traced_missing_frames')
    if (matched!=path.get('mapped_missing') or matched!=end[5] or path.get('phone_counts_unmatched_frames')!=0
            or not isinstance(path.get('phone_complete_missing_frames'),int)):
        return {'status':'incomplete_gap_coverage'}
    return dict(status='matched',gap_frames=end[5],gap_frames_with_all_host_observed_packets_accepted_by_local_udp=path['phone_complete_missing_frames'],
                callback_units_received=end[1],units_submitted=end[2],frames_presented_at_last_sample=end[3],
                callback_idr_requests=end[6],reported_render_errors=end[7])


if __name__=='__main__':
    # Re-evaluate an existing numeric ledger without touching the phone or the
    # saved result. Require the original run duration, not its surviving samples.
    import argparse,json
    from pathlib import Path
    cli=argparse.ArgumentParser(description='Read-only diagnosis of a sealed LAN bitrate experiment.')
    cli.add_argument('folder',type=Path)
    cli.add_argument('--seconds',type=int,choices=(120,180,300,600),required=True)
    args=cli.parse_args()
    report=json.loads((args.folder/'result.json').read_text('utf-8'))
    windows=json.loads((args.folder/'encoder-phone-windows.json').read_text('utf-8'))
    if (report.get('route')!='lan' or report.get('host_setups')!=[[1920,1080,60,20000]] or
        report.get('encrypted_video_audio') is not True):
        cli.error('not an authenticated standard LAN run')
    diagnosis=diagnose(20000,report['sunshine_rate_witness'],windows,60,args.seconds)
    diagnosis['receive_evidence']=receiver_evidence(report)
    rec=json.loads((args.folder/'phone-numeric.json').read_text('utf-8'))
    diagnosis['phone_decode_boundary']=phone_boundary(rec['epochs'],report['attribution'])
    print(json.dumps(diagnosis,indent=2))
