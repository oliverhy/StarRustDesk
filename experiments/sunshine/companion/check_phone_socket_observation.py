import unittest
from phone_socket_observation import gap_windows,summarize


class ReadOnlySocketEvidence(unittest.TestCase):
    base=86_400_000*20
    def test_aggregate_skips_replacement_holes_clock_jumps_and_counter_resets(self):
        v=[[0,1,0,4],[500,1,8,5],[1000,0,0,0],[1500,2,8,1],[2000,2,4,0],
           [4000,2,0,9],[4499,2,4,9]]
        r=summarize(v)
        self.assertEqual((r["matched"],r["covered_ms"],r["counter_increase"],r["counter_resets"]),(6,999,1,1))
        self.assertIsNone(summarize(v[:1])["counter_increase"])

    def test_enclosing_samples_even_across_midnight_only_on_one_socket(self):
        start=self.base-8*3600_000
        r=[[start+i*500,1,20*i,3+(i>=3)] for i in range(6)]
        epoch={"gap_events":[[0,3,11,7,1100]],"gap_stamps":["00:00:01.700"]}
        w=gap_windows(r,[epoch],480)[0]
        self.assertEqual((w["gap_ms"],w["socket_drops"],w["before_ms"],w["after_ms"]),(1100,1,100,300))
        for i in (1,2,3):
            copy=[p[:] for p in r];copy[i][1]=2
            self.assertEqual(gap_windows(copy,[epoch],480),[])
        self.assertEqual(gap_windows(r[:-3],[epoch],480),[])
        self.assertEqual(gap_windows(r,[epoch],None),[])

    def test_uncovered_or_backwards_clock_is_unknown_not_zero_drops(self):
        e={"gap_events":[[0,1,3,1,600]],"gap_stamps":["00:00:01.300"]}
        r=[[self.base,1,0,0],[self.base+1900,1,0,0]]
        self.assertFalse(gap_windows(r,[e],0))
        self.assertFalse(gap_windows(r[::-1],[e],0))
        self.assertFalse(gap_windows(r,[{"gap_events":e["gap_events"]}],0))
