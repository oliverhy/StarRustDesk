import unittest
import phone_burst_metrics as b

class TestBurst(unittest.TestCase):
    def row(self,**kw):
        r=dict.fromkeys(b.FIELDS,0)
        r.update(t=2000,active=1,ts=1,ov=1,packets=48,stamped=47,bad=1,calls=15,full=1,burst=28,
                 age=19000,aged=4,loss=3,lossage=8000,lossburst=17,lossgap=2500,turn=9000)
        r.update(kw)
        return 'rx_ledger_burst '+' '.join(f'{k}={r[k]}' for k in b.FIELDS)
    def test_earliest_loss_marker_is_not_all_network_loss(self):
        a=b.parse(self.row());other=b.parse(self.row(t=4000,loss=0,lossage=0,lossburst=0,lossgap=0))
        s=b.summary([a,other])
        self.assertEqual((s['datagrams'],s['kernel_stamped'],s['drop_marker_increase'],s['drop_windows']),(96,94,3,1))
        self.assertEqual(s['worker_gap_before_drop_marker_us'],2500)
        self.assertIsNone(b.summary([other])['drop_marker_peak_kernel_age_us'])
        self.assertIsNone(b.summary([]))
        r=b.parse(self.row()+' mem=2 mempeak=150000 mempct=28')
        self.assertEqual(b.summary([r])['sampled_kernel_queue_bytes'],150000)
        self.assertIsNone(s['sampled_kernel_queue_bytes'])
        a['socket_counter']=21;other['socket_counter']=31
        s=b.summary([a,other]);self.assertEqual((s['socket_loss_intervals'],s['socket_increase_in_covered_windows']),(1,10))
        other['t']=9000
        self.assertEqual(b.summary([a,other])['socket_loss_intervals'],0)
    def test_unknown_format_never_reaches_results(self):
        for r in (self.row(burst=257),self.row(stamped=48),self.row(lossage=900000),self.row()+' payload=anything'):
            self.assertIsNone(b.parse(r))
    def test_drop_cluster_never_bridges_quiet_reset_or_unobserved_intervals(self):
        row=lambda t,n:dict(t=t,socket_counter=n,stamped=1,age=t,mem=1,mempct=90)
        r=[row(t,n) for t,n in [(0,0),(2000,392),(4001,533),(6000,533),(8000,600),
                                (15000,1200),(17000,2),(19000,None),(21000,1500)]]
        self.assertEqual(b.largest_socket_drop_cluster(r),
            dict(start_ms=0,end_ms=4001,drops=533,windows=2,queue_age_us=4001,queue_pct=90))
        self.assertIsNone(b.largest_socket_drop_cluster([row(1,None),row(2,1)]))
    def test_worker_pairs_drops_with_its_own_monotonic_window(self):
        self.assertEqual(b.parse(self.row()+' mem=2 mempeak=13 mempct=1 socket_drops=78')['socket_counter'],78)
        self.assertIsNone(b.parse(self.row()+' socket_drops=-1')['socket_counter'])
        self.assertNotIn('socket_counter',b.parse(self.row()))
        self.assertIsNone(b.parse(self.row()+' socket_drops=4294967296'))
