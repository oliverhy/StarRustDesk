export interface RemoteWheelStep {
  x: number;
  y: number;
  limited: boolean;
}

// RustDesk wheel packets contain detents, not pixels or platform axis units.
// Keep independent accumulators for each source, and never retain a large
// integer backlog after clipping (otherwise the next tiny movement repeats it).
export class RemoteWheelNormalizer {
  private remainderX: number = 0;
  private remainderY: number = 0;
  private source: string = '';
  private device: number = -1;
  private lastAt: number = -1;
  private budgetAt: number = -1;
  private budget: number = 3;

  reset(): void {
    this.remainderX = 0;
    this.remainderY = 0;
    this.source = '';
    this.device = -1;
    this.lastAt = -1;
    this.budgetAt = -1;
    this.budget = 3;
  }

  convert(x: number, y: number, source: string, device: number, now: number): RemoteWheelStep {
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(now)) {
      this.reset();
      return { x: 0, y: 0, limited: true };
    }
    if (source !== this.source || device !== this.device || now < this.lastAt || now - this.lastAt > 250) {
      this.reset();
      this.source = source;
      this.device = device;
    }
    this.lastAt = now;
    if (this.budgetAt < 0 || now - this.budgetAt >= 32) {
      this.budgetAt = now;
      this.budget = 3;
    }
    // ArkUI mouse axes use wheel-angle units; continuous touchpad axes do not.
    // Unknown tools conservatively use discrete wheel handling, never guess
    // a touchpad from a numeric tool value seen on one device/SDK.
    const units: number = source === 'touchpad' ? 40 : source === 'touch' ? 12 :
      source === 'virtual' ? 1 : 15;
    if (x * this.remainderX < 0) this.remainderX = 0;
    if (y * this.remainderY < 0) this.remainderY = 0;
    const totalX: number = this.remainderX + x / units;
    const totalY: number = this.remainderY + y / units;
    const wholeX: number = Math.trunc(totalX);
    const wholeY: number = Math.trunc(totalY);
    this.remainderX = totalX - wholeX;
    this.remainderY = totalY - wholeY;
    const maximum: number = Math.min(this.budget, source === 'mouse' || source === 'virtual' ? 1 : 3);
    const stepX: number = Math.max(-maximum, Math.min(maximum, wholeX));
    const stepY: number = Math.max(-maximum, Math.min(maximum, wholeY));
    this.budget -= Math.max(Math.abs(stepX), Math.abs(stepY));
    return { x: stepX === 0 ? 0 : stepX, y: stepY === 0 ? 0 : stepY,
      limited: stepX !== wholeX || stepY !== wholeY };
  }
}
