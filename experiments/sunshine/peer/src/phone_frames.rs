//! Debug-only counters for authenticated video and phone loopback delivery.
//! Never retain packet content, endpoints, cryptographic fields or RTSP data.
const MAX_FRAME: u32 = 65_536;
const BLOCK: u32 = 128;
const REORDER_GUARD: u32 = 180;
const HEX: &[u8; 16] = b"0123456789abcdef";

pub(super) struct PhoneFrames {
    pairs: Vec<[u8; 2]>,
    next: u32,
    highest: u32,
    late: u32,
    untracked: u32,
}

impl PhoneFrames {
    pub fn new() -> Self {
        Self { pairs: vec![[0, 0]; MAX_FRAME as usize], next: 1, highest: 0, late: 0, untracked: 0 }
    }

    pub fn mark(&mut self, frame: u32, delivered: bool) {
        if frame == 0 || frame > MAX_FRAME {
            self.untracked = self.untracked.saturating_add(1);
        } else if frame < self.next {
            self.late = self.late.saturating_add(1);
        } else {
            self.highest = self.highest.max(frame);
            let p = &mut self.pairs[frame as usize - 1];
            if p[0] == u8::MAX {
                self.untracked = self.untracked.saturating_add(1);
            } else {
                p[0] += 1;
                p[1] += u8::from(delivered);
            }
        }
    }

    pub fn invalidate(self, emit: &impl Fn(String)) {
        emit("rx_ledger_invalid=1".to_owned());
    }

    pub fn flush(&mut self, closing: bool, emit: &impl Fn(String)) {
        let covered = if closing { self.highest } else { self.highest.saturating_sub(REORDER_GUARD) };
        let mut blocks = 0;
        // Limit work at each poll even if the peer sends an implausibly
        // large frame number. A missing block is never counted as loss.
        while self.next <= covered && blocks < 4 {
            let n = (covered - self.next + 1).min(BLOCK);
            if !closing && n < BLOCK { break; }
            let mut row = format!("rx_ledger first={} pairs=", self.next);
            let i = self.next as usize - 1;
            for bytes in &self.pairs[i..i + n as usize] {
                for &b in bytes {
                    row.push(HEX[(b >> 4) as usize] as char);
                    row.push(HEX[(b & 15) as usize] as char);
                }
            }
            emit(row);
            self.next += n;
            blocks += 1;
        }
        if blocks != 0 || closing {
            emit(format!("rx_ledger_status covered={} late={} untracked={}", self.next - 1, self.late, self.untracked));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn keep_reorder_guard_and_report_authenticated_vs_local_delivery() {
        let mut f = PhoneFrames::new();
        let log = RefCell::new(Vec::new());
        let emit = |s| log.borrow_mut().push(s);
        f.mark(1, false);
        f.mark(1, true);
        f.mark(BLOCK + REORDER_GUARD - 1, true);
        f.flush(false, &emit);
        assert!(log.borrow().is_empty());
        f.mark(BLOCK + REORDER_GUARD, true);
        f.flush(false, &emit);
        assert!(log.borrow()[0].starts_with("rx_ledger first=1 pairs=02010000"));
        assert_eq!(log.borrow()[1], "rx_ledger_status covered=128 late=0 untracked=0");
        f.mark(1, true);
        f.mark(MAX_FRAME + 1, true);
        f.flush(true, &emit);
        assert_eq!(*log.borrow().last().unwrap(), "rx_ledger_status covered=308 late=1 untracked=1");
    }
}
