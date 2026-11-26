import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from lan_send_recap import recap


class RecapTest(unittest.TestCase):
    def test_unverified_route_and_missing_socket_witness_are_not_success(self):
        base=1800000000000
        span=dict(begin_ms=base+2000,end_ms=base+4500,busy_ms=2500,attempts=42,errno=10035,
                  pc_gateway=dict(confirmed_timeout=4,ok=0),phone_gateway=dict(ok=4,timeout=0),
                  phone_ok_during_pc_failure=True,scan_complete_from_start_ms=[2496])
        witness=dict(long_refusals=[span],scan_complete=2,scan_complete_away_from_long_refusals=1)
        sample=dict(samples=[[8000,1,1,1,300,0,0,0,10],[18000,601,601,601,25_000_300,1,0,0,100]])
        with tempfile.TemporaryDirectory() as tmp,patch('lan_send_recap.reread',return_value=witness):
            root=Path(tmp)
            (root/'phone-numeric.json').write_text(json.dumps(dict(epochs=[sample])))
            (root/'udp-send-probes.json').write_text(json.dumps(dict(summary=dict(spans=[
                dict(begin_ms=span['begin_ms'],recovered=True,guard_holds=64,reported_not_writable=11)]))))
            r=recap(root)
            self.assertIsNone(r['authenticated_route_report'])
            self.assertIsNone(r['refusals'][0]['writable_to_send_us'])
            self.assertEqual((r['playback']['mbps'],r['playback']['fps']),(20,60))
            lines=[f'lan_tx_clock phase=1 elapsed_us=0 utc_ms={base} bracket_us=1',
                   'lan_tx_resume elapsed_ms=4501 busy_us=2500000 ready_seen=1 noticed_us=2499950 to_send_us=50 false_ready=0 attempts=42 holds=64',
                   'lan_tx_resume elapsed_ms=8500 busy_us=2500000 ready_seen=1 noticed_us=2499940 to_send_us=60 false_ready=0 attempts=42 holds=64',
                   f'lan_tx_clock phase=2 elapsed_us=10000000 utc_ms={base+10000} bracket_us=1']
            (root/'host-path-numeric.txt').write_text('\n'.join(lines))
            self.assertEqual(recap(root)['refusals'][0]['writable_to_send_us'],50)
