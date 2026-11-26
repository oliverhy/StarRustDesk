import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from core_rx_order import scan,ROW,abandonment_counts
from core_rx_diag import HEAD,END,parse,join

def line(tag,keys,d):return 'lan_core_'+tag+' '+' '.join(f'{k}={d.get(k,0)}' for k in keys)
def head(f=100,n=2,**kw):return line('head',HEAD,dict(f=f,n=n,**kw))
def tail(**kw):return line('end',END,dict(dict(reads=1000,gaps=1,samples=50,buf=600000),**kw))
def path(n):return dict(source_packets=7,sent_packets=7,phone_authenticated=n,phone_loopback=n)
class TestCoreRx(unittest.TestCase):
    def join_(self,h,e,x,rows=None):
        return join([{'gap_events':[[1,99,102,2,120,0,0,1,0]]}],[(None,t) for t in (rows or [h,e])],[{'100':x}])
    def test_inner_queue_short_not_inferred_from_wifi(self):
        r=self.join_(head(raw=5,auth=5,flags=64,need=2,failn=1),tail(drops=2),path(7))
        self.assertEqual(r['heads'][0]['boundary'],'short_at_core_read')
        self.assertEqual(r['heads'][0]['decision'],'abandoned_fec')
    def test_all_read_and_delayed_after_confirmed_abandon(self):
        r=self.join_(head(raw=7,auth=5,old=2,flags=64,late=2,lag=20,failn=1),tail(),path(7))
        self.assertEqual(r['head_counts'],dict(all_read_by_core=1,abandoned_fec=1,post_abandon_late_heads=1))
    def test_ordinary_parity_and_reference_wait_are_distinct(self):
        r=self.join_(head(raw=7,old=3,auth=4,flags=33,waitn=2,fulln=2),tail(),path(7))
        self.assertEqual(r['complete_wait_frames'],2);self.assertNotIn('post_abandon_late_heads',r['head_counts'])
        self.assertEqual(r['heads'][0]['decision'],'withheld_complete_for_reference')
    def test_absence_mismatch_and_out_of_range_never_are_zero(self):
        h=head(raw=5,auth=5);e=tail();p=path(5)
        self.assertNotEqual(self.join_(h,e,p,[h])['status'],'matched')
        self.assertEqual(self.join_(h,e,p,[e])['status'],'incomplete')
        self.assertEqual(self.join_(h,e,p,[h,h,e])['status'],'duplicate_head')
        self.assertEqual(self.join_(h,e,path(4))['status'],'inconsistent_core_count')
        self.assertEqual(self.join_(h,e,p)['heads'][0]['boundary'],'short_before_phone_auth')
        self.assertEqual(self.join_(h,tail(drops=-1),p)['socket']['drops'],-1)
        for v in (head(raw=2,auth=1),head(flags=128),head(late=2,old=1,raw=1),head(f=65536,n=2),e+' text=a'):
            self.assertIsNone(parse(v))
    def test_clean_session_needs_seal(self):
        self.assertEqual(join([{}],[(None,tail(gaps=0))],[{}])['status'],'matched')
        self.assertNotEqual(join([{}],[],[{}])['status'],'matched')
    def test_deficit_requires_observed_abandon_and_positive_need(self):
        h=lambda flag,need,b:dict(flags=flag,need=need,boundary=b)
        got=abandonment_counts([h(64,2,'all_read_by_core'),h(80,1,'short_before_phone_auth'),
                                h(64,0,'all_read_by_core'),h(16,3,'all_read_by_core')])
        self.assertEqual(got,dict(explicit_abandon_heads=3,below_normal_threshold_heads=2,
                                  eventually_all_read_but_short_at_abandon=1))
    def test_sender_order_uses_actual_sequence_not_millisecond_ties(self):
        with TemporaryDirectory() as d:
            p=Path(d)/'trace';rows=[(0,10,5,0,0),(0,11,5,0,0),(1,10,6,0,0),(1,11,6,0,0),(1,10,6,0,0)]
            p.write_bytes(b''.join(ROW.pack(*a) for a in rows))
            with self.assertRaises(ValueError):scan(p,{10})
            with p.open('ab') as out:out.write(ROW.pack(255,0,0,len(rows),0))
            r,=scan(p,{10})
            self.assertEqual(r['send']['tail_after_newer'],1)
            self.assertEqual(r['source']['tail_after_newer'],0)
