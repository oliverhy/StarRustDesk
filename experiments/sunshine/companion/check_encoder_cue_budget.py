import unittest
from encoder_cue_budget import compare,confirmed_start
def rows(offset=0,fps=60):
    return [dict(start=offset+i*20000,end=offset+(i+1)*20000,fps=fps,rate=10+i,mean=30,peak=40,low=1) for i in range(12)]
class Match(unittest.TestCase):
    def test_scheduled_time_without_observed_paused_source_is_not_a_match(self):
        a=dict(displayed_start='06:07',was_paused=True,media_quality_1080p60=True,absolute_delta_ms=15)
        self.assertTrue(confirmed_start(a))
        for field,value in [('was_paused',False),('displayed_start','06:06'),('media_quality_1080p60',False),('absolute_delta_ms',300),('absolute_delta_ms',True)]:
            self.assertFalse(confirmed_start(dict(a,**{field:value})))
    def test_same_scene_not_assumed_from_ordinal(self):
        a=rows();b=rows(3500);x=compare(a,b[1:]);self.assertEqual((x['matched'],x['encoder_pattern_r'],x['mean_delta_mbps']),(11,1.,0))
    def test_low_overlap_low_cadence_and_duplicates_rejected(self):
        for b in (rows(7000),rows(0,48),rows()+rows()):
            with self.assertRaises(ValueError):compare(rows(),b)
    def test_constant_signal_not_perfect_correlation(self):
        a=[dict(x,rate=10) for x in rows()];self.assertIsNone(compare(a,a)['encoder_pattern_r'])
