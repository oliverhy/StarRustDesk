import unittest
import phone_dispatch as d
from long_metrics import Recorder

def line(**v):
    r=dict.fromkeys(d.KEYS,0);r.update(t=12,reads=300,cp=299,cnt=299,stamps=240,rq=50);r.update(v)
    return 'rx_ledger_dispatch '+' '.join(f'{k}={r[k]}' for k in d.KEYS)

class Dispatch(unittest.TestCase):
    def test_controlled_arm_is_distinct_from_natural_activation(self):
        rec=Recorder('test',None)
        marker='12:00:00.001 I SesameWanProbe: rx_ledger_margin_comparison=1'
        rec.observe(marker);rec.observe(marker)
        self.assertEqual(rec.rx_margin_comparison,1)
        rec.observe('12:00:00.003 I SesameWanProbe: rx_ledger_margin state=1 before=1048576 effective=1572864')
        rec.observe('12:00:00.004 I SesameWanProbe: rx_ledger_margin_comparison=1')
        self.assertEqual(rec.rx_margin_comparison,2)
    def test_margin_replay_rejects_old_or_mismatched_windows(self):
        def reader(t,n):return dict(t=t,ph=n,bc=n,hb=n,ha=n,dc=n,ds=0)
        def burst(t,n,age):return dict(t=t,socket_counter=n,packets=1000,stamped=1000,aged=age,burst=72,age=25000)
        rows=[reader(2000,0),reader(4000,83),reader(6000,92)]
        packet=[burst(2001,0,0),burst(4000,83,347),burst(6001,175,250)]
        r=d.margin_opportunities(rows,packet)
        self.assertEqual([w['eligible'] for w in r['positive']],[False,True])
        self.assertEqual(r['positive'][0]['stamped_old_pct'],34.7)
        self.assertEqual(d.margin_opportunities(rows,[*packet[:2],{**packet[2],'socket_counter':80}])['covered_intervals'],1)
        self.assertIsNone(d.margin_opportunities(rows,[*packet[:2],{**packet[2],'t':7500}]))
    def test_margin_requires_correct_order_exact_readback_and_no_rearm(self):
        rec=Recorder('test',None)
        def line(n,s,b,e):rec.observe(f'12:00:0{n}.000 I SesameWanProbe: rx_ledger_margin state={s} before={b} effective={e}')
        base,limit=1<<20,3<<19
        line(0,2,limit,base);line(1,1,base,limit+1);line(2,1,base,limit);line(3,1,base,limit)
        line(4,4,limit,base);line(5,2,limit,base);line(6,1,base,limit)
        self.assertEqual([q['state'] for q in rec.rx_margin],[1,2])
    def test_already_high_ignored_and_incomplete_counters_are_not_confirmed_interventions(self):
        base=dict(windows=300,coverage='matched',reader_qos_states=[1],phase_bounds=None,observed_drops=4)
        self.assertEqual(d.qualify(base,'initiated',600),'reader_level_changed_and_read_back')
        self.assertEqual(d.qualify(dict(base,reader_qos_states=[3]),'initiated',600),'already_at_or_above')
        self.assertEqual(d.qualify(dict(base,coverage='partial'),'initiated',600),'evidence_incomplete')
        self.assertEqual(d.qualify(base,'phase',600),'phase_missing_or_mixed')
        self.assertEqual(d.qualify(dict(base,reader_qos_states=[0],phase_bounds=dict(all_windows_covered=True,counts=dict(ph=4))),'phase',600),'reader_phase_observed')
    def test_four_buckets_not_four_proven_causes(self):
        a=d.parse(line(inc=2,dp=4,du=3,pool=7000,wp=6800,span=9000))
        b=d.parse(line(t=2012,inc=1,dr=9,ready=9000,wr=7300,off=2000,wo=1900))
        for total,status in [(16,'matched'),(20,'partial'),(12,'inconsistent'),(None,'unknown')]:
            s=d.summarize([a,b],total);self.assertEqual((s['observed_drops'],s['coverage'],s['peaks_us']['wo']),(16,status,1900))
    def test_ignore_unknown_invalid_and_replayed_windows(self):
        rec=Recorder('test',None)
        for l in [line(),line(),line(t=11),line(t=2012),'rx_ledger_dispatch private',line(t=3012,ready=10,off=11),line(t=4012,cp=333)]:
            rec.observe('12:00:00.000 I SesameWanProbe: '+l)
        self.assertEqual([x['t'] for x in rec.rx_dispatch],[12,2012])
    def test_missing_is_not_clean_and_unavailable_scheduler_is_not_proof(self):
        self.assertIsNone(d.summarize([],0))
        a=d.parse(line(rq=0,ready=6000,off=4000,runq=0))
        self.assertEqual((a['rq'],a['runq']),(0,0))
        self.assertIsNone(d.parse(line(inc=1,dp=0)))
    def test_qos_requires_numeric_readback_and_legacy_is_not_confirmed(self):
        self.assertIsNone(d.parse(line()+' reader_qos=7'))
        self.assertEqual(d.summarize([d.parse(line()),d.parse(line(t=2012)+' reader_qos=1')])['reader_qos_states'],[0,1])
    def test_survivor_independent_bounds_optional_and_must_partition_every_counter_delta(self):
        def extended(**v):
            x=dict.fromkeys(d.PHASE,0);x.update(ph=7,bc=6,bu=1,ds=7,mc=20,mw=43,pb=99);x.update(v)
            return line(inc=1,du=7)+' phase_v=1 '+ ' '.join(f'{k}={x[k]}' for k in d.PHASE)
        s=d.summarize([d.parse(line()),d.parse(extended())],7)
        self.assertFalse(s['phase_bounds']['all_windows_covered'])
        self.assertEqual(s['phase_bounds']['counts']['bc'],6)
        for v in (dict(bc=7),dict(ds=8),dict(hb=8),dict(pa=101),dict(mo=70)):
            self.assertIsNone(d.parse(extended(**v)))
