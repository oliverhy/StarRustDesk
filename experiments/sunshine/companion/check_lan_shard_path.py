import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from long_metrics import META
from lan_shard_path import SHARD, classify, report


class ShardPath(unittest.TestCase):
    def inspect(self,phase=None,out=None,shard=None,proof=None,gap=True,prior=None):
        p=[12,500,500,583,1,583,584,585,2,2]
        o=[12,500,660,669,1,1,0,0]
        s=[12,500,8,500,1,8,10,502,0,0]
        for row,changes in ((p,phase),(o,out),(s,shard)):
            for i,v in (changes or {}).items():row[i]=v
        e=dict(encoder_idr_frame_match=True,source_shards=12,sent_shards=12,
               matched_surface_gap_ms=210,earlier_candidate_encoded_idrs=[])
        e.update(proof or {})
        return classify(tuple(p),tuple(o),tuple(s),e,[660,7,12,4,125,2,0,1,0] if gap else None,prior)

    def test_exact_admission_both_sides_of_guard(self):
        for at,lead in ((500,67),(502,67),(570,13),(583,0),(585,0)):
            e=self.inspect(shard={7:at})
            self.assertEqual(e['observed_margin_after_16ms_ms'],lead)
            self.assertEqual(e['loss_to_exact_idr_surface_ms'],169)
            self.assertEqual(e['measured_request_advance_ms'],0)
            self.assertIsNone(e['display_improvement_ms'])

    def test_no_clean_evidence_no_candidate(self):
        for args,status in [({'shard':{8:1}},'first_admission_was_parity'),
                            ({'shard':{9:1}},'newer_picture_also_lost_before_request'),
                            ({'phase':{4:2}},'not_native_first_idr_path'),
                            ({'phase':{5:550}},'not_native_first_idr_path'),
                            ({'out':{6:580,7:1}},'first_intent_origin_ambiguous'),
                            ({'prior':345},'inside_previous_control_cooldown'),
                            ({'proof':{'earlier_candidate_encoded_idrs':[10]}},'earlier_host_idr_not_excluded'),
                            ({'out':{4:0}},'not_exact_gap_and_host_idr_match'),
                            ({'proof':{'sent_shards':11}},'not_exact_gap_and_host_idr_match'),
                            ({'gap':False},'not_exact_gap_and_host_idr_match')]:
            with self.subTest(status=status):
                e=self.inspect(**args);self.assertEqual(e['status'],status)
                self.assertIsNone(e['observed_margin_after_16ms_ms'])

    def test_clear_negative_and_unknown_are_different(self):
        self.assertEqual(self.inspect(phase={2:0},shard={i:0 for i in range(2,10)})['status'],
                         'no_confirmed_video_loss')
        self.assertEqual(self.inspect(shard={6:0,7:0})['status'],'no_admitted_newer_fragment_observed')

    def test_bad_crossframe_clocks_not_accepted(self):
        for args in ({'shard':{0:13}},{'shard':{3:501}},{'shard':{5:10}},
                     {'shard':{7:499}},{'shard':{7:661}},{'shard':{6:0,8:1}},{'phase':{6:0}}):
            with self.subTest(args=args),self.assertRaises(ValueError):self.inspect(**args)

    def test_numeric_allowlist_no_payload(self):
        line='lan_key_shard f=11 first=899 lf=7 loss=900 why=1 floor=8 nf=9 admit=901 parity=0 reloss=0'
        self.assertIsNotNone(SHARD.fullmatch(line))
        self.assertIsNotNone(META.fullmatch(line))
        self.assertIsNotNone(META.fullmatch('lan_key_shard_policy=1'))
        for unsafe in (line+' text=example',line.replace('nf=9','nf=-1'),line.replace('why=1','why=8')):
            self.assertIsNone(SHARD.fullmatch(unsafe));self.assertIsNone(META.fullmatch(unsafe))

    def test_archive_join_and_missing_evidence_do_not_manufacture_a_zero(self):
        with TemporaryDirectory() as d:
            folder=Path(d)
            shard='lan_key_shard f=12 first=500 lf=8 loss=500 why=1 floor=8 nf=10 admit=502 parity=0 reloss=0'
            phase='lan_key_phase f=12 first=500 loss=500 wait=583 kind=1 queue=583 sent=584 last=585 nq=2 ns=2'
            out='lan_key_out f=12 first=500 unit=660 surface=669 exact=1 idr=1 backup=0 tries=0'
            marker='lan_key_shard_policy=1'
            proof=dict(frame=12,encoder_idr_frame_match=True,source_shards=12,sent_shards=12,
                       matched_surface_gap_ms=210,earlier_candidate_encoded_idrs=[])
            def put(lines):
                (folder/'phone-numeric.json').write_text(json.dumps(dict(events=list(enumerate(lines)),
                    epochs=[dict(gap_events=[[660,7,12,4,125,2,0,1,0]])])),encoding='ascii')
            with patch('lan_shard_path.key.join',return_value=dict(censored=0,episodes=[proof])):
                put([phase,out]);self.assertIsNone(report(folder)['candidate_count'])
                put([marker,phase,shard,out]);self.assertEqual(report(folder)['candidate_count'],1)
                for invalid in ([marker,phase,out],[marker,phase,out,shard,shard]):
                    put(invalid)
                    with self.assertRaises(ValueError):report(folder)
            with patch('lan_shard_path.key.join',return_value=dict(censored=1,episodes=[])):
                put([marker]);r=report(folder);self.assertEqual(r['status'],'no_completed_incidents')
                self.assertEqual(r['censored'],1)


if __name__=='__main__':unittest.main()
