import { ENGLISH, TRADITIONAL, DYNAMIC_KEYS } from './I18nCatalog'

// Existing English call sites remain valid; new custom UI text has a stable
// Simplified-Chinese source key. These are display keys, never protocol values.
const translations: Record<string, string> = {
  'Connection': '连接',
  'Remote ID': '远程ID',
  'Connect': '连接',
  'Server': '服务器',
  'Settings': '设置',
  'Home': '首页',
  'Disconnect': '断开连接',
  'Password': '密码',
  'Start Service': '启动服务',
  'Stop Service': '停止服务',
  'Device ID': '设备ID',
  'Device Name': '设备名称',
  'Online': '在线',
  'Offline': '离线',
  'Incoming Connection': '传入连接',
  'Outgoing Connection': '传出连接',
  'Download new version': '下载新版本',
  'Account': '账户',
  'Display': '显示',
  'Security': '安全',
  'Network': '网络',
  'Audio': '音频',
  'Language': '语言',
  'About': '关于',
  'Login': '登录',
  'Logout': '退出登录',
  'Resolution': '分辨率',
  'Frame Rate': '帧率',
  'Color Quality': '色彩质量',
  'Relay Server': '中继服务器',
  'Port': '端口',
  'Version': '版本',
  'APP Filing Number': 'APP备案号',
  'Update': '更新',
  'Cancel': '取消',
  'Confirm': '确认',
  'Save': '保存',
  'Delete': '删除',
  'Search': '搜索',
  'Recent': '最近',
  'Address Book': '通讯录',
  'Favorites': '收藏',
  'No devices': '暂无设备',
  'Connecting': '连接中...',
  'Connected': '已连接',
  'Connection failed': '连接失败',
  'File Transfer': '文件传输',
  'Chat': '聊天',
  'Keyboard': '键盘',
  'Mouse': '鼠标',
  'Touch': '触摸',
  'Zoom': '缩放',
  'Full Screen': '全屏',
  'Exit': '退出',
  'Allow': '允许',
  'Deny': '拒绝',
  'Always': '始终',
  'Never': '从不',
  'Whitelist': '白名单',
  'Approval Required': '需要审批',
  'Active Sessions': '活跃会话',
  'No active sessions': '暂无活跃会话',
  'App Name': '芝麻远控',
  'ID/Relay Server': 'ID/中继服务器',
  'Configure custom server': '配置自定义服务器',
  'ID Server': 'ID服务器',
  'API Server': 'API服务器',
  'Key': '密钥',
  'Import server config': '导入服务器配置',
  'Export Server Config': '导出服务器配置',
  'Import server configuration successfully': '导入服务器配置成功',
  'Export server configuration successfully': '导出服务器配置成功',
  'Invalid server configuration': '无效的服务器配置',
  'Clipboard is empty': '剪贴板为空',
  'Successful': '成功',
  'Failed': '失败',
  'Custom Server': '自定义服务器',
  'Using custom server': '正在使用自定义服务器',
  'Retry': '重试',
  'No active connection': '暂无活跃连接',
  'Enter a Remote ID to connect': '输入远程ID进行连接',
  'Status': '状态',
  'Dark Mode': '深色模式',
  'Connecting...': '正在连接...',
  'Local': '本地',
  'Remote': '远程',
  'Upload': '上传',
  'Download': '下载',
  'Confirm Password': '确认密码',
  'Testing connection...': '正在测试连接...',
  'Test Connection': '测试连接',
  'Please enter ID server address': '请输入ID服务器地址',
  'Server connected successfully': '服务器连接成功',
  'Keyboard Input': '键盘输入',
  'Mouse Control': '鼠标控制',
  'Send': '发送',
  'Close': '关闭',
  'Waiting for video stream...': '等待视频流...',
  'Connected to': '已连接到',
  'Remote Desktop': '远程桌面',
  'Passwords do not match': '两次输入的密码不一致',
  'Back': '返回',
  'Auto': '自动',
  'OK': '确定',
}

export function resolveLanguage(preference: string, systemLanguage: string): string {
  const locale: string = (preference === 'system' || preference.length === 0 ?
    systemLanguage : preference).replace(/_/g, '-').toLowerCase()
  if (locale.startsWith('zh')) {
    if (locale.includes('hans')) return 'zh-Hans'
    if (locale.includes('hant') || /(^|-)(tw|hk|mo)(-|$)/.test(locale)) return 'zh-Hant'
    return 'zh-Hans'
  }
  return 'en'
}

class DynamicTranslation {
  key: string
  pattern: RegExp

  constructor(key: string) {
    this.key = key
    const escaped: string = key.replace(/[.*+?^$()|[\]\\]/g, '\\$&')
    this.pattern = new RegExp('^' + escaped.replace(/\{\d+\}/g, '([\\s\\S]*?)') + '$')
  }
}

const dynamicTranslations: DynamicTranslation[] = DYNAMIC_KEYS.map((key: string) => new DynamicTranslation(key))

export function translate(key: string, language: string = AppStorage.get<string>('uiLanguage') ?? 'zh-Hans'): string {
  const source: string = translations[key] ?? key
  const locale: string = resolveLanguage(language, 'en')
  if (locale === 'zh-Hans') return source
  const exact: string = locale === 'zh-Hant' ? TRADITIONAL[source] : ENGLISH[source]
  if (exact !== undefined && exact.length > 0) return exact
  // Combined status/file metadata is generated from stable source labels.
  // Avoid scanning every template for ordinary ASCII values such as FPS/IDs.
  if (!/[\u4e00-\u9fff]/.test(source)) return source
  for (let index: number = 0; index < dynamicTranslations.length; index++) {
    const entry: DynamicTranslation = dynamicTranslations[index]
    const match: RegExpExecArray | null = entry.pattern.exec(source)
    if (match === null) continue
    const result: string = (locale === 'zh-Hant' ? TRADITIONAL[entry.key] : ENGLISH[entry.key]) ??
      ENGLISH[entry.key] ?? entry.key
    const values: string[] = []
    for (let valueIndex: number = 1; valueIndex < match.length; valueIndex++) {
      let value: string = match[valueIndex]
      // Only known label-bearing templates translate their substitutions.
      // Device names, filenames, IDs, paths and chat text stay untouched.
      if (entry.key === '排序：{0}' || entry.key === '{0}，长按拖动调整顺序' ||
        entry.key === '{0} · 硬解' || entry.key === '{0} · 软解' ||
        entry.key === '{0} · 检测中' || (entry.key === '{0}（错误码 {1}）' && valueIndex === 1) ||
        entry.key === '文件传输失败：{0}' || entry.key === '读取远端目录失败：{0}' ||
        (entry.key === '确定永久删除“{0}”{1}？此操作不能撤销。' && valueIndex === 2) ||
        (entry.key === '远端 {0} · {1} · {2} 项' && valueIndex === 2)) value = translate(value, locale)
      values.push(value)
    }
    // One pass prevents a filename containing "{1}" from becoming a placeholder.
    return result.replace(/\{(\d+)\}/g, (_token: string, index: string): string => values[Number(index)] ?? _token)
  }
  return ENGLISH[source] ?? source
}
