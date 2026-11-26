"""Offline checks of numeric attribution; no simulated result is reported as live."""
from pathlib import Path
import tempfile
import unittest

import long_metrics as m
import udp_broker as b


class TestAttribution(unittest.TestCase):
    def test_prearmed_receiver_does_not_imply_high_observed_rate(self):
        with tempfile.TemporaryDirectory() as root:
            r=m.Recorder('lan',Path(root),60)
            r.observe('SesameWanProbe: rx_ledger_admission reason=2 base=524288')
            r.observe('SesameWanProbe: rx_ledger_socket before=229376 effective=524288 qualified=0 drops=0')
            r.observe('SesameWanProbe: rx_ledger_admission reason=2 base=524288 unexpected=raw')
            self.assertEqual(r.rx_admission,dict(cause='standard_lan_offer',base_bytes=524288))
            self.assertFalse(r.rx_socket['high_rate_seen'])
            self.assertEqual(r.rx_socket['counted_drops'],0)

    def test_owned_socket_unknown_is_not_zero_and_non_numeric_input_is_ignored(self):
        with tempfile.TemporaryDirectory() as root:
            r=m.Recorder('lan',Path(root),60)
            self.assertIsNone(r.rx_socket)
            r.observe('SesameWanProbe: rx_ledger_socket before=212992 effective=425984 qualified=1 drops=-1')
            self.assertIsNone(r.rx_socket['counted_drops'])
            r.observe('SesameWanProbe: rx_ledger_socket before=212992 effective=425984 qualified=1 drops=23')
            r.observe('SesameWanProbe: rx_ledger_socket before=212992 effective=425984 qualified=1 drops=other')
            self.assertEqual(r.rx_socket,dict(before_bytes=212992,effective_bytes=425984,high_rate_seen=True,counted_drops=23))

    def test_requested_is_not_delivered_or_simultaneous(self):
        # 60 fps and 20 Mbps each occur, but never together. Nor can a
        # short burst of both pass a long-run test.
        with tempfile.TemporaryDirectory() as root:
            r=m.Recorder("joint-gate",Path(root),60)
            samples=[]; frames=size=0
            for s in range(121):
                frames+=60 if s<61 else 50
                size+=1_900_000 if s<61 else 2_600_000
                samples.append((s*1000,frames,frames,frames,size,0,0,0,22,4,0))
            r.epochs=[dict(rate=(20000,20000),samples=samples,peaks={x[0]:22 for x in samples})]
            result=r.summary("lan",120)
            self.assertFalse(result['sustained_20mbps_60fps'])
            self.assertEqual(result['clean_20mbps_60fps_windows'],0)

    def test_relay_offer_never_licenses_using_8m_on_direct(self):
        from check_public import measured_budget
        reply=[(1920,1080,60,550)]
        self.assertEqual(measured_budget("direct",True,[],reply,True),(1800,1400,None))
        for events,replies in (([],[(1920,1080,60,1850)]),
                (["companion_relay_capacity_plan wire_kbps=7300 video_cap_kbps=5800"],reply),
                (["companion_host_relay_frame_spread=1"],reply)):
            with self.assertRaises(RuntimeError):measured_budget("direct",True,events,replies,True)
    def test_source_counts_pictures_not_fragments_and_only_full_wire_seconds(self):
        with tempfile.TemporaryDirectory() as root:
            folder=Path(root); host=folder/"trace"
            rows=[]
            for i in range(151):
                for _ in range(2): rows.append((0,i+1,round(i*1000/60),1000,0))
            with host.open("wb") as f:
                for row in rows+[(255,0,0,len(rows),0)]: f.write(m.RECORD.pack(*row))
            rec=m.Recorder("unit",folder,60)
            rec.epochs=[dict(samples=[(2500,151,151,151,200000,0,0,0,40,34,2)],gap_events=[])]
            a=rec.attribute("direct",host,{},None)
            self.assertEqual((a["host_distinct_frames"],a["host_observed_fps"]),(151,60.0))
            self.assertEqual((a["host_video_wire_seconds"],a["host_video_wire_avg_kbps"],
                              a["host_video_wire_peak_kbps"]),(2,960,960))

    def test_high_relay_trial_requires_evidence_for_high_or_low_outcome(self):
        from check_public import high_trial_plan
        plans=["companion_relay_capacity_plan wire_kbps=7300 video_cap_kbps=5800"]
        active="companion_host_relay_frame_spread=1"
        high=[(960,540,30,5800)]; low=[(960,540,30,1400)]
        self.assertEqual(high_trial_plan(plans+[active],high,True)["selected_wire_kbps"],7300)
        fallback=["companion_relay_capacity_plan wire_kbps=1800 video_cap_kbps=1400"]
        self.assertTrue(high_trial_plan(fallback,low,True)["conservative_fallback"])
        for events,replies in ((plans,high),(fallback+[active],low),(fallback,high),(plans+fallback,low),([],low)):
            with self.assertRaises(RuntimeError): high_trial_plan(events,replies,True)

    def test_restart_gap_needs_an_actual_cross_decoder_presentation(self):
        with tempfile.TemporaryDirectory() as root:
            rec=m.Recorder("unit",Path(root),30)
            rec.epochs=[dict(samples=[(t*1000,30*t,30*t,30*t,30000*t,0,0,0,45,34,2)
                                    for t in range(1,61)],rate=(1400,1400)) for _ in range(2)]
            self.assertIsNone(rec.summary("relay",120)["longest_including_restart_ms"])
            rec.events=[("12:01:02.000","render_across_restart_ms=2975")]
            result=rec.summary("relay",120)
            self.assertEqual((result["largest_gap_ms"],result["longest_including_restart_ms"]),(45,2975))
    def test_early_loss_and_lifetime_peak_are_not_steady_playback_loss(self):
        from check_device import split_window
        rows={t:(t,0,0,t//32,1200*t,36,0,1,580,30,1) for t in range(1000,51_000,1000)}
        peaks={t:(580 if t==3000 else 64) for t in rows}
        tail,gaps,errors,peak=split_window(rows,peaks)
        self.assertEqual((tail[0][0],gaps,errors,peak),(8000,0,0,64))
        self.assertEqual(split_window(rows,{})[3],None)
        del rows[18000]
        self.assertIsNone(split_window(rows,peaks)[3])

    def test_phone_receive_local_delivery_and_decoder_wait_are_separate(self):
        with tempfile.TemporaryDirectory() as root:
            recorder=m.Recorder("relay",Path(root),60)
            pairs=bytearray(256)
            pairs[2:8]=bytes([1,1,2,1,2,2])
            recorder.observe("SesameWanProbe: rx_ledger first=1 pairs="+pairs.hex()+"\n"
                             "SesameWanProbe: rx_ledger_status covered=128 late=0 untracked=0\n"
                             "SesameSecureClient: core_wait_idr at=1950")
            details={
                f:m.Counter(source_packets=2,relay_forwarded=2,sent_packets=2) for f in (2,3,4)
            }
            details[2]["relay_rate_limited"]=1
            details[2]["source_packets"]=details[2]["sent_packets"]=3
            report={}
            recorder.count_missing_frames("relay",dict(gap_events=[(2000,1,5,3,90,1,0,1,20)]),details,report)
            self.assertEqual(report["phone_packet_audit_frames"],128)
            self.assertEqual(report["phone_traced_missing_frames"],3)
            self.assertEqual(report["phone_missing_before_authenticated_receive"],1)
            self.assertEqual(report["phone_local_delivery_short_frames"],1)
            self.assertEqual(report["phone_complete_missing_during_idr_wait"],1)
            self.assertEqual(report["gap_runs_start_relay_limited"],1)
            self.assertEqual(report["gap_runs_end_idr"],1)
            recorder.observe("SesameWanProbe: rx_ledger_status covered=256 late=1 untracked=0")
            self.assertIsNone(recorder.phone_counts(3))

    def test_same_frame_mapping_does_not_treat_all_gaps_as_relay_throttle(self):
        with tempfile.TemporaryDirectory() as root:
            directory=Path(root)
            recorder=m.Recorder("forced-relay",directory)
            recorder.epochs=[dict(samples=[(4200,800,800,800,34000,3,0,0,115,30,1)],
                gap_events=[(2000,9,13,3,140,5,4,0,20)],rate=(1400,1400))]
            host=directory/"host-numeric.ssmeta"
            rows=[(0,10,3000,748,0),(0,11,3033,748,0),(0,12,3066,748,0),(0,12,3066,748,0),
                  (1,10,3002,48,4),(1,11,3035,48,5)]
            host.write_bytes(b"".join(m.RECORD.pack(*r) for r in rows+[(255,0,0,len(rows),0)]))
            outcome=recorder.attribute("relay",host,{48:bytes([0,0,0,0,2,1])},0)
            self.assertEqual(outcome["reported_missing"],3)
            self.assertEqual(outcome["relay_limited_frames"],1)
            self.assertEqual(outcome["some_packets_not_sent"],1)
            self.assertEqual(outcome["all_sent_packets_forwarded"],1)
            self.assertEqual(outcome["host_frame_wire_p95_bytes"],1496)
            self.assertEqual(outcome["host_frame_wire_max_bytes"],1496)
            outcome=recorder.attribute("relay",host,{48:b""},1)
            self.assertEqual(outcome["relay_trace_complete"],0)
            self.assertNotIn("relay_limited_frames",outcome)

    def test_relay_correlation_does_not_export_wg_indices(self):
        trace=b.PacketTrace(b"z"*16)
        packet=b"\x04\0\0\0"+b"aaaa"+(12).to_bytes(8,"little")+bytes(50)
        trace.mark(packet,2)
        value=next(iter(trace.epochs.values()))
        self.assertEqual(value[0][12],2)
        trace.mark(packet,1)
        trace.mark(packet,2)
        self.assertEqual(value[0][12],1)
        self.assertEqual(value[1],13)

    def test_fps_stability_uses_the_requested_profile(self):
        with tempfile.TemporaryDirectory() as root:
            for fps,expected_stable in ((30,True),(60,False)):
                recorder=m.Recorder("natural",Path(root),fps)
                recorder.epochs=[dict(samples=[(i*1000,i*30,i*30,i*30,i*87_500,0,0,0,40,32,3)
                                               for i in range(1,120)],rate=(1400,1400))]
                result=recorder.summary("direct",120)
                self.assertAlmostEqual(result["rendered_fps"],30)
                self.assertEqual(bool(result["clean_windows"]),expected_stable)


if __name__=="__main__":
    unittest.main()
