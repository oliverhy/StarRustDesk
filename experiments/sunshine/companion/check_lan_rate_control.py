import unittest

import lan_rate_control as rc
import lan_encoder_pair as paired


class RateControlTest(unittest.TestCase):
    safe=('bind_address = 127.0.0.1\nupnp = disabled\nlan_encryption_mode = 2\n'
          'wan_encryption_mode = 2\nencoder = nvenc\nfec_percentage = 20\nmax_bitrate = 50000\n')
    stamp='[2026-11-24 20:12:00.123]: '
    created=stamp+'Info: NvEnc: created encoder v1202 H.264 P1 async two-pass vbv+50 rfi'

    def test_source_counter_only_claims_one_closed_ordered_observation(self):
        setup='lan_source_rx_setup tuned=1 before=65536 effective=262144 error=0'
        row='lan_source_rx_seq finish=0 packets=12 holes=3 breaks=1 backwards=0 invalid=0 jumps=0'
        end=row.replace('finish=0','finish=1').replace('packets=12','packets=20')
        self.assertEqual(rc.source_rx_boundary([setup,row,end],'bounded')['internal_missing'],3)
        for lines in ([row,end],[setup,row],[setup,setup,end],[setup,end,row],[setup,end.replace('invalid=0','invalid=1')],
                      [setup,end.replace('jumps=0','jumps=1')],[setup,end.replace('backwards=0','backwards=2')],
                      [setup,row,end.replace('holes=3','holes=2')],[setup.replace('262144','65536'),end]):
            self.assertFalse(rc.source_rx_boundary(lines,'bounded')['verified'])
        self.assertFalse(rc.source_rx_boundary([setup,end],'stock')['verified'])
        k=rc.source_rx_boundary([setup.replace('tuned=1','tuned=0').replace('262144','65536'),end],'stock')
        self.assertEqual((k['before_bytes'],k['effective_bytes'],k['internal_missing']),(65536,65536,3))

    def test_first_missing_is_not_dependent_tail_or_final_idr(self):
        import tempfile
        from pathlib import Path
        from lan_gap_heads import ROW,analyze
        with tempfile.TemporaryDirectory() as temp:
            f=Path(temp)/'trace.ssmeta';rows=[]
            for frame,count in [(1,3),(2,64),(3,2),(4,70),(5,4)]:
                for stage in (0,1):
                    rows.extend(ROW.pack(stage,frame,frame,1000,0) for _ in range(count))
            f.write_bytes(b''.join(rows)+ROW.pack(255,0,0,len(rows),0))
            group,frames,heads,missing=analyze(f,[[0,1,4,2]])
            self.assertEqual((heads,missing,group(heads)['source_packets']['max']),({2},{2,3},64))
            with self.assertRaises(ValueError):analyze(f,[[0,1,4,2],[0,2,5,2]])
            f.write_bytes(b''.join(rows))
            with self.assertRaises(ValueError):analyze(f,[])

    def test_discontinuity_at_frame_boundary_does_not_identify_an_exact_frame(self):
        o={'verified':True,'discontinuities':2,'internal_missing':8}
        e=[{'gap_events':[[0,7,11,3],[0,18,21,2],[0,26,28,1]]}]
        rows=['lan_source_rx_gap prev=8 next=8 missing=3','lan_source_rx_gap prev=18 next=19 missing=5']
        r=rc.source_rx_gap_overlap(rows,o,e)
        self.assertEqual((r['gap_runs'],r['inside_first_frame'],r['in_or_bordering_first_frame'],r['unrelated_first_frames']),(3,1,2,1))
        self.assertEqual(rc.source_rx_gap_overlap(rows[:1],o,e)['status'],'incomplete_event_sample')
        self.assertEqual(rc.counter_delta({'input_errors':7},{'input_errors':12}),{'input_errors':5})
        self.assertEqual(rc.counter_delta({'input_errors':7},{}),{})
        self.assertEqual(rc.counter_delta({'input_errors':7},{'input_errors':1}),{})

    def test_failed_start_is_not_a_zero_bitrate_benchmark(self):
        lines=['lan_source_rx_seq finish=1 packets=0 holes=0 breaks=0 backwards=0 invalid=0 jumps=0',
               'wan_media_host video_to_phone=0 phone_video_probes=6 control_to_phone=5 drop_local=0']
        self.assertEqual(rc.failed_start_boundary(lines,[{'samples':[[1000,0,0,0]]}])['status'],
                         'no_video_at_windows_ingress_despite_probes')
        self.assertEqual(rc.failed_start_boundary(lines[1:],[{'samples':[[1000,0,0,0]]}])['status'],'unavailable')
        self.assertEqual(rc.failed_start_boundary(lines,[{'samples':[[1000,1,1,1]]}])['status'],'not_a_zero_frame_start')

    def test_scope_not_custom_wan_or_interactive(self):
        from windows_companion import paired_video_rate,lan_wire_budget
        self.assertEqual([rate for rate in range(2000,50001,1000) if paired_video_rate(rate) and lan_wire_budget(rate)==34000],[20000])
        rc.verify_scope('vbv50',True,'1080p60',20000,None)
        for opts in [('unknown',True,'1080p60',20000,None),('vbv50',False,'1080p60',20000,None),
                     ('vbv50',True,'1080p60',21000,None),('vbv50',True,'1080p30',20000,None),
                     ('vbv50',True,'1080p60',20000,'verify')]:
            with self.assertRaises(ValueError):rc.verify_scope(*opts)

    def test_real_phone_request_is_checked_before_capture_launch(self):
        from check_lan_path import ObservedHost
        from types import SimpleNamespace
        host=SimpleNamespace(requested_encoder_trial='quality4')
        for origin,rate,wan in [(16000,16000,False),(20000,18000,False),(20000,20000,True)]:
            with self.assertRaisesRegex(RuntimeError,'encoder_trial_actual_request_mismatch'):
                ObservedHost.configuration(host,origin,rate,300,wan)

    def test_changes_only_reservoir_and_fails_closed(self):
        self.assertEqual(rc.configure(self.safe,'stock'),self.safe)
        self.assertEqual(rc.configure(self.safe,'vbv50'),self.safe+'nvenc_vbv_increase = 50\n')
        self.assertEqual(rc.configure(self.safe,'quality4'),self.safe+'nvenc_preset = 4\n')
        self.assertEqual(rc.configure(self.safe,'fullpass'),self.safe+'nvenc_twopass = full_res\n')
        for mode in rc.PROFILES:
            self.assertTrue(rc.config_witness(rc.configure(self.safe,mode),mode))
        self.assertFalse(rc.config_witness(self.safe+'nvenc_twopass = full_res\nnvenc_twopass = full_res\n','fullpass'))
        self.assertFalse(rc.config_witness(rc.configure(self.safe,'fullpass100').replace('lan_encryption_mode = 2','lan_encryption_mode = 0'),'fullpass100'))
        self.assertFalse(rc.config_witness(rc.configure(self.safe,'fullpass'),'fullpass100'))
        for bad in [self.safe+'nvenc_vbv_increase=0\n',self.safe+'bind_address=0.0.0.0\n',
                    self.safe.replace('wan_encryption_mode = 2','wan_encryption_mode = 0')]:
            with self.assertRaises(ValueError):rc.configure(bad,'vbv50')
            with self.assertRaises(ValueError):rc.configure(bad,'stock')

    def test_requires_actual_runtime_settings_not_configuration(self):
        obs=dict(rc.effective(self.created),frame_target_kb=41.67)
        self.assertTrue(rc.verified([obs],'vbv50'))
        self.assertTrue(rc.verified([dict(obs,preset=4,vbv_increase_pct=0)],'quality4'))
        self.assertTrue(rc.verified([obs,obs],'vbv50'))
        for settings,mode in [([], 'stock'),([obs,dict(obs,frame_target_kb=12)],'vbv50'),([obs],'vbv25'),
                              ([dict(obs,filler=True)],'vbv50'),([dict(obs,two_pass=False)],'vbv50')]:
            self.assertFalse(rc.verified(settings,mode))
        for bad in [' other-private-text','\nprivate', ' vbv+25']:
            self.assertIsNone(rc.effective(self.created+bad))
        self.assertEqual(rc.effective(self.stamp+'Debug: NvEnc: requested encoded frame size 41.67 kB'),
                         {'requested_frame_kb':41.67})

    def test_capability_probes_before_rtsp_do_not_masquerade_as_active_encoder(self):
        w=rc.SessionEncoderWitness()
        goal=self.stamp+'Debug: NvEnc: requested encoded frame size 41.67 kB'
        w.note(self.created); w.note(self.created)
        self.assertFalse(w.report('vbv50')['verified'])
        w.note(self.stamp+'Debug: Final adjusted video encoding bitrate is 20000 Kbps')
        w.note(goal);w.note(self.created)
        self.assertEqual((w.report('vbv50')['verified'],w.preflight,len(w.settings)),(True,2,1))
        w.note(self.created)  # previous frame goal cannot be reused
        self.assertFalse(w.report('vbv50')['verified'])

    def test_paired_comparison_needs_every_matching_real_timestamp(self):
        lines=[f'pic {i} {n} {n/60:.6f} {42000+i}' for n in range(960) for i in range(3)]
        out=paired.compare(lines,16)
        self.assertEqual((out['measured_fps'],out['frames_per_branch']),(60,960))
        self.assertEqual(out['mean_vcl_mbps']['stock'],20.16)
        for invalid in [lines[:-1],lines[:30]+lines[31:],['unexpected']+lines,
                        [v.replace('pic 2 600 10.000000','pic 2 600 10.001000') for v in lines]]:
            with self.assertRaises(ValueError):paired.compare(invalid,16)

    def test_paired_encoder_excludes_duplicates_and_non_picture_units(self):
        args=paired.command('ffmpeg',0,0,36)
        self.assertIn('dup_frames=0',args[args.index('-filter_complex')+1])
        self.assertEqual(args[args.index('-fps_mode:v')+1],'passthrough')
        self.assertEqual(args[args.index('-bsf:v')+1],'filter_units=pass_types=1-5')
        self.assertEqual(args[args.index('-f')+1],'null')

    def test_quality_loopback_checks_each_decoded_frame_and_rejects_missing_metrics(self):
        lines=[msg for n in range(960) for i in range(3)
               for msg in (f'pic {i} {n} {n/60:.6f} 29500',f'ssim {i} {n} {n/60:.6f}')]
        err='\n'.join(f'[ssim@{k} @ 000abc] SSIM Y:0.900000 (10) U:0.95 (13) V:0.95 (13) All:0.912345 (11)'
                      for k in paired.PRESETS)
        report=paired.quality_report(lines,err,16)
        self.assertEqual(report['mean_ssim'],dict.fromkeys(paired.PRESETS,.912345))
        with self.assertRaises(ValueError):paired.quality_report(lines[:-1],err,16)
        with self.assertRaises(ValueError):paired.quality_report(lines,'',16)
        args=paired.command('ffmpeg',0,0,16,'quality')
        for i in range(3):self.assertEqual(args[args.index(f'-bufsize:v:{i}')+1],'333333')
        args=paired.command('ffmpeg',0,0,16,'fullpass-budgets')
        self.assertEqual(args[args.index('-multipass')+1],'fullres')
        self.assertNotIn('-preset:v:1',args)
        self.assertEqual([args[args.index(f'-bufsize:v:{i}')+1] for i in range(3)],['333333','500000','666666'])
        self.assertEqual((args[args.index('-b:v')+1],args[args.index('-maxrate:v')+1]),('20M','20M'))

    def test_motion_witness_matches_the_actual_encoded_timeline(self):
        src=['pic 0 0 0 300','pic 0 1 0.02 320','pic 0 2 0.06 201']
        counters=[s for i,(t,d) in enumerate([(1.5,0),(1.52,12),(1.56,3)]) for s in
                  (f'frame:{i}    pts: {45+i}   pts_time:{t}',f'lavfi.signalstats.YDIF={d}')]
        r={'windows':[{'start_s':0,'frames':3}]}
        paired.motion_windows(r,src,counters)
        self.assertEqual((r['motion']['matched_frames'],r['windows'][0]['luma_change_mean_0_255']),(3,5))
        for bad in (counters[:-2],counters[:2]+counters[4:]+counters[2:4],counters[:-2]+[counters[-2].replace('1.56','1.59'),counters[-1]]):
            with self.assertRaises(ValueError):paired.motion_windows(r,src,bad)
        args=paired.command('ffmpeg',0,0,16,'fullpass-budgets','quality-pts.txt',True)
        self.assertIn('file=motion-luma.txt,nullsink',args[args.index('-filter_complex')+1])

    def test_target_sweep_has_independent_limits_and_one_frame_each(self):
        args=paired.command('ffmpeg',0,0,36,'target-sweep')
        for i,k in enumerate((12000,16000,20000)):
            for flag,value in [('b',f'{k}k'),('maxrate',f'{k}k'),('bufsize',str(k*1000//60))]:
                opt=f'-{flag}:v:{i}'
                self.assertEqual(args.count(opt),1)
                self.assertEqual(args[args.index(opt)+1],value)
        self.assertNotIn('-b:v',args)
        self.assertNotIn('-preset:v:1',args)
        self.assertEqual(args[args.index('-multipass')+1],'qres')
        rows=[f'pic {i} {n} {n/60:.6f} 21000' for n in range(960) for i in range(3)]
        report=paired.compare(rows,16,paired.TARGET_NAMES)
        self.assertNotIn('target_kbps',report)
        self.assertEqual(report['target_kbps_by_branch'],dict(zip(paired.TARGET_NAMES,(12000,16000,20000))))
        lite=paired.command('ffmpeg',0,0,36,'target-sweep-lite')
        self.assertNotIn('-dec',lite)
        self.assertNotIn('hwdownload',lite[lite.index('-filter_complex')+1])
        self.assertEqual(lite[lite.index('-bufsize:v:2')+1],'333333')

    def test_mixed_origin_remains_visible_and_absent_evidence_is_not_a_loss(self):
        rates={'encoder_kbps':20000}
        data=dict(status='matched',seconds=80,encoder_mbps_est=16,decoder_input_mbps=15,
                  windows=[dict(frames=f,duration_ms=20000,encoder_mbps_est=h,decoder_input_mbps=p,frame_gap_delta=g)
                           for f,h,p,g in [(1200,16,16.2,0),(1200,16,13.2,4),(800,13,12.7,0),(1200,20,18,0)]])
        answer=rc.diagnose(20000,rates,data,60,100)
        self.assertEqual(answer['window_counts'],dict(slow_source=1,below_at_normal_cadence=2,
            delivery_deficit_with_frame_gaps=1,both=1,delivery_delta_without_frame_gaps=1,frame_gap_windows=1))
        self.assertEqual(rc.diagnose(20000,{},data,60,100)['status'],'encoder_target_unknown')
        self.assertEqual(rc.diagnose(20000,{'encoder_kbps':18000},data,60,100)['status'],'encoder_target_different')
        self.assertEqual(rc.diagnose(20000,rates,dict(data,seconds=40),60,100)['status'],'matched_coverage_insufficient')
        data['windows'][0]['encoder_mbps_est']=float('nan')
        self.assertEqual(rc.diagnose(20000,rates,data,60,100)['status'],'invalid_window')

    def test_socket_receipt_and_system_context_have_distinct_evidence(self):
        r=dict(host_source_rx=dict(verified=False,internal_missing=0),phone_udp_device_wide_delta={'RcvbufErrors':150})
        e=rc.receiver_evidence(r)
        self.assertIsNone(e['host_internal_missing_shards'])
        self.assertIsNone(e['phone_socket_dropped_datagrams'])
        self.assertIsNone(e['early_policy_read_back'])
        self.assertEqual(e['phone_device_rcvbuf_errors_context'],150)
        r.update(host_source_rx={'verified':True,'internal_missing':0},phone_burst_receive={'active_windows':4},
                 phone_authenticated_udp_socket=dict(effective_bytes=524288,counted_drops=0,high_rate_seen=False),
                 phone_receive_admission=dict(cause='standard_lan_offer',base_bytes=524288))
        e=rc.receiver_evidence(r)
        self.assertEqual((e['host_internal_missing_shards'],e['phone_socket_dropped_datagrams'],e['early_policy_read_back']),(0,0,True))
        r['phone_burst_receive']={'active_windows':0}
        self.assertFalse(rc.receiver_evidence(r)['early_policy_read_back'])
        r['phone_burst_receive']={'active_windows':2}
        r['phone_receive_admission']['base_bytes']=425984
        self.assertFalse(rc.receiver_evidence(r)['early_policy_read_back'])

    def test_local_udp_success_is_not_decoder_receipt_or_display_loss(self):
        e=[dict(samples=[(0,1,1,0,0,0,0,0),(998,57,57,56,1000,3,0,0)])]
        a=dict(host_trace_complete=1,mapped_missing=3,phone_traced_missing_frames=3,
               phone_counts_unmatched_frames=0,phone_complete_missing_frames=2)
        r=rc.phone_boundary(e,a)
        self.assertEqual((r['gap_frames_with_all_host_observed_packets_accepted_by_local_udp'],r['units_submitted'],
                          r['callback_idr_requests'],r['reported_render_errors']),(2,57,0,0))
        self.assertEqual(rc.phone_boundary(e,dict(a,phone_counts_unmatched_frames=1))['status'],'incomplete_gap_coverage')
        self.assertEqual(rc.phone_boundary(e+e,a)['status'],'unavailable')


if __name__=='__main__':unittest.main()
