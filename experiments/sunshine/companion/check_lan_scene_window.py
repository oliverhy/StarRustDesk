import unittest
from lan_scene_window import window


class TestSceneWindow(unittest.TestCase):
    frames=[(2,0,3),(3,10,12),(4,27,32),(5,40,41),(6,50,51)]

    def test_adjacent_packet_silence_is_not_a_missing_frame(self):
        self.assertEqual(window(self.frames,9300,9312,9327),
                         dict(starts=0,longest_intersecting_source_gap_ms=15))

    def test_half_open_source_counts_and_gaps_straddling_edges(self):
        self.assertEqual(window(self.frames,1,4,33),
                         dict(starts=2,longest_intersecting_source_gap_ms=15))
        self.assertEqual(window(self.frames,0,27,32),
                         dict(starts=1,longest_intersecting_source_gap_ms=0))

    def test_incomplete_capture_not_silence(self):
        for left,right in ((-1,4),(45,53),(22,22)):
            with self.assertRaisesRegex(ValueError,"fully_recorded"):
                window(self.frames,0,left,right)
