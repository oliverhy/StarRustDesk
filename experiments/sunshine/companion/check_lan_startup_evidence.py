import unittest
from lan_startup_evidence import explain,observe_endpoint

def row(i=0,plan=200,tx=200,us=300000,ack=1,rx=200,rs=298000,gap=5100,state=5):
    return f'lan_probe_step step={i} rate={8500*(1+i)} planned={plan} sent={tx} tx_us={us} ack={ack} received={rx} rx_us={rs} idle_us={gap} state={state}'

class Probe(unittest.TestCase):
    def test_correlate_same_wait_not_unrelated_phase_maxima(self):
        step=row(tx=36,rx=36,state=4)
        sender='lan_probe_sender step=0 attempts=36 no_data=0 block=0 no_buffer=0 other=0 short=0 waits=20 slow_waits=2 wait_us=298000 wait_max=17001 seal_us=800 seal_max=90 udp_us=600 udp_max=120'
        wait='lan_probe_wake step=0 signal=19 timeout=1 arm_fail=0 wait_fail=0 no_timer=0 slow_signal=1 slow_timeout=1 slow_arm=0 slow_fail=0 slow_none=0 sleep_us=12000 peak_kind=1 peak_arm=10 peak_wait=4990 peak_sleep=12000'
        self.assertEqual(explain([step,sender,wait])['steps'][0]['windows']['wake']['peak_kind'],1)
        self.assertNotIn('wake',explain([step,sender])['steps'][0]['windows'])
        for bad in [wait.replace('signal=19','signal=18'),wait.replace('peak_kind=1','peak_kind=0'),
                    wait.replace('peak_wait=4990','peak_wait=8000'),wait.replace('slow_timeout=1','slow_timeout=2')]:
            self.assertEqual(explain([step,sender,bad])['status'],'inconsistent_trace')
        self.assertEqual(explain([step,wait])['status'],'inconsistent_trace')
        self.assertEqual(explain([step,sender,wait,wait])['status'],'inconsistent_trace')
    def test_sender_coverage_preserves_unknowns_and_rejects_inconsistent_accounting(self):
        step=row(tx=36,rx=36,state=4)
        s='lan_probe_sender step=0 attempts=38 no_data=0 block=1 no_buffer=1 other=0 short=0 waits=20 slow_waits=18 wait_us=298000 wait_max=17000 seal_us=800 seal_max=90 udp_us=600 udp_max=120'
        self.assertNotIn('windows',explain([step])['steps'][0])
        d=explain([step,s])['steps'][0]['windows']
        self.assertEqual((d['round_packet_ceiling'],d['outside_phases_us']),(40,600))
        for rows in [[s],[step,s,s],[step,s.replace('attempts=38','attempts=37')],
                     [step,s.replace('waits=20','waits=19').replace('wait_us=298000','wait_us=300000')]]:
            self.assertEqual(explain(rows)['status'],'inconsistent_trace')
        self.assertEqual(explain([step,s+' raw'])['status'],'invalid_trace')
    def test_short_startup_cannot_stand_in_for_long_or_public_tests(self):
        from check_lan_path import run
        from unittest.mock import patch
        with patch('check_lan_path.wc.load_fixture',side_effect=AssertionError('must reject before device I/O')):
            for seconds,short,medium in [(600,True,'ethernet'),(20,False,'ethernet'),(20,True,'wifi')]:
                with self.assertRaisesRegex(RuntimeError,'invalid_startup_only_scope'):
                    run('not-a-device',seconds,startup_only=short,host_medium=medium)
    def test_no_inferred_denial_or_arbitrary_text_saved(self):
        obs={}
        for msg in ['secure_result=other','secure_result=standard_video_budget_insufficient extra',
                    'bandwidth_result state=3 good_kbps=55555 unstable_kbps=0 cap_kbps=34000']:
            observe_endpoint(obs,msg)
        self.assertEqual(obs,{})
        observe_endpoint(obs,'bandwidth_result state=3 good_kbps=0 unstable_kbps=8500 cap_kbps=34000')
        self.assertNotIn('budget_denial_seen',obs)
        observe_endpoint(obs,'secure_result=standard_video_budget_insufficient')
        self.assertEqual(obs,{'sample':dict(state=3,good_kbps=0,upper_kbps=8500),'budget_denial_seen':True})
    def test_exact_limits_and_four_valid_steps(self):
        rows=[row(i,tx=200,rx=194,rs=375000,gap=55000,state=2 if i==3 else 5) for i in range(4)]
        r=explain(rows);self.assertEqual(r['status'],'grade_observed')
        self.assertTrue(all(not v['reasons'] for v in r['steps']))
        self.assertEqual(explain(rows[:-1])['status'],'incomplete_trace')

    def test_sender_and_receiver_are_not_interchangeable(self):
        r=explain([row(tx=180,us=340000,rx=166,gap=60000,state=4)])
        self.assertEqual(r['steps'][0]['reasons'],['sender_packet_count','sender_duration'])
        r=explain([row(rx=193,rs=375001,gap=55001,state=3)])
        self.assertEqual(r['steps'][0]['reasons'],['receiver_packet_count','receiver_duration','receiver_read_gap'])

    def test_missing_ack_is_not_zero_received(self):
        r=explain([row(ack=0,rx=0,rs=0,gap=0)])
        self.assertIsNone(r['steps'][0]['received'])
        self.assertEqual(r['steps'][0]['reasons'],['sample_reply_missing'])

    def test_missing_or_contradictory_rows_are_not_success(self):
        self.assertEqual(explain([])['status'],'no_samples')
        self.assertEqual(explain([row(1)])['status'],'inconsistent_trace')
        self.assertEqual(explain([row(state=3)])['status'],'grade_disagrees_with_counts')
        self.assertEqual(explain([row()+' unknown'])['status'],'invalid_trace')
        self.assertEqual(explain([row(gap=56000,state=3),row(1)])['status'],'inconsistent_trace')
