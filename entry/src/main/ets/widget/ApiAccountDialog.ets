import { ApiBook, ApiPeer, ApiFailure, ApiLoginOption, RustDeskApiService, AccountSession } from '../service/RustDeskApiService';
import { common } from '@kit.AbilityKit';
import { ApiAddressBookImport } from '../service/ApiAddressBookImport';
import { RustDeskNapi } from '../service/RustDeskNapi';
import { ApiAccountAction } from './ApiAccountAction';
import { ApiBookSync, BookSyncPlan, BookSyncChange } from '../service/ApiBookSync';

@CustomDialog
export struct ApiAccountDialog {
  controller: CustomDialogController;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true;
  @State server: string = '';
  @State provider: string = 'official';
  @State username: string = '';
  @State password: string = '';
  @State code: string = '';
  @State allowHttp: boolean = false;
  @State remember: boolean = false;
  @State authorizeConnections: boolean = false;
  @State busy: boolean = false;
  @State loggedIn: boolean = false;
  @State challenge: string = '';
  @State message: string = '';
  @State books: ApiBook[] = [];
  @State peers: ApiPeer[] = [];
  @State selected: string[] = [];
  @State bookIndex: number = -1;
  @State loginOptions: ApiLoginOption[] = [];
  @State webWaiting: boolean = false;
  @State syncPlan: BookSyncPlan | undefined = undefined;
  @State preferLocal: boolean = false;
  @State editingId: string = '';
  @State editingName: string = '';
  @State editingTags: string = '';
  private webTimer: number = -1;
  private webAttempt: number = 0;
  private api: RustDeskApiService = AccountSession.getApi();
  private alive: boolean = true;

  aboutToAppear(): void {
    this.alive = true;
    this.server = RustDeskApiService.defaultServer();
    this.provider = RustDeskNapi.getOption('api-account-provider') === 'thirdParty' ? 'thirdParty' : 'official';
    this.initialize();
  }
  aboutToDisappear(): void {
    this.alive = false;
    this.stopWebLogin();
    this.password = ''; this.code = '';
    this.api.cancel();
  }

  stopWebLogin(): void {
    this.webAttempt++;
    if (this.webTimer >= 0) clearTimeout(this.webTimer);
    this.webTimer = -1; this.webWaiting = false;
    this.api.cancel();
  }

  async loadLoginOptions(): Promise<void> {
    this.busy = true; this.message = ''; this.loginOptions = [];
    try {
      this.api.configure(this.server, this.provider, this.allowHttp);
      const options = await this.api.loginOptions();
      if (this.alive) {
        this.loginOptions = options;
        if (!options.length) this.message = '服务器没有提供网页登录方式，可使用账号密码登录';
      }
    } catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }

  async webLogin(op: string): Promise<void> {
    this.busy = true; this.webWaiting = true; this.message = '正在打开安全登录网页…';
    const attempt: number = ++this.webAttempt;
    let browserPhase: boolean = false;
    try {
      const address = await this.api.startWebLogin(op, this.remember, this.authorizeConnections);
      if (!this.alive || attempt !== this.webAttempt) return;
      const context = getContext(this) as common.UIAbilityContext;
      browserPhase = true;
      RustDeskNapi.appendDiagnosticLog('api-account', `web_browser_open_start attempt=${attempt}`);
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: address });
      RustDeskNapi.appendDiagnosticLog('api-account', `web_browser_open_complete attempt=${attempt}`);
      if (!this.alive || attempt !== this.webAttempt) return;
      this.message = '请在浏览器完成登录后返回，正在等待确认（最多 3 分钟）';
      this.pollWebLogin(attempt);
    } catch (error) {
      RustDeskNapi.appendDiagnosticLog('api-account', `web_launch_failed attempt=${attempt} phase=${browserPhase ? 'browser' : 'authorization'} raw_redacted=true`);
      if (this.alive && attempt === this.webAttempt) {
        this.stopWebLogin(); this.busy = false;
        this.showError(error as Error);
      }
    }
  }

  async pollWebLogin(attempt: number): Promise<void> {
    if (!this.alive || attempt !== this.webAttempt) return;
    try {
      const done = await this.api.pollWebLogin();
      if (!this.alive || attempt !== this.webAttempt) return;
      if (done) {
        this.loggedIn = true; this.username = this.api.username;
        this.webWaiting = false; this.busy = false;
        this.message = this.api.warning || '登录成功';
        await this.refreshBooks();
        return;
      }
      this.challenge = this.api.challenge;
      if (this.challenge) { this.webWaiting = false; this.busy = false; return; }
    } catch (error) {
      if (!this.alive || attempt !== this.webAttempt) return;
      this.stopWebLogin(); this.busy = false; this.showError(error as Error);
      return;
    }
    this.webTimer = setTimeout(() => { this.pollWebLogin(attempt); }, 1000);
  }
  async initialize(): Promise<void> {
    this.busy = true;
    try {
      this.loggedIn = this.api.isLoggedIn() || await this.api.restore();
      if (!this.alive) return;
      if (this.loggedIn) {
        this.server = this.api.server; this.provider = this.api.provider;
        this.username = this.api.username; this.allowHttp = this.api.allowHttp;
        this.message = this.api.warning;
        this.books = await this.api.books();
      }
    } catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  showError(error: Error): void {
    if (!this.alive) return;
    this.message = error instanceof ApiFailure ? error.message : '操作失败，请稍后重试';
    this.loggedIn = this.api.isLoggedIn();
    if (!this.loggedIn) { this.books = []; this.peers = []; this.selected = []; }
  }
  async login(): Promise<void> {
    this.busy = true; this.message = '';
    try {
      if (!this.challenge) {
        this.api.configure(this.server, this.provider, this.allowHttp);
        this.loggedIn = await this.api.login(this.username, this.password, this.remember, this.authorizeConnections);
      } else { this.loggedIn = await this.api.verify(this.code); }
      if (!this.alive) return;
      this.challenge = this.api.challenge;
      this.message = this.api.warning;
      if (this.loggedIn) { this.username = this.api.username; this.books = await this.api.books(); }
    } catch (error) { this.showError(error as Error); this.challenge = this.api.challenge; }
    finally { this.password = ''; this.code = ''; if (this.alive) this.busy = false; }
  }
  async logout(): Promise<void> {
    this.busy = true;
    await this.api.logout();
    if (!this.alive) return;
    this.loggedIn = false; this.challenge = ''; this.peers = []; this.books = []; this.selected = [];
    this.message = this.api.warning || '已退出账号，本地已保存连接不受影响';
    this.busy = false;
  }
  async refreshBooks(): Promise<void> {
    this.syncPlan = undefined; this.editingId = '';
    this.busy = true; this.peers = []; this.selected = []; this.bookIndex = -1;
    try { this.books = await this.api.books(); }
    catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  async loadBook(index: number): Promise<void> {
    this.syncPlan = undefined; this.editingId = '';
    this.busy = true; this.message = ''; this.peers = []; this.selected = []; this.bookIndex = index;
    try {
      const peers = await this.api.peers(this.books[index]);
      if (this.alive) { this.peers = peers; this.message = `已获取 ${peers.length} 台设备，请勾选后导入`; }
    } catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  toggle(id: string): void {
    this.selected = this.selected.includes(id) ? this.selected.filter((item: string) => item !== id) : this.selected.concat([id]);
  }
  importPeers(): void {
    try {
      const count = ApiAddressBookImport.importSelected(this.books[this.bookIndex],
        this.peers.filter((peer: ApiPeer) => this.selected.includes(peer.id)));
      this.message = `已新增 ${count} 台设备；已有设备已跳过，未覆盖密码或修改服务器地址`;
      this.selected = [];
    } catch (error) { this.showError(error as Error); }
  }
  async previewSync(): Promise<void> {
    if (this.bookIndex < 0 || this.busy) return;
    this.busy = true; this.syncPlan = undefined;
    try {
      const plan = await ApiBookSync.preview(this.api, this.books[this.bookIndex]);
      if (this.alive) { this.syncPlan = plan; this.message = plan.changes.length ? '请核对以下双向同步变更，再点击确认执行' : '本地和服务器一致，无需变更'; }
    } catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  async applySync(): Promise<void> {
    if (!this.syncPlan || this.busy) return;
    this.busy = true;
    try {
      await ApiBookSync.apply(this.api, this.books[this.bookIndex], this.syncPlan, this.preferLocal);
      if (!this.alive) return;
      const peers = await this.api.peers(this.books[this.bookIndex]);
      if (this.alive) { this.syncPlan = undefined; this.peers = peers; this.message = '双向同步完成，未同步密码'; }
    } catch (error) { this.syncPlan = undefined; this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  syncLabel(kind: string): string {
    if (kind === 'upload') return '上传至服务器';
    if (kind === 'download') return '更新至本地';
    if (kind === 'deleteRemote') return '删除服务器记录';
    if (kind === 'deleteLocal') return '删除本地记录';
    return '两端冲突';
  }
  async savePeer(): Promise<void> {
    const old = this.peers.find((p: ApiPeer) => p.id === this.editingId);
    if (!old || this.busy) return;
    this.busy = true; this.syncPlan = undefined;
    try {
      await this.api.writePeer(this.books[this.bookIndex], { id: old.id, name: this.editingName.trim() || old.id,
        platform: old.platform, tags: this.editingTags.split(/[,，]/).map((s: string) => s.trim()).filter((s: string) => !!s) }, false);
      if (!this.alive) return;
      const peers = await this.api.peers(this.books[this.bookIndex]);
      if (this.alive) { this.editingId = ''; this.peers = peers; this.message = '服务器设备信息已保存'; }
    } catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  confirmDeletePeer(peer: ApiPeer): void {
    AlertDialog.show({ title: '删除地址簿设备', message: `从服务器地址簿删除“${peer.name}”？不会删除远端设备或其文件。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => { this.deletePeer(peer); } } });
  }
  async deletePeer(peer: ApiPeer): Promise<void> {
    if (this.busy) return;
    this.busy = true; this.syncPlan = undefined;
    try {
      await this.api.deletePeer(this.books[this.bookIndex], peer.id);
      if (!this.alive) return;
      const peers = await this.api.peers(this.books[this.bookIndex]);
      if (this.alive) { this.peers = peers; this.message = '已从服务器地址簿删除'; }
    } catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  textColor(): ResourceColor { return this.isDarkMode ? '#EFF4FB' : '#17253D'; }
  secondaryColor(): ResourceColor { return this.isDarkMode ? '#B6C4D7' : '#60728B'; }
  bookOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    this.books.forEach((book: ApiBook) => { options.push({ value: book.name }); });
    return options;
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('服务器账号与地址簿').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.textColor()).layoutWeight(1);
        ApiAccountAction({ label: this.busy ? '取消请求' : '关闭', onAction: () => {
          if (this.webWaiting) {
            this.stopWebLogin(); this.busy = false; this.message = '已取消网页登录';
          } else if (this.busy) {
            // Leave controls disabled until the cancelled HTTP call settles.
            this.api.cancel();
          } else {
            this.stopWebLogin(); this.controller.close();
          }
        } });
      }.width('100%');
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 8 }) {
            ApiAccountAction({ label: '官方 / Server Pro', selected: this.provider === 'official',
              isEnabled: !this.busy && !this.loggedIn && !this.challenge,
              onAction: () => { this.provider = 'official'; this.loginOptions = []; } });
            ApiAccountAction({ label: '第三方 rustdesk-api', selected: this.provider === 'thirdParty',
              isEnabled: !this.busy && !this.loggedIn && !this.challenge,
              onAction: () => { this.provider = 'thirdParty'; this.loginOptions = []; } });
          }.width('100%');
          TextInput({ text: this.server, placeholder: 'API 地址，例如 https://api.example.com' }).fontSize(14)
            .enabled(!this.loggedIn && !this.busy && !this.challenge).onChange((value: string) => { this.server = value; this.loginOptions = []; });
          if (!this.loggedIn && !this.challenge) {
            Row() {
              Checkbox({ name: 'allowHttp' }).select(this.allowHttp).enabled(!this.busy)
                .onChange((value: boolean) => { this.allowHttp = value; this.loginOptions = []; });
              Text('允许 HTTP（账号密码和令牌可能被窃听）').fontSize(12).fontColor(this.secondaryColor()).layoutWeight(1);
            }.width('100%');
            TextInput({ text: this.username, placeholder: '服务器账号，不是远端设备 ID' }).enabled(!this.busy)
              .onChange((value: string) => { this.username = value; }).maxLength(128);
            TextInput({ text: this.password, placeholder: '账号密码' }).type(InputType.Password).enabled(!this.busy)
              .onChange((value: string) => { this.password = value; }).maxLength(256);
            Row() {
              Checkbox({ name: 'rememberApi' }).select(this.remember).enabled(!this.busy)
                .onChange((value: boolean) => { this.remember = value; });
              Text('记住登录（仅令牌保存在本机安全存储）').fontSize(12).fontColor(this.secondaryColor()).layoutWeight(1);
            }.width('100%');
            Row() {
              Checkbox({ name: 'authorizeConnections' }).select(this.authorizeConnections).enabled(!this.busy)
                .onChange((value: boolean) => { this.authorizeConnections = value; });
              Text('用于当前自建 ID 服务器的连接权限认证（需公钥）')
                .fontSize(12).fontColor(this.secondaryColor()).layoutWeight(1);
            }.width('100%');
            ApiAccountAction({ label: '登录', selected: true, isEnabled: !this.busy, onAction: () => { this.login(); } });
            Text('官方公共网络登录后自动用于官方连接；自建网络需勾选上方连接认证。账号密码不是远端设备密码。')
              .fontSize(12).fontColor(this.secondaryColor());
            ApiAccountAction({ label: '获取网页登录方式', isEnabled: !this.busy, onAction: () => { this.loadLoginOptions(); } });
            ForEach(this.loginOptions, (option: ApiLoginOption) => {
              ApiAccountAction({ label: `通过 ${option.name} 登录`, isEnabled: !this.busy, onAction: () => { this.webLogin(option.name); } });
            }, (option: ApiLoginOption) => option.name);
          } else if (!this.loggedIn) {
            Text(this.challenge === 'email' ? '请输入邮箱验证码' : '请输入身份验证器验证码')
              .fontSize(14).fontColor(this.textColor());
            TextInput({ text: this.code, placeholder: '6 位验证码' }).maxLength(6).type(InputType.Number)
              .enabled(!this.busy).onChange((value: string) => { this.code = value; });
            Row({ space: 8 }) {
              ApiAccountAction({ label: '验证', selected: true, isEnabled: !this.busy, onAction: () => { this.login(); } });
              ApiAccountAction({ label: '重新登录', isEnabled: !this.busy, onAction: () => { this.api.cancel(); this.challenge = ''; this.code = ''; } });
            }
          } else {
            Row({ space: 8 }) {
              Text(`已登录：${this.username}`).fontSize(14).fontColor(this.textColor()).layoutWeight(1);
              ApiAccountAction({ label: '刷新', isEnabled: !this.busy, onAction: () => { this.refreshBooks(); } });
              ApiAccountAction({ label: '退出', isEnabled: !this.busy, onAction: () => { this.logout(); } });
            }.width('100%');
            Select(this.bookOptions())
              .value(this.bookIndex >= 0 ? this.books[this.bookIndex]?.name : '选择个人或共享地址簿')
              .enabled(!this.busy).width('100%').onSelect((index: number) => { this.syncPlan = undefined; this.editingId = ''; this.loadBook(index); });
            if (this.bookIndex >= 0) {
              ApiAccountAction({ label: '预览双向同步', isEnabled: !this.busy, onAction: () => { this.previewSync(); } });
              Text('手动同步本地全部 ID 连接与当前地址簿，请确认它们属于同一服务器。IP 直连、密码及服务器密钥不参与同步。删除及冲突会先列出，不会自动执行。')
                .fontSize(12).fontColor(this.secondaryColor());
            }
            if (this.syncPlan) {
              ForEach(this.syncPlan.changes, (change: BookSyncChange) => {
                Text(`${this.syncLabel(change.kind)}：${change.name} (${change.id})`).fontSize(13).fontColor(this.textColor()).width('100%');
              }, (change: BookSyncChange) => change.id);
              Row() {
                Checkbox().select(this.preferLocal).enabled(!this.busy).onChange((v: boolean) => { this.preferLocal = v; });
                Text('冲突时使用本地版本（不选则使用服务器版本）').fontSize(12).fontColor(this.textColor()).layoutWeight(1);
              }
              ApiAccountAction({ label: '确认执行上述变更（含删除）', isEnabled: !this.busy && this.syncPlan.changes.length > 0,
                onAction: () => { this.applySync(); } });
              ApiAccountAction({ label: '取消同步', isEnabled: !this.busy, onAction: () => { this.syncPlan = undefined; } });
            }
            if (this.editingId) {
              TextInput({ text: this.editingName, placeholder: '设备名称' }).maxLength(100).onChange((v: string) => { this.editingName = v; });
              TextInput({ text: this.editingTags, placeholder: '标签，用逗号分隔' }).maxLength(400).onChange((v: string) => { this.editingTags = v; });
              Row({ space: 8 }) {
                ApiAccountAction({ label: '保存到服务器', isEnabled: !this.busy, onAction: () => { this.savePeer(); } });
                ApiAccountAction({ label: '取消修改', isEnabled: !this.busy, onAction: () => { this.editingId = ''; } });
              }
            }
            if (this.peers.length > 0) {
              Row({ space: 8 }) {
                ApiAccountAction({ label: this.selected.length === this.peers.length ? '取消全选' : '全选', isEnabled: !this.busy, onAction: () => {
                  this.selected = this.selected.length === this.peers.length ? [] : this.peers.map((peer: ApiPeer) => peer.id);
                } });
                ApiAccountAction({ label: `导入已选 (${this.selected.length})`, selected: true,
                  isEnabled: !this.busy && this.selected.length > 0, onAction: () => { this.importPeers(); } });
              }.width('100%');
              ForEach(this.peers, (peer: ApiPeer) => {
                Row({ space: 8 }) {
                  // The framework also fires onChange for state-driven select()
                  // changes. Only toggle on a real user click (callback value
                  // disagrees with the selection set); otherwise "select all"
                  // would oscillate forever against toggle()'s unconditional flip.
                  Checkbox({ name: peer.id }).select(this.selected.includes(peer.id)).onChange((value: boolean) => {
                    if (value !== this.selected.includes(peer.id)) this.toggle(peer.id);
                  });
                  Column({ space: 3 }) {
                    Text(peer.name).fontSize(15).fontColor(this.textColor()).width('100%');
                    Text(`${peer.id} · ${peer.platform || '设备'}${peer.tags.length > 0 ? ' · ' + peer.tags.join(' / ') : ''}`)
                      .fontSize(12).fontColor(this.secondaryColor()).width('100%');
                  }.layoutWeight(1);
                  if (this.books[this.bookIndex]?.writable) {
                    Button('⋯').height(36).width(40).enabled(!this.busy).bindMenu([
                      { value: '修改名称 / 标签', action: () => { this.editingId = peer.id; this.editingName = peer.name; this.editingTags = peer.tags.join(', '); } },
                      { value: '删除服务器记录', action: () => { this.confirmDeletePeer(peer); } }
                    ]);
                  }
                }.width('100%').padding({ top: 8, bottom: 8 });
              }, (peer: ApiPeer) => peer.id);
            }
          }
          if (this.busy) { Text('正在请求服务器…').fontSize(13).fontColor(this.secondaryColor()); }
          if (this.message) { Text(this.message).fontSize(13).fontColor(this.textColor()).width('100%'); }
          Text('API 用于账号和地址簿，不替代 ID/中继服务器。导入后沿用当前中继配置，请确保属于同一网络。不会自动上传本地连接；不导入远端密码或密码哈希。')
            .fontSize(12).fontColor(this.secondaryColor()).width('100%');
        }.width('100%');
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto);
    }.padding(20).width('94%').constraintSize({ maxWidth: 600 }).height('86%')
      .borderRadius(20).backgroundColor(this.isDarkMode ? '#1E2A3A' : '#FFFFFF');
  }
}
