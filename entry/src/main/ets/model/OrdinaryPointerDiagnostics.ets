type PointerDeliveryStage = 'move' | 'final' | 'before_press' | 'press';
type PointerSkipReason = 'virtual' | 'relative' | 'disconnected' | 'invalid_target' | 'cancelled';
type PointerFeedback = 'none' | 'deferred_geometry' | 'superseded' | 'virtual_drag' |
  'outside_display' | 'local_guard' | 'applied';

export class OrdinaryPointerDiagnostics {
  private gesture: number = 0;
  private sequence: number = 0;
  private lastQueuedX: number = 0;
  private lastQueuedY: number = 0;
  private hasQueuedMove: boolean = false;
  private feedback: PointerFeedback = 'none';
  private feedbackAt: number = 0;
  private feedbackCount: number = 0;
  private feedbackApplied: number = 0;
  private feedbackLocalGuard: number = 0;
  private finalQueued: number = 0;
  private finalFailed: number = 0;
  private finalSkipped: number = 0;
  private prepQueued: number = 0;
  private prepFailed: number = 0;
  private prepSkipped: number = 0;
  private pressQueued: number = 0;
  private pressFailed: number = 0;
  private moveFailed: number = 0;
  private recentEvents: string[] = [];

  nextGesture(): number {
    return ++this.gesture;
  }

  noteMove(x: number, y: number, result: number | undefined, stage: PointerDeliveryStage = 'move',
    gesture: number = 0): void {
    if (result === 0 && Number.isFinite(x) && Number.isFinite(y)) {
      // Match the integer coordinates passed to Rust; never serialize x/y.
      this.lastQueuedX = Math.trunc(x);
      this.lastQueuedY = Math.trunc(y);
      this.hasQueuedMove = true;
    }
    if (stage === 'move') {
      if (result !== undefined && result !== 0) this.moveFailed++;
      return;
    }
    this.noteResult(stage, gesture, result);
  }

  noteResult(stage: PointerDeliveryStage, gesture: number, result: number | undefined,
    reason?: PointerSkipReason): void {
    if (stage === 'final') {
      if (result === 0) this.finalQueued++;
      else if (result === undefined) this.finalSkipped++;
      else this.finalFailed++;
    } else if (stage === 'before_press') {
      if (result === 0) this.prepQueued++;
      else if (result === undefined) this.prepSkipped++;
      else this.prepFailed++;
    } else if (stage === 'press') {
      if (result === 0) this.pressQueued++;
      else if (result !== undefined) this.pressFailed++;
    }
    const outcome: string = result === 0 ? 'queued' : result === undefined ? `skipped_${reason ?? 'not_dispatched'}` :
      `failed_${result}`;
    // Keep a bounded tail, including both stages of a double-click, without logging on the input path.
    if (this.recentEvents.length >= 8) this.recentEvents.shift();
    this.recentEvents.push(`${++this.sequence}:${gesture}:${stage}:${outcome}`);
  }

  noteFeedback(state: PointerFeedback, now: number): void {
    this.feedback = state;
    this.feedbackAt = now;
    this.feedbackCount++;
    if (state === 'applied') this.feedbackApplied++;
    if (state === 'local_guard') this.feedbackLocalGuard++;
  }

  summary(now: number, localX: number, localY: number, scaleX: number, scaleY: number): string {
    const distance: string = this.hasQueuedMove && scaleX > 0 && scaleY > 0 &&
      Number.isFinite(localX) && Number.isFinite(localY) ?
      Math.hypot((localX - this.lastQueuedX) * scaleX, (localY - this.lastQueuedY) * scaleY).toFixed(1) : 'unknown';
    return `local_to_last_queued_move_vp=${distance} ordinary_move_queue_failed=${this.moveFailed} ` +
      `final_move_queue=${this.finalQueued}/${this.finalFailed}/${this.finalSkipped} ` +
      `before_press_queue=${this.prepQueued}/${this.prepFailed}/${this.prepSkipped} ` +
      `press_queue=${this.pressQueued}/${this.pressFailed} ` +
      `pointer_events=${this.recentEvents.length > 0 ? this.recentEvents.join(',') : 'none'} ` +
      `remote_cursor_feedback=${this.feedback} cursor_feedback_samples=${this.feedbackCount} ` +
      `cursor_feedback_applied=${this.feedbackApplied} cursor_feedback_local_guard=${this.feedbackLocalGuard} ` +
      `cursor_feedback_age_ms=${this.feedbackAt > 0 ? Math.max(0, now - this.feedbackAt) : -1}`;
  }

  clearInterval(): void {
    this.finalQueued = 0;
    this.finalFailed = 0;
    this.finalSkipped = 0;
    this.prepQueued = 0;
    this.prepFailed = 0;
    this.prepSkipped = 0;
    this.pressQueued = 0;
    this.pressFailed = 0;
    this.moveFailed = 0;
    this.recentEvents = [];
    this.feedbackCount = 0;
    this.feedbackApplied = 0;
    this.feedbackLocalGuard = 0;
  }

  invalidateQueuedMove(): void {
    this.hasQueuedMove = false;
  }

  resetTarget(): void {
    this.invalidateQueuedMove();
    this.feedback = 'none';
    this.feedbackAt = 0;
    this.clearInterval();
  }

  resetSession(): void {
    this.resetTarget();
    this.gesture = 0;
    this.sequence = 0;
  }
}
