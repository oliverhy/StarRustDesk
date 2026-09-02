import { RustDeskTheme } from '../theme/RustDeskTheme'
import { FileTransferHistoryRecord, FileTransferHistoryService } from '../service/FileTransferHistoryService'

@CustomDialog
export struct FileTransferHistoryDialog {
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @State records: FileTransferHistoryRecord[] = []
  @State filter: string = 'all'
  controller?: CustomDialogController

  aboutToAppear(): void {
    this.reload()
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('文件传输历史')
            .fontSize(21)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
            .fontColor(this.primaryTextColor())
            .width('100%')
          Text(`本机保存最近 90 天，最多 500 条 · 共 ${this.records.length} 条`)
            .fontSize(12)
            .fontColor(this.secondaryTextColor())
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('清空')
          .height(34)
          .fontSize(13)
          .fontColor(this.records.length > 0 ? RustDeskTheme.ERROR : this.secondaryTextColor())
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          .borderRadius(7)
          .enabled(this.records.length > 0)
          .onClick(() => {
            this.confirmClear()
          })
      }
      .width('100%')

      Row({ space: 7 }) {
        this.buildFilterButton('全部', 'all')
        this.buildFilterButton('发送', 'upload')
        this.buildFilterButton('取回', 'download')
        this.buildFilterButton('失败', 'failed')
      }
      .width('100%')

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      if (this.filteredRecords().length === 0) {
        Column({ space: 8 }) {
          Text('暂无传输记录')
            .fontSize(16)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.primaryTextColor())
          Text(this.filter === 'all' ? '完成发送或取回后会显示在这里' : '当前筛选条件下没有记录')
            .fontSize(13)
            .fontColor(this.secondaryTextColor())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.filteredRecords(), (record: FileTransferHistoryRecord) => {
            ListItem() {
              this.buildRecord(record)
            }
          }, (record: FileTransferHistoryRecord) => record.id)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }

      Button('关闭')
        .height(42)
        .width('100%')
        .fontSize(15)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(Color.White)
        .backgroundColor(RustDeskTheme.ACCENT)
        .borderRadius(7)
        .onClick(() => {
          if (this.controller !== undefined) this.controller.close()
        })
    }
    .width('92%')
    .height('78%')
    .constraintSize({ maxWidth: 680 })
    .padding({ left: 18, right: 18, top: 20, bottom: 16 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.BORDER_DARK : '#E4EAF3' })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#26345A84', offsetX: 0, offsetY: 8 })
  }

  @Builder
  buildFilterButton(label: string, value: string) {
    Button(label)
      .layoutWeight(1)
      .height(34)
      .fontSize(13)
      .fontColor(this.filter === value ? Color.White : this.primaryTextColor())
      .backgroundColor(this.filter === value ? RustDeskTheme.ACCENT :
        (this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED))
      .borderRadius(7)
      .onClick(() => {
        this.filter = value
      })
  }

  @Builder
  buildRecord(record: FileTransferHistoryRecord) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(record.direction === 'download' ? '取回' : '发送')
          .fontSize(12)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(Color.White)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(6)
        Text(record.displayName)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.primaryTextColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.statusText(record.status))
          .fontSize(12)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.statusColor(record.status))
      }
      .width('100%')

      Text(`远端 ${record.peerId.length > 0 ? record.peerId : '未知'} · ${record.fileType} · ${record.itemCount} 项`)
        .width('100%')
        .fontSize(12)
        .fontColor(this.secondaryTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`${this.formatFileSize(record.totalBytes)} · ${this.formatDuration(record.durationMs)} · 平均 ${this.formatSpeed(record.averageSpeed)}`)
        .width('100%')
        .fontSize(12)
        .fontColor(this.secondaryTextColor())

      Row() {
        Text(this.formatDateTime(record.finishedAt))
          .layoutWeight(1)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
        Button('删除')
          .height(30)
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            FileTransferHistoryService.delete(record.id)
            this.reload()
          })
      }
      .width('100%')

      if (record.error.length > 0) {
        Text(record.error)
          .width('100%')
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER })
    .borderRadius(8)
  }

  filteredRecords(): FileTransferHistoryRecord[] {
    if (this.filter === 'all') return this.records
    if (this.filter === 'failed') {
      return this.records.filter((record: FileTransferHistoryRecord) => record.status === 'failed')
    }
    return this.records.filter((record: FileTransferHistoryRecord) => record.direction === this.filter)
  }

  reload(): void {
    this.records = FileTransferHistoryService.load()
  }

  confirmClear(): void {
    AlertDialog.show({
      title: '清空文件传输历史',
      message: '只会删除本机记录，不会删除已经传输的文件。',
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '清空',
        fontColor: RustDeskTheme.ERROR,
        action: () => {
          FileTransferHistoryService.clear()
          this.reload()
        },
      },
    })
  }

  statusText(status: string): string {
    if (status === 'completed') return '已完成'
    if (status === 'cancelled') return '已取消'
    return '失败'
  }

  statusColor(status: string): ResourceColor {
    if (status === 'completed') return RustDeskTheme.SUCCESS
    if (status === 'cancelled') return RustDeskTheme.WARNING
    return RustDeskTheme.ERROR
  }

  formatFileSize(bytes: number): string {
    if (bytes <= 0) return '大小未知'
    if (bytes < 1024) return `${Math.floor(bytes)} B`
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`
  }

  formatSpeed(bytesPerSecond: number): string {
    return bytesPerSecond > 0 ? `${this.formatFileSize(bytesPerSecond)}/s` : '速度未知'
  }

  formatDuration(durationMs: number): string {
    if (durationMs < 1000) return '不足 1 秒'
    let seconds: number = Math.floor(durationMs / 1000)
    if (seconds < 60) return `${seconds} 秒`
    let minutes: number = Math.floor(seconds / 60)
    let remainSeconds: number = seconds % 60
    return `${minutes} 分 ${remainSeconds} 秒`
  }

  formatDateTime(timestamp: number): string {
    let date: Date = new Date(timestamp)
    let pad = (value: number): string => value.toString().padStart(2, '0')
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
  }

  primaryTextColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY
  }

  secondaryTextColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY
  }
}
