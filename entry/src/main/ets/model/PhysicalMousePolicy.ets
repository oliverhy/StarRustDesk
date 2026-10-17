// Match an actual native/ArkUI event pair, not every event in a time window.
// A native button event must never swallow later ArkUI-only movement.
interface PhysicalPointerDelivery {
  action: number;
  x: number;
  y: number;
  at: number;
  origins: number;
  hasPosition: boolean;
}

export class PhysicalMouseDeduplicator {
  private action: number = -1;
  private x: number = 0;
  private y: number = 0;
  private at: number = 0;
  private deliveries: PhysicalPointerDelivery[] = [];

  clear(): void { this.action = -1; this.deliveries = []; }

  rememberNative(action: number, x: number, y: number, at: number): void {
    this.action = Number.isFinite(x) && Number.isFinite(y) ? action : -1;
    this.x = x;
    this.y = y;
    this.at = at;
  }

  consumeDuplicate(action: number, x: number, y: number, now: number): boolean {
    const duplicate: boolean = action >= 0 && action === this.action &&
      now >= this.at && now - this.at < 80 &&
      Math.abs(x - this.x) < 0.01 && Math.abs(y - this.y) < 0.01;
    // Never reuse a stale native sample after a different ArkUI event.
    this.action = -1;
    return duplicate;
  }

  // Physical buttons can reach onTouch, onMouse and the queued native callback
  // in either order, in local as well as projected windows. Match across
  // origins only: a second real click from the same path must never be dropped.
  consumePointerDuplicate(action: number, x: number, y: number, now: number, origin: number,
    hasPosition: boolean = true): boolean {
    if (action < 0 || (hasPosition && (!Number.isFinite(x) || !Number.isFinite(y)))) return false;
    // Some compatibility Up events have no touch coordinates. Only releases
    // may match without a position; never turn a missing Down/Move into input.
    if (!hasPosition && action !== 2 && action !== 4) return false;
    this.deliveries = this.deliveries.filter((sample: PhysicalPointerDelivery) =>
      now >= sample.at && now - sample.at < 80);
    for (const sample of this.deliveries) {
      if (sample.action === action && (sample.origins & origin) === 0 &&
        (!hasPosition || !sample.hasPosition ||
          (Math.abs(sample.x - x) <= 0.5 && Math.abs(sample.y - y) <= 0.5))) {
        sample.origins |= origin;
        if (!sample.hasPosition && hasPosition) {
          sample.x = x;
          sample.y = y;
          sample.hasPosition = true;
        }
        return true;
      }
    }
    this.deliveries.push({ action, x, y, at: now, origins: origin, hasPosition });
    if (this.deliveries.length > 32) this.deliveries.shift();
    return false;
  }
}

export function isTouchOnlyMouseEvent(touchSource: boolean, mouseSource: boolean,
  pointerTool: boolean, touchTool: boolean): boolean {
  // Projection can wrap a physical mouse in a touch-compatible source. Explicit
  // hardware tool/source information takes precedence over that wrapper.
  return !mouseSource && !pointerTool && (touchSource || touchTool);
}
