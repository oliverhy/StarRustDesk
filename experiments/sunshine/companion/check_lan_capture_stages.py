"""Regression checks for fail-closed capture attribution; run without a desktop or a phone."""
import json
from datetime import datetime
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock
import subprocess

import analyze_lan_capture as obs
import lan_phone_progress as phone
from capture_audit import CaptureAudit
from check_device import retry_lan_diagnostic_read
from lan_capture_stages import stage_stat


class CaptureStages(unittest.TestCase):
    def test_dwm_unqualified_counters_are_never_frame_evidence(self):
        for flag,expected in [(None,0),(0,0),(1,1)]:
            audit=CaptureAudit((1920,1080),lan_1080=True)
            gate=[] if flag is None else [f'capture_dwm_capability {flag}'.encode()]
            audit.process=SimpleNamespace(stdout=gate+[b'capture_dwm 1000 9 42 5 5 4',
                b'capture_dwm 1001 8 43 6 6 5 contents'])
            audit.read()
            self.assertEqual(len(audit.dwm),expected)

    def test_late_callback_is_not_a_player_stall(self):
        from check_player_submission import summarize
        rows=[[10,8,0,1],[307,305,296,19],[324,322,313,20]]
        self.assertEqual((summarize(rows)['missed_callbacks'],summarize(rows)['longest_observed_adjacent_ms']),(17,17))
        rows[0][3]=18
        self.assertEqual(summarize(rows)['gaps'][0]['duration_ms'],297)
        self.assertEqual(summarize(rows+[rows[-1]])['state'],'discontinuous')

    def test_compositor_never_infers_player_activity_from_refresh(self):
        rows=[[30,5,100,10,9,8],[70,5,103,10,9,8],[110,5,106,10,9,8]]
        r=obs.compositor_progress(rows,0,150)
        self.assertEqual((r['covered_ms'],r['advancing_submission_pairs']),(80,0))
        rows[1][0]=145
        self.assertIsNone(obs.compositor_progress(rows[:2],0,190))
    def test_source_uses_last_packet_not_last_frame_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'trace'
            rows=[(0,7,40,7,1),(1,7,43,7,1),(0,7,110,8,1),(1,7,115,8,1),(0,8,120,9,1)]
            def put(data,seal=True):
                path.write_bytes(b''.join(obs.RECORD.pack(*r) for r in data + ([(255,0,0,len(data),0)] if seal else [])))
            put(rows)
            a,b=obs.source_frames(path)
            self.assertEqual((b[1]-a[2],b[1]-a[1]),(10,80))
            put(rows,False)
            with self.assertRaisesRegex(ValueError,'unsealed'):obs.source_frames(path)
            put(rows+[(0,11,121,11,1)])
            with self.assertRaisesRegex(ValueError,'noncontiguous'):obs.source_frames(path)
            put(rows+[(1,8,55,9,1)])
            with self.assertRaisesRegex(ValueError,'order'):obs.source_frames(path)
            path.write_bytes(b'x'*23)
            with self.assertRaisesRegex(ValueError,'size'):obs.source_frames(path)

    def test_quiet_requires_contiguous_valid_observation(self):
        raw=[[t,100,0,0,1] for t in range(20,320,40)]
        self.assertEqual(obs.desktop(raw,0,330)['signal'],'quiet_interior')
        self.assertEqual(obs.desktop(raw[:2]+raw[-2:],0,330)['signal'],'insufficient_coverage')
        for idx in (3,4):raw[idx][4]=0
        self.assertEqual(obs.desktop(raw,0,330)['signal'],'insufficient_coverage')
        raw[3][2:]=[2,140,0] # masked surfaces do not establish a desktop update
        raw[4][1:]=[18000,2,180,1]
        evidence=obs.desktop(raw,0,330)
        self.assertEqual(evidence['distinct_presents'],0)
        self.assertEqual((evidence['excluded_masked_polls'],evidence['excluded_slow_unmasked_polls']),(1,1))

    def test_actual_presents_must_be_distinct_and_interior(self):
        rows=[[20,0,3,5,1],[60,0,2,58,1],[90,0,1,58,1],[120,0,4,118,1]]
        self.assertEqual(obs.desktop(rows[:3],0,200)['signal'],'one_update')
        res=obs.desktop(rows,0,200)
        self.assertEqual((res['signal'],res['distinct_presents'],res['enclosed_accumulated']),('desktop_updated',2,6))

    def test_worker_generation_and_unobserved_intervals(self):
        w=lambda t,g,c,s:[t,200,1,s,g,c]
        hist=[w(20,1,5,5),w(60,1,8,5),w(100,2,8,1),w(140,2,8,3),w(180,2,8,1),w(300,2,8,3)]
        res=obs.worker(hist,0,340)
        self.assertEqual((res['progress_pairs'],res['wait_snapshots'],res['ready_endpoints_flat_ms']),(1,2,80))
        self.assertEqual(obs.worker([w(20,1,4,1),w(60,2,8,1)],0,100)['progress_pairs'],0)

    def test_dual_clocks_and_bounded_stage_intervals(self):
        anchor=lambda phase,us,ms:f'lan_tx_clock phase={phase} elapsed_us={us} utc_ms={ms} bracket_us=8'
        a=1795500000000
        self.assertIsNotNone(obs.clock([anchor(1,0,a),anchor(2,20000000,a+20000)]))
        self.assertIsNone(obs.clock([anchor(1,0,a),anchor(2,20000000,a+20015)]))
        self.assertIsNone(obs.clock([anchor(1,0,a)]))
        stages=[dict(stage='frame_network',utc_ms=t,max_ms=v) for t,v in [(0,40),(20010,3),(40111,6),(70000,90)]]
        self.assertEqual(obs.stages(stages,1500,1900),{'frame_network':3})
        self.assertEqual(obs.stages(stages,19990,20100),{})
        self.assertEqual(obs.stages(stages,42000,42200),{})

    def test_allowlist_drops_other_log_information(self):
        date='2026-11-24 20:31:23.100'
        now=round(datetime.strptime(date,'%Y-%m-%d %H:%M:%S.%f').timestamp()*1000)
        line=f'[{date}]: Debug: Frame processing latency (min/max/avg): 1.00ms/3.00ms/2.00ms'
        self.assertEqual(stage_stat(line,now)['max_ms'],3)
        for s,t in [(line+' other',now),(line.replace('Debug:','Info:'),now),(line,now+2000),
                    (line.replace('3.00ms','1.01ms'),now),(line.replace('Frame processing latency','Other'),now)]:
            self.assertIsNone(stage_stat(s,t))

    def test_attribution_does_not_invent_a_root_cause(self):
        self.assertEqual(obs.interpretation('not_observed',3.5,323),'desktop_not_observed')
        self.assertEqual(obs.interpretation('desktop_updated',3.5,323),'desktop_changed_resumed_picture_fresh')
        self.assertEqual(obs.interpretation('one_update',None,180),'inconclusive')
        self.assertEqual(obs.interpretation('desktop_updated',130,170),'resumed_picture_already_old_at_packetization')

    def test_missing_route_or_epoch_never_uses_ledger(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)
            (p/'result.json').write_text(json.dumps(dict(timeline={},attribution={},route='relay')))
            (p/'phone-numeric.json').write_text('{"epochs":[]}')
            with self.assertRaisesRegex(ValueError,'scope'):obs.analyze(p)

    def test_phone_stall_is_not_always_source_silence(self):
        frames=[[n,n*16,n*16+2] for n in range(1,80)]
        gap=[123456,6,26,19,380,10,0,1,18]
        match=dict(previous_frame=9,frame=23,host_udp_accept_peak_ms=245,phone_packet_gap_ms=270)
        unrelated={**match,'frame':70,'host_udp_accept_peak_ms':900}
        r=obs.phone_stalls(frames,[gap],[match,unrelated])[0]
        self.assertEqual((r['source_packet_gap_upper_ms'],r['intervening_source_frames'],
                          r['nested_host_udp_gap_upper_ms']),(14,19,245))
        frames[10][2]+=9
        self.assertEqual(obs.phone_stalls(frames,[gap],[])[0]['source_packet_gap_upper_ms'],14)
        bad=gap.copy(); bad[3]=0
        self.assertEqual(obs.phone_stalls(frames,[bad],[]),[])

    def test_cadence_never_extrapolates_a_hole(self):
        frames=[[n,n*20,n*20] for n in range(1001)]
        polls=[[t,50,3,t-1,1] for t in range(20,20000,40) if not 3000<t<6000]
        out=obs.cadence(frames,0,obs.Series(polls))
        self.assertEqual((out['windows'],out['covered_windows'],out['desktop_ge55_source_lt55']),(2,1,1))
        self.assertLess(out['rows'][0]['observed_ms'],7500)
        self.assertEqual(out['lowest_source']['source_fps'],50)

    def test_probe_fault_and_privacy_filter(self):
        a=CaptureAudit([1920,1080],lan_1080=True)
        a.process=SimpleNamespace(stdout=[b'capture_setup 1 1920 1080',b'capture_sample 1000 112 2 999 1',
            b'capture_sample 1001 112 2 999 1 unrecognized',b'capture_worker 2000 500 1 5 1 800',
            b'capture_worker 2001 500 9 5 1 900',b'capture_setup 0 0 0',b'capture_clock_invalid 1'])
        a.read()
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);s=a.save_lan(p,[])
            self.assertTrue(s['primary_verified'] and s['probe_failed'])
            self.assertFalse(s['clock_ok'])
            self.assertEqual((s['worker_roles'],s['polls']),(1,1))
            self.assertNotIn('unrecognized',(p/'lan-capture-samples.json').read_text())

    def test_refusal_is_anchored_and_counts_only_interior_frames(self):
        frames=[[n,n*20,n*20+2] for n in range(101)]
        s=dict(begin_ms=10400,end_ms=10900,busy_ms=500,errno=10035)
        w=dict(long_refusals=[s],clock_inconsistent_spans=0)
        r=obs.source_during_refusals(frames,10000,w,None)[0]
        self.assertEqual((r['source_frames_inside'],r['first_frame'],r['last_frame'],r['source_quiet_inside_ms']),(24,21,44,18))
        self.assertEqual(obs.source_during_refusals(frames,None,w,None),[])
        self.assertEqual(obs.source_during_refusals(frames,10000,{**w,'clock_inconsistent_spans':1},None),[])

    def test_phone_local_progress_before_recovery_including_midnight(self):
        stamps=['23:59:58.500','23:59:59.500','00:00:00.500','00:00:01.500']
        e=dict(gap_stamps=['23:59:56.900','00:00:00.900'],
               gap_events=[[90,1,2,0,20,0,0,0,0],[4090,20,70,49,2000,20,0,1,0]],
               sample_stamps=stamps,samples=[[1000*(i+1),20,20,20] for i in range(4)])
        logs=[]
        for i,t in enumerate(stamps):
            for stage in (2,3):
                logs.append([t,f'video_path stage={stage} ms={1000*(i+1)} packets={30+i} event_gap=0 peak_gap=31 previous_frame=0 frame={18+i*20} loop_peak=8'])
        v=phone.correlate(e,logs)[20,70]
        self.assertEqual((v['local_frame_before_resume'],v['local_progress_lead_ms'],v['decoded_counters_flat_ms']),(58,400,1000))
        self.assertEqual(phone.correlate(e,[x for x in logs if 'stage=3' in x[1]]),{})
        e['gap_events'][1][0]+=300
        self.assertEqual(phone.correlate(e,logs),{})

    def test_diagnostic_retry_never_grants_a_route_or_extends_a_session(self):
        seen={'companion_wifi_udp_authenticated=1','ui_player_first_decoded_frame=1'}
        self.assertTrue(retry_lan_diagnostic_read(True,'lan',seen,2,3))
        for enabled,r,s,c,n in ((False,'lan',seen,1,1),(True,'relay',seen,1,1),(True,'lan',set(),1,1),
                                (True,'lan',seen,3,3),(True,'lan',seen,1,4)):
            self.assertFalse(retry_lan_diagnostic_read(enabled,r,s,c,n))

    def test_owned_probe_timeout_does_not_mask_primary_failure(self):
        a=CaptureAudit((1920,1080),lan_1080=True)
        a.process=Mock(); a.process.poll.return_value=None
        a.process.wait.side_effect=subprocess.TimeoutExpired('owned test probe',4)
        a.reader=Mock(); a.reader.is_alive.return_value=True
        a.close()
        a.process.terminate.assert_called_once()
        a.process.kill.assert_called_once()
        a.process.stdout.close.assert_not_called()
        self.assertTrue(a.probe_failed)

    def test_socket_bracket_uses_phone_clock_and_never_credits_loss_to_a_frame(self):
        e=dict(gap_stamps=['00:00:08.200'],gap_events=[[10100,12,55,42,1900,12,0,1,0]])
        rows=[dict(log_time=f'00:00:{i:02}.000',t=100000+i*1000,socket_counter=4 if i<9 else 6)
              for i in (4,6,8,10)]
        self.assertEqual(phone.socket_brackets(e,rows)[12,55],
                         dict(counter_before=4,counter_after=6,increase=2,before_margin_ms=300,after_margin_ms=1800))
        rows[2]['socket_counter']=2
        self.assertEqual(phone.socket_brackets(e,rows),{})
        self.assertIsNone(phone.stamp(None))


if __name__=='__main__':
    unittest.main()
