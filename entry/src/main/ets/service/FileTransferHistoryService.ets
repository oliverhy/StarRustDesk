import { RustDeskNapi } from './RustDeskNapi'

export interface FileTransferHistoryRecord {
  id: string
  direction: string
  peerId: string
  displayName: string
  fileType: string
  totalBytes: number
  itemCount: number
  startedAt: number
  finishedAt: number
  durationMs: number
  averageSpeed: number
  status: string
  error: string
}

const HISTORY_OPTION_KEY: string = 'file-transfer-history-v1'
const HISTORY_MAX_RECORDS: number = 500
const HISTORY_RETENTION_MS: number = 90 * 24 * 60 * 60 * 1000

export class FileTransferHistoryService {
  static load(): FileTransferHistoryRecord[] {
    let raw: string = RustDeskNapi.getOption(HISTORY_OPTION_KEY)
    if (raw.length === 0) return []
    try {
      let rows: FileTransferHistoryRecord[] = JSON.parse(raw) as FileTransferHistoryRecord[]
      let cutoff: number = Date.now() - HISTORY_RETENTION_MS
      let records: FileTransferHistoryRecord[] = []
      rows.forEach((row: FileTransferHistoryRecord) => {
        if (row.id.length > 0 && row.finishedAt >= cutoff) {
          records.push(row)
        }
      })
      records.sort((left: FileTransferHistoryRecord, right: FileTransferHistoryRecord) =>
        right.finishedAt - left.finishedAt)
      if (records.length > HISTORY_MAX_RECORDS) {
        records = records.slice(0, HISTORY_MAX_RECORDS)
      }
      return records
    } catch (_e) {
      return []
    }
  }

  static add(record: FileTransferHistoryRecord): void {
    let records: FileTransferHistoryRecord[] = FileTransferHistoryService.load().filter(
      (item: FileTransferHistoryRecord) => item.id !== record.id)
    records.unshift(record)
    FileTransferHistoryService.save(records)
  }

  static delete(id: string): void {
    FileTransferHistoryService.save(FileTransferHistoryService.load().filter(
      (item: FileTransferHistoryRecord) => item.id !== id))
  }

  static clear(): void {
    RustDeskNapi.setOption(HISTORY_OPTION_KEY, '[]')
  }

  private static save(records: FileTransferHistoryRecord[]): void {
    let cutoff: number = Date.now() - HISTORY_RETENTION_MS
    let trimmed: FileTransferHistoryRecord[] = records.filter(
      (item: FileTransferHistoryRecord) => item.finishedAt >= cutoff).slice(0, HISTORY_MAX_RECORDS)
    RustDeskNapi.setOption(HISTORY_OPTION_KEY, JSON.stringify(trimmed))
  }
}
