// Conservative gate: a display with an unknown or mirrored source mode is not
// evidence of a system-extended desktop. Remote multi-frame routing and an
// independent decoder/surface must also be ready before offering the feature.
export interface RemoteLocalDisplay {
  id: number;
  sourceMode: number;
  width: number;
  height: number;
}

export interface RemoteMultiDisplayCapability {
  candidates: RemoteLocalDisplay[];
  reason: string;
  available: boolean;
}

export function evaluateRemoteMultiDisplay(isPc: boolean, localId: number, displays: RemoteLocalDisplay[],
  remoteCount: number, remoteMultiStreamReady: boolean, secondSurfaceReady: boolean): RemoteMultiDisplayCapability {
  const candidates: RemoteLocalDisplay[] = displays.filter((item: RemoteLocalDisplay) =>
    Number.isInteger(item.id) && item.id >= 0 && item.id !== localId && item.sourceMode === 3 &&
    Number.isFinite(item.width) && item.width > 0 && Number.isFinite(item.height) && item.height > 0);
  if (!isPc) return { candidates: [], reason: 'device_not_pc', available: false };
  if (!Number.isInteger(localId) || localId < 0) return { candidates: [], reason: 'local_display_unknown', available: false };
  if (remoteCount < 2) return { candidates, reason: 'remote_single_display', available: false };
  if (candidates.length === 0) return { candidates, reason: 'no_confirmed_extended_display', available: false };
  if (!remoteMultiStreamReady || !secondSurfaceReady) return { candidates, reason: 'multi_stream_not_ready', available: false };
  return { candidates, reason: 'ready', available: true };
}
