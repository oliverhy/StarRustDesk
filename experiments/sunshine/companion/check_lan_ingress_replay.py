import tempfile
import unittest
from pathlib import Path

from lan_ingress_replay import gap_rows, gateway_cluster, loss_windows, paired, sender_bounds, video_gaps
from long_metrics import PAIR, RECORD, Recorder


class ReplayTests(unittest.TestCase):
    gap = ('07:00:00.000',205,203,19,19)
    row = (205,19,19,55,59,203000,173000,200000,3000,30000,2000,5000)

    def test_bounds_are_not_a_guess_at_the_packet_ordinal(self):
        records=[(0,0,0,1,0),(1,19,9,23,52),(1,19,10,23,55),(1,19,12,23,59),(1,19,18,23,61)]
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'trace'
            p.write_bytes(b''.join(RECORD.pack(*r) for r in [*records,(255,0,0,len(records),0)]))
            ep={(19,55):[],(19,59):[]}
            span=sender_bounds(p,[self.gap],ep)
            self.assertEqual(gap_rows([self.gap],span)[0]['windows_endpoint_span_upper_ms'],10)
            r=paired([self.row],[(1,1)],[self.gap],ep)['events'][0]
            self.assertEqual(r['kernel_minus_accept_spacing_interval_us'],[170000,172000])
            self.assertFalse(r['egress_on_wire_observed'])
            self.assertEqual((r['windows_send_spacing_ms'],r['kernel_minus_windows_spacing_us'],
                r['socket_queue_spacing_change_us'],r['post_read_spacing_change_us']),(2,171000,27000,3000))
            p.write_bytes(p.read_bytes()[:-RECORD.size])
            with self.assertRaisesRegex(ValueError,'unsealed'): sender_bounds(p,[self.gap],ep)

    def test_missing_end_missing_observer_and_quiet_trial_are_distinct(self):
        self.assertEqual(paired([],[],[],{})['status'],'not_in_archive')
        self.assertEqual(paired([],[(1,0)],[],{})['status'],'incomplete_capture')
        self.assertEqual(paired([],[(0,0)],[],{})['status'],'no_video_silence')
        self.assertEqual(paired([],[(1,0)],[self.gap],{})['status'],'no_exact_pair')

    def test_missing_duplicate_and_cross_epoch_send_witnesses_are_inconclusive(self):
        for b in [[],[(42,10)],[(1,10),(1,12)]]:
            ev=paired([self.row],[(1,1)],[self.gap],{(19,55):[(1,9)],(19,59):b})['events'][0]
            self.assertEqual(ev['status'],'ambiguous_sender')
            self.assertEqual(ev['phone_kernel_spacing_us'],173000)
            self.assertNotIn('kernel_minus_windows_spacing_us',ev)

    def test_distinct_frame_send_spacing_is_bounded_even_across_rekey(self):
        g=('07:00:00.000',360008,290,20609,20610)
        s=gap_rows([g],{20609:[359707,359716],20610:[360003,360011]})[0]
        self.assertEqual((s['windows_endpoint_span_lower_ms'],s['windows_endpoint_span_upper_ms']),(286,305))

    def test_an_exact_pair_without_footer_is_not_a_complete_run(self):
        delta=paired([self.row],[],[self.gap],{(19,55):[(1,8)],(19,59):[(1,10)]})
        self.assertEqual(delta['status'],'partial_exact_pairs')
        self.assertFalse(delta['coverage_sealed'])

    def test_reordering_and_drain_after_backlog_keep_signed_differences(self):
        # Later observed frame went on the wire first. Negative deltas are
        # meaningful and must not be normalized to zero or added as delays.
        gap=('07:00:00.000',500,200,21,20)
        row=(500,21,20,80,70,200000,270000,220000,60000,10000,30000,10000)
        ep={(21,80):[(3,15)],(20,70):[(3,13)]}
        d=paired([row],[(1,1)],[gap],ep)['events'][0]
        self.assertEqual((d['windows_send_spacing_ms'],d['kernel_minus_windows_spacing_us'],
            d['socket_queue_spacing_change_us'],d['post_read_spacing_change_us']),(-2,272000,-50000,-20000))
        line='video_path stage=2 ms=500 packets=8 event_gap=200 peak_gap=200 previous_frame=21 frame=20 loop_peak=1'
        self.assertEqual(video_gaps([(gap[0],line)]),[gap])

    def test_mismatched_clocks_or_video_identity_never_report_a_location(self):
        bad=list(self.row);bad[5]+=500
        with self.assertRaisesRegex(ValueError,'pair_clock'): paired([bad],[(1,1)],[self.gap],{})
        bad=list(self.row);bad[0]+=5
        with self.assertRaisesRegex(ValueError,'identity'): paired([bad],[(1,1)],[self.gap],{})

    def test_capture_selects_only_measured_gaps_and_accepts_only_numeric_pairs(self):
        row='video_path stage=2 ms=205 packets=8 event_gap=203 peak_gap=203 previous_frame=19 frame=19 loop_peak=1'
        self.assertEqual(video_gaps([(self.gap[0],row),(self.gap[0],row.replace('event_gap=203','event_gap=0'))]),[self.gap])
        pair='rx_ledger_gap_pair ms=205 f0=19 f1=19 c0=55 c1=59 auth=203000 kernel=173000 read=200000 q0=3000 q1=30000 p0=2000 p1=5000'
        self.assertIsNotNone(PAIR.fullmatch(pair))
        for suffix in (' extra',' p2=0','\nignored'):
            self.assertIsNone(PAIR.fullmatch(pair+suffix))
        r=Recorder('fixture',Path('.'),60)
        r.observe('07:00:00.000 SesameWanProbe: '+pair+'\n07:00:00.000 SesameWanProbe: '+pair+' unsafe')
        self.assertEqual([msg for _,msg in r.events],[pair])

    def test_gateway_includes_only_wholly_contained_probes(self):
        gaps=[('00:00:01.000',1000,200,10,11),('00:00:01.600',1600,200,13,14)]
        probes=[(785,900,1,115),(1000,1100,1,100),(1250,1400,2,0),(1550,1598,1,48)]
        v=gateway_cluster(gaps,(0,1500,-4,4),probes)
        self.assertEqual((v['whole_probes'],v['timeouts'],v['success_rtts_ms']),(2,1,[100]))

    def test_sample_is_not_identified_by_publication_time_alone(self):
        b=dict(socket_counter=0,t=100,loss=0)
        b1=dict(b,t=2100,socket_counter=3,log_time='00:00:06.000',packets=128,calls=90,
                burst=18,age=10000,aged=12,stamped=110,mempct=98)
        d=dict(t=100,ph=0)
        d1=dict(t=2106,ph=3,inc=1,bc=3,dc=3,dx=0,mc=50)
        ticks=[('00:00:04.000','rx_ledger_ahead packets=128 blocks=90 oldest_us=470'),
               ('00:00:06.000','rx_ledger_ahead packets=300 blocks=125 oldest_us=298')]
        def run():
            return loss_windows([b,b1],[d,d1],ticks)[0]['delivery_counter_match']
        self.assertEqual(run(),dict(delivery_to_publication_ms=2000,handoff_max_us=470))
        b1['packets']=300
        self.assertIsNone(run())
        d1['ph']=0
        with self.assertRaisesRegex(ValueError,'inconsistent'):run()


if __name__=='__main__': unittest.main()
