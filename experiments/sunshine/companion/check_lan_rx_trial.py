import unittest
from lan_rx_trial import summarize,gap_paths

class RxTrial(unittest.TestCase):
    def test_late_only_observation_does_not_artificially_shorten_recovery(self):
        m=summarize([('',s) for s in ('lan_loss_recovered unit_ms=205 surface_ms=212 idr=1 retry=1 source=2',
            'lan_loss_recovered unit_ms=0 surface_ms=3 idr=0 retry=0 source=3','lan_loss_idr_retry=1')])
        self.assertEqual((m['loss_to_surface_max_ms'],m['submit_to_surface_max_ms']),(212,7))
        self.assertEqual((m['confirmed_recoveries'],m['decoder_only'],m['repair_requests']),(1,1,1))
        m=summarize([('','lan_loss_recovered unit_ms=0 surface_ms=3 idr=1 retry=0 source=3')])
        self.assertIsNone(m['loss_to_surface_max_ms']);self.assertEqual(m['submit_to_surface_max_ms'],3)
    def test_no_events_no_inferred_latencies_and_no_arbitrary_data(self):
        m=summarize([['','lan_loss_recovered unit_ms=500 surface_ms=400 idr=1 retry=0'],
                     ['','rx_ledger_ahead packets=15 blocks=1 oldest_us=700 extra=reject'],
                     ['','rx_ledger_ahead packets=25 blocks=1 oldest_us=1'],[],None])
        self.assertIsNone(m['oldest_batch_max_us']);self.assertIsNone(m['loss_to_surface_max_ms'])
    def test_batch_ages_are_per_window_extremes_not_per_frame_latency(self):
        m=summarize([['','rx_ledger_ahead packets=36 blocks=2 oldest_us=8000'],
                     ['','rx_ledger_ahead packets=8 blocks=2 oldest_us=4000']])
        self.assertEqual((m['handed_datagrams'],m['avg_datagrams_per_batch'],m['oldest_batch_max_us']),(44,11,8000))
    def test_missing_packets_are_not_automatically_labeled_wifi_or_decoder_loss(self):
        rows=[dict(gap_events=[[400,99,104,4,70,10,0,1,0]])]
        def packet(a,b,c,d):return dict(source_packets=a,sent_packets=b,phone_authenticated=c,phone_loopback=d)
        paths=[{'100':packet(12,12,12,12),'101':packet(12,12,8,8),'102':packet(13,13,13,12)}]
        g,=gap_paths(rows,paths)
        self.assertEqual((g['all_entered_local_udp'],g['short_at_phone'],g['short_at_loopback'],g['unmatched']),(1,1,1,1))
        self.assertEqual(g['first_missing_path'],'all_entered_local_udp')  # later loss doesn't reclassify the first frame
        self.assertEqual(gap_paths(rows,[{'101':packet(12,12,8,8)}])[0]['first_missing_path'],'unmatched')
        self.assertEqual(gap_paths(rows,[]),[])
