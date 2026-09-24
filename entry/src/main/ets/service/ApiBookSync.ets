import { ApiBook, ApiPeer, ApiFailure, RustDeskApiService } from './RustDeskApiService';
import { ApiAddressBookImport } from './ApiAddressBookImport';
import { RustDeskNapi } from './RustDeskNapi';
import { CloudSyncService } from './CloudSyncService';
import { OperationDiagnostic } from './OperationDiagnostic';

export interface BookSyncChange { id: string; name: string; kind: string; local?: ApiPeer; remote?: ApiPeer; }
export interface BookSyncPlan { key: string; revision: number; rows: string; remote: ApiPeer[]; changes: BookSyncChange[]; }

export class ApiBookSync {
  static same(a?: ApiPeer, b?: ApiPeer): boolean {
    if (!a || !b) return a === b;
    return a.name === b.name && JSON.stringify(a.tags.slice().sort()) === JSON.stringify(b.tags.slice().sort());
  }
  static diff(base: ApiPeer[], local: ApiPeer[], remote: ApiPeer[]): BookSyncChange[] {
    const ids = Array.from(new Set(base.concat(local, remote).map((p: ApiPeer) => p.id)));
    const result: BookSyncChange[] = [];
    for (const id of ids) {
      const b = base.find((p: ApiPeer) => p.id === id);
      const l = local.find((p: ApiPeer) => p.id === id);
      const r = remote.find((p: ApiPeer) => p.id === id);
      if (ApiBookSync.same(l, r)) continue;
      const lc = !ApiBookSync.same(l, b), rc = !ApiBookSync.same(r, b);
      const kind = lc && rc ? 'conflict' : lc ? (l ? 'upload' : 'deleteRemote') : (r ? 'download' : 'deleteLocal');
      result.push({ id: id, name: l?.name || r?.name || b?.name || id, kind: kind, local: l, remote: r });
    }
    return result;
  }
  // By design, direct-IP entries do not take part in two-way sync: both sides
  // (local and remote) are filtered to syncable IDs, so direct-IP peers never
  // produce "download" changes that can never settle.
  static syncableId(id: string): boolean {
    return /^[A-Za-z0-9_-]{1,64}$/.test(id);
  }
  static key(api: RustDeskApiService, book: ApiBook): string {
    return `api-book-sync:${encodeURIComponent(api.server)}:${encodeURIComponent(api.username)}:${encodeURIComponent(book.guid || 'legacy')}`;
  }
  static readLocal(): Record<string, string>[] {
    const rows = JSON.parse(RustDeskNapi.getOption('saved-connections') || '[]') as Record<string, string>[];
    if (!Array.isArray(rows) || rows.some((p: Record<string, string>) => !p || typeof p.remoteId !== 'string')) throw new ApiFailure('本地连接格式错误');
    return rows;
  }
  static async preview(api: RustDeskApiService, book: ApiBook): Promise<BookSyncPlan> {
    const trace = new OperationDiagnostic('api-book-sync', 'preview');
    try {
    trace.event('read_local', { legacy: book.legacy });
    const key = ApiBookSync.key(api, book);
    const revision = api.sessionRevision();
    const rows = RustDeskNapi.getOption('saved-connections');
    const base = JSON.parse(RustDeskNapi.getOption(key) || '[]') as ApiPeer[];
    if (!Array.isArray(base) || base.some((p: ApiPeer) => !p || typeof p.id !== 'string' ||
      typeof p.name !== 'string' || !Array.isArray(p.tags))) throw new ApiFailure('同步基线格式错误，已停止，未改动数据');
    trace.event('read_remote');
    const remote = (await api.peers(book, true)).filter((p: ApiPeer) => ApiBookSync.syncableId(p.id));
    if (key !== ApiBookSync.key(api, book) || revision !== api.sessionRevision() ||
      rows !== RustDeskNapi.getOption('saved-connections')) throw new ApiFailure('账号或本地连接已改变，请重试');
    const local = ApiBookSync.readLocal().filter((p: Record<string, string>) => ApiBookSync.syncableId(p.remoteId))
      .map((p: Record<string, string>) => {
        const old = base.find((v: ApiPeer) => v.id === p.remoteId);
        return { id: p.remoteId, name: p.name || p.remoteId, platform: old?.platform || '', tags: old?.tags || [] } as ApiPeer;
      });
    const changes = ApiBookSync.diff(base, local, remote);
    trace.end('completed', { items: local.length, remote_items: remote.length,
      conflicts: changes.filter((c: BookSyncChange) => c.kind === 'conflict').length,
      deletions: changes.filter((c: BookSyncChange) => c.kind === 'deleteLocal' || c.kind === 'deleteRemote').length });
    return { key: key, revision: revision, rows: rows, remote: remote, changes: changes };
    } catch (error) { trace.fail(error as Object); throw error as Error; }
  }
  static async apply(api: RustDeskApiService, book: ApiBook, plan: BookSyncPlan, preferLocal: boolean): Promise<void> {
    const trace = new OperationDiagnostic('api-book-sync', 'apply');
    let writes = 0;
    try {
    trace.event('preflight', { items: plan.changes.length, prefer_local: preferLocal, legacy: book.legacy });
    if (plan.key !== ApiBookSync.key(api, book) || plan.revision !== api.sessionRevision() ||
      plan.rows !== RustDeskNapi.getOption('saved-connections')) throw new ApiFailure('账号或本地数据已变化，请重新预览');
    trace.event('read_remote');
    const current = (await api.peers(book, true)).filter((p: ApiPeer) => ApiBookSync.syncableId(p.id));
    if (JSON.stringify(current) !== JSON.stringify(plan.remote)) throw new ApiFailure('服务器数据已变化，请重新预览');
    // Preflight permissions before any operation. A read-only book can still be imported.
    const push = plan.changes.some((c: BookSyncChange) => c.kind === 'upload' || c.kind === 'deleteRemote' || (c.kind === 'conflict' && preferLocal));
    trace.event('permissions');
    if (push && !book.writable) throw new ApiFailure('地址簿只读，请使用导入功能');
    const pull: ApiPeer[] = [], remove: string[] = [];
    let expected = plan.remote.slice();
    trace.event('write_remote');
    for (const change of plan.changes) {
      if (plan.key !== ApiBookSync.key(api, book) || plan.revision !== api.sessionRevision()) throw new ApiFailure('账号已改变，同步停止');
      const useLocal = change.kind === 'upload' || change.kind === 'deleteRemote' || (change.kind === 'conflict' && preferLocal);
      if (useLocal) {
        if (change.local) await api.writePeer(book, change.local, !change.remote);
        else await api.deletePeer(book, change.id);
        writes++;
        expected = expected.filter((p: ApiPeer) => p.id !== change.id);
        if (change.local) expected.push(change.local);
      } else if (change.remote) pull.push(change.remote);
      else remove.push(change.id);
    }
    // If the user edited locally while HTTP was in flight, never overwrite it.
    if (plan.key !== ApiBookSync.key(api, book) || plan.revision !== api.sessionRevision() ||
      plan.rows !== RustDeskNapi.getOption('saved-connections')) throw new ApiFailure('上传已执行，但账号或本地又有修改；请重新预览，未覆盖本地数据');
    trace.event('write_local', { writes: writes, items: pull.length, deletions: remove.length });
    if (pull.length) ApiAddressBookImport.importSelected(book, pull);
    let rows = ApiBookSync.readLocal();
    rows = rows.filter((p: Record<string, string>) => !remove.includes(p.remoteId));
    for (const row of rows) {
      const peer = pull.find((p: ApiPeer) => p.id === row.remoteId);
      if (peer) row.name = peer.name; // Password, group and performance settings stay local.
    }
    RustDeskNapi.setOption('saved-connections', JSON.stringify(rows));
    CloudSyncService.markLocalChanged();
    AppStorage.setOrCreate('savedConnectionsCloudRevision', (AppStorage.get<number>('savedConnectionsCloudRevision') ?? 0) + 1);
    const applied = RustDeskNapi.getOption('saved-connections');
    trace.event('verify');
    const verified = (await api.peers(book, true)).filter((p: ApiPeer) => ApiBookSync.syncableId(p.id));
    if (plan.key !== ApiBookSync.key(api, book) || plan.revision !== api.sessionRevision() ||
      applied !== RustDeskNapi.getOption('saved-connections')) throw new ApiFailure('同步期间数据发生变化，请重新预览');
    if (expected.length !== verified.length || expected.some((p: ApiPeer) =>
      !ApiBookSync.same(p, verified.find((v: ApiPeer) => v.id === p.id)))) {
      throw new ApiFailure('服务器未完整保存或又有修改，请重新预览；未更新同步基线');
    }
    RustDeskNapi.setOption(plan.key, JSON.stringify(verified));
    trace.end('completed', { writes: writes, items: plan.changes.length });
    } catch (error) { trace.fail(error as Object, { writes: writes }); throw error as Error; }
  }
}
