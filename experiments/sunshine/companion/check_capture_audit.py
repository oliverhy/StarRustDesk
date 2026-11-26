import unittest

from capture_audit import cadence_minutes, classify, thread_evidence


class ScreenEvidence(unittest.TestCase):
    def setUp(self):
        self.gap=dict(source_from_ms=1000,source_to_ms=1632,
                      duration_ms=632,missing_indices=0)
        self.times=list(range(2100,2601,100))
        self.samples=[[t,1200,0,0,1] for t in self.times]

    def test_certainty_needs_two_interior_comparisons(self):
        self.assertEqual(classify(self.gap,1000,self.samples,self.times)["activity"],"quiet")
        self.assertEqual(classify(self.gap,1000,self.samples[:2],self.times[:2])["activity"],"unclassified")
        # A blank or unavailable desktop must not be used as proof of quiet.
        self.samples[2][4]=0
        self.assertEqual(classify(self.gap,1000,self.samples,self.times)["activity"],"unclassified")

    def test_desktop_updates_are_marked_separately(self):
        self.samples[2][2:4]=[4,2290]
        self.assertEqual(classify(self.gap,1000,self.samples,self.times)["activity"],"desktop_updates")

    def test_change_outside_interval_and_frame_loss_do_not_prove_quiet(self):
        rows=[[2000,1400,4,1980,1]]+self.samples
        self.assertEqual(classify(self.gap,1000,rows,[r[0] for r in rows])["activity"],"quiet")
        self.gap["missing_indices"]=1
        self.assertEqual(classify(self.gap,1000,rows,[r[0] for r in rows])["activity"],"unclassified")

    def test_ready_time_requires_contiguous_samples_and_no_cpu_progress(self):
        rows=[[i,1000,1,1,0,1000] for i in (100,200,300,400)]
        self.assertEqual(thread_evidence(rows,100,401)["ready_observed_ms"],300)
        rows[2][5]=4000
        rows[3][5]=6000
        self.assertEqual(thread_evidence(rows,100,401)["ready_observed_ms"],100)
        rows[1][3]=5
        self.assertEqual(thread_evidence(rows,100,401)["ready_observed_ms"],0)
        self.assertEqual(thread_evidence(rows,100,401)["wait_samples"],1)

    def test_minute_fps_counts_real_frames_and_ignores_partial_tail(self):
        frames=list(range(2000,70000,50))
        desktop=[[t,100,6,t,1] for t in range(3000,71000,100)]
        windows=cadence_minutes(frames,1000,desktop,[r[0] for r in desktop],{},[])
        self.assertEqual(len(windows),1)
        self.assertEqual(windows[0]["source_fps"],20)
        self.assertGreater(windows[0]["desktop_present_count"],3500)


if __name__=="__main__":
    unittest.main()
