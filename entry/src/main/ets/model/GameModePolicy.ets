// Backlog is the app-visible compressed-frame queue, not end-to-end latency.
// Never discard dependent frames: ask the peer for a lower rate when decoding
// cannot keep up, and recover slowly once the queue has drained.
export class GameModePolicy {
  private target: number = 60
  private lastSample: number = 0
  private highSamples: number = 0
  private lowSamples: number = 0

  reset(): void {
    this.target = 60
    this.lastSample = 0
    this.highSamples = 0
    this.lowSamples = 0
  }

  fps(): number { return this.target }

  observe(queue: number, now: number): number {
    if (!Number.isFinite(queue) || queue < 0 || !Number.isFinite(now) || now <= 0) return this.target
    if (this.lastSample > 0 && now < this.lastSample) {
      this.lastSample = now
      this.highSamples = 0
      this.lowSamples = 0
      return this.target
    }
    // React to a sustained backlog in about half a second instead of letting
    // compressed frames accumulate for two seconds. A single burst is ignored.
    if (this.lastSample > 0 && now - this.lastSample < 500) return this.target
    // A stalled UI, background transition or unavailable decoder snapshot
    // cannot count as continuous congestion or continuous recovery.
    if (this.lastSample > 0 && now - this.lastSample > 1500) {
      this.highSamples = 0
      this.lowSamples = 0
    }
    this.lastSample = now
    if (queue >= 4) {
      this.highSamples++
      this.lowSamples = 0
      if (this.highSamples >= 2) {
        this.target = Math.max(20, this.target - 10)
        this.highSamples = 0
      }
    } else if (queue <= 1) {
      this.lowSamples++
      this.highSamples = 0
      // Recovery remains deliberately slow (six seconds of clean samples).
      if (this.lowSamples >= 12) {
        this.target = Math.min(60, this.target + 5)
        this.lowSamples = 0
      }
    } else {
      this.highSamples = 0
      this.lowSamples = 0
    }
    return this.target
  }
}
