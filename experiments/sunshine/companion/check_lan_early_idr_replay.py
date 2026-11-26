import unittest

from lan_early_idr_replay import shadow_first


class EarlyIdrReplayTests(unittest.TestCase):
    def test_fast_native_is_not_delayed(self):
        self.assertEqual(shadow_first([(100, 'confirmed'), (102, 'native')], 16), ('native', 102))

    def test_slow_native_exposes_a_conditional_67_ms(self):
        events = [(100, 'confirmed'), (183, 'native')]
        self.assertEqual(shadow_first(events, 0), ('early', 100))
        self.assertEqual(shadow_first(events, 16), ('early', 116))

    def test_speculation_does_not_mask_a_later_confirmed_discard(self):
        events = [(88, 'speculative'), (100, 'confirmed'), (108, 'confirmed'), (183, 'native')]
        self.assertEqual(shadow_first(events, 16), ('early', 116))

    def test_speculation_decoder_reject_and_late_packet_are_not_loss(self):
        events = [(50, 'speculative'), (80, 'decoder_reject'), (90, 'late'), (200, 'native')]
        self.assertEqual(shadow_first(events, 0), ('native', 200))

    def test_no_early_if_unencrypted_rfi_or_already_pending(self):
        for options in ({'secure': False}, {'strict_idr': False}, {'pending': True}):
            with self.subTest(options=options):
                self.assertEqual(shadow_first([(5, 'confirmed'), (90, 'native')], 0, **options), ('native', 90))

    def test_healthy_or_static_scene_does_not_request(self):
        self.assertEqual(shadow_first([(2000, 'progress'), (2200, 'tick')], 0), ('unresolved', None))

    def test_progress_must_be_newer_and_after_the_loss(self):
        events = [(99, 'progress'), (100, 'confirmed'), (100, 'progress'), (120, 'late'), (183, 'native')]
        self.assertEqual(shadow_first(events, 16, require_progress=True), ('native', 183))

    def test_no_new_traffic_keeps_early_timer_silent(self):
        self.assertEqual(shadow_first([(100, 'confirmed'), (250, 'tick')], 16, require_progress=True),
                         ('unresolved', None))

    def test_known_forward_progress_can_trigger_at_or_after_the_deadline(self):
        for arrived, expected in ((103, 116), (145, 145)):
            with self.subTest(arrived=arrived):
                self.assertEqual(shadow_first([(100, 'confirmed'), (arrived, 'progress'), (183, 'native')],
                                              16, require_progress=True), ('early', expected))

    def test_coarse_equal_timestamps_give_precedence_to_native(self):
        for end in (116, 183):
            with self.subTest(end=end):
                self.assertEqual(shadow_first([(end, 'progress'), (100, 'confirmed'), (end, 'native')],
                                              16, require_progress=True), ('native', end))

    def test_cooldown_never_suppresses_native_and_expires(self):
        for loss, expected in ((849, ('native', 885)), (850, ('early', 866))):
            self.assertEqual(shadow_first([(loss, 'confirmed'), (885, 'native')], 16, previous_request=100), expected)

    def test_recovery_or_stop_cancels_even_on_timer_boundary(self):
        for end in ('stop', 'recovered'):
            self.assertEqual(shadow_first([(30, 'confirmed'), (46, 'tick'), (46, end)], 16), ('cancelled', None))

    def test_no_extrapolation_past_the_recording(self):
        self.assertEqual(shadow_first([(30, 'confirmed')], 16), ('unresolved', None))

    def test_unknown_input_fails_closed(self):
        for events, delay in (([(30, 'guess')], 16), ([(1.3, 'native')], 1), ([], -1)):
            with self.assertRaises(ValueError):
                shadow_first(events, delay)


if __name__ == '__main__':
    unittest.main()
