"""Numeric quality gates; these examples are not actual streaming measurements."""
import argparse
from copy import deepcopy
from pathlib import Path
from types import SimpleNamespace
import unittest
from check_device import watch_stream
from long_metrics import Recorder,output_acceptance
from windows_companion import setup_timings,full_hd_initial_kbps,add_output_options


class FullHD(unittest.TestCase):
    def test_helper_output_switch_is_explicit_and_mutually_exclusive(self):
        p=argparse.ArgumentParser(exit_on_error=False)
        add_output_options(p)
        self.assertIsNone(p.parse_args([]).output_profile)
        for name in ("1080p30","1080p60"):
            self.assertEqual(p.parse_args(["--output-"+name]).output_profile,name)
        with self.assertRaises(argparse.ArgumentError):
            p.parse_args(["--output-1080p30","--output-1080p60"])

    def test_high_comparison_never_forces_unavailable_budget(self):
        s=SimpleNamespace(events=["companion_relay_capacity_plan wire_kbps=1800 video_cap_kbps=1400"])
        with self.assertRaisesRegex(RuntimeError,"high_sample_unavailable_fallback_preserved"):
            watch_stream(None,None,s,300,expected="relay",require_high_sample=True)

    def test_relay_burst_headroom_does_not_raise_or_invert_any_grant(self):
        rates=[full_hd_initial_kbps(n) for n in range(500,6401)]
        self.assertEqual(rates,sorted(rates))
        self.assertTrue(all(500<=v<=n for n,v in enumerate(rates,500)))
        self.assertEqual([full_hd_initial_kbps(n) for n in (500,1400,1450,5800,6400)],[500,800,1100,1850,1950])
        for n in (499,6401):
            with self.assertRaises(RuntimeError):full_hd_initial_kbps(n)

    def setUp(self):
        self.epochs=[{"samples":[1],"presented_pictures":[(1920,1080)]}]
        self.metrics=dict(windows=11,clean_windows=11,coverage_ok=True,secs=111,
            rendered_fps=29.98,frame_gaps=0,render_errors=0,longest_including_restart_ms=90)

    def test_sixty_fps_full_hd_budgets_keep_repair_headroom(self):
        grants=(500,1000,1400,1450,2850,3200,5650,5800,6400)
        self.assertEqual([full_hd_initial_kbps(n,60) for n in grants],[500,500,500,500,950,1100,1800,1850,1950])
        prev=500
        for n in range(500,6401):
            rate=full_hd_initial_kbps(n,60)
            self.assertTrue(prev<=rate<=min(n,prev+50))
            prev=rate
        with self.assertRaises(RuntimeError):full_hd_initial_kbps(1400,120)

    def verdict(self):
        return output_acceptance(self.epochs,self.metrics,1920,1080,30,120)

    def test_clean_real_size(self):
        self.assertTrue(self.verdict()['passed'])

    def test_rendered_30_is_not_a_passing_60fps_session(self):
        verify=lambda:output_acceptance(self.epochs,self.metrics,1920,1080,60,120)
        self.assertFalse(verify()['checks']['average_fps'])
        self.metrics['rendered_fps']=59.95
        self.assertTrue(verify()['passed'])

    def test_unknown_or_resized_chapter_is_not_full_hd(self):
        for other in ([],[(960,540)],[(1920,1080),(1920,1088)],[(0,0)]):
            self.epochs=self.epochs[:1]+[dict(samples=[1],presented_pictures=other)]
            self.assertFalse(self.verdict()['checks']['decoded_dimensions'])

    def test_host_must_actually_supply_sixty_distinct_frames(self):
        self.metrics["rendered_fps"]=59.96
        proof=dict(host_trace_complete=1,host_frame_span_ms=119975,host_observed_fps=59.93)
        verdict=lambda source: output_acceptance(self.epochs,self.metrics,1920,1080,60,120,source)["passed"]
        self.assertTrue(verdict(proof))
        for override in (dict(host_trace_complete=0),dict(host_observed_fps=30),dict(host_frame_span_ms=60000)):
            self.assertFalse(verdict({**proof,**override}))

    def test_dont_hide_freezes_behind_average_or_restart(self):
        base=deepcopy(self.metrics)
        for k,v in (('longest_including_restart_ms',None),('longest_including_restart_ms',2500),
                    ('rendered_fps',28),('frame_gaps',5),('coverage_ok',False),
                    ('windows',5),('clean_windows',8),('render_errors',1)):
            self.metrics={**base,k:v}
            self.assertFalse(self.verdict()['passed'])

    def test_measurement_uses_present_events_only(self):
        rec=Recorder('format',Path('.'))
        messages=('decoder_setup_code=0 enc_video=1 enc_audio=1','requested_picture width=1920 height=1080',
                  'presented_picture width=960 height=540','decoder_setup_code=0 enc_video=1 enc_audio=1',
                  'presented_picture width=1920 height=1080')
        for i,line in enumerate(messages):rec.observe(f'12:00:0{i}.000 I SesameSecureClient: '+line)
        self.assertEqual([e['presented_pictures'] for e in rec.epochs],[[(960,540)],[(1920,1080)]])

    def test_start_failure_uses_only_known_stage_and_number(self):
        rec=Recorder('no-frame',Path('.'))
        for line in ('rtsp_stage=play error=104','core_stage_failed=4 error=104',
                     'rtsp_stage=other error=104','rtsp_stage=play error=104 response=ignored'):
            rec.observe('12:00:00.001 I SesameSecureClient: '+line)
        self.assertEqual([v for _,v in rec.events],['rtsp_stage=play error=104','core_stage_failed=4 error=104'])

    def test_low_relay_reference_retry_logs_only_elapsed_time(self):
        rec=Recorder('compact',Path('.'))
        for value in ('810','850 extra=data','unknown'):
            rec.observe('12:00:00.001 I SesameSecureClient: compact_idr_retry wait_ms='+value)
        self.assertEqual([v for _,v in rec.events],['compact_idr_retry wait_ms=810'])

    def test_proxy_summary_does_not_include_arbitrary_text_or_assume_response(self):
        good='companion_setup_timing exchange=7 peer_data=1 reply_ms=-1 total_ms=42 end=peer_end'
        rows=setup_timings([good,good+' extra=not-a-metric','RTSP response (not a metric)'])
        self.assertEqual(rows,[dict(exchange=7,peer_data=True,first_reply_ms=None,total_ms=42,end='peer_end')])

if __name__=='__main__':unittest.main()
