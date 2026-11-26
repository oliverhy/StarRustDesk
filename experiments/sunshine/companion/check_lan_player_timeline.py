import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from lan_player_timeline import FILENAME, Timeline, live_binding


class PlayerTimelineTests(unittest.TestCase):
    def setUp(self):
        tmp=TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.p=Path(tmp.name)/'trial'
        self.p.mkdir()
        self.t=1800000000000
        self.rows=[[self.t+18+16*i,self.t+16+16*i,367000+16*i,10+i] for i in range(150)]
        (self.p/'playback-cue.json').write_text(json.dumps(dict(utc_ms=self.t)))
        self.data=dict(schema=2,binding=dict(run='trial',cue_utc_ms=self.t),
                       state='complete',width=1920,height=864,rows=self.rows)

    def load(self,**changes):
        (self.p/FILENAME).write_text(json.dumps({**self.data,**changes}))
        return Timeline.load(self.p,self.t,self.t+5000)

    def test_archive_without_player_is_unknown(self):
        self.assertEqual(Timeline.load(self.p,self.t,self.t+5000).gap(self.t,self.t+296),
                         {'signal':'not_recorded'})

    def test_cross_session_and_wrong_source_ignored(self):
        self.assertEqual(self.load(binding=dict(run='other',cue_utc_ms=self.t)).status,'not_same_completed_trial')
        self.assertEqual(self.load(width=640,height=288).status,'noncomparable_video')
        self.assertEqual(self.load(binding=dict(run='trial',cue_utc_ms=self.t-700000)).status,'not_same_completed_trial')

    def test_wrong_epoch_clock_or_rate_ignored(self):
        self.assertEqual(self.load(rows=[[a+8000,b+8000,c,d] for a,b,c,d in self.rows]).status,'different_time_window')
        self.assertEqual(self.load(rows=[[a,b,c+10000,d] for a,b,c,d in self.rows]).status,'different_time_window')
        self.assertEqual(self.load(rows=[[a,b,367000+33*i,d] for i,(a,b,c,d) in enumerate(self.rows)]).status,'noncomparable_cadence')
        self.assertEqual(Timeline.load(self.p,None,None).status,'host_clock_unverified')

    def test_guard_and_coverage(self):
        t=self.load()
        self.assertEqual(t.gap(self.t+160,self.t+456)['signal'],'player_submissions_within_gap')
        self.assertEqual(t.gap(self.t-296,self.t+150)['signal'],'outside_coverage')
        self.assertEqual(t.gap(self.t+100,self.t+145)['signal'],'outside_coverage')

    def test_gap_vs_skipped_callbacks(self):
        # Both cases have the same callback wall times. Only the count
        # emitted by the player distinguishes the two.
        rows=self.rows[:61]+[[a+280,b+280,c+280,d] for a,b,c,d in self.rows[61:]]
        start,end=rows[60][1],rows[61][1]
        self.assertEqual(end-start,296)
        self.assertEqual(self.load(rows=rows).gap(start,end)['signal'],'consecutive_submissions_span_gap')
        for r in rows[61:]:r[3]+=17
        self.assertEqual(self.load(rows=rows).gap(start,end)['signal'],'callbacks_skipped_unknown')

    def test_late_callbacks_are_not_late_submissions(self):
        rows=[[a+300,b,c,d] for a,b,c,d in self.rows]
        self.assertGreater(self.load(rows=rows).gap(self.t+32,self.t+210)['observed_inside'],3)

    def test_bad_row_and_out_of_order_do_not_fall_back_to_zero(self):
        for bad in [[],[0,0,float('nan'),1],[1,0,5,True]]:
            self.assertEqual(self.load(rows=self.rows+[bad]).status,'invalid_record')
        self.assertEqual(self.load(rows=self.rows+[self.rows[-1]]).status,'nonmonotonic_record')

    def test_binding_cannot_target_unrelated_folder(self):
        with self.assertRaisesRegex(ValueError,'not_new_lan_trial'):
            live_binding(self.p,self.t-3000)


if __name__=='__main__':unittest.main()
