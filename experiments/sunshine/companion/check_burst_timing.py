import socket
import struct
import tempfile
import unittest
from pathlib import Path
from burst_timing import compare_peaks, HOST
from udp_broker import Broker, BURST_ROW, kernel_stamp


class BurstTiming(unittest.TestCase):
    def trace(self,path,duplicate=False,missed=0):
        rows=[HOST.pack(1,6,125+i*15,91,20+i) for i in range(5)]
        if duplicate: rows.append(rows[-1])
        path.write_bytes(b"".join(rows)+HOST.pack(255,0,0,len(rows),missed))

    def test_identical_real_video_only_and_three_independent_clocks(self):
        with tempfile.TemporaryDirectory() as root:
            host=Path(root)/"fixture";self.trace(host)
            probe=b"".join(BURST_ROW.pack(92,i,1250,i*100,-1) for i in range(50))
            rows=[(19+i*.001,1200,(91,20+i),9_000_000_000+i*1_250_000) for i in range(5)]
            result=compare_peaks([probe,Broker.burst_evidence(rows)],host)
            self.assertEqual((result["matched_windows"],result["sampled_windows"]),(1,2))
            self.assertEqual((result["host_span_ms"],result["kernel_span_us"],result["relay_read_span_us"]),(60,5000,4000))
            self.assertEqual((result["video_wire_bytes"],result["matched_video_packets"]),(6000,5))

    def test_clock_missing_or_stepped_is_not_a_zero_duration_burst(self):
        with tempfile.TemporaryDirectory() as root:
            host=Path(root)/"fixture";self.trace(host)
            for stamps in ([99,None,102,105],[99,103,102,105],[99,199,299,3_000_000_299]):
                rows=[(4+i*.001,100,(91,20+i),s) for i,s in enumerate(stamps)]
                r=compare_peaks([Broker.burst_evidence(rows)],host)
                self.assertEqual((r["status"],r["kernel_span_us"]),("matched",None))

    def test_missing_duplicate_and_nonvideo_do_not_confirm_a_compression(self):
        with tempfile.TemporaryDirectory() as root:
            host=Path(root)/"fixture"
            blob=b"".join(BURST_ROW.pack(91,i,500,i,i) for i in range(20,25))
            self.assertEqual(compare_peaks([blob],host)["status"],"no_complete_host_trace")
            self.trace(host,missed=1)
            self.assertEqual(compare_peaks([blob],host)["status"],"no_complete_host_trace")
            self.trace(host,duplicate=True)
            self.assertEqual(compare_peaks([blob],host)["status"],"ambiguous_host_counter")
            self.trace(host)
            self.assertEqual(compare_peaks([blob+blob],host)["status"],"no_verified_video_peak")
            self.assertEqual(compare_peaks([blob[:1]],host)["status"],"bad_peak")
            self.assertEqual(compare_peaks([],host)["status"],"no_observed_limited_peak")

    def test_ancillary_is_numeric_validated_and_not_used_as_a_send_clock(self):
        def read(blob,flags=0,kind=64):
            return kernel_stamp([(socket.SOL_SOCKET,kind,blob)],flags,64)
        valid=struct.pack("=qq",42,7)
        self.assertEqual(read(valid),42_000_000_007)
        self.assertIsNone(read(valid,kind=63))
        self.assertIsNone(read(valid,flags=getattr(socket,"MSG_CTRUNC",8)))
        self.assertIsNone(read(valid[:8]))
        self.assertIsNone(read(struct.pack("=qq",42,1_000_000_000)))


if __name__=="__main__": unittest.main()
