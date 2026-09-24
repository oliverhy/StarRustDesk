import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { url, util } from '@kit.ArkTS';
import { RustDeskNapi } from './RustDeskNapi';
import { ApiAccountStore, ApiSession } from './ApiAccountStore';

export interface ApiPeer {
  id: string;
  name: string;
  platform: string;
  tags: string[];
}
export interface ApiBook {
  guid: string;
  name: string;
  legacy: boolean;
  writable?: boolean;
}
interface ApiUser { name?: string; display_name?: string; }
interface ApiRow {
  id?: string; alias?: string; hostname?: string; platform?: string; tags?: string[];
  guid?: string; name?: string; owner?: string; rule?: number;
}
interface ApiReply {
  code?: string; url?: string; loginOptions?: string[];
  error?: string; access_token?: string; type?: string; tfa_type?: string; secret?: string;
  user?: ApiUser; name?: string; guid?: string; total?: number;
  data?: string | ApiRow[]; peers?: ApiRow[];
}
interface LoginDevice { name: string; os: string; type: string; }
interface LoginBody {
  username?: string; password?: string; id: string; uuid: string; autoLogin: boolean;
  type: string; deviceInfo: LoginDevice; secret?: string; verificationCode?: string; tfaCode?: string;
}
interface ClientIdentity { id: string; uuid: string; }
interface AccountTransport { token: string; rendezvous: string; key: string; }
export interface ApiLoginOption { name: string; }
interface OidcRequest { op: string; id: string; uuid: string; deviceInfo: LoginDevice; apiDomain: string; }

export class ApiFailure extends Error {
  status: number;
  constructor(message: string, status: number = 0) { super(message); this.status = status; }
}

export class AccountSession {
  private static instance: RustDeskApiService | undefined = undefined;
  static getApi(): RustDeskApiService {
    if (!AccountSession.instance) AccountSession.instance = new RustDeskApiService();
    return AccountSession.instance;
  }
}

export class RustDeskApiService {
  static readonly PUBLIC_API: string = 'https://admin.rustdesk.com';
  private static readonly PUBLIC_BINDING: string = '@public';
  server: string = '';
  provider: string = 'official';
  username: string = '';
  allowHttp: boolean = false;
  challenge: string = '';
  warning: string = '';
  private token: string = '';
  private secret: string = '';
  private remember: boolean = false;
  private epoch: number = 0;
  private requests: rcp.Session[] = [];
  private boundRendezvous: string = '';
  private boundKey: string = '';
  private restorePromise: Promise<boolean> | undefined = undefined;
  private restoring: boolean = false;
  private oidcCode: string = '';
  private oidcDeadline: number = 0;
  private oidcOptions: string[] = [];
  private oidcIdentity: ClientIdentity | undefined = undefined;
  private oidcPolls: number = 0;
  private static diagnosticSequence: number = 0;

  // Only fixed event names, booleans and counters may enter this method.
  // Never pass a URL, request/response body, account name or exception message.
  private trace(event: string): void {
    try {
      if (RustDeskNapi.getOption('diagnostic-log-enabled') === '1') {
        RustDeskNapi.appendDiagnosticLog('api-account', `epoch=${this.epoch} ${event}`);
      }
    } catch (_e) { /* Diagnostics must not change authentication behavior. */ }
  }

  private operation(path: string): string {
    const route = path.split('?')[0];
    if (route.startsWith('/api/ab/peer/add/')) return 'peer_add';
    if (route.startsWith('/api/ab/peer/update/')) return 'peer_update';
    if (route.startsWith('/api/ab/peer/')) return 'peer_delete';
    switch (route) {
      case '/api/login': return 'login';
      case '/api/currentUser': return 'current_user';
      case '/api/login-options': return 'login_options';
      case '/api/oidc/auth': return 'web_start';
      case '/api/oidc/auth-query': return 'web_poll';
      case '/api/logout': return 'logout';
      case '/api/ab': return 'book_legacy';
      case '/api/ab/personal': return 'book_personal';
      case '/api/ab/shared/profiles': return 'book_shared';
      case '/api/ab/peers': return 'book_peers';
      default: return 'other';
    }
  }

  static defaultServer(): string {
    const configured = RustDeskNapi.getOption('api-server').trim();
    if (configured) return configured;
    const custom = RustDeskNapi.getOption('custom-rendezvous-server').trim();
    if (!custom) return RustDeskApiService.PUBLIC_API;
    // Match upstream ID port minus two; IPv6 literals must stay bracketed.
    try {
      const value = new url.URL(custom.includes('://') ? custom : `http://${custom}`);
      const port = value.port ? Number(value.port) - 2 : 21114;
      if (port < 1 || port > 65535) return '';
      return `http://${value.hostname}:${port}`;
    } catch (_e) { return ''; }
  }

  private isPublicAccount(): boolean {
    return this.provider === 'official' && this.server === RustDeskApiService.PUBLIC_API &&
      RustDeskNapi.getOption('custom-rendezvous-server').trim() === '' &&
      RustDeskNapi.getOption('key').trim() === '';
  }

  private bindTransport(authorizeConnections: boolean): void {
    this.boundRendezvous = ''; this.boundKey = '';
    if (this.isPublicAccount()) {
      this.boundRendezvous = RustDeskApiService.PUBLIC_BINDING;
    } else if (authorizeConnections) {
      this.boundRendezvous = RustDeskNapi.getOption('custom-rendezvous-server').trim();
      this.boundKey = RustDeskNapi.getOption('key').trim();
      if (!this.boundRendezvous || !this.boundKey) {
        this.trace('binding_rejected reason=missing_server_or_key');
        throw new ApiFailure('请先在服务器配置中填写自建 ID 服务器及公钥，再启用账号连接认证');
      }
    }
    this.trace(`binding_selected mode=${this.boundRendezvous === RustDeskApiService.PUBLIC_BINDING ? 'public' : this.boundRendezvous ? 'custom' : 'address_book_only'}`);
  }

  private bindingMatchesCurrentNetwork(): boolean {
    if (!this.currentApiMatches()) return false;
    if (this.boundRendezvous === RustDeskApiService.PUBLIC_BINDING) return this.isPublicAccount();
    return this.boundRendezvous.length > 0 &&
      RustDeskNapi.getOption('custom-rendezvous-server').trim() === this.boundRendezvous &&
      RustDeskNapi.getOption('key').trim() === this.boundKey;
  }

  private currentApiMatches(): boolean {
    try { return RustDeskApiService.normalizeServer(RustDeskApiService.defaultServer(), this.allowHttp) === this.server; }
    catch (_e) { return false; }
  }

  async prepareConnection(): Promise<void> {
    // An anonymous custom ID server does not need API session restoration.
    // A remembered session must still be checked even if the API field was cleared.
    if (RustDeskNapi.getOption('custom-rendezvous-server').trim().length > 0 &&
      RustDeskNapi.getOption('api-server').trim().length === 0 &&
      RustDeskNapi.getOption('api-session-disabled') !== '0' &&
      !this.token && !this.restorePromise && !this.restoring) {
      this.trace('prepare_skipped reason=custom_server_without_api_account');
      return;
    }
    const started = Date.now();
    this.trace(`prepare_start restore_pending=${this.restorePromise !== undefined} token_present=${this.token.length > 0}`);
    try {
      if (this.restorePromise) await this.restorePromise;
      else if (!this.isLoggedIn()) await this.restore();
      if (this.token) this.publishTransport();
      this.trace(`prepare_complete elapsed_ms=${Date.now() - started} token_present=${this.token.length > 0} binding_match=${this.bindingMatchesCurrentNetwork()}`);
    } catch (_e) {
      // A separate address-book-only account must not make anonymous remote
      // control depend on that API server's availability.
      if (!this.bindingMatchesCurrentNetwork()) {
        this.trace(`prepare_bypass reason=unrelated_account elapsed_ms=${Date.now() - started}`);
        return;
      }
      this.trace(`prepare_failed reason=bound_account_unavailable elapsed_ms=${Date.now() - started}`);
      throw new ApiFailure('账号登录恢复未完成，请检查网络后重试，或到设置中的 API 账号重新登录');
    }
  }

  static normalizeServer(value: string, allowHttp: boolean): string {
    if (value.length > 2048) throw new ApiFailure('API 地址过长');
    let parsed: url.URL;
    try { parsed = new url.URL(value.trim()); } catch (_e) { throw new ApiFailure('请输入完整 API 地址，例如 https://api.example.com'); }
    if (parsed.protocol !== 'https:' && !(allowHttp && parsed.protocol === 'http:')) {
      throw new ApiFailure('默认只允许 HTTPS；确需 HTTP 时请明确勾选风险确认');
    }
    if (!parsed.hostname || parsed.username || parsed.password || parsed.search || parsed.hash) {
      throw new ApiFailure('API 地址不能包含账号、密码、查询参数或片段');
    }
    return parsed.toString().replace(/\/+$/, '').replace(/\/api$/, '');
  }

  isLoggedIn(): boolean { return this.token.length > 0 && !this.restoring; }

  configure(server: string, provider: string, allowHttp: boolean): void {
    const normalized = RustDeskApiService.normalizeServer(server, allowHttp);
    if (provider !== 'official' && provider !== 'thirdParty') throw new ApiFailure('不支持的 API 类型');
    this.cancel();
    RustDeskNapi.setApiAccountContext('');
    this.boundRendezvous = ''; this.boundKey = '';
    this.server = normalized;
    this.oidcOptions = [];
    this.provider = provider;
    this.allowHttp = allowHttp;
    this.token = ''; this.username = ''; this.challenge = ''; this.secret = ''; this.warning = '';
    this.trace(`configured provider=${provider === 'official' ? 'official' : 'third_party'} endpoint=${normalized === RustDeskApiService.PUBLIC_API ? 'public' : 'custom'} https=${normalized.startsWith('https:')}`);
  }

  cancel(): void {
    if (this.requests.length > 0 || this.oidcCode || this.secret) {
      this.trace(`cancel_requested requests=${this.requests.length} web_pending=${this.oidcCode.length > 0} challenge_pending=${this.secret.length > 0}`);
    }
    this.epoch++;
    this.requests.forEach((session: rcp.Session) => { session.cancel(); });
    this.secret = ''; this.challenge = '';
    this.oidcCode = ''; this.oidcDeadline = 0; this.oidcIdentity = undefined;
  }

  async restore(): Promise<boolean> {
    if (this.isLoggedIn()) { this.trace('restore_skip reason=already_logged_in'); return true; }
    if (this.restorePromise) { this.trace('restore_join reason=in_flight'); return this.restorePromise; }
    const started = Date.now();
    this.trace('restore_start');
    this.restoring = true;
    this.restorePromise = this.restoreStored();
    try {
      const restored = await this.restorePromise;
      this.trace(`restore_complete restored=${restored} elapsed_ms=${Date.now() - started}`);
      return restored;
    } catch (_e) {
      this.trace(`restore_failed elapsed_ms=${Date.now() - started} raw_redacted=true`);
      throw _e as Error;
    }
    finally { this.restorePromise = undefined; this.restoring = false; }
  }

  private async restoreStored(): Promise<boolean> {
    const epoch = this.epoch;
    const saved = await ApiAccountStore.load();
    if (epoch !== this.epoch) { this.trace('restore_skip reason=cancelled'); throw new ApiFailure('请求已取消'); }
    if (!saved) { this.trace('restore_skip reason=no_saved_session'); return false; }
    // A backup or manual server change must not silently restore the old account.
    const configuredServer = RustDeskApiService.defaultServer();
    if (!configuredServer || RustDeskApiService.normalizeServer(configuredServer, saved.allowHttp === true) !== saved.server) {
      this.trace('restore_skip reason=api_changed'); return false;
    }
    this.configure(saved.server, saved.provider, saved.allowHttp === true);
    const restoreEpoch = this.epoch;
    this.token = saved.token; this.username = saved.username; this.remember = true;
    this.boundRendezvous = saved.boundRendezvous || ''; this.boundKey = saved.boundKey || '';
    if (!this.boundRendezvous && this.isPublicAccount()) {
      this.boundRendezvous = RustDeskApiService.PUBLIC_BINDING;
      this.trace('restore_binding_migrated mode=public');
    }
    try {
      const user = await this.request('/api/currentUser', 'POST', JSON.stringify(this.identity()));
      if (typeof user.name !== 'string' || user.name.length === 0) throw new ApiFailure('服务器返回的账号信息无效');
      this.username = user.name;
      this.publishTransport();
      return true;
    } catch (error) {
      if (this.epoch === restoreEpoch) {
        this.token = '';
        RustDeskNapi.setApiAccountContext('');
      }
      throw error as Error;
    }
  }

  private publishTransport(): void {
    RustDeskNapi.setApiAccountContext('');
    if (!this.boundRendezvous) { this.trace('transport_auth_skipped reason=address_book_only'); return; }
    if (this.boundRendezvous === RustDeskApiService.PUBLIC_BINDING) {
      if (!this.isPublicAccount() || !this.currentApiMatches()) {
        this.warning = '服务器配置已改变，官方账号认证未启用';
        this.trace('transport_auth_skipped mode=public reason=network_changed');
        return;
      }
      const context: AccountTransport = { token: this.token, rendezvous: this.boundRendezvous, key: '' };
      if (RustDeskNapi.setApiAccountContext(JSON.stringify(context)) !== 0) {
        this.trace('transport_auth_failed mode=public reason=native_rejected');
        throw new ApiFailure('官方账号认证上下文设置失败，请重新登录');
      }
      this.warning = '';
      this.trace('transport_auth_ready mode=public');
      return;
    }
    if (RustDeskNapi.getOption('custom-rendezvous-server').trim() !== this.boundRendezvous ||
      RustDeskNapi.getOption('key').trim() !== this.boundKey || !this.currentApiMatches()) {
      this.warning = '服务器配置已改变，账号连接认证未启用；请在新网络下重新登录绑定';
      this.trace('transport_auth_skipped mode=custom reason=network_changed');
      return;
    }
    const context: AccountTransport = { token: this.token, rendezvous: this.boundRendezvous, key: this.boundKey };
    if (RustDeskNapi.setApiAccountContext(JSON.stringify(context)) !== 0) {
      this.warning = '已登录地址簿，但 ID 服务器公钥无效，账号连接认证未启用';
      this.trace('transport_auth_failed mode=custom reason=native_rejected');
    } else {
      this.trace('transport_auth_ready mode=custom');
    }
  }

  private identity(): ClientIdentity {
    let uuid = RustDeskNapi.getOption('api-client-uuid');
    if (!uuid) { uuid = util.generateRandomUUID(true); RustDeskNapi.setOption('api-client-uuid', uuid); }
    let id = RustDeskNapi.getOption('client-id');
    if (!id) {
      id = `harmony-${uuid.replace(/-/g, '').slice(0, 16)}`;
      RustDeskNapi.setOption('client-id', id);
    }
    return { id: id, uuid: uuid };
  }

  async login(username: string, password: string, remember: boolean, authorizeConnections: boolean = false): Promise<boolean> {
    this.trace(`login_start method=password remember=${remember} authorize_custom=${authorizeConnections}`);
    if (!username.trim() || !password) throw new ApiFailure('请输入账号和密码');
    this.token = ''; this.secret = ''; this.challenge = '';
    RustDeskNapi.setApiAccountContext('');
    this.bindTransport(authorizeConnections);
    const epoch = this.epoch;
    await ApiAccountStore.clear();
    if (epoch !== this.epoch) throw new ApiFailure('请求已取消');
    this.remember = remember;
    this.username = username.trim();
    const identity = this.identity();
    const body: LoginBody = {
      username: this.username, password: password, id: identity.id, uuid: identity.uuid,
      autoLogin: remember, type: 'account', deviceInfo: { name: RustDeskNapi.getDeviceName(), os: 'HarmonyOS', type: 'client' }
    };
    return this.acceptLogin(await this.request('/api/login', 'POST', JSON.stringify(body), false));
  }

  async verify(code: string): Promise<boolean> {
    this.trace(`verification_start challenge=${this.challenge === 'email' ? 'email' : this.challenge === 'totp' ? 'totp' : 'none'}`);
    if (!this.secret || !/^\d{6}$/.test(code)) throw new ApiFailure('请输入 6 位验证码');
    const identity = this.identity();
    // Upstream sends email_code for both email and TOTP, with tfaCode for TOTP.
    const body: LoginBody = {
      username: this.username, id: identity.id, uuid: identity.uuid, autoLogin: this.remember,
      type: 'email_code', secret: this.secret, verificationCode: code,
      deviceInfo: { name: RustDeskNapi.getDeviceName(), os: 'HarmonyOS', type: 'client' }
    };
    if (this.challenge !== 'email') body.tfaCode = code;
    return this.acceptLogin(await this.request('/api/login', 'POST', JSON.stringify(body), false));
  }

  async loginOptions(): Promise<ApiLoginOption[]> {
    const reply = await this.request('/api/login-options', 'GET', undefined, false);
    const result: ApiLoginOption[] = [];
    for (const option of reply.loginOptions || []) {
      if (option.startsWith('oidc/')) result.push({ name: option.substring(5) });
      if (option.startsWith('common-oidc/')) {
        try {
          const values = JSON.parse(option.substring(12)) as ApiLoginOption[];
          if (Array.isArray(values)) values.forEach((value: ApiLoginOption) => {
            if (value && typeof value.name === 'string') result.push({ name: value.name });
          });
        } catch (_e) { throw new ApiFailure('网页登录选项格式不兼容'); }
      }
    }
    this.oidcOptions = result.map((value: ApiLoginOption) => value.name)
      .filter((value: string, index: number, values: string[]) => value.length > 0 && value.length <= 128 &&
        !/[\r\n]/.test(value) && values.indexOf(value) === index).slice(0, 30);
    this.trace(`web_options_ready count=${this.oidcOptions.length}`);
    return this.oidcOptions.map((name: string) => { return { name: name } as ApiLoginOption; });
  }

  async startWebLogin(op: string, remember: boolean, authorizeConnections: boolean): Promise<string> {
    this.trace(`login_start method=web remember=${remember} authorize_custom=${authorizeConnections}`);
    if (!this.oidcOptions.includes(op)) throw new ApiFailure('请先刷新服务器提供的网页登录方式');
    this.cancel(); this.token = ''; this.warning = '';
    RustDeskNapi.setApiAccountContext('');
    this.bindTransport(authorizeConnections);
    this.remember = remember;
    const epoch = this.epoch;
    await ApiAccountStore.clear();
    if (epoch !== this.epoch) throw new ApiFailure('请求已取消');
    const identity = this.identity();
    const body: OidcRequest = { op: op, id: identity.id, uuid: identity.uuid, apiDomain: this.server,
      deviceInfo: { name: RustDeskNapi.getDeviceName(), os: 'HarmonyOS', type: 'client' } };
    const reply = await this.request('/api/oidc/auth', 'POST', JSON.stringify(body), false);
    if (typeof reply.code !== 'string' || !reply.code || reply.code.length > 16384 ||
      typeof reply.url !== 'string' || reply.url.length > 8192) throw new ApiFailure('网页登录响应无效');
    let target: url.URL;
    try { target = new url.URL(reply.url); } catch (_e) { throw new ApiFailure('网页登录地址无效'); }
    if (target.protocol !== 'https:' || !target.hostname || target.username || target.password) {
      this.trace('web_start_rejected reason=unsafe_url');
      throw new ApiFailure('网页登录仅允许安全 HTTPS 地址');
    }
    this.oidcCode = reply.code; this.oidcIdentity = identity; this.oidcDeadline = Date.now() + 180000;
    this.oidcPolls = 0;
    this.trace('web_authorization_ready timeout_ms=180000');
    return target.toString();
  }

  async pollWebLogin(): Promise<boolean> {
    if (!this.oidcCode || !this.oidcIdentity) throw new ApiFailure('网页登录已取消，请重新开始');
    if (Date.now() >= this.oidcDeadline) {
      this.trace(`web_timeout polls=${this.oidcPolls}`);
      this.cancel(); throw new ApiFailure('网页登录已超时，请重试');
    }
    this.oidcPolls++;
    const path = `/api/oidc/auth-query?code=${encodeURIComponent(this.oidcCode)}` +
      `&id=${encodeURIComponent(this.oidcIdentity.id)}&uuid=${encodeURIComponent(this.oidcIdentity.uuid)}`;
    const reply = await this.request(path, 'GET', undefined, false);
    if (!reply.type) {
      if (this.oidcPolls === 1 || this.oidcPolls % 15 === 0) this.trace(`web_pending polls=${this.oidcPolls}`);
      return false;
    }
    const accepted = await this.acceptLogin(reply);
    if (accepted) { this.trace(`web_complete polls=${this.oidcPolls}`); this.oidcCode = ''; this.oidcIdentity = undefined; }
    return accepted;
  }

  private async acceptLogin(reply: ApiReply): Promise<boolean> {
    if (reply.type === 'email_check' || reply.type === 'tfa_check') {
      if (typeof reply.secret !== 'string' || !reply.secret || reply.secret.length > 16384) throw new ApiFailure('二次验证响应无效');
      this.secret = reply.secret;
      this.challenge = reply.type === 'email_check' || reply.tfa_type === 'email' ? 'email' : 'totp';
      this.trace(`login_challenge type=${this.challenge}`);
      if (reply.user && typeof reply.user.name === 'string') this.username = reply.user.name;
      return false;
    }
    if (reply.type !== 'access_token' || typeof reply.access_token !== 'string' ||
      !reply.access_token || reply.access_token.length > 16384 || /[\r\n]/.test(reply.access_token)) {
      this.trace('login_rejected reason=invalid_token_response');
      throw new ApiFailure('服务器未返回兼容的登录令牌，请检查 API 版本和登录策略，或重新选择网页登录方式');
    }
    this.token = reply.access_token; this.secret = ''; this.challenge = '';
    if (reply.user && typeof reply.user.name === 'string') this.username = reply.user.name;
    RustDeskNapi.setOption('api-server', this.server);
    RustDeskNapi.setOption('api-account-provider', this.provider);
    this.publishTransport();
    if (this.remember) {
      const saved: ApiSession = { server: this.server, provider: this.provider, token: this.token,
        username: this.username, allowHttp: this.allowHttp, boundRendezvous: this.boundRendezvous, boundKey: this.boundKey };
      try { await ApiAccountStore.save(saved); this.trace('credential_save_complete'); }
      catch (_e) { this.trace('credential_save_failed raw_redacted=true'); this.warning = '已登录，但安全存储失败；退出应用后需要重新登录'; }
    }
    this.trace(`login_complete remember=${this.remember} warning_present=${this.warning.length > 0}`);
    return true;
  }

  async logout(): Promise<void> {
    this.trace('logout_start');
    try { if (this.token) await this.request('/api/logout', 'POST', JSON.stringify(this.identity())); }
    catch (_e) { this.warning = '本机已退出；服务器注销未确认，可在服务端撤销会话'; }
    finally {
      this.cancel(); this.token = ''; this.username = ''; this.remember = false;
      RustDeskNapi.setApiAccountContext('');
      await ApiAccountStore.clear();
      this.trace('logout_complete credential_disabled=true');
    }
  }

  async books(): Promise<ApiBook[]> {
    const books: ApiBook[] = [];
    let personal: ApiReply = {};
    try { personal = await this.request('/api/ab/personal', 'POST'); }
    catch (error) { if (!(error instanceof ApiFailure) || error.status !== 404) throw error as Error; }
    if (typeof personal.guid === 'string' && personal.guid.length > 0) {
      books.push({ guid: personal.guid, name: '个人地址簿', legacy: false, writable: true });
    } else { books.push({ guid: '', name: '个人地址簿（旧版）', legacy: true, writable: true }); }
    const seen: string[] = books.map((book: ApiBook) => book.guid);
    for (let page = 1; page <= 20; page++) {
      let result: ApiReply;
      try { result = await this.request(`/api/ab/shared/profiles?current=${page}&pageSize=100`, 'POST'); }
      catch (error) { if (error instanceof ApiFailure && error.status === 404) break; throw error as Error; }
      if (result.data === undefined || result.data === null) break;
      if (!Array.isArray(result.data)) throw new ApiFailure('共享地址簿格式不兼容');
      let added = 0;
      for (const row of result.data) {
        if (row && typeof row.guid === 'string' && row.guid && !seen.includes(row.guid)) {
          seen.push(row.guid); added++;
          books.push({ guid: row.guid, name: (typeof row.name === 'string' ? row.name : '共享地址簿').slice(0, 100), legacy: false,
            writable: row.rule === 2 || row.rule === 3 });
        }
      }
      if (!added || result.data.length < 100 || (typeof result.total === 'number' && (result.total === 0 || page * 100 >= result.total))) break;
      if (page === 20) throw new ApiFailure('地址簿数量过多，请在服务端缩小范围');
    }
    return books;
  }

  static parsePeers(rows: ApiRow[]): ApiPeer[] {
    const peers: ApiPeer[] = [];
    for (const row of rows) {
      if (!row || typeof row.id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(row.id)) continue;
      if (peers.some((peer: ApiPeer) => peer.id === row.id)) continue;
      const name = typeof row.alias === 'string' && row.alias ? row.alias :
        (typeof row.hostname === 'string' ? row.hostname : row.id);
      peers.push({ id: row.id, name: name.slice(0, 100), platform: typeof row.platform === 'string' ? row.platform.slice(0, 32) : '',
        tags: Array.isArray(row.tags) ? row.tags.filter((tag: string) => typeof tag === 'string').slice(0, 20) : [] });
    }
    return peers;
  }

  sessionRevision(): number { return this.epoch; }

  async peers(book: ApiBook, strict: boolean = false): Promise<ApiPeer[]> {
    if (book.legacy) {
      const result = await this.request('/api/ab', 'GET');
      if (result.data === undefined || result.data === null || result.data === '') {
        if (strict) throw new ApiFailure('服务器未返回明确的设备列表，已取消同步');
        return [];
      }
      if (typeof result.data !== 'string') throw new ApiFailure('旧版地址簿格式不兼容');
      let data: ApiReply;
      try { data = JSON.parse(result.data) as ApiReply; } catch (_e) { throw new ApiFailure('旧版地址簿内容无效'); }
      if (!data || data.peers === undefined || data.peers === null) {
        if (strict) throw new ApiFailure('服务器未返回明确的设备列表，已取消同步');
        return [];
      }
      if (!Array.isArray(data.peers)) throw new ApiFailure('地址簿设备列表无效');
      const parsed = RustDeskApiService.parsePeers(data.peers);
      if (strict && parsed.length !== data.peers.length) throw new ApiFailure('设备列表含无效或重复记录，已取消同步');
      return parsed;
    }
    const peers: ApiPeer[] = [];
    for (let page = 1; page <= 50; page++) {
      const result = await this.request(`/api/ab/peers?current=${page}&pageSize=100&ab=${encodeURIComponent(book.guid)}`, 'POST');
      if (result.data === undefined || result.data === null) throw new ApiFailure('服务器未返回完整设备列表，已取消同步');
      if (!Array.isArray(result.data)) throw new ApiFailure('地址簿设备列表无效');
      const rows = RustDeskApiService.parsePeers(result.data);
      if (strict && rows.length !== result.data.length) throw new ApiFailure('设备列表含无效或重复记录，已取消同步');
      let added = 0;
      for (const row of rows) {
        if (!peers.some((peer: ApiPeer) => peer.id === row.id)) { peers.push(row); added++; }
      }
      // Some third-party releases ignore pagination and return 1000 entries.
      // Never spin forever or silently claim a partial list is complete.
      if (typeof result.total === 'number' && result.total > 0 && peers.length >= result.total) break;
      if (!added) {
        if (typeof result.total === 'number' && result.total > peers.length) throw new ApiFailure('服务器未正确分页，设备列表不完整，请升级 API 服务');
        break;
      }
      if (result.data.length < 100 && !(typeof result.total === 'number' && result.total > peers.length)) break;
      if (page === 50) throw new ApiFailure('设备超过分页限制，请在服务端分组后重试');
    }
    return peers;
  }

  async writePeer(book: ApiBook, peer: ApiPeer, create: boolean): Promise<void> {
    if (!book.writable) throw new ApiFailure('当前地址簿为只读，不能上传或修改');
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(peer.id)) throw new ApiFailure('设备 ID 不支持地址簿同步');
    const data: ApiRow = { id: peer.id, alias: peer.name.slice(0, 100), tags: peer.tags.slice(0, 20) };
    if (book.legacy) { await this.editLegacyPeer(data, false); return; }
    const action = create ? 'add' : 'update';
    await this.request(`/api/ab/peer/${action}/${encodeURIComponent(book.guid)}`, create ? 'POST' : 'PUT', JSON.stringify(data));
  }

  async deletePeer(book: ApiBook, id: string): Promise<void> {
    if (!book.writable) throw new ApiFailure('当前地址簿为只读，不能删除');
    if (book.legacy) { await this.editLegacyPeer({ id: id }, true); return; }
    await this.request(`/api/ab/peer/${encodeURIComponent(book.guid)}`, 'DELETE', JSON.stringify([id]));
  }

  private async editLegacyPeer(peer: ApiRow, remove: boolean): Promise<void> {
    // Keep fields from other clients (including their hashes) in the server document.
    // Do not create password/hash fields or copy credentials from local storage.
    const epoch = this.epoch;
    const reply = await this.request('/api/ab', 'GET');
    let document: ApiReply = { peers: [] };
    if (reply.data !== undefined && reply.data !== null && typeof reply.data !== 'string') {
      throw new ApiFailure('旧版地址簿格式不兼容，未覆盖');
    }
    if (typeof reply.data === 'string' && reply.data) {
      try { document = JSON.parse(reply.data) as ApiReply; }
      catch (_e) { throw new ApiFailure('旧版地址簿内容无效，已取消写入'); }
    }
    if (!Array.isArray(document.peers)) throw new ApiFailure('旧版地址簿格式不兼容，未覆盖');
    if (remove) document.peers = document.peers.filter((row: ApiRow) => row.id !== peer.id);
    else {
      const found = document.peers.find((row: ApiRow) => row.id === peer.id);
      if (found) { found.alias = peer.alias; found.tags = peer.tags; }
      else document.peers.push(peer);
    }
    if (epoch !== this.epoch) throw new ApiFailure('操作已取消');
    const latest = await this.request('/api/ab', 'GET');
    if (latest.data !== reply.data) throw new ApiFailure('旧版地址簿被其他客户端修改，请重新预览');
    await this.request('/api/ab', 'POST', JSON.stringify({ data: JSON.stringify(document) }));
  }

  private async request(path: string, method: rcp.HttpMethod, content?: string, authenticated: boolean = true): Promise<ApiReply> {
    const operation = this.operation(path);
    if (authenticated && !this.token) {
      this.trace(`request_skipped op=${operation} reason=no_token`);
      throw new ApiFailure('请先登录');
    }
    const requestId = ++RustDeskApiService.diagnosticSequence;
    const started = Date.now();
    const sampled = operation !== 'web_poll' || this.oidcPolls === 1 || this.oidcPolls % 15 === 0;
    const epoch = this.epoch;
    if (sampled) this.trace(`request_start id=${requestId} op=${operation} authenticated=${authenticated}`);
    const session = rcp.createSession();
    this.requests.push(session);
    const chunks: Uint8Array[] = [];
    let size = 0;
    let tooLarge = false;
    let status = 0;
    let phase = 'transport';
    let outcome = 'failed';
    let errorCode = 0;
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
    if (authenticated) headers['Authorization'] = `Bearer ${this.token}`;
    try {
      const response = await session.fetch(new rcp.Request(this.server + path, method, headers, content,
        undefined, undefined, {
          transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 15000 } },
          tracing: { verbose: false, httpEventsHandler: { onDataReceive: (buffer: ArrayBuffer): number => {
            size += buffer.byteLength;
            if (size > 2 * 1024 * 1024) { tooLarge = true; session.cancel(); return 0; }
            chunks.push(new Uint8Array(buffer)); return buffer.byteLength;
          } } }
        }));
      status = response.statusCode;
      phase = 'http_status';
      if (epoch !== this.epoch) throw new ApiFailure('请求已取消');
      if (tooLarge) throw new ApiFailure('服务器响应超过安全大小限制');
      if (response.statusCode >= 300 && response.statusCode < 400) throw new ApiFailure('API 地址发生跳转，请填写最终地址；为保护凭据已阻止跳转');
      if (response.statusCode === 401 || (response.statusCode === 400 && path === '/api/currentUser')) {
        RustDeskNapi.setApiAccountContext('');
        this.token = ''; this.secret = ''; this.challenge = '';
        await ApiAccountStore.clear();
        this.trace(`credential_invalidated id=${requestId} reason=unauthorized credential_disabled=true`);
        throw new ApiFailure('账号或密码不正确，或登录已过期，请重新登录', 401);
      }
      if (response.statusCode !== 200) throw new ApiFailure(`API 请求被拒绝（HTTP ${response.statusCode}），请检查地址和账号权限`, response.statusCode);
      phase = 'decode';
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      const raw = util.TextDecoder.create('utf-8').decodeToString(bytes);
      if (!raw.trim() || raw.trim() === 'null') { outcome = 'empty'; return {}; }
      phase = 'response_format';
      if (path === '/api/login-options') {
        const options = JSON.parse(raw) as string[];
        if (!Array.isArray(options) || options.some((item: string) => typeof item !== 'string')) {
          throw new ApiFailure('网页登录选项格式不兼容');
        }
        outcome = 'ok'; return { loginOptions: options };
      }
      let reply: ApiReply;
      try { reply = JSON.parse(raw) as ApiReply; } catch (_e) { throw new ApiFailure('服务器没有返回 JSON，请检查 API 地址是否指向网页'); }
      if (!reply || typeof reply !== 'object' || Array.isArray(reply)) throw new ApiFailure('API 响应格式不兼容');
      if (path.startsWith('/api/oidc/auth-query?') && typeof reply.error === 'string' &&
        reply.error.includes('No authed oidc is found')) { outcome = 'pending'; return {}; }
      phase = 'server_result';
      if (reply.error !== undefined) throw new ApiFailure('服务器拒绝操作，请检查账号密码、验证码、权限及服务端登录策略');
      outcome = 'ok';
      return reply;
    } catch (error) {
      if (error !== null && error !== undefined) {
        const code = (error as BusinessError).code;
        if (typeof code === 'number' && Number.isSafeInteger(code)) errorCode = code;
      }
      if (epoch !== this.epoch) phase = 'cancelled';
      else if (tooLarge) phase = 'response_limit';
      if (tooLarge) throw new ApiFailure('服务器响应超过安全大小限制');
      if (error instanceof ApiFailure) throw error;
      throw new ApiFailure('API 网络请求失败，请检查网络、端口和 HTTPS 证书');
    } finally {
      // Query parameters may contain one-time codes and device identities.
      // Only the allowlisted operation label and numeric metadata are exported.
      if (sampled || outcome === 'failed') {
        this.trace(`request_end id=${requestId} request_epoch=${epoch} op=${operation} outcome=${outcome} phase=${phase} http=${status} error_code=${errorCode} elapsed_ms=${Date.now() - started} bytes=${size} raw_redacted=true`);
      }
      this.requests = this.requests.filter((item: rcp.Session) => item !== session);
      session.close();
    }
  }
}
