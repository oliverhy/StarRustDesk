"""Local, synthetic regression of the destination used for SSH and phone build."""
import json
import tempfile
import unittest
from pathlib import Path
from public_target import endpoint, read_profile


class TargetTest(unittest.TestCase):
    def test_only_one_explicit_public_numeric_destination(self):
        with tempfile.TemporaryDirectory() as home:
            p=Path(home)/"target.json"
            for record in (None, {}, [], {"endpoint": "127.0.0.1:23388"},
                           {"endpoint":"224.0.0.1:23388"}, {"endpoint":"example.invalid:23388"},
                           {"endpoint":"8.8.8.8:22"}, {"endpoint":"8.8.8.8:23388","password":"dummy"},
                           {"endpoint":"8.8.8.8:23388/path"}, {"endpoint":"8.8.8.8:23388\n"}):
                with self.subTest(record=record):
                    if record is not None: p.write_text(json.dumps(record),encoding="utf-8")
                    with self.assertRaisesRegex(RuntimeError,"local_test_target"):
                        endpoint(p)
            p.write_text('{"endpoint":"1.1.1.1:23388","endpoint":"8.8.8.8:23388"}',encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError,"local_test_target"): endpoint(p)
            p.write_text('{"endpoint":"8.8.8.8:23388"}',encoding="utf-8")
            self.assertEqual(endpoint(p),("8.8.8.8",23388))
            self.assertEqual(read_profile(p)[2],1800)
            for cap in (1800,8000,8001,7999,True,8000.0,"8000",None):
                p.write_text(json.dumps({"endpoint":"8.8.8.8:23388","maxRelayKbps":cap}),encoding="utf-8")
                if type(cap) is int and cap in (1800,8000):
                    self.assertEqual(read_profile(p)[2],cap)
                else:
                    with self.assertRaisesRegex(RuntimeError,"local_test_target"): read_profile(p)


if __name__=="__main__": unittest.main()
