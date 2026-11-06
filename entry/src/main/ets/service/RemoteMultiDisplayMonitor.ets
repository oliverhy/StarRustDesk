import { display } from '@kit.ArkUI';
import { RemoteLocalDisplay, RemoteMultiDisplayCapability, evaluateRemoteMultiDisplay } from '../model/RemoteMultiDisplayCapability';
import { RustDeskNapi } from './RustDeskNapi';
import { RemoteDisplayPolicy } from './RemoteDisplayPolicy';

// Detect local topology and the peer protocol. An actual decoder/surface is
// created on demand, so runtime resource errors still need graceful handling.
export class RemoteMultiDisplayMonitor {
  private readonly onChange: (value: RemoteMultiDisplayCapability) => void;
  constructor(onChange: (value: RemoteMultiDisplayCapability) => void = () => {}) { this.onChange = onChange; }
  private generation: number = 0;
  private request: number = 0;
  private running: boolean = false;
  private remoteCount: number = 1;
  private peerMultiStreamReady: boolean = false;
  private lastSummary: string = '';
  private mainDisplayId: number = -1;
  private registered: string[] = [];
  private readonly changed = (_id: number): void => { this.refresh(); };

  start(): void {
    if (this.running) return;
    this.running = true;
    this.generation++;
    for (const kind of ['add', 'remove', 'change']) {
      try {
        display.on(kind as 'add' | 'remove' | 'change', this.changed);
        this.registered.push(kind);
      } catch (_error) {
        RustDeskNapi.appendDiagnosticLog('multi-display', `listener_unavailable event=${kind}`);
      }
    }
    this.refresh();
  }

  setRemoteCount(count: number): void {
    const value: number = Number.isInteger(count) && count > 0 ? count : 1;
    const localId: number = this.getMainDisplayId();
    const peerReady: boolean = RustDeskNapi.isSecondaryDisplaySupported();
    if (this.remoteCount === value && this.mainDisplayId === localId && this.peerMultiStreamReady === peerReady) return;
    this.remoteCount = value;
    this.peerMultiStreamReady = peerReady;
    this.refresh();
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    this.generation++;
    this.request++;
    for (const kind of this.registered) {
      try { display.off(kind as 'add' | 'remove' | 'change', this.changed); } catch (_error) {}
    }
    this.registered = [];
    this.lastSummary = '';
    this.mainDisplayId = -1;
    this.peerMultiStreamReady = false;
  }

  private getMainDisplayId(): number {
    try {
      const main = RemoteDisplayPolicy.getMainWindow();
      const id = main?.getWindowProperties().displayId;
      return typeof id === 'number' && Number.isInteger(id) && id >= 0 ? id : -1;
    } catch (_error) { return -1; }
  }

  private refresh(): void {
    if (!this.running) return;
    const generation: number = this.generation;
    const request: number = ++this.request;
    const localId: number = this.getMainDisplayId();
    const peerReady: boolean = this.peerMultiStreamReady;
    this.mainDisplayId = localId;
    let query: Promise<display.Display[]>;
    try { query = display.getAllDisplays(); } catch (_error) {
      this.log({ candidates: [], reason: 'display_query_failed', available: false });
      return;
    }
    query.then((items: display.Display[]) => {
      if (!this.running || generation !== this.generation || request !== this.request) return;
      const candidates: RemoteLocalDisplay[] = items.map((item: display.Display): RemoteLocalDisplay => ({
        id: item.id, sourceMode: item.sourceMode ?? -1, width: item.width, height: item.height
      }));
      const result: RemoteMultiDisplayCapability = evaluateRemoteMultiDisplay(true, localId, candidates,
        this.remoteCount, peerReady, true);
      this.log(result);
    }).catch(() => {
      if (!this.running || generation !== this.generation || request !== this.request) return;
      this.log({ candidates: [], reason: 'display_query_failed', available: false });
    });
  }

  private log(result: RemoteMultiDisplayCapability): void {
    this.onChange(result);
    const summary: string = `reason=${result.reason} local_extended=${result.candidates.length} ` +
      `remote_displays=${this.remoteCount} available=${result.available ? 1 : 0}`;
    if (summary === this.lastSummary) return;
    this.lastSummary = summary;
    RustDeskNapi.appendDiagnosticLog('multi-display', `capability ${summary}`);
  }
}
