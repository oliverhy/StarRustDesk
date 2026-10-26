export interface DisplaySwipePoint {
  id: number;
  x: number;
  y: number;
}

export interface DisplaySwipeResult {
  action: string;
  reason: string;
  duration: number;
  dx: number;
  dy: number;
}

// Window-vp coordinates, never remote pixels: zoom/density must not change the
// distance required to switch displays. Only real three-contact touch events
// belong here; wheel axes do not carry a reliable touchpad finger count.
export class RemoteDisplaySwipe {
  private start: DisplaySwipePoint[] = [];
  private last: DisplaySwipePoint[] = [];
  private startedAt: number = 0;
  private axis: string = '';
  private invalid: string = '';

  reset(): void {
    this.start = [];
    this.last = [];
    this.startedAt = 0;
    this.axis = '';
    this.invalid = '';
  }

  begin(points: DisplaySwipePoint[], now: number): void {
    this.reset();
    this.startedAt = now;
    if (!this.validPoints(points) || !Number.isFinite(now)) {
      this.invalid = 'invalid_start';
      return;
    }
    this.start = points.map((p: DisplaySwipePoint): DisplaySwipePoint => ({ id: p.id, x: p.x, y: p.y }));
    this.last = this.start.slice();
  }

  private validPoints(points: DisplaySwipePoint[]): boolean {
    return points.length === 3 && points.every((p: DisplaySwipePoint) =>
      Number.isFinite(p.id) && Number.isFinite(p.x) && Number.isFinite(p.y)) &&
      points[0].id !== points[1].id && points[0].id !== points[2].id && points[1].id !== points[2].id;
  }

  update(points: DisplaySwipePoint[]): void {
    if (this.invalid) return;
    if (!this.validPoints(points) || this.start.length !== 3) {
      this.invalid = 'finger_count'; return;
    }
    const ordered: DisplaySwipePoint[] = [];
    for (const first of this.start) {
      const point = points.find((p: DisplaySwipePoint) => p.id === first.id);
      if (!point) { this.invalid = 'finger_replaced'; return; }
      ordered.push({ id: point.id, x: point.x, y: point.y });
    }
    this.last = ordered;
    const dx = this.delta(true), dy = this.delta(false);
    if (!this.axis && Math.max(Math.abs(dx), Math.abs(dy)) >= 18) {
      if (Math.abs(dx) >= Math.abs(dy) * 1.5) this.axis = 'x';
      else if (Math.abs(dy) >= Math.abs(dx) * 1.5) this.axis = 'y';
    }
  }

  private delta(horizontal: boolean): number {
    if (this.start.length !== 3 || this.last.length !== 3) return 0;
    let total: number = 0;
    for (let i = 0; i < 3; i++) total += horizontal ?
      this.last[i].x - this.start[i].x : this.last[i].y - this.start[i].y;
    return total / 3;
  }

  finish(now: number): DisplaySwipeResult {
    const dx = this.delta(true), dy = this.delta(false), duration = now - this.startedAt;
    let action = 'none', reason = this.invalid;
    if (!reason && (this.start.length !== 3 || !Number.isFinite(duration) || duration < 0 || duration > 1500)) reason = 'expired';
    if (!reason) {
      const horizontal = this.axis === 'x';
      const distance = horizontal ? dx : dy, cross = horizontal ? dy : dx;
      // Reject diagonal movement and pinch/spread, including one moving finger
      // with two stationary ones. Evaluate coherence at release because ArkUI
      // can update just one finger per callback.
      if (!this.axis || Math.abs(distance) < 70 || Math.abs(distance) < Math.abs(cross) * 1.5) reason = 'direction_or_distance';
      else if (this.start.some((p: DisplaySwipePoint, i: number) => {
        const fingerDelta = horizontal ? this.last[i].x - p.x : this.last[i].y - p.y;
        const fingerCross = horizontal ? this.last[i].y - p.y : this.last[i].x - p.x;
        const tolerance = Math.max(28, Math.abs(distance) * 0.45);
        return fingerDelta * distance <= 0 || Math.abs(fingerDelta - distance) > tolerance ||
          Math.abs(fingerCross - cross) > tolerance;
      })) reason = 'not_parallel';
      else if (!horizontal && dy > 0) reason = 'downward';
      else { action = horizontal ? (dx < 0 ? 'left' : 'right') : 'up'; reason = 'recognized'; }
    }
    this.reset();
    return { action, reason, duration, dx, dy };
  }
}

export function adjacentRemoteDisplay(current: number, count: number, action: string): number {
  if (!Number.isInteger(count) || count < 2 || !Number.isInteger(current) || current < 0 || current >= count ||
    (action !== 'left' && action !== 'right')) return -1;
  return (current + (action === 'left' ? 1 : count - 1)) % count;
}
