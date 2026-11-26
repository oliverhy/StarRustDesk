import json
from pathlib import Path
import tempfile
import unittest
from queue_slot_replay import SlotQueue,replay


class ReplayLimits(unittest.TestCase):
    def test_overflow_reserves_started_frame_without_any_new_slots(self):
        base,trial=(SlotQueue(748,x) for x in [False,True])
        for q in (base,trial):
            for _ in range(12):q.push(7,0)
            q.slot(2)
            for _ in range(q.capacity):q.push(8,10)
            for ms in range(12,57,4):q.slot(ms)
            self.assertLessEqual(sum(q.sent.values()),13)
            self.assertLessEqual(q.size,q.capacity)
        self.assertEqual(base.sent[7],1);self.assertEqual(trial.sent[7],12);self.assertEqual(trial.retained,1)

    def test_unstarted_head_and_head_without_deadline_budget_not_protected(self):
        for started,arrival in [(False,8),(True,110)]:
            q=SlotQueue(748,True)
            for _ in range(22):q.push(1,0)
            if started:q.slot(2)
            for _ in range(q.capacity):q.push(2,arrival)
            self.assertEqual(q.retained,0)
            self.assertTrue(all(f==2 for f,_ in q.queue))

    def test_no_old_frame_emitted_and_no_banked_empty_slots(self):
        q=SlotQueue(748,True)
        for _ in range(10):q.slot(0)
        for _ in range(8):q.push(7,2)
        q.slot(5);q.slot(127);self.assertEqual(q.sent[7],1)
        self.assertEqual(q.size,0);q.push(8,150);self.assertEqual(q.sent[8],0)

    def test_unrelated_archives_not_replayed(self):
        with tempfile.TemporaryDirectory() as p:
            d=Path(p);(d/'result.json').write_text(json.dumps({'wire_cap_kbps':7300}),'ascii')
            self.assertEqual(replay(d),{'status':'wrong_scope'})


if __name__=='__main__':unittest.main()
