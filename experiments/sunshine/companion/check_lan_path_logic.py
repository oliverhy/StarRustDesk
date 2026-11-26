"""Offline regression of same-frame-ID bounds and complete trace requirements."""
import tempfile
import unittest
import io
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch, Mock

from lan_path import bounds,locate,stages,timeline,Stage
from long_metrics import RECORD
from check_device import route_proofs, RouteTap


class TestLanPath(unittest.TestCase):
    def test_only_exact_native_route_markers_and_ambiguity_preserved(self):
        self.assertEqual(route_proofs('SesameSecureClient: companion_wifi_udp_authenticated=1\n'
                        'SesameWanProbe: companion_wifi_udp_authenticated=0\n'
                        'SesameWanProbe: companion_wifi_udp_authenticated=1 suffix'),set())
        events=['companion_wifi_udp_authenticated=1','companion_wan_relay_authenticated=1']
        self.assertEqual(route_proofs('\n'.join('12:33:00 SesameWanProbe: '+v for v in events)),set(events))

    def test_pretap_rejects_reused_pid_and_keeps_only_allowlisted_values(self):
        line=b'12:00:00 SesameWanProbe: companion_wifi_udp_authenticated=1\n'
        wrong=b'12:00:00 SesameSecureClient: companion_wan_relay_authenticated=1\n'
        p=SimpleNamespace(pid='3521',hdc=['hdc','-t','test'],shell=Mock(return_value=line.decode()))
        with patch('check_device.subprocess.Popen') as spawn:
            with self.assertRaisesRegex(RuntimeError,'previous_route'): RouteTap(p)
            spawn.assert_not_called()
        p.shell.return_value=''
        proc=Mock(stdout=io.BytesIO(wrong+line+line));proc.poll.return_value=0
        with patch('check_device.subprocess.Popen',return_value=proc) as spawn:
            tap=RouteTap(p)
            try:
                tap.worker.join(2)
                self.assertEqual(tap.snapshot(),{'companion_wifi_udp_authenticated=1'})
                self.assertIn('-P 3521 -T SesameWanProbe',spawn.call_args.args[0][-1])
            finally:tap.close()
        self.assertTrue(proc.stdout.closed)

    def test_compact_boundaries_preserve_packet_intervals_and_uncertainty(self):
        rows=[(1,0),(1,0),(1,0),(2,5),(3,9),(3,11),(3,11),(3,11),(4,16)]
        stage=Stage()
        for f,t in rows:stage.mark(f,t)
        for a,b in ((1,1),(2,2),(2,3),(3,3),(1,4),(5,5)):
            self.assertEqual(bounds(rows,a,b),bounds(stage,a,b))
    def test_source_sender_and_downstream_are_distinct(self):
        self.assertEqual(locate((901,910),(904,915),950,8),'at_or_before_host_video_ingress')
        self.assertEqual(locate((16,18),(904,920),950,8),'between_host_ingress_and_udp_accept')
        self.assertEqual(locate((16,22),(25,28),950,8),'after_host_udp_accept_before_phone_tunnel')
        self.assertEqual(locate((16,25),(25,28),950,890),'unresolved')
        self.assertEqual(locate((16,20),(None,None),950,5),'unresolved')
        self.assertEqual(locate((600,650),(650,670),950,12),'mixed_or_unresolved')

    def test_adjacent_packets_not_time_between_distant_frame_ids(self):
        rows=[(f,f*14) for f in range(1,201)]
        self.assertEqual(bounds(rows,1,200),(14,14))
        self.assertEqual(bounds(rows,3,3),(None,None))
        self.assertEqual(bounds(rows,3,211),(None,None))
        self.assertEqual(bounds([(8,60),(5,70),(9,80)],8,9),(None,None))

    def test_silence_within_boundary_frame_cannot_be_excluded_by_adjacent_frame_ids(self):
        source=bounds([(8,10),(8,800),(9,814),(9,818)],8,9)
        self.assertEqual(source,(14,790))
        self.assertEqual(locate(source,(14,18),800,5),'mixed_or_unresolved')
        self.assertEqual(bounds([(8,20),(8,28),(9,45)],8,8),(None,8))
        self.assertEqual(locate((None,8),(None,24),220,5),'after_host_udp_accept_before_phone_tunnel')

    def test_truncated_incomplete_restarted_and_ambiguous_files_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'host.ssmeta'
            def write(rows,footer):
                p.write_bytes(b''.join(RECORD.pack(*r) for r in rows+[footer]))
            base=[(0,1,2,300,0),(1,1,3,1,7)]
            write(base,(255,0,0,1,0)); self.assertIsNone(stages(p))
            write(base,(255,0,0,2,1)); self.assertIsNone(stages(p))
            write(base+[(255,0,0,2,0)],(255,0,0,3,0)); self.assertIsNone(stages(p))
            write(base+[(0,100,2000,300,0),(0,1,2001,300,0)],(255,0,0,4,0)); self.assertIsNone(stages(p))
            write(base+[(0,2,1,300,0)],(255,0,0,3,0)); self.assertIsNone(stages(p))
            p.write_bytes(b'x'); self.assertIsNone(stages(p))

    def test_duplicate_reports_dedup_and_phone_restart_never_mapped(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'host.ssmeta'
            rows=[(0,7,10,350,0),(1,7,11,1,9),(0,8,26,350,0),(1,8,28,1,10),(255,0,0,4,0)]
            p.write_bytes(b''.join(RECORD.pack(*r) for r in rows))
            line='video_path stage=2 ms=240 packets=20 event_gap=185 peak_gap=185 previous_frame=7 frame=8 loop_peak=8'
            rec=SimpleNamespace(epochs=[dict(samples=[(200,)])],path=[('a',line),('b',line),('c',line.replace('stage=2','stage=3'))])
            out=timeline(p,rec)
            self.assertEqual(len(out['gaps']),1)
            self.assertEqual((out['host_ingress_peak_ms'],out['host_udp_accept_peak_ms']),(16,17))
            self.assertEqual(out['gaps'][0]['first_observed_stage'],'after_host_udp_accept_before_phone_tunnel')
            rec.epochs[0]['samples']=[(50000,)]
            self.assertFalse(timeline(p,rec)['matching_duration'])
            self.assertEqual(timeline(p,rec)['gaps'][0]['first_observed_stage'],'unresolved')
            rec.epochs.append(dict(samples=[(200,)]))
            self.assertEqual(timeline(p,rec)['gaps'][0]['first_observed_stage'],'unresolved')


if __name__=='__main__':
    unittest.main()
