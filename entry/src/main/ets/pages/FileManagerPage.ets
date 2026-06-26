import { router } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { translate } from '../utils/I18n';
import { FileTransferProgressInfo, PeerInfo, RustDeskNapi } from '../service/RustDeskNapi';

interface FileItem {
  name: string
  isDir: boolean
  size: number
  path: string
}

@Entry
@Component
struct FileManagerPage {
  @State isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') ?? false
  @State localFiles: FileItem[] = []
  @State remoteFiles: FileItem[] = []
  @State localPath: string = '/data/storage/el2/base/haps/entry/files'
  @State remotePath: string = '/'
  @State selectedLocalFile: string = ''
  @State selectedRemoteFile: string = ''
  @State isTransferring: boolean = false
  @State transferProgress: number = 0
  @State transferFileName: string = ''
  @State transferStatus: string = ''
  @State activeTab: number = 0
  private progressTimer: number = -1

  aboutToAppear(): void {
    this.loadLocalFiles()
  }

  aboutToDisappear(): void {
    if (this.progressTimer !== -1) {
      clearTimeout(this.progressTimer)
    }
  }

  loadLocalFiles(): void {
    let files: FileItem[] = []
    try {
      let names: string[] = fileIo.listFileSync(this.localPath)
      names.forEach((name: string) => {
        let fullPath: string = this.localPath + '/' + name
        let stat: fileIo.Stat = fileIo.statSync(fullPath)
        files.push({
          name: name,
          isDir: stat.isDirectory(),
          size: stat.size,
          path: fullPath
        })
      })
    } catch (_e) {
      // Directory may not exist
    }
    this.localFiles = files
  }

  loadRemoteFiles(): void {
    let files: FileItem[] = []
    try {
      let peers: PeerInfo[] = RustDeskNapi.getPeerList()
      peers.forEach((peer: PeerInfo) => {
        files.push({
          name: peer.name,
          isDir: false,
          size: 0,
          path: peer.id
        })
      })
    } catch (_e) {
      // Not connected
    }
    this.remoteFiles = files
  }

  startProgressPolling(): void {
    let poll = () => {
      let progress: FileTransferProgressInfo = RustDeskNapi.getFileTransferProgress()
      let status: number = progress.status
      let pct: number = progress.progress
      let name: string = progress.fileName
      this.transferProgress = pct
      this.transferFileName = name
      if (status === 2) {
        this.transferStatus = '完成'
        this.isTransferring = false
        this.loadLocalFiles()
        return
      } else if (status === 3) {
        this.transferStatus = '失败'
        this.isTransferring = false
        return
      } else if (status === 1) {
        this.transferStatus = '传输中...'
      }
      this.progressTimer = setTimeout(poll, 500)
    }
    this.progressTimer = setTimeout(poll, 500)
  }

  build() {
    Column() {
      this.buildHeader()

      Tabs({ index: this.activeTab, barPosition: BarPosition.Start }) {
        TabContent() {
          this.buildFilePanel(translate('Local'), this.localFiles, true)
        }
        .tabBar(translate('Local'))

        TabContent() {
          this.buildFilePanel(translate('Remote'), this.remoteFiles, false)
        }
        .tabBar(translate('Remote'))
      }
      .barMode(BarMode.Fixed)
      .onChange((index: number) => {
        this.activeTab = index
        if (index === 1) {
          this.loadRemoteFiles()
        }
      })
      .layoutWeight(1)

      this.buildTransferBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : RustDeskTheme.BG_LIGHT)
  }

  @Builder
  buildHeader() {
    Row() {
      Button({ type: ButtonType.Circle }) {
        Text('←')
          .fontSize(18)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
      }
      .width(36)
      .height(36)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        router.back()
      })

      Text(translate('File Transfer'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
  }

  @Builder
  buildFilePanel(title: string, files: FileItem[], isLocal: boolean) {
    Column() {
      Row() {
        Text(this.localPath)
          .fontSize(12)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
          .layoutWeight(1)
      }
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })

      List({ space: 2 }) {
        ForEach(files, (item: FileItem) => {
          ListItem() {
            Row() {
              Text(item.isDir ? '📁' : '📄')
                .fontSize(16)
                .margin({ right: 8 })

              Column() {
                Text(item.name)
                  .fontSize(14)
                  .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
                  .lineHeight(18)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis})
                  .width('100%')

                if (!item.isDir) {
                  Text(this.formatFileSize(item.size))
                    .fontSize(11)
                    .fontColor(RustDeskTheme.TEXT_SECONDARY)
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (isLocal && !item.isDir) {
                Button(translate('Upload'))
                  .fontSize(12)
                  .fontColor(Color.White)
                  .backgroundColor(RustDeskTheme.ACCENT)
                  .borderRadius(6)
                  .height(28)
                  .onClick(() => {
                    this.selectedLocalFile = item.path
                    this.uploadFile(item.path)
                  })
              }

              if (!isLocal && !item.isDir) {
                Button(translate('Download'))
                  .fontSize(12)
                  .fontColor(Color.White)
                  .backgroundColor(RustDeskTheme.SUCCESS)
                  .borderRadius(6)
                  .height(28)
                  .onClick(() => {
                    this.selectedRemoteFile = item.path
                    this.downloadFile(item.path)
                  })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
            .borderRadius(8)
          }
        }, (item: FileItem) => item.path)
      }
      .layoutWeight(1)
      .padding({ left: 8, right: 8 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  buildTransferBar() {
    if (this.isTransferring) {
      Column() {
        Row() {
          Text(this.transferFileName)
            .fontSize(13)
            .fontColor(RustDeskTheme.TEXT_PRIMARY)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis})

          Text(this.transferStatus)
            .fontSize(12)
            .fontColor(RustDeskTheme.TEXT_SECONDARY)
            .margin({ left: 8 })
        }
        .width('100%')

        Row() {
          Progress({ value: this.transferProgress * 100, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(6)
            .color(RustDeskTheme.ACCENT)
            .backgroundColor(RustDeskTheme.DIVIDER)
        }
        .width('100%')
        .padding({ top: 4 })

        Text(Math.round(this.transferProgress * 100) + '%')
          .fontSize(11)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.End)
      }
      .padding(12)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
      .borderRadius(8)
      .margin({ left: 8, right: 8, bottom: 8 })
    }
  }

  uploadFile(filePath: string): void {
    this.isTransferring = true
    this.transferProgress = 0
    this.transferFileName = filePath.substring(filePath.lastIndexOf('/') + 1)
    this.transferStatus = '传输中...'
    RustDeskNapi.sendFile(filePath, '/')
    this.startProgressPolling()
  }

  downloadFile(filePath: string): void {
    this.isTransferring = true
    this.transferProgress = 0
    this.transferFileName = filePath.substring(filePath.lastIndexOf('/') + 1)
    this.transferStatus = '传输中...'
    let localPath: string = this.localPath + '/' + this.transferFileName
    RustDeskNapi.receiveFile(filePath, localPath)
    this.startProgressPolling()
  }

  formatFileSize(bytes: number): string {
    if (bytes < 1024) {
      return bytes + ' B'
    } else if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(1) + ' KB'
    } else {
      return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
    }
  }
}
