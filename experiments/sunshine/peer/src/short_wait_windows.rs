//! Per-sender wait for paced tests. No change to the computer-wide timer resolution.
use core::ffi::c_void;
use core::ptr;
use std::time::{Duration,Instant};
use super::bandwidth::{ProbeWait,WaitEnd};

type Handle = *mut c_void;
type TimerCallback = unsafe extern "system" fn(*mut c_void, u32, u32);

#[link(name = "kernel32")]
extern "system" {
    fn CreateWaitableTimerExW(attrs: *const c_void, name: *const u16, flags: u32, access: u32) -> Handle;
    fn SetWaitableTimer(timer: Handle, due: *const i64, period: i32, callback: Option<TimerCallback>,
                        argument: *const c_void, resume: i32) -> i32;
    fn WaitForSingleObject(handle: Handle, millis: u32) -> u32;
    fn CloseHandle(handle: Handle) -> i32;
}

pub(super) struct ShortWait(Handle);

#[derive(Clone, Copy)]
pub(super) enum Wake {
    Signalled,
    TimedOut,
    Failed,
}

impl ShortWait {
    pub fn new(enabled: bool) -> Option<Self> {
        if !enabled { return None; }
        const HIGH_RESOLUTION: u32 = 2;
        const SYNCHRONIZE: u32 = 0x0010_0000;
        const MODIFY_STATE: u32 = 2;
        let handle = unsafe {
            CreateWaitableTimerExW(ptr::null(), ptr::null(), HIGH_RESOLUTION, SYNCHRONIZE | MODIFY_STATE)
        };
        if handle.is_null() { None } else { Some(Self(handle)) }
    }

    fn arm(&self, delay:Duration)->bool {
        let due = -(delay.as_nanos().div_ceil(100).clamp(1, 10_000) as i64);
        unsafe { SetWaitableTimer(self.0, &due, 0, None, ptr::null(), 0) != 0 }
    }
    fn wait_event(&self)->Wake {
        unsafe {
            match WaitForSingleObject(self.0, 4) {
                0 => Wake::Signalled,
                258 => Wake::TimedOut,
                _ => Wake::Failed,
            }
        }
    }
    pub fn wait_for(&self, delay: Duration) -> Wake {
        if self.arm(delay) {self.wait_event()} else {Wake::Failed}
    }
}

// Both the observed train and ordinary naps execute the same arm/wait/fallback
// decisions. No clocks or per-wake output on the unobserved path.
pub(super) fn pace_one_ms<const TRACE:bool>(timer:Option<&ShortWait>)->ProbeWait {
    let one=Duration::from_millis(1);
    let stamp=||TRACE.then(Instant::now);
    let start=stamp();
    let armed=timer.filter(|t|t.arm(one));
    let a=stamp();
    let end=if let Some(t)=armed {
        match t.wait_event() { Wake::Signalled=>WaitEnd::Signalled, Wake::TimedOut=>WaitEnd::Timeout,
                               Wake::Failed=>WaitEnd::WaitFailed }
    } else if timer.is_some() {WaitEnd::ArmFailed} else {WaitEnd::NoTimer};
    let b=stamp();
    let fallback=!matches!(end,WaitEnd::Signalled);
    if fallback {std::thread::sleep(one);}
    // Attribute no time to a fallback that was not called, even if preempted.
    let sleep=if fallback {b.map(|t|t.elapsed()).unwrap_or_default()} else {Duration::ZERO};
    ProbeWait { end,arm:a.zip(start).map(|(a,s)|a-s).unwrap_or_default(),
        kernel_wait:b.zip(a).map(|(b,a)|b-a).unwrap_or_default(),sleep }
}

impl Drop for ShortWait {
    fn drop(&mut self) { unsafe { CloseHandle(self.0); } }
}

#[cfg(feature = "companion-soak")]
#[link(name = "avrt")]
extern "system" {
    fn AvSetMmThreadCharacteristicsW(task: *const u16, index: *mut u32) -> Handle;
    fn AvRevertMmThreadCharacteristics(handle: Handle) -> i32;
}

// Use the normal multimedia distribution class only for this thread, and
// only while the isolated WAN trial sends media. No process-wide priority,
// registry, system timer-resolution or power settings are changed.
#[cfg(feature = "companion-soak")]
pub(super) struct DispatchSchedule(Handle);

#[cfg(feature = "companion-soak")]
impl DispatchSchedule {
    pub fn enter() -> Option<Self> {
        const DISTRIBUTION: [u16; 13] = [68, 105, 115, 116, 114, 105, 98, 117, 116, 105, 111, 110, 0];
        let mut index = 0;
        let handle = unsafe { AvSetMmThreadCharacteristicsW(DISTRIBUTION.as_ptr(), &mut index) };
        (!handle.is_null()).then_some(Self(handle))
    }
}

#[cfg(feature = "companion-soak")]
impl Drop for DispatchSchedule {
    fn drop(&mut self) { unsafe { AvRevertMmThreadCharacteristics(self.0); } }
}
