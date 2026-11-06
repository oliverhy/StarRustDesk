import { ScreenGameKey } from './GameScreenControls';

// The saved model stays plain JSON. This observed view model keeps each
// control's identity stable while its position and appearance are edited.
@Observed
export class GameScreenRenderKey {
  id: number = 0;
  target: string = '';
  x: number = 0;
  y: number = 0;
  size: number = 52;
  opacity: number = 70;
  constructor(key: ScreenGameKey) { this.apply(key); }
  apply(key: ScreenGameKey): void {
    this.id = key.id; this.target = key.target; this.x = key.x; this.y = key.y;
    this.size = key.size; this.opacity = key.opacity;
  }
}
