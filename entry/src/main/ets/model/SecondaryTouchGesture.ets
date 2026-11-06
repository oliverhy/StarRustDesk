export interface SecondaryTouchPoint { id: number; x: number; y: number }
export interface SecondaryTouchAction { kind: string; x: number; y: number; dx: number; dy: number; scale: number }

function action(kind: string, x: number = 0, y: number = 0, dx: number = 0,
  dy: number = 0, scale: number = 1): SecondaryTouchAction {
  return { kind, x, y, dx, dy, scale };
}

// One sequence has one owner. A released finger from a multi-touch sequence
// can never turn into a new click; cancel/third finger release held buttons.
export class SecondaryTouchGesture {
  private phase: string = 'idle';
  private first: SecondaryTouchPoint = { id: -1, x: 0, y: 0 };
  private last: SecondaryTouchPoint = { id: -1, x: 0, y: 0 };
  private started: number = 0;
  private moved: boolean = false;
  private multiKind: string = '';
  private multiStartDistance: number = 0;
  private multiLastDistance: number = 0;
  private centerX: number = 0;
  private centerY: number = 0;
  private originX: number = 0;
  private originY: number = 0;
  private tapAllowed: boolean = false;

  reset(): void { this.phase = 'idle'; this.multiKind = ''; this.moved = false; }

  longPress(): SecondaryTouchAction[] {
    if (this.phase !== 'single' || this.moved) return [];
    this.phase = 'long';
    return [action('right', this.first.x, this.first.y)];
  }

  handle(type: string, points: SecondaryTouchPoint[], changed: SecondaryTouchPoint[], now: number): SecondaryTouchAction[] {
    if (type === 'cancel') { const held = this.phase === 'drag'; this.phase = 'drain'; return held ? [action('release')] : []; }
    if (this.phase === 'drain') { if (points.length === 0) this.reset(); return []; }
    if (points.length >= 3) { const held = this.phase === 'drag'; this.phase = 'drain'; return held ? [action('release')] : []; }
    if (this.phase === 'idle') {
      if (type !== 'down' || points.length !== 1) return [];
      this.first = points[0]; this.last = points[0]; this.started = now; this.moved = false;
      this.phase = 'single';
      return [action('preview', this.first.x, this.first.y)];
    }
    if (points.length === 2 && this.phase !== 'multi') {
      const held = this.phase === 'drag';
      this.tapAllowed = this.phase === 'single' && !this.moved;
      this.phase = 'multi'; this.multiKind = '';
      this.originX = this.centerX = (points[0].x + points[1].x) / 2;
      this.originY = this.centerY = (points[0].y + points[1].y) / 2;
      this.multiStartDistance = this.multiLastDistance = Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
      return held ? [action('release')] : [];
    }
    if (this.phase === 'multi') {
      if (type === 'up' || points.length < 2) {
        const tap = this.tapAllowed && this.multiKind === '' && now - this.started <= 500;
        this.phase = points.length > 0 ? 'drain' : 'idle';
        return tap ? [action('right', this.originX, this.originY)] : [];
      }
      const x = (points[0].x + points[1].x) / 2; const y = (points[0].y + points[1].y) / 2;
      const distance = Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
      const deciding = this.multiKind === '';
      if (deciding) {
        if (Math.abs(distance - this.multiStartDistance) >= 12) this.multiKind = 'zoom';
        else if (Math.hypot(x - this.originX, y - this.originY) >= 8) this.multiKind = 'scroll';
      }
      const dx = x - (deciding ? this.originX : this.centerX);
      const dy = y - (deciding ? this.originY : this.centerY);
      const previousDistance = deciding ? this.multiStartDistance : this.multiLastDistance;
      const ratio = previousDistance > 0 ? distance / previousDistance : 1;
      this.centerX = x; this.centerY = y; this.multiLastDistance = distance;
      if (this.multiKind === 'scroll') return [action('scroll', x, y, dx, dy)];
      if (this.multiKind === 'zoom') return [action('zoom', x, y, dx, dy, ratio)];
      return [];
    }
    const item = points.find((p: SecondaryTouchPoint) => p.id === this.first.id) ??
      changed.find((p: SecondaryTouchPoint) => p.id === this.first.id) ?? this.last;
    if (type === 'move' && (this.phase === 'single' || this.phase === 'drag')) {
      const moved = Math.hypot(item.x - this.first.x, item.y - this.first.y) >= 8;
      if (moved && this.phase === 'single') {
        this.phase = 'drag'; this.moved = true; this.last = item;
        return [action('down', this.first.x, this.first.y), action('move', item.x, item.y)];
      }
      this.last = item;
      return this.phase === 'drag' ? [action('move', item.x, item.y)] : [action('preview', item.x, item.y)];
    }
    if (type === 'up') {
      const previous = this.phase; this.phase = points.length > 0 ? 'drain' : 'idle';
      if (previous === 'drag') return [action('up', item.x, item.y)];
      if (previous === 'single') return [action('click', item.x, item.y)];
    }
    return [];
  }
}
