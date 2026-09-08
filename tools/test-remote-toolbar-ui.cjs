const fs = require('fs')
const path = require('path')

const root = path.resolve(__dirname, '..')
const remotePage = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'),
  'utf8'
)
const theme = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/theme/RustDeskTheme.ets'),
  'utf8'
)

function expect(source, pattern, message) {
  if (!pattern.test(source)) {
    throw new Error(message)
  }
}

expect(theme, /CONTROL_SELECTED_BG:\s*ResourceColor\s*=\s*'#DCEBFF'/,
  'light toolbar selection background must use the approved pale blue')
expect(theme, /CONTROL_SELECTED_TEXT:\s*ResourceColor\s*=\s*'#246BCE'/,
  'light toolbar selection text must remain readable blue')
expect(remotePage, /@State remoteToolbarCollapsed:\s*boolean\s*=\s*false/,
  'remote toolbar must support a collapsed state')
expect(remotePage, /buildFloatingToolbar\(\)[\s\S]*Text\('控'\)[\s\S]*remoteToolbarCollapsed\s*=\s*false/,
  'collapsed remote toolbar must expose a compact restore button')
expect(remotePage, /beginRemoteToolbarDrag\(\)[\s\S]*updateRemoteToolbarDrag\(offsetX:\s*number,\s*offsetY:\s*number\)/,
  'remote toolbar must support bounded dragging')
expect(remotePage, /controlSelectedBackgroundColor\(\)[\s\S]*CONTROL_SELECTED_BG_DARK[\s\S]*CONTROL_SELECTED_BG/,
  'selected toolbar colors must adapt to dark mode')
expect(remotePage, /display === this\.currentDisplay[\s\S]*controlSelectedBackgroundColor\(\)/,
  'the current remote display must use the pale-blue selected style')
expect(remotePage, /edgeAutoPanEnabled \? this\.controlSelectedBackgroundColor\(\)/,
  'edge following must use the pale-blue selected style')
expect(remotePage, /selected \? this\.controlSelectedBackgroundColor\(\) : this\.mutedSurfaceColor\(\)/,
  'general selected toolbar buttons must use the pale-blue selected style')
expect(remotePage, /按钮变为淡蓝色/,
  'gesture help must describe the new selected state')
expect(remotePage, /Button\(`屏\$\{display \+ 1\}`\)[\s\S]*?\.width\(44\)/,
  'phone display buttons must stay compact enough to avoid a clipped keyboard button')
expect(remotePage, /buildInputModeButton\(56, false\)[\s\S]*buildToolbarButton\('键盘', 56/,
  'mouse and keyboard buttons must both fit completely in the initial phone viewport')
expect(remotePage, /height - this\.getRemoteToolbarHeight\(\) - 18/,
  'floating toolbar must keep a safe gap above the system navigation area')

console.log('PASS floating remote toolbar style, drag, collapse and pale-blue selections')
