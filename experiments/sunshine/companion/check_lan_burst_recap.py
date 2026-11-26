import tempfile,unittest
from pathlib import Path
from analyze_lan_bursts import host_density,prefix,after_growth,socket_after_growth,known_gap_budget,longest_unit_break,bounded_margin_exposure,RECORD
from analyze_lan_bursts import queue_age_profile

class Recap(unittest.TestCase):
    def test_queue_percentile_uses_well_stamped_window_maxima_not_individual_packets(self):
        r=dict(packets=400,stamped=400,aged=40,age=8000)
        stats=queue_age_profile([r]*19+[{**r,'age':60000},{**r,'stamped':150,'age':99000},dict(age=100000)])
        self.assertEqual((stats['windows'],stats['p95_window_max_us'],stats['max_us'],stats['stamped_at_least_5ms_pct']),
                         (20,8000,60000,10))
        self.assertIsNone(queue_age_profile([r,r]))
    def test_bounded_margin_never_counts_losses_after_reversion(self):
        transitions=[dict(state=1,before=1048576,effective=1572864,time='23:59:58.500'),
                     dict(state=2,before=1572864,effective=1048576,time='00:00:02.090')]
        times=['23:59:58.000','23:59:59.000','00:00:00.000','00:00:01.000','00:00:02.000','00:00:03.000']
        rows=[dict(t=i*1000,log_time=t,socket_counter=n,stamped=100,aged=0,burst=8,age=2000)
              for i,(t,n) in enumerate(zip(times,[0,10,11,14,99,199]))]
        e=dict(samples=[(i*1000,0,0,60*i,10000*i,n,0,0,999)
                        for i,n in enumerate([2,5,7,9,80,90])],
               sample_stamps=times,peaks={str(1000*i):v for i,v in enumerate([500,600,50,67,900,300])})
        r=bounded_margin_exposure(rows,[e],transitions)
        self.assertEqual((r['between_readbacks_s'],r['complete_socket_intervals']['new_socket_drops'],
                          r['complete_player_intervals']['new_missing'],r['complete_player_intervals']['longest_complete_window_ms']),
                         (3.59,4,4,67))
        self.assertIsNone(bounded_margin_exposure(rows,[e],transitions[::-1]))
        self.assertIsNone(bounded_margin_exposure(rows,[e],transitions+[transitions[0]]))
        self.assertIsNone(bounded_margin_exposure(rows,[{**e,'sample_stamps':times[::-1]}],transitions))
    def test_unit_break_does_not_confuse_delivered_complete_with_socket_loss(self):
        epochs=[dict(gap_events=[[3000,9,12,2,700,20,0,1,0]])]
        def frame(n):return dict(sent_packets=10,source_packets=10,phone_authenticated=n,phone_loopback=n)
        groups=[{'10':frame(0),'11':frame(10)}];a=dict(host_trace_complete=1,host_stream_epochs=1,stream_epochs=1)
        b=longest_unit_break(epochs,groups,a,[('', 'core_wait_idr at=2450'),('', 'core_wait_idr at=2000')])
        self.assertEqual((b['phone_received_nothing'],b['complete_to_local_player'],b['logged_core_waits']),(1,1,1))
        h=dict(f=10,n=2,boundary='all_read_by_core',decision='abandoned_fec',late=7,need=1,waitn=1,failn=1)
        def with_core(status,heads):return longest_unit_break(epochs,groups,a,[],dict(status=status,heads=heads))
        self.assertEqual(with_core('matched',[h])['decoder_core']['first_fragments_observed_after_abandon'],7)
        for status,heads in [('incomplete',[h]),('matched',[h,h]),('matched',[{**h,'f':11}])]:
            self.assertNotIn('decoder_core',with_core(status,heads))
        del groups[0]['11']['phone_authenticated']; self.assertNotIn('incomplete_at_phone_ingress',longest_unit_break(epochs,groups,a,[]))
        epochs=[dict(gap_events=[[3000,8,9,0,2500,20,0,0,0],[3080,9,11,1,80,21,0,1,0]])]
        groups=[{'10':dict(source_packets=10,phone_authenticated=0,phone_loopback=0)}]
        b=longest_unit_break(epochs,groups,a,[])
        self.assertEqual((b['missing'],b['following_sequence_gap']['host_sent_nothing']),(0,1))
        epochs[0]['gap_events'][1][0]=3500;self.assertNotIn('following_sequence_gap',longest_unit_break(epochs,groups,a,[]))
    def test_socket_after_growth_excludes_straddling_interval_and_missing_time(self):
        def row(t,stamp,n):return dict(t=t,log_time=stamp,socket_counter=n,age=5000,stamped=200,aged=30,burst=42)
        rows=[row(1,'23:59:57.000',0),row(2001,'23:59:59.000',100),row(4001,'00:00:01.000',103),
              row(10001,'00:00:07.000',500)]
        transitions=[dict(time='23:59:58.000',state=1)]
        result=socket_after_growth(rows,transitions)
        self.assertEqual((result['covered_seconds'],result['new_socket_drops'],result['stamped_at_least_5ms_pct']),(2.0,3,15))
        rows[2]['socket_counter']=None
        self.assertIsNone(socket_after_growth(rows,transitions))
    def test_gap_budget_is_rounded_up_and_refuses_incomplete_evidence(self):
        a=dict(host_trace_complete=1,host_stream_epochs=1,stream_epochs=1,source_not_seen=0,
               host_frame_wire_max_bytes=58_864,reported_missing=30,mapped_missing=30)
        run=dict(route='lan',attribution=a,playback=dict(frame_gaps=30,secs=592.78))
        self.assertEqual(known_gap_budget(run)['max_mean_mbps_from_these_frames'],.024)
        for key,value in [('mapped_missing',29),('source_not_seen',1),('host_trace_complete',0),('stream_epochs',2)]:
            self.assertIsNone(known_gap_budget({**run,'attribution':{**a,key:value}}))
        self.assertIsNone(known_gap_budget({**run,'route':'relay'}))
    def test_rolling_ceiling_and_seal(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'numeric'; rows=[(1,1,i,0,0) for i in [1,1,1,2,2,5,5,5,5]]
            def write(missing):
                p.write_bytes(b''.join(RECORD.pack(*r) for r in rows+[(255,0,0,len(rows),missing)]))
            write(0);r=host_density(p)
            self.assertEqual((r['peak_in_one_integer_ms'],r['upper_bound_any_rolling_1ms'],r['video_udp_accepted']),(4,5,9))
            write(1);self.assertIsNone(host_density(p))
    def test_compares_only_a_single_complete_prefix(self):
        samples=[(t,0,0,t*60,2_500_000*t,3,0,0,210) for t in (8,280,300,380)]
        e={'samples':[(t*1000,*v) for t,*v in samples]}
        p=prefix([e],300);self.assertEqual((p['fps'],p['useful_mbps'],p['missing']),(60,20,3))
        self.assertIsNone(prefix([e,e],300));self.assertIsNone(prefix([e],600))
    def test_headroom_clock_crosses_midnight_and_peak_ignores_old_freeze(self):
        e=dict(samples=[(i*1000,0,0,i*60,i*2500000,2+i,0,0,999) for i in range(4)],
               sample_stamps=['23:59:58.000','23:59:59.100','00:00:00.100','00:00:01.100'],
               peaks={'1000':999,'2000':31,'3000':19})
        change=[dict(state=1,time='23:59:59.000')]
        self.assertEqual(after_growth([e],change)['longest_complete_window_ms'],31)
        del e['peaks']['2000'];self.assertIsNone(after_growth([e],change)['longest_complete_window_ms'])
        self.assertIsNone(after_growth([e],change+[dict(state=2,time='00:00:02.000')]))
