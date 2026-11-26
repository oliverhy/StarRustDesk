import unittest

from tx_probe import hello, intersect_events, is_challenge
from udp_broker import Broker, tickets


class TxProbeContract(unittest.TestCase):
    def test_authenticated_hello_does_not_change_routing_state(self):
        keys=tickets(b"x"*32)
        key,nonce=keys[0],bytes(range(16))
        broker=Broker(keys)
        challenge=broker.request(hello(key,nonce),("198.51.98.1",31000),10)
        self.assertTrue(is_challenge(key,nonce,challenge))
        self.assertFalse(is_challenge(key,bytes(range(1,17)),challenge))
        self.assertFalse(is_challenge(keys[1],nonce,challenge))
        self.assertIsNone(broker.lease)
        self.assertEqual(broker.proved,{})
        self.assertEqual((broker.rx,broker.tx,broker.dropped),(0,0,0))

    def test_report_only_probes_completed_inside_stall(self):
        events=[dict(phase=1,utc_ms=1000,busy_ms=0,errno=10035,ready=0,attempts=1),
                dict(phase=2,utc_ms=2000,busy_ms=1000,errno=10035,ready=0,attempts=65),
                dict(phase=3,utc_ms=3000,busy_ms=2000,errno=10035,ready=1,attempts=130)]
        udp=[[999,1,24,0],[1392,1,27,0],[1900,2,0,0],[2960,1,51,0]]
        lan=[[1300,1,2,1,0,0,0,1],[2050,0,0,1,0,0,0,2]]
        result=intersect_events(events,udp,lan,[[240,21],[998,7],[3040,26],[4000,7]])
        self.assertEqual(len(result),1)
        self.assertEqual(result[0]["reported_not_writable"],2)
        self.assertEqual(result[0]["udp_success"],1)
        self.assertEqual(result[0]["udp_timeout"],1)
        self.assertEqual(result[0]["gateway_success"],1)
        self.assertEqual(result[0]["gateway_timeout"],1)
        self.assertEqual(result[0]["wlan_notifications"],[[-2,7],[2040,26]])

    def test_counters_use_sample_time_not_probe_start(self):
        events=[dict(phase=1,utc_ms=1000,busy_ms=0,errno=10035,ready=0,attempts=1),
                dict(phase=3,utc_ms=3000,busy_ms=2000,errno=10035,ready=1,attempts=80)]
        lan=[[900,0,0,1,3,0,100,300],[1400,0,0,1,3,0,100,390],
             [2750,0,0,1,4,0,500,580]]
        observed=[[900,1360,0,5,0],[1400,1860,0,5,0],[2750,3220,0,4,0]]
        r=intersect_events(events,[],lan,link_observed=observed)[0]
        self.assertEqual(r["gateway_full_failures"],1)
        self.assertEqual(r["gateway_cache_states"],[(5,0)])
        self.assertEqual(r["link_interval"],dict(first_ms=360,last_ms=860,
                         discards=0,errors=0,tx_bytes=0,rx_bytes=90))

    def test_late_windows_wakeup_is_not_counted_as_a_timeout_inside_the_stall(self):
        events=[dict(phase=1,utc_ms=1000,busy_ms=0,errno=10035,ready=0,attempts=1),
                dict(phase=3,utc_ms=2000,busy_ms=1000,errno=10035,ready=1,attempts=32)]
        udp=[[1500,2,0,0,790],[1600,1,40,0,41],[1100,2,0,0,568],[1400,2,0,0]]
        r=intersect_events(events,udp,[])[0]
        self.assertEqual((r["udp_timeout"],r["udp_success"],r["udp_measured_completions"],r["udp_legacy_estimates"]),(2,1,2,1))

    def test_counter_reset_and_cache_failure_are_not_normal_link_evidence(self):
        events=[dict(phase=1,utc_ms=1000,busy_ms=0,errno=10035,ready=0,attempts=1),
                dict(phase=3,utc_ms=3000,busy_ms=2000,errno=10035,ready=1,attempts=80)]
        lan=[[1100,0,0,1,3,0,100,300],[1700,1,2,1,0,0,260,390]]
        observed=[[1100,1550,1168,0,0],[1700,1702,0,1,1]]
        r=intersect_events(events,[],lan,link_observed=observed)[0]
        self.assertEqual(r["link_interval"],{})
        self.assertEqual(r["gateway_cache_errors"],[1168])
        self.assertEqual(r["gateway_cache_states"],[(1,1)])


if __name__=="__main__":
    unittest.main()
