import { decodeRemoteToolbarPosition } from './RemoteToolbarPlacement';

export const REMOTE_PEER_OPTION_NAMES: string[] = [
  'input-mode', 'show-local-cursor', 'show-virtual-mouse', 'edge-auto-pan-enabled',
  'keyboard-compat', 'relative-mouse', 'cursor-compat', 'remote-control-toolbar-order',
  'remote-keyboard-toolbar-order', 'remote-keyboard-more-order', 'remote-toolbar-position-v1',
  'keyboard-toolbar-position-v1', 'remote-toolbar-collapsed', 'keyboard-tools-collapsed',
  'pc-toolbar-pinned', 'desktop-view-mode', 'desktop-custom-percent', 'handheld-zoom'
];

export function remotePeerPreferenceKey(server: string, peer: string): string {
  const id: string = peer.replace(/[\s\u200B-\u200D\uFEFF]+/g, '');
  if (!id || id.length > 512 || server.length > 512) return '';
  const address: string = server.trim().toLowerCase();
  // A tuple avoids ambiguous separators and preserves IPv4/IPv6 punctuation.
  return `remote-peer-preferences-v1-${encodeURIComponent(JSON.stringify([
    address ? 'custom' : 'public', address, id
  ]))}`;
}

export function validRemotePeerOption(name: string, value: string): boolean {
  if (REMOTE_PEER_OPTION_NAMES.indexOf(name) < 0 || typeof value !== 'string' || value.length > 2048) return false;
  if (name === 'input-mode') return value === 'mouse' || value === 'touch';
  if (name === 'keyboard-compat') return value === '0' || value === '1' || value === '2';
  if (name === 'cursor-compat') return value === 'auto' || value === 'embedded' || value === 'separate';
  if (name === 'desktop-view-mode') return value === 'adaptive' || value === 'original' || value === 'custom';
  if (name === 'desktop-custom-percent' || name === 'handheld-zoom') {
    const number: number = Number(value);
    return value.length > 0 && Number.isFinite(number) &&
      (name === 'handheld-zoom' ? number >= 0.5 && number <= 5 : number >= 25 && number <= 300);
  }
  if (name.endsWith('-position-v1')) return decodeRemoteToolbarPosition(value) !== undefined;
  if (name.endsWith('-order')) return /^[A-Za-z0-9_+,.-]+$/.test(value);
  return value === '0' || value === '1';
}

export function decodeRemotePeerOptions(value: string): Map<string, string> {
  const result: Map<string, string> = new Map<string, string>();
  if (!value || value.length > 16384) return result;
  try {
    const record = JSON.parse(value) as Record<string, string> | null;
    if (!record || Array.isArray(record)) return result;
    for (const name of REMOTE_PEER_OPTION_NAMES) {
      if (validRemotePeerOption(name, record[name])) result.set(name, record[name]);
    }
  } catch (_error) {}
  return result;
}
