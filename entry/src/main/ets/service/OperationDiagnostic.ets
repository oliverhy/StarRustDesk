import { RustDeskNapi } from './RustDeskNapi';

// Closed vocabulary and numeric/boolean fields: never serialize an Error, URI,
// peer name, server configuration, credential or user-entered content.
const SCOPES: string[] = ['api-book-sync', 'recording', 'file-operation', 'file-transfer', 'server-config'];
const ACTIONS: string[] = ['preview', 'apply', 'record', 'export', 'delete', 'prepare_files', 'prepare_folder', 'prepare_download', 'transfer', 'remote_action', 'qr_scan'];
const STEPS: string[] = ['start', 'read_local', 'read_remote', 'preflight', 'permissions', 'write_remote', 'write_local',
  'verify', 'select', 'copy', 'open_source', 'open_target', 'close', 'queued', 'cancel_requested', 'failed', 'cancelled',
  'completed', 'started', 'stop', 'decode', 'ready', 'stale', 'timeout', 'rejected', 'progress', 'archive', 'waiting_confirmation'];
const FIELDS: string[] = ['code', 'result', 'items', 'bytes', 'written_bytes', 'conflicts', 'deletions', 'remote_items',
  'writes', 'prefer_local', 'legacy', 'kind', 'job', 'upload', 'files', 'depth', 'source_bytes', 'native_status', 'bytes_per_second'];
interface DiagnosticError { code?: number | string; status?: number; message?: string; }
export interface DiagnosticFields {
  code?: number;
  result?: number;
  items?: number;
  bytes?: number;
  written_bytes?: number;
  conflicts?: number;
  deletions?: number;
  remote_items?: number;
  writes?: number;
  prefer_local?: boolean;
  legacy?: boolean;
  kind?: number;
  job?: number;
  upload?: boolean;
  files?: number;
  depth?: number;
  source_bytes?: number;
  native_status?: number;
  bytes_per_second?: number;
}

export class OperationDiagnostic {
  private static sequence: number = 0;
  private id: string;
  private started: number = Date.now();
  private finished: boolean = false;
  private scope: string;
  private action: string;
  private lastStep: string = 'start';
  private failureReason: string = 'none';
  constructor(scope: string, action: string) {
    this.scope = SCOPES.includes(scope) ? scope : 'file-operation';
    this.action = ACTIONS.includes(action) ? action : 'remote_action';
    this.id = `${this.started}-${++OperationDiagnostic.sequence}`;
    this.event('start');
  }
  event(step: string, fields: DiagnosticFields = {}): void {
    if (this.finished || !STEPS.includes(step)) return;
    const after = this.lastStep;
    this.lastStep = step;
    try {
      if (RustDeskNapi.getOption('diagnostic-log-enabled') !== '1') return;
      let message = `op_id=${this.id} action=${this.action} step=${step} after=${after} reason=${this.failureReason} elapsed_ms=${Math.max(0, Date.now() - this.started)}`;
      const values: (number | boolean | undefined)[] = [fields.code, fields.result, fields.items, fields.bytes,
        fields.written_bytes, fields.conflicts, fields.deletions, fields.remote_items, fields.writes,
        fields.prefer_local, fields.legacy, fields.kind, fields.job, fields.upload, fields.files, fields.depth,
        fields.source_bytes, fields.native_status, fields.bytes_per_second];
      for (let index = 0; index < FIELDS.length; index++) {
        const key = FIELDS[index];
        const value = values[index];
        if (typeof value === 'boolean' || (typeof value === 'number' && Number.isFinite(value))) message += ` ${key}=${value}`;
      }
      RustDeskNapi.appendDiagnosticLog(this.scope, message);
    } catch (_e) { /* Logging must never change the operation's result. */ }
  }
  end(step: string, fields: DiagnosticFields = {}): void {
    this.event(step, fields);
    this.finished = true;
  }
  fail(error: Object, fields: DiagnosticFields = {}): void {
    this.failureReason = 'operation_error';
    try {
      const message = (error as DiagnosticError)?.message;
      if (typeof message === 'string') {
        if (/取消/.test(message)) this.failureReason = 'cancelled';
        else if (/变化|改变|修改/.test(message)) this.failureReason = 'state_changed';
        else if (/只读|权限|permission denied|EACCES/i.test(message)) this.failureReason = 'permission';
        else if (/空间不足|no space|ENOSPC/i.test(message)) this.failureReason = 'storage_full';
        else if (/超时|timed? ?out/i.test(message)) this.failureReason = 'timeout';
        else if (/格式|无效|重复|不兼容/.test(message)) this.failureReason = 'invalid_data';
        else if (/未返回|不完整|未完整/.test(message)) this.failureReason = 'incomplete_response';
        else if (/校验|大小|size mismatch|file is empty|archive is empty/i.test(message)) this.failureReason = 'verification';
        else if (/file is missing|not found|ENOENT/i.test(message)) this.failureReason = 'missing_file';
        else if (/关键帧|没有可导出/.test(message)) this.failureReason = 'no_video';
        else if (/文件数|层级/.test(message)) this.failureReason = 'limit';
      }
    } catch (_e) {}
    fields.code = OperationDiagnostic.errorCode(error);
    this.end('failed', fields);
  }
  static errorCode(error: Object): number {
    try {
      if (!error || typeof error !== 'object') return 0;
      const code = (error as DiagnosticError).code;
      if (typeof code === 'number' && Number.isFinite(code)) return code;
      if (typeof code === 'string' && /^-?\d{1,10}$/.test(code)) return Number(code);
      const status = (error as DiagnosticError).status;
      if (typeof status === 'number' && Number.isFinite(status)) return status;
    } catch (_e) {}
    return 0;
  }
}
