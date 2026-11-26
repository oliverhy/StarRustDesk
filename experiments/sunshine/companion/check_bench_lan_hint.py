"""Bench-only address candidate: no pairing export, no overwrites or implicit WAN."""
from contextlib import ExitStack
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import bench_lan_hint as lab


class TestCandidate(unittest.TestCase):
    def test_same_private_subnet_is_explicit(self):
        self.assertEqual(lab.validate('192.168.7.9','192.168.7.11'),'192.168.7.9')
        for a,b in [('1.1.1.1','1.1.1.2'),('192.168.6.9','192.168.7.11'),
                    ('10.2.3.4','10.2.3.4'),('127.0.0.1','127.0.0.4')]:
            with self.subTest(a=a,b=b), self.assertRaises(RuntimeError):lab.validate(a,b)

    def test_occupied_slot_is_untouched(self):
        result=SimpleNamespace(returncode=0,stdout='')
        with ExitStack() as scope, patch.object(lab.subprocess,'run',return_value=result) as sh:
            with self.assertRaisesRegex(RuntimeError,'slot_not_empty'):
                lab.stage(scope,SimpleNamespace(hdc=['hdc','-t','test']),'com.yinhe.starrustdesk','10.2.3.4','10.2.3.9')
            self.assertEqual(sh.call_count,1)
            self.assertNotIn('printf',sh.call_args.args[0][-1])

    def test_other_app_is_never_written(self):
        with ExitStack() as scope, patch.object(lab.subprocess,'run') as sh:
            with self.assertRaisesRegex(RuntimeError,'not_the_debug_app'):
                lab.stage(scope,None,'other.app','10.2.3.4','10.2.3.9')
            sh.assert_not_called()
