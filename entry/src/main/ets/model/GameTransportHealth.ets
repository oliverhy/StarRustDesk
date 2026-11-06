// Use only distinct peer-reported delay samples. A frozen desktop, low FPS,
// one high ping, or repeated reads of a stale sample is not evidence that the
// transport is unstable. Values are deliberately conservative until measured
// against real networks; a reconnect may still not improve a long route.
export class GameTransportHealth {
  private lastSeq: number = 0
  private lastAt: number = 0
  private badSince: number = 0
  private badSamples: number = 0

  reset(): void {
    this.lastSeq = 0
    this.lastAt = 0
    this.badSince = 0
    this.badSamples = 0
  }

  observe(seq: number, delayMs: number, now: number): boolean {
    if (!Number.isFinite(seq) || seq <= 0 || !Number.isFinite(delayMs) ||
      !Number.isFinite(now) || now <= 0 || seq === this.lastSeq) return false
    if ((this.lastSeq > 0 && (seq < this.lastSeq || seq > this.lastSeq + 1)) ||
      (this.lastAt > 0 && (now < this.lastAt || now - this.lastAt > 15000))) {
      this.badSince = 0
      this.badSamples = 0
    }
    this.lastSeq = seq
    this.lastAt = now
    if (delayMs < 1200) {
      this.badSince = 0
      this.badSamples = 0
      return false
    }
    if (this.badSamples === 0) this.badSince = now
    this.badSamples++
    return this.badSamples >= 4 && now - this.badSince >= 12000
  }
}
