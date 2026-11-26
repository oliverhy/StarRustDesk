// Only actions supported by the paired Windows streaming helper. These are
// local UI names, not commands that can be supplied by the remote host.
export const STREAM_KEYS: string[] = ['Esc', 'Tab', 'Enter', 'Backspace', 'Space', 'Delete', 'Home', 'End',
  'PageUp', 'PageDown', 'Left', 'Up', 'Right', 'Down', 'Ins', 'W', 'A', 'S', 'D', 'Ctrl+Shift+Esc', 'Ctrl+Shift+Del', 'Alt+F4'];
export function streamBoundPan(offset: number, canvas: number, viewport: number): number {
  if (!Number.isFinite(offset) || !Number.isFinite(canvas) || !Number.isFinite(viewport) || viewport <= 0) return 0;
  const limit = Math.max(0, (canvas - viewport) / 2);
  return Math.max(-limit, Math.min(limit, offset));
}
export function streamRefreshingPicture(phase: number, route: number, previousPicture: boolean, elapsedMs: number): boolean {
  return previousPicture && (route===4 || route===5 || route===11) && (phase===1 || phase===2) &&
    elapsedMs>=0 && elapsedMs<6000;
}
export function streamKeyGrid(saved: string[]): string[] {
  const allowed=STREAM_KEYS.filter((k: string)=>!k.includes('+') && k!=='Ins');
  const sorted: string[]=[];
  for(const k of saved.concat(allowed)) if(allowed.includes(k) && !sorted.includes(k)) sorted.push(k);
  return sorted;
}
export function streamKeyCode(key: string): number {
  if (/^F([1-9]|1[0-2])$/.test(key)) return 111 + Number(key.slice(1));
  if (/^[WASD]$/.test(key)) return key.charCodeAt(0);
  switch (key) {
    case 'Ctrl': return 17; case 'Alt': return 18; case 'Shift': return 16; case 'Win/Cmd': return 91;
    case 'Esc': return 27; case 'Tab': return 9; case 'Enter': return 13; case 'Backspace': return 8;
    case 'Space': return 32; case 'Delete': return 46; case 'Ins': return 45; case 'Home': return 36;
    case 'End': return 35; case 'PageUp': return 33; case 'PageDown': return 34; case 'Left': return 37;
    case 'Up': return 38; case 'Right': return 39; case 'Down': return 40; default: return 0;
  }
}
export class StreamControlsBack {
  dismiss: () => boolean = (): boolean => false;
}
