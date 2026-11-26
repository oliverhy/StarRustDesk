"""View-only real-primary LAN acceptance. USB only carries diagnostics and local UI."""
import argparse
from contextlib import ExitStack
from datetime import datetime
import json
import os
from pathlib import Path
import re
import secrets
import struct
import sys
import time
import traceback

import check_device as ui
from lan_path import timeline
from long_metrics import Recorder,output_acceptance
from phone_burst_metrics import summary as phone_burst_summary
import windows_companion as wc
import lan_encoder_witness as enc
from lan_capture_stages import stage_stat
import lan_rate_control as rate_control
import lan_key_path
from lan_startup_evidence import explain as explain_lan_start, observe_endpoint

class StartRecorder(Recorder):
    def __init__(self,*args):
        super().__init__(*args)
        self.startup_phone={}

    def observe(self,raw):
        super().observe(raw)
        for line in raw.splitlines():
            for tag in ('SesameWanProbe: ','SesameSecureClient: '):
                _,found,msg=line.partition(tag)
                if found:
                    observe_endpoint(self.startup_phone,msg.strip())
                    break


def rate_witness(host_type,encoder_profile=None):
    # The pinned host exposes the final encoder target at debug level.
    # Discard debug output at the source: its file sink is the Windows null
    # device; retain only allowlisted integer targets and numeric NVENC sizes.
    class Host(host_type):
        # Physical 1080p LAN fixture only: a cold display/encoder probe was
        # alive but not ready within 28s. Keep the loopback identity and
        # owned-process/listener checks; only extend the observation window.
        readiness_seconds=65
        def __init__(self,*args):
            self.rates={};self.sizes=[];self.skip_debug=False;self.watch_stages=False;self.stage_stats=[]
            self.encoder_witness=rate_control.SessionEncoderWitness();self.encoder_config_observed=False
            self.start_evidence={}
            self.key_path=lan_key_path.HostKeys()
            super().__init__(*args)
        def mark_start(self):
            super().mark_start()
            if encoder_profile=='stock' and self.output_id:self.key_path.armed=True
        def conf(self):
            conf=super().conf()
            if encoder_profile is not None and self.output_id:
                conf=rate_control.configure(conf,encoder_profile)
            wc.require(os.name=='nt' and '\nmin_log_level = info\n' in conf and
                       conf.count('\nlog_path = ')==1,'unverified_host_log_sink')
            return '\n'.join(('log_path = '+os.path.abspath(os.devnull) if s.startswith('log_path = ')
                else 'min_log_level = debug' if s=='min_log_level = info' else s) for s in conf.split('\n'))
        def start(self):
            super().start()
            if encoder_profile is not None and self.output_id:
                self.encoder_config_observed=rate_control.config_witness((self.runtime/'sunshine.conf').read_text('utf-8'),encoder_profile)
                wc.require(self.encoder_config_observed,'encoder_process_configuration_not_observed')
        def line(self,row):
            if self.key_path.armed and ('idr frame ' in row or 'type [IDX_' in row or 'CLIENT ' in row):
                self.key_path.observe(row,time.time_ns()//1000000)
            if self.session_at and time.monotonic()-self.session_at<18:
                # Only numeric counters from the isolated host, not SDP, ports, identifiers or pixels.
                m=row.lower()
                for label,words in (('video_ping',('video','ping')),('audio_ping',('audio','ping')),
                    ('ping_timeout',('ping','timeout')),('received_ping',('received','ping')),
                    ('capture_fail',('captur','fail')),('encode_fail',('encod','fail')),
                    ('display_fail',('display','fail')),('desktop_fail',('desktop','fail')),
                    ('invalid_ping',('ping','invalid')),('unmatched',('session','match')),
                    ('keyframe',('keyfram',)),('encode_sizes',('encoded frame sizes',)),
                    ('first_rtp',('first','packet')),('duplicator_fail',('duplicat','fail')),
                    ('packet_fail',('packet','fail')),('client_connected',('client connected',))):
                    if all(w in m for w in words):self.start_evidence[label]=min(65535,self.start_evidence.get(label,0)+1)
            if self.session_at and ('Final adjusted video encoding bitrate is ' in row or
                    'NvEnc: created encoder' in row or 'NvEnc: requested encoded frame size' in row):
                with self.lock:self.encoder_witness.note(row)
            if self.watch_stages and self.session_at and ' (min/max/avg):' in row:
                stage=stage_stat(row,time.time_ns()//1000000)
                if stage:
                    with self.lock:
                        if len(self.stage_stats)<160:self.stage_stats.append(stage)
            if self.session_at and 'NvEnc: encoded frame sizes in kB' in row:
                size=enc.frame_stat(row,time.time_ns()//1000000)
                if size:
                    with self.lock:
                        if len(self.sizes)<48:self.sizes.append(size)
            for prefix,key in [('Final adjusted video encoding bitrate is ','encoder_kbps'),
                               ('Client configured bitrate is ','sdp_kbps')]:
                m=re.search(re.escape(prefix)+r'(\d{1,6}) Kbps\s*$',row)
                if m and self.session_at:
                    with self.lock:self.rates[key]=int(m[1])
            level=re.search(r'\]\s*:\s*(Verbose|Debug|Info|Warning|Error|Fatal):',row,re.I)
            if level:self.skip_debug=level[1].lower() in ('verbose','debug')
            if not self.skip_debug:super().line(row)
    return Host


class ObservedHost(wc.PhysicalBackend):
    def configuration(self, original, rate, seconds, wan=False):
        if getattr(self,'requested_encoder_trial',None) is not None:
            # The phone's authenticated request, not just a command-line
            # expectation. Never start a tuned experiment on a custom rate.
            wc.require(not wan and original==rate==wc.STANDARD_VIDEO,'encoder_trial_actual_request_mismatch')
        reply=super().configuration(original,rate,seconds,wan)
        width,height,fps,kbps,_,_=struct.unpack_from('!6I',reply,4)
        wc.require(not wan and 0<kbps<=50000,'not_bounded_lan_stream')
        self.profile_replies.append((width,height,fps,kbps))
        wc.event(f'lan_host_setup width={width} height={height} target_fps={fps} video_kbps={kbps}')
        return reply


def udp_counters(phone):
    rows=[s.split()[1:] for s in phone.shell('cat /proc/net/snmp').splitlines() if s.startswith('Udp:')]
    if len(rows)!=2 or len(rows[0])!=len(rows[1]) or not all(v.isdecimal() for v in rows[1]):return {}
    return {k:int(v) for k,v in zip(*rows) if k in ('InErrors','RcvbufErrors','SndbufErrors','InCsumErrors')}


def run(device,seconds,monitor=None,profile='1080p60',verify_full_hd=False,observe_wifi=False,expected_kbps=None,ready_trial=False,observe_capture=False,encoder_profile=None,source_rx=None,playback_cue=False,host_medium='wifi',require_rx_trial=False,core_rx=False,reader_trial=None,startup_only=False):
    wc.require((seconds==20)==startup_only and (not startup_only or
        (host_medium=='ethernet' and ready_trial and encoder_profile=='stock' and source_rx=='auto' and
         not any((monitor,observe_capture,playback_cue,require_rx_trial,core_rx,reader_trial)))),
        'invalid_startup_only_scope')
    wc.require(reader_trial is None or (reader_trial in ('initiated','phase','margin','margin-paired') and core_rx and require_rx_trial and playback_cue and encoder_profile=='stock'), 'unexpected_reader_trial_scope')
    wc.require(host_medium=='wifi' or (host_medium=='ethernet' and ready_trial and observe_wifi and not monitor),'invalid_wired_lan_trial')
    link_field='wifi_uplink' if host_medium=='wifi' else 'ethernet_phone_wifi'
    wc.require(not playback_cue or (seconds==600 and ready_trial and encoder_profile in ('stock','fullpass','vbv50') and source_rx=='auto' and not monitor),'unexpected_playback_cue_scope')
    wc.require(not ready_trial or (observe_wifi and verify_full_hd and profile=='1080p60' and expected_kbps==20000),
               'lan_ready_trial_requires_standard_local_witness')
    wc.require(not observe_capture or (ready_trial and verify_full_hd and not monitor),'capture_requires_view_only_standard_lan')
    if encoder_profile is not None:
        rate_control.verify_scope(encoder_profile,ready_trial,profile,expected_kbps,monitor)
    wc.require(source_rx is None or (source_rx in ('stock','bounded','auto') and encoder_profile is not None and ready_trial),
               'source_rx_requires_verified_encoder_request')
    wc.require(encoder_profile!='fullpass100' or source_rx in ('bounded','auto'),'larger_fullpass_frames_require_bounded_source_rx')
    win=wc.load_fixture(); d=win.d; phone=d.CoverageApp()
    wc.require(re.fullmatch(r'[A-Za-z0-9_-]{7,64}',device) and phone.hdc[-2:]==['-t',device],
               'wrong_usb_device')
    before=phone.debug_targets(); phone.idle_preflight(); ui.no_usb_forward(phone)
    pc,phone_ip=win.lan.wifi_pair(phone)
    if observe_wifi:
        from wifi_uplink import windows_lan_medium
        medium=windows_lan_medium(pc,phone_ip)
        wc.event('lan_windows_route_medium='+medium)
        wc.require(medium==host_medium,'windows_'+host_medium+'_not_selected_no_media_started')
    state=wc.runtime_dir()/'windows-companion-state'
    wc.require((state/'protected-companion.dat').is_file(),'no_saved_pc_pairing')
    base=Path(__file__).resolve().parents[1]/'.generated'/'lan-compare'
    fps=30 if profile=='1080p30' else 60
    expected_kbps=expected_kbps or (wc.STANDARD_VIDEO if fps==60 else 8000)
    wc.require(wc.paired_video_rate(expected_kbps),'invalid_expected_bitrate')
    label='path' if encoder_profile is None else 'encoder-'+encoder_profile
    if source_rx is not None:label+='-rx'+source_rx
    if host_medium=='ethernet':label+='-ethernet'
    if startup_only:label+='-startup'
    folder=base/(datetime.now().strftime('%Y%m%d-%H%M%S')+f'-{profile}-{expected_kbps}k-{label}-'+secrets.token_hex(2))
    folder.mkdir(parents=True)
    recorder_cls=StartRecorder if ready_trial and host_medium=='ethernet' else Recorder
    rec=recorder_cls(f'lan-real-primary-{expected_kbps}k',folder,fps); trace=folder/'host-numeric.ssmeta'
    wc.event('lan_numeric_run='+folder.name)
    started=False
    witness=None
    capture=None
    t0=t1=None
    try:
        early=enc.phone_clock(phone) if ready_trial else None
        with ExitStack() as scope:
            host=ObservedHost(scope,output_profile=profile if profile=='1080p30' else None,
                              test_host_factory=(lambda cls:rate_witness(cls,encoder_profile)) if expected_kbps>=wc.STANDARD_VIDEO else None)
            host.lan_ready_trial=ready_trial
            host.requested_encoder_trial=encoder_profile
            host.lan_source_rx=source_rx
            if observe_capture:
                from capture_audit import CaptureAudit
                host.host.watch_stages=True
                capture=CaptureAudit(host.desktop_size,host.host.p.pid,lan_1080=True)
                capture.start()
                scope.callback(capture.close)
            if profile=='1080p30' or verify_full_hd:
                wc.require(host.desktop_size[0]>=1920 and host.desktop_size[1]>=1080,'primary_below_full_hd')
            server=wc.Companion(pc,47837,state,host,seconds=seconds,allowed_phone=phone_ip,
                                trace_file=trace,trace_salt=secrets.token_bytes(16))
            scope.callback(server.close)
            wc.require(not server.invitation() and not server.allow_input and server.wan is None
                       and not server.menu_fixture,'unexpected_lan_scope')
            server.start(); started=True
            if observe_wifi:
                from wifi_uplink import WifiWitness
                witness=WifiWitness(pc,phone_ip,phone.hdc,host_medium)
                witness.start()
                scope.callback(witness.close)
            ui.open_page(phone,d)
            wc.require(ui.marker(phone,'companion_saved_host_loaded=1') and
                       ui.has(phone,lambda r:r.get('type','').lower() in ('web','webview'),25),
                       'no_saved_phone_pairing')
            if host_medium=='ethernet':
                from bench_lan_hint import stage
                came_from_usb=stage(scope,phone,d.APP,pc,phone_ip)
            kernel_before=udp_counters(phone)
            pc_kernel_before=rate_control.windows_udp_counts() if source_rx is not None else {}
            if ready_trial:
                immediate=enc.phone_clock(phone)
                t0=enc.opening_clock(early,immediate,time.time_ns()//1000000)
            x,y=phone.button_spot()
            route_tap=None
            if (observe_capture and playback_cue) or startup_only:
                # Short trials can lose the one-shot authentication marker
                # before the first mixed-tag poll. Observe this PID before tapping.
                route_tap=ui.RouteTap(phone)
                scope.callback(route_tap.close)
            if playback_cue:
                # The operator starts the same paused movie on the physical main screen.
                # USB is not a media path. Store a clock cue, never screen or input data.
                due=time.monotonic()+35
                utc=time.time_ns()//1000000+35000
                (folder/'playback-cue.json').write_text(json.dumps({'utc_ms':utc}),encoding='ascii')
                wc.event(f'lan_playback_cue_utc_ms={utc}')
                while (remaining:=due-time.monotonic())>0:time.sleep(min(.15,remaining))
                wc.require(phone.focused_id(),'debug_app_lost_focus_before_cue')
            phone.tap_start(x,y)
            callback=None
            if monitor:
                from check_monitor_live import inspect
                callback=lambda: inspect(phone,d,server,folder,monitor=='verify')
            try:
                route=ui.watch_stream(phone,win,server,seconds,expected='lan',recorder=rec,on_first_frame=callback,
                                      retry_usb_reads=bool(capture),route_tap=route_tap,startup_only=startup_only)
                if core_rx:
                    # The outer receiver seals many blocks at once. Read just the video
                    # tag from this run's fresh PID once; don't recreate epochs or import
                    # arbitrary native logs if the mixed-tag tail evicted a gap head.
                    tail=phone.shell("hilog -P "+phone.pid+" -T SesameSecureClient -z 320")
                    rec.observe('\n'.join(x for x in tail.splitlines() if 'SesameSecureClient: lan_core_' in x))
                pc_kernel_after=rate_control.windows_udp_counts() if source_rx is not None else {}
                t1=enc.phone_clock(phone) if ready_trial else None
                if host_medium=='ethernet': wc.require(came_from_usb(),'temporary_lan_hint_not_consumed')
            except Exception as exc:
                last=traceback.extract_tb(exc.__traceback__)[-1]
                # No exception text or command arguments (may include test identity).
                wc.event(f'lan_media_observation_failed class={type(exc).__name__} line={last.lineno}')
                host.host.sanitized_session_hints()
                wc.event('isolated_host_start_counts='+json.dumps(getattr(host.host,'start_evidence',{}),separators=(',',':')))
                raise
        if reader_trial=='phase' and phone.pid and phone.shell('pidof '+d.APP)==phone.pid:
            # Shutdown writes the seal after the final decoder sample. Import
            # only this PID's numeric pair rows, never arbitrary diagnostic text.
            tail=phone.shell("hilog -P "+phone.pid+" -T SesameWanProbe -z 256")
            rec.observe('\n'.join(x for x in tail.splitlines() if 'SesameWanProbe: rx_ledger_gap_pair' in x))
        # The media peer's clean shutdown seals its packet ledger. Never match
        # a partially flushed ledger or mix IDs across decoder lifetimes.
        wc.require(not any(e.startswith('companion_input_granted') for e in server.events),'unexpected_remote_input')
        if startup_only:
            wc.require(host.profile_replies==[(1920,1080,60,20000)] and windows_lan_medium(pc,phone_ip)=='ethernet',
                       'startup_source_or_setup_mismatch')
            pictures={tuple(size) for e in rec.epochs for size in e.get('presented_pictures',[])}
            wc.require(pictures=={(1920,1080)},'startup_decoded_dimensions_not_verified')
            probe=explain_lan_start(server.path_samples)
            wc.require(probe['status']=='grade_observed' and all('wake' in r.get('windows',{}) for r in probe['steps']),
                       'startup_probe_witness_missing')
            (folder/'startup-only.json').write_text(json.dumps(dict(
                authenticated_lan=True,first_encrypted_picture=True,requested_applied_kbps=20000,
                decoded_dimensions=sorted(pictures),requested_fps=60,performance_evaluated=False,
                link_probes=[e for e in server.events if re.fullmatch(
                    r'companion_host_bandwidth_result state=\d+ good_kbps=\d+ unstable_kbps=\d+ cap_kbps=\d+',e)])),'ascii')
            wc.event('lan_startup_encrypted_first_picture_verified=1')
            return
        clock=timeline(trace,rec)
        attribution=rec.attribute(route,trace,{},None)
        metrics=rec.summary(route,seconds)
        (folder/'host-path-numeric.txt').write_text('\n'.join(server.path_samples),'utf-8')
        report=dict(host_setups=host.profile_replies,route=route,host_refuses_input=True,
                    primary_capture_confirmed=True,usb_forward=False,encrypted_video_audio=True,
                    link_probes=[e for e in server.events if re.fullmatch(
                        r'companion_host_bandwidth_result state=\d+ good_kbps=\d+ unstable_kbps=\d+ cap_kbps=\d+',e)],
                    even_dispatch='companion_host_lan_pacer_even_dispatch=1' in server.events,
                    fresh_recovery='companion_host_lan_fresh_recovery=1' in server.events,
                    playback=metrics,timeline=clock,attribution=attribution)
        if monitor=='verify':
            from check_monitor_live import match_native
            report['monitor_matched_native_samples']=match_native(folder,rec.epochs)
        report['source_desktop_size']=host.desktop_size
        if source_rx is not None:
            report['host_source_rx']=rate_control.source_rx_boundary(server.path_samples,source_rx)
            report['host_source_rx_frame_overlap']=rate_control.source_rx_gap_overlap(server.path_samples,report['host_source_rx'],rec.epochs)
            report['windows_ipv4_udp_whole_host_delta']=rate_control.counter_delta(pc_kernel_before,pc_kernel_after)
            wc.event('lan_source_ingress='+json.dumps(report['host_source_rx'],separators=(',',':')))
        report['lan_ready_trial']='companion_host_lan_tx_writable_trial=1' in server.events
        kernel_after=udp_counters(phone)
        report['phone_udp_device_wide_delta']={k:kernel_after[k]-old for k,old in kernel_before.items()
            if k in kernel_after and kernel_after[k]>=old}  # not app-specific proof
        report['phone_authenticated_udp_socket']=rec.rx_socket  # absent is not a zero drop count
        report['phone_receive_admission']=rec.rx_admission  # measured traffic and admission are independent
        report['phone_burst_receive']=phone_burst_summary(rec.rx_bursts)
        if rec.rx_dispatch:
            import phone_dispatch
            report['phone_reader_dispatch']=phone_dispatch.summarize(rec.rx_dispatch,(rec.rx_socket or {}).get('counted_drops'))
            (folder/'phone-reader-dispatch.json').write_text(json.dumps(rec.rx_dispatch),'ascii')
        if reader_trial:
            import phone_dispatch
            is_margin=reader_trial in ('margin','margin-paired')
            report['reader_trial_status']=phone_dispatch.qualify(report.get('phone_reader_dispatch'),'phase' if is_margin else reader_trial,seconds)
            if is_margin:
                report['reader_margin_transitions']=list(rec.rx_margin)
                report['controlled_margin_comparison']=rec.rx_margin_comparison
                if report['reader_trial_status']=='reader_phase_observed':
                    states=[s['state'] for s in rec.rx_margin]
                    report['reader_trial_status']={(): 'margin_not_triggered',(1,):'bounded_margin_applied',(1,2):'bounded_margin_reverted',(3,):'margin_unsupported'}.get(tuple(states),'margin_not_verified')
                    if rec.rx_margin_comparison!=int(reader_trial=='margin-paired'):
                        report['reader_trial_status']='margin_comparison_arm_unverified'
        from lan_rx_trial import summarize as rx_trial_summary
        if any(msg.startswith('rx_ledger_ahead ') for _,msg in rec.events):
            report['phone_receive_trial']=rx_trial_summary(rec.events)
            report['phone_receive_trial']['recovery_armed']=any(msg=='lan_rx_recovery_ready=1' for _,msg in rec.events)
        if core_rx or any(msg.startswith('lan_core_') for _,msg in rec.events):
            import core_rx_diag
            paths=folder/'missing-frame-path.json'
            core=core_rx_diag.join(rec.epochs,rec.events,json.loads(paths.read_text('utf-8')) if paths.is_file() else [])
            (folder/'core-receive-numeric.json').write_text(json.dumps(core,indent=2),'utf-8')
            report['core_receive']={k:v for k,v in core.items() if k!='heads'}
        report['phone_rx_headroom_transitions']=list(rec.rx_headroom)
        report['sunshine_rate_witness']=dict(getattr(host.host,'rates',{}))
        if encoder_profile is not None:
            report['encoder_trial']=host.host.encoder_witness.report(encoder_profile)
            report['encoder_trial']['process_configuration_observed']=host.host.encoder_config_observed
        if capture:
            report['primary_capture_observer']=capture.save_lan(folder,host.host.stage_stats)
        if ready_trial:
            sizes=list(host.host.sizes)
            (folder/'encoder-size-numeric.json').write_text(json.dumps(dict(sizes=sizes,clocks=[t0,t1])),'ascii')
            matched=enc.same_windows(sizes,server.path_samples,trace,rec.epochs,[t0,t1])
            report['encoder_phone']={k:v for k,v in matched.items() if k!='windows'}
            report['bitrate_diagnosis']=rate_control.diagnose(expected_kbps,report['sunshine_rate_witness'],matched,fps,seconds)
            report['bitrate_diagnosis']['receive_evidence']=rate_control.receiver_evidence(report)
            report['phone_decode_boundary']=rate_control.phone_boundary(rec.epochs,attribution)
            (folder/'encoder-phone-windows.json').write_text(json.dumps(matched,indent=2),'ascii')
        if witness:
            report[link_field]=witness.save(folder,server.path_samples)
            report['windows_medium_at_boundaries']=[medium,windows_lan_medium(pc,phone_ip)]
            wc.event('lan_gateway_witness='+json.dumps({k:report[link_field][k] for k in ('phone_source_bound','wlan_registered')},separators=(',',':')))
        report['full_hd']=output_acceptance(rec.epochs,metrics,1920,1080,fps,seconds,attribution if fps==60 else None)
        wc.event("lan_full_hd_acceptance="+json.dumps(report['full_hd'],separators=(',',':')))
        (folder/'result.json').write_text(json.dumps(report,indent=2),'utf-8')
        if reader_trial:
            wc.event('lan_reader_trial_status='+report['reader_trial_status'])
            wc.require(report['reader_trial_status'] in ('reader_level_changed_and_read_back','reader_phase_observed','bounded_margin_applied','bounded_margin_reverted'),'reader_treatment_not_verified')
        if require_rx_trial:
            trial=report.get('phone_receive_trial',{})
            wc.require(trial.get('recovery_armed') and trial.get('ahead_windows',0)>=seconds*.40
                       and trial.get('handed_datagrams',0)>seconds*60,'phone_receive_trial_unwitnessed')
        if core_rx:
            cr=report.get('core_receive',{})
            wc.require(cr.get('status')=='matched' and cr['socket']['drops']>=0 and cr['socket']['samples']>10,
                       'player_receive_witness_incomplete')
        wc.require(report['lan_ready_trial']==ready_trial,'lan_writable_trial_mismatch')
        if encoder_profile is not None:wc.require(report['encoder_trial']['verified'],'encoder_profile_unwitnessed')
        if source_rx is not None:wc.require(report['host_source_rx']['verified'],'source_rx_unwitnessed')
        if capture:
            seen=report['primary_capture_observer']
            wc.require(seen['primary_verified'] and seen['clock_ok'] and not seen.get('probe_failed') and seen['polls']>=seconds*10,
                       'primary_capture_observation_incomplete')
        if expected_kbps>=wc.STANDARD_VIDEO:
            wc.event('lan_encoder_witness='+json.dumps(report['sunshine_rate_witness'],separators=(',',':')))
            wc.require(report['sunshine_rate_witness'].get('encoder_kbps')==expected_kbps,'encoder_video_target_not_confirmed')
        if ready_trial:
            compared=report['encoder_phone']
            wc.require(compared.get('status')=='matched' and compared.get('seconds',0)>=seconds*.75,
                       'same_window_encoder_comparison_incomplete')
        if witness:
            sample=report[link_field]
            wc.require(report['windows_medium_at_boundaries']==[host_medium,host_medium],'windows_benchmark_route_changed')
            wc.require(sample['wlan_registered']==(host_medium=='wifi') and sample['phone_source_bound'] and
                       sample['phone']['ok']>=10 and sample['pc_gateway']['ok']>=10,
                       'independent_gateway_observation_incomplete')
        wc.require(host.profile_replies[:1]==[(1920,1080,fps,expected_kbps)] and
                   all(r and tuple(r)==(expected_kbps,expected_kbps) for r in metrics['rates']),'wrong_negotiated_profile')
        if profile=='1080p30' or verify_full_hd: wc.require(report['full_hd']['passed'],'full_hd_output_not_stable')
        if verify_full_hd and expected_kbps==20000:
            wc.require(metrics['sustained_20mbps_60fps'],'full_hd20_payload_and_cadence_not_sustained')
        wc.require(metrics['coverage_ok'],'insufficient_numeric_coverage')
        wc.require(clock['matching_duration'],'incomplete_path_evidence')
        wc.require(report['even_dispatch'] and report['fresh_recovery'],'unverified_lan_runtime')
    finally:
        rec.save_phone()
        if core_rx and encoder_profile=='stock' and started and (folder/'result.json').is_file() and (folder/'encoder-size-numeric.json').is_file():
            try:lan_key_path.seal(folder,host.host.key_path)
            except (OSError,ValueError):wc.event('lan_key_host_seal=unavailable')
        if ready_trial and witness and host_medium=='wifi' and (folder/'result.json').is_file():
            # All clocks, Surface counters and the per-session UDP ledger must
            # be sealed before joining them. This cannot turn a failed run green.
            from lan_recovery_witness import report as recovery_witness
            try:
                recovery=recovery_witness(folder)
                (folder/'windows-recovery-to-surface.json').write_text(json.dumps(recovery,indent=2),'ascii')
                wc.event('lan_recovery_timing='+recovery['status'])
            except (OSError,ValueError,TypeError,KeyError,IndexError,struct.error):
                wc.event('lan_recovery_timing=unavailable')
        if started:
            try:
                if ready_trial and host_medium=='ethernet':
                    # Available even when the client declines the first train before RTSP.
                    startup=explain_lan_start(server.path_samples)
                    startup['phone']=rec.startup_phone
                    startup['host']={}
                    for line in server.events:
                        if line.startswith('companion_host_'):observe_endpoint(startup['host'],line[len('companion_host_'):])
                    (folder/'lan-startup-probe.json').write_text(json.dumps(startup,indent=2),'ascii')
                # Fail closed on identity or route, but keep bounded diagnostic
                # evidence of a failed run. Never manufacture a passing result.
                if not (folder/'result.json').exists():
                    if capture:capture.save_lan(folder,host.host.stage_stats)
                    (folder/'host-path-numeric.txt').write_text('\n'.join(server.path_samples),'ascii')
                    if ready_trial and not (folder/'startup-only.json').exists():
                        (folder/'partial-encoder-size-numeric.json').write_text(json.dumps(
                            dict(sizes=list(getattr(host.host,'sizes',[])),clocks=[t0,t1],
                                 failed_start_boundary=rate_control.failed_start_boundary(server.path_samples,rec.epochs),
                                 encoder_trial=host.host.encoder_witness.report(encoder_profile) if encoder_profile else None)),'ascii')
                if witness and not (folder/witness.filename).exists():
                    witness.save(folder,server.path_samples)
                (folder/'setup-numeric.json').write_text(json.dumps(wc.setup_timings(server.events)),encoding='ascii')
                if capture and (folder/'result.json').exists():
                    # Postprocess only after both ledgers are closed. This optional
                    # attribution never overrides playback acceptance or an earlier failure.
                    from analyze_lan_capture import analyze
                    try:
                        linked=analyze(folder)
                        (folder/'source-stages.json').write_text(json.dumps(linked,indent=2),'ascii')
                        wc.event(f"lan_source_stages independent={int(linked['independent_observer'])} gaps80={linked['gaps_ge80_ms']} gaps250={linked['gaps_ge250_ms']}")
                    except (OSError,ValueError,KeyError,TypeError,IndexError):
                        wc.event('lan_source_stage_attribution_unavailable=1')
            finally:
                try: phone.shell('aa force-stop '+d.APP)
                finally: phone.shell('aa start -a EntryAbility -b '+d.APP)
        ui.no_usb_forward(phone); wc.require(phone.debug_targets()==before,'other_apps_changed')
        wc.event('lan_apps_and_routing_preserved=1')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device',required=True); p.add_argument('--seconds',type=int,choices=(20,120,180,300,600),default=120)
    p.add_argument('--startup-only',action='store_true',help='20-second isolated LAN admission/first-picture test; never a performance pass')
    p.add_argument('--monitor',choices=('baseline','verify'),help='Observe actual HUD values without clicking the desktop')
    p.add_argument('--profile',choices=('1080p30','1080p60'),default='1080p60')
    p.add_argument('--verify-full-hd',action='store_true',help='Require measured decoder dimensions and stability for 60 FPS too')
    p.add_argument('--observe-wifi',action='store_true',help='Verify the Wi-Fi phone and observe both paths to its LAN gateway; read Windows WLAN counters only on an actual Wi-Fi host route')
    p.add_argument('--observe-capture',action='store_true',help='Observe physical primary presents and only this host process, without reading pixels')
    p.add_argument('--lan-ready-trial',action='store_true',help='Only in the 20 Mbps LAN lab: retry on a verified writable transition, without changing SO_SNDBUF')
    p.add_argument('--expected-kbps',type=int,help='Assert the phone setting; never change it for this test')
    p.add_argument('--built-test-peer',action='store_true',help='Use the locally built delivery test peer used in the standard-bitrate comparisons')
    p.add_argument('--paired-playback-cue',action='store_true',help='Wait for a shared wall-clock cue before tapping start in the paired ten-minute LAN comparison')
    p.add_argument('--require-phone-rx-trial',action='store_true',help='Require the numeric read-ahead and recovery witnesses in the standard LAN-only 20 Mbps debug trial')
    p.add_argument('--require-core-rx',action='store_true',help='Require end-to-end per-gap player socket and authenticated FEC evidence; no changes to playback')
    p.add_argument('--expect-reader-trial',choices=['initiated','phase','margin','margin-paired'],help='Read back the one isolated reader treatment; never configure the device from this flag')
    p.add_argument('--host-medium',choices=('wifi','ethernet'),default='wifi',help='Verified Windows route to Wi-Fi phone; Ethernet runs do not measure Windows wireless recovery')
    p.add_argument('--lan-encoder-profile',choices=rate_control.PROFILES,help='Only in the authenticated 20 Mbps LAN experiment: compare real encoder output at fixed target')
    p.add_argument('--lan-source-rx',choices=('stock','bounded','auto'),help='Observe Sunshine video-packet continuity on the private local socket: original, bounded or normal helper policy')
    args=p.parse_args()
    try:
        if args.built_test_peer:
            wc.WAN_PEER=wc.HERE.parent/'.generated/delivery-rust-target/release/sesame_wan_peer.exe'
            wc.require(wc.WAN_PEER.is_file(),'updated_peer_missing')
        wc.require(not args.lan_ready_trial or args.built_test_peer,'lan_trial_needs_test_peer')
        wc.require(not args.require_phone_rx_trial or (args.lan_ready_trial and args.verify_full_hd and args.profile=='1080p60' and args.expected_kbps==20000),'wrong_phone_receive_trial_scope')
        wc.require(not args.require_core_rx or args.require_phone_rx_trial,'wrong_player_receive_scope')
        run(args.device,args.seconds,args.monitor,args.profile,args.verify_full_hd,args.observe_wifi,args.expected_kbps,args.lan_ready_trial,args.observe_capture,args.lan_encoder_profile,args.lan_source_rx,args.paired_playback_cue,args.host_medium,args.require_phone_rx_trial,args.require_core_rx,args.expect_reader_trial,args.startup_only)
    except Exception as exc:
        why=str(exc) if isinstance(exc,RuntimeError) and re.fullmatch('[a-z_0-9]{3,83}',str(exc)) else type(exc).__name__
        frames=traceback.extract_tb(exc.__traceback__)
        local=[f for f in frames if Path(f.filename).parent.resolve()==Path(__file__).resolve().parent]
        wc.event('lan_check_failed='+why+' at='+'|'.join(f'{Path(t.filename).name}:{t.lineno}' for t in (local or frames)[-4:])); sys.exit(1)
