import io
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from tx_probe import TxProbes
from scan_cadence import classify
from scan_order import compare
from wifi_uplink import checked_addresses, completed, describe, phy_range, ping_result, quality_range, radio_range, rtt_range


class UplinkWitnessTests(unittest.TestCase):
    def test_targets_are_distinct_hosts_on_paired_rfc1918_subnet(self):
        pc,phone,gw='192.168.33.10','192.168.33.20','192.168.33.1'
        self.assertEqual(checked_addresses(pc,phone,gw),(phone,gw))
        for target in (None,pc,phone,'192.168.34.1','192.168.33.0','192.168.33.255','1.1.1.1','::1'):
            with self.assertRaises((ValueError,TypeError)): checked_addresses(pc,phone,target)
        with self.assertRaises(ValueError): checked_addresses('127.0.0.1','127.0.0.2','127.0.0.3')

    def test_ping_requires_bound_address_and_real_response(self):
        pc,gw='192.168.33.20','192.168.33.1'
        head=f'Ping {gw} ({gw}) from {pc} ({pc}): 8(36) bytes.\n'
        reply=f'16 bytes from {gw}: icmp_seq=1 ttl=64 time=7.4 ms\n'
        ok='1 packets transmitted, 1 received, 0% packet loss'
        self.assertEqual(ping_result(head+reply+ok,pc,gw),(1,8))
        self.assertEqual(ping_result(head+'1 packets transmitted, 0 received, 100% packet loss',pc,gw),(2,0))
        for bad in ('ping: permission denied',head+ok,head+reply,head.replace(pc,'wlan0')+reply+ok):
            self.assertEqual(ping_result(bad,pc,gw),(0,0))

    def test_timestamp_containment_and_distinct_station(self):
        span=dict(begin_ms=2000,end_ms=3800,busy_ms=1801,recovered=True,errno=10035,attempts=110)
        phone=[[1000,1200,1,8],[1980,2100,2,0],[2500,2650,1,4],[3150,4100,2,0],[4500,4800,1,7]]
        lan=[[1200,1,3],[2150,0,0],[3620,0,0],[4300,1,3]]
        obs=[[1200,1210],[2150,2690],[3620,3900],[4300,4310]]
        out=describe([span],phone,lan,obs,[[1000,7],[3799,7],[3803,26],[8000,7]],[])
        w=out['long_refusals'][0]
        self.assertTrue(w['phone_ok_during_pc_failure'])
        self.assertEqual((w['phone_gateway']['ok'],w['phone_gateway']['timeout'],w['pc_gateway']['no_reply']),(1,0,1))
        self.assertEqual(w['pc_gateway']['confirmed_timeout'],0)
        self.assertEqual(out['gateway_episodes'][0]['phone_ok_inside_individual_failed_ping'],1)
        self.assertEqual(w['scan_complete_from_start_ms'],[1799])
        self.assertEqual(out['scan_complete_away_from_long_refusals'],2)
        self.assertEqual(completed([[2000,1999],[3800,3800]],2000,3800),[])
        # No post-stall control: a superficially good ping cannot qualify.
        self.assertFalse(describe([span],phone[:-1],lan,obs,[],[])['long_refusals'][0]['phone_ok_during_pc_failure'])
        step=describe([dict(span,end_ms=202000)],phone,lan,obs,[],[])
        self.assertEqual((step['clock_inconsistent_spans'],step['long_refusals']),(1,[]))

    def test_phy_unsupported_reset_and_query_error_never_become_zero_loss(self):
        def row(n, err=0): return [1000,1001,err,n,0,2,0,0,n,0]
        self.assertIsNone(phy_range([row(0),row(0)])['deltas'])
        self.assertIsNone(phy_range([row(8),row(1),row(9)])['deltas'])
        self.assertIsNone(phy_range([row(8),row(9,5)])['deltas'])
        self.assertEqual(phy_range([row(5),row(7)])['deltas']['tx'],2)

    def test_signal_and_association_are_not_media_throughput(self):
        self.assertIsNone(quality_range([[100,102,1168,0,0,0]])['reported_quality_range'])
        self.assertEqual(radio_range([[100,102,0,-40,0,1],[104,105,0,-80,5,0],[109,111,13,0,0,0]]),
                         dict(samples=3,valid_rssi=2,rssi_dbm=[-80,-40],connected=1,disconnected_or_transitional=1))
        self.assertEqual(rtt_range([[0,900,1,12],[901,2001,2,0]])['p95_ms'],12)

    def test_scan_cadence_counts_completions_not_refresh_or_failed_etw_setup(self):
        refusal=dict(begin_ms=17800,end_ms=20100,busy_ms=2300,errno=10035,recovered=True)
        j=dict(summary=dict(wlan_setup=1,spans=[refusal,dict(refusal,recovered=False)]),
               wlan=[[1000,7],[20000,7],[20003,26],[80000,7],[81100,8]])
        result=classify(j)
        self.assertEqual((result['complete'],result['refusals'],result['short_near_refusal'],
                          result['regular_all'],result['regular_near_refusal']),(3,1,1,1,0))
        j['summary']['wlan_setup']=0
        self.assertIsNone(classify(j))

    def test_actual_scan_order_needs_same_window_and_unique_complete(self):
        host=dict(summary=dict(wlan_setup=1,spans=[dict(begin_ms=1200,end_ms=2400,busy_ms=1200,
                                                         recovered=True,errno=10035)]),
                  link_observed=[[450,500],[4050,4100]],wlan=[[2398,7]])
        def trace(begin,end=2400):
            return (f'scan_etw_setup stage=5 error=0 pid=123 seconds=300\n'
                    f'scan_etw_event utc_100ns={begin*10000} id=20022 status=0\n'
                    f'scan_etw_event utc_100ns={end*10000} id=20023 status=0\n'
                    'scan_etw_finish stop=0 process=0 early=0 events=2 lost=0 buffer_lost=0 capped=0\n')
        for begin,want in [(900,'scan_first'),(1203,'too_close'),(1250,'refusal_first')]:
            self.assertEqual(compare(trace(begin),host)['order'][0]['order'],want)
        self.assertEqual(compare(trace(900).replace('lost=0','lost=1'),host)['status'],'trace_incomplete')
        self.assertEqual(compare(trace(4900,5300),host)['status'],'no_matched_fault')
        nested=trace(900).replace('scan_etw_event utc_100ns=24000000',
                                  'scan_etw_event utc_100ns=9500000 id=20022 status=0\nscan_etw_event utc_100ns=24000000')
        self.assertEqual(compare(nested.replace('events=2','events=3'),host)['status'],'trace_overlapping_scans')
        host['wlan'].append([2401,7])
        self.assertEqual(compare(trace(900),host)['status'],'no_matched_fault')

    def test_witness_has_no_wan_ticket_or_sender(self):
        with patch('tx_probe.udp_broker.tickets',side_effect=AssertionError):
            p=TxProbes('192.168.33.10',None,None,local_only=True)
            with patch('tx_probe.subprocess.Popen',side_effect=OSError):
                p.start();p.close()
            self.assertEqual((p.key,p.endpoint,p.workers),(None,None,[]))
            with self.assertRaises(ValueError):
                TxProbes('192.168.33.10','1.1.1.1:23388',None,local_only=True)
            p.process=SimpleNamespace(stdout=io.BytesIO(
                b'private_gateway ignore-this\nprivate_gateway 192.168.33.1\nwlan_phy 1000 1001 0 1 2 3 4 5 6 7\n'))
            p.link_run()
            self.assertEqual(p.gateway,'192.168.33.1')
            self.assertEqual(p.phy,[[1000,1001,0,1,2,3,4,5,6,7]])


if __name__=='__main__': unittest.main()
