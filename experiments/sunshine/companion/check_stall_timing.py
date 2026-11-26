import unittest
from check_stall_path import restart_windows,freshness_windows


def observed(*messages):
    return restart_windows([("unused wall clock", message) for message in messages])


class RestartTiming(unittest.TestCase):
    STOP="switch_timing phase=core_stopped ms=298"
    RATE="quality_restart from_kbps=3250 to_kbps=2400"
    SETUP="switch_timing phase=setup_received ms=501"
    GAP="render_across_restart_ms=16211"
    FIRST="switch_timing phase=first_render ms=5008"

    def test_distinguishes_stall_preceding_request_from_actual_switch(self):
        event,=observed(self.STOP,self.RATE,self.SETUP,self.GAP,self.FIRST)
        self.assertEqual((event["last_to_first_ms"],event["before_request_ms"],
            event["request_to_setup_ms"],event["setup_to_present_ms"],event["request_to_present_ms"]),
            (16211,11203,501,4507,5008))

    def test_missing_or_reversed_counter_does_not_mean_zero(self):
        self.assertFalse(observed(self.STOP,self.RATE,self.SETUP,self.FIRST))
        self.assertFalse(observed(self.STOP,self.RATE,self.SETUP,"render_across_restart_ms=2000",self.FIRST))
        self.assertFalse(observed(self.STOP,self.RATE,"switch_timing phase=setup_received ms=250",self.GAP,self.FIRST))

    def test_never_borrow_timing_from_another_transition(self):
        self.assertFalse(observed(self.STOP,self.RATE,self.SETUP,self.GAP,self.STOP,self.FIRST))
        self.assertFalse(observed(self.STOP,self.RATE,self.SETUP,self.GAP,self.RATE,self.FIRST))
        self.assertFalse(observed(self.STOP,self.SETUP,self.GAP,self.FIRST))

    def test_old_data_gap_and_actual_recovery_are_different(self):
        req="freshness_request at=4100 frame=92 gap_ms=2542 extra_ms=2525 request=1"
        second="freshness_request at=4200 frame=98 gap_ms=33 extra_ms=2 request=2"
        render="freshness_render at=4267 wait_ms=167 pts_ms=9750"
        check=lambda *ms:freshness_windows([("ignored",s) for s in ms])
        self.assertEqual(check(req,second,render),[dict(prior_unit_silence_ms=2542,
                         stale_above_floor_ms=2525,recovery_to_fresh_present_ms=167)])
        self.assertFalse(check(req,render.replace("167","166")))
        self.assertFalse(check(req,"decoder_setup_code=0 enc_video=1 enc_audio=1",render))


if __name__=="__main__":unittest.main()
