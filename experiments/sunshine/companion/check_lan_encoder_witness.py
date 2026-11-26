"""Offline validation: actual NVENC frame statistics, clock bounds, partial traces and midnight."""
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock
import subprocess

import lan_encoder_witness as m


class WitnessTest(unittest.TestCase):
    def test_opening_clock_only_accepts_a_recent_bounded_pre_playback_clock(self):
        early=dict(host_ms=3000,radius_ms=150);near=dict(host_ms=61000,radius_ms=105)
        self.assertIs(m.opening_clock(early,near,61010),near)
        self.assertIs(m.opening_clock(early,None,61010),early)
        self.assertIsNone(m.opening_clock(early,None,123001))
        self.assertIsNone(m.opening_clock(dict(host_ms=61000,radius_ms=300),None,61010))

    def test_phone_clock_failure_is_not_a_zero_offset_or_a_playback_failure(self):
        device=Mock();device.shell.side_effect=subprocess.TimeoutExpired('hdc',2)
        self.assertIsNone(m.phone_clock(device))
        self.assertEqual(device.shell.call_count,3)

    def test_strict_sizes_only_and_stale_or_reordered_values(self):
        t='2026-11-24 07:08:09.001'
        now=round(datetime.strptime(t,'%Y-%m-%d %H:%M:%S.%f').timestamp()*1000)
        s=f'[{t}]: Debug: NvEnc: encoded frame sizes in kB (min/max/avg): 0.05/310.01/41.67'
        self.assertEqual(m.frame_stat(s,now+4),dict(utc_ms=now,min_kb=.05,max_kb=310.01,mean_kb=41.67))
        for text,delay in [(s+' arbitrary',0),(s,-80),(s,1900),(s.replace('41.67','4100.00'),0),
                           (s.replace('Debug:', 'Info:'),0),(s.replace('11-24','22-24'),0)]:
            self.assertIsNone(m.frame_stat(text,now+delay))

    def test_verified_epoch_only_with_valid_phone_and_monotonic_anchors(self):
        self.assertIsNone(m.utc_base([]))
        for second,bracket in [(200,1),(0,2500)]:
            a='lan_tx_clock phase=1 elapsed_us=0 utc_ms=1800000000000 bracket_us=1'
            b=f'lan_tx_clock phase=2 elapsed_us=1000000 utc_ms={1800000001000+second} bracket_us={bracket}'
            self.assertIsNone(m.utc_base([a,b]))
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'numeric.ssmeta'
            base=int(datetime(2026,11,24,23,59,30,tzinfo=timezone.utc).timestamp()*1000)
            def rows(seq):
                p.write_bytes(b''.join(m.RECORD.pack(*r) for r in seq+[(255,0,0,len(seq),0)]))
            records=[(0,i,round(i*1000/60),0,0) for i in range(3061)]
            rows(records)
            logs=[f'lan_tx_clock phase={k} elapsed_us={ms*1000} utc_ms={base+ms} bracket_us=1'
                  for k,ms in [(1,0),(2,51000)]]
            sizes=[dict(utc_ms=base+i,mean_kb=40) for i in (7000,27000,47000)]
            ep=dict(sample_stamps=[],samples=[])
            for i in range(52):
                ep['samples'].append((i*1000,0,0,60*i,2_400_000*i,0))
                ep['sample_stamps'].append(datetime.fromtimestamp(base/1000+i,tz=timezone.utc).strftime('%H:%M:%S.000'))
            cs=[dict(host_ms=base+i,offset_ms=0,radius_ms=4,tz_min=0) for i in (-1000,53000)]
            def compare():return m.same_windows(sizes,logs,p,[ep],cs)
            out=compare(); self.assertEqual((out['count'],out['encoder_mbps_est'],out['decoder_input_mbps']),(2,19.2,19.2))
            self.assertEqual(out['max_boundary_error_ms'],0)
            self.assertEqual(m.same_windows(sizes,logs,p,[ep,ep],cs)['status'],'unavailable')
            cs[1]['offset_ms']=450
            self.assertEqual(compare()['reason'],'unstable_phone_clock')
            cs[1]['offset_ms']=0
            ep['sample_stamps'][30]='invalid';self.assertEqual(compare()['reason'],'invalid_phone_time')
            rows(records[:2]+records[4:]);self.assertIsNone(m.frame_times(p))
            p.write_bytes(p.read_bytes()[:-1]);self.assertIsNone(m.frame_times(p))


if __name__=='__main__':unittest.main()
