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
expect(remotePage, /buildFloatingToolbar\(\)[\s\S]*Text\(translate\('控', this\.uiLanguage\)\)[\s\S]*setFloatingPanelCollapsed\(false, false\)/,
  'collapsed remote toolbar must expose a compact restore button')
expect(remotePage, /beginRemoteToolbarDrag\(\)[\s\S]*updateRemoteToolbarDrag\(offsetX:\s*number,\s*offsetY:\s*number\)/,
  'remote toolbar must support bounded dragging')
expect(remotePage, /controlSelectedBackgroundColor\(\)[\s\S]*CONTROL_SELECTED_BG_DARK[\s\S]*CONTROL_SELECTED_BG/,
  'selected toolbar colors must adapt to dark mode')
expect(remotePage, /display === this\.currentDisplay[\s\S]*controlSelectedBackgroundColor\(\)/,
  'the current remote display must use the pale-blue selected style')
expect(remotePage, /edgeAutoPanEnabled \? this\.controlSelectedBackgroundColor\(\)/,
  'edge following must use the pale-blue selected style')
expect(remotePage, /selected \? this\.controlSelectedBackgroundColor\(\) : \(this\.controlMenu \? Color\.Transparent : this\.mutedSurfaceColor\(\)\)/,
  'general buttons keep pale-blue selection; compact menus use a transparent unselected row')
expect(remotePage, /按钮变为淡蓝色/,
  'gesture help must describe the new selected state')
expect(remotePage, /Button\(translate\(`屏\$\{display \+ 1\}`, this\.uiLanguage\)\)[\s\S]*?\.width\(this\.adaptiveToolbarButtonWidth\(vertical \? 80 : 44\)\)/,
  'phone display buttons must keep their compact base width and adapt to large system fonts')
expect(remotePage, /item === 'input'[\s\S]*buildInputModeButton\(vertical \? 80 : 56, vertical, item\)/,
  'the dynamic toolbar must preserve the compact phone input-mode button')
expect(remotePage, /item === 'keyboard'[\s\S]*buildToolbarButton\('键盘', vertical \? 80 : 56/,
  'the dynamic toolbar must preserve the compact phone keyboard button')
expect(remotePage, /height - this\.getRemoteToolbarHeight\(\) - 18/,
  'floating toolbar must keep a safe gap above the system navigation area')
expect(remotePage, /isHandheldLandscape\(\)[\s\S]*deviceInfo\.deviceType === 'phone' \|\| deviceInfo\.deviceType === 'tablet'/,
  'phone and tablet landscape layouts must be detected explicitly')
expect(remotePage, /getKeyboardToolsBaseX\(\)[\s\S]*isHandheldLandscape\(\)\) return 8/,
  'the keyboard toolbar must default to the top-left in handheld landscape')
expect(remotePage, /getRemoteToolbarBaseX\(\)[\s\S]*width - this\.getRemoteToolbarCurrentWidth\(\) - 8/,
  'the control toolbar must default to the top-right in handheld landscape')
expect(remotePage, /buildUnifiedControlItems\(true\)[\s\S]*ScrollDirection\.Vertical/,
  'the landscape control toolbar must expand downward')
expect(remotePage, /buildKeyboardToolbarItems\(true\)[\s\S]*ScrollDirection\.Vertical/,
  'the landscape keyboard toolbar must expand downward')
expect(remotePage, /LongPressGesture\(\{ repeat: false, duration: 550 \}\)[\s\S]*openToolbarOrderEditor/,
  'toolbar buttons must expose long-press ordering')
expect(remotePage, /getOption\('show-virtual-mouse'\)[\s\S]*setOption\('show-virtual-mouse'/,
  'the RustDesk-style virtual mouse preference must be toggleable')
expect(remotePage, /menu-\$\{item\}[\s\S]*showVirtualMouse \? 1 : 0/,
  'the control toolbar key must refresh when virtual mouse visibility changes')
expect(remotePage, /this\.showVirtualMouse[\s\S]*this\.isHandheldDevice\(\)[\s\S]*this\.buildVirtualMouseOverlay\(\)/,
  'the RustDesk-style virtual mouse must render only on handheld devices')
expect(remotePage, /showVirtualMouse[\s\S]*canPanViewport\(\)[\s\S]*handleViewportPan\(event\)/,
  'the zoomed background must pan while the virtual mouse controls the remote pointer')
expect(remotePage, /buildRemoteViewportWithQualityMonitor\(\)[\s\S]*buildRemoteViewport\(\)[\s\S]*buildVirtualMouseOverlay\(\)/,
  'the virtual mouse must share the remote viewport coordinate system')
expect(remotePage, /updatePointerFromVirtualMouse\(\)[\s\S]*visualPointToRemote\([\s\S]*virtualMouseX[\s\S]*virtualMouseY/,
  'virtual mouse movement must use absolute viewport-to-remote mapping')
expect(remotePage, /applyRemoteCursorPosition[\s\S]*alignVirtualMouseToRemotePosition\(cursor\.x, cursor\.y\)/,
  'authoritative remote cursor samples must recalibrate the virtual mouse')
expect(remotePage, /updateVirtualMouseMove[\s\S]*updatePointerFromVirtualMouse\(\)/,
  'virtual mouse dragging must not reuse accelerated touchpad deltas')
expect(remotePage, /handleVirtualMouseButtonTouch[\s\S]*TouchType\.Move[\s\S]*VIRTUAL_MOUSE_BUTTON_DRAG_THRESHOLD[\s\S]*beginVirtualMouseButtonDrag[\s\S]*TouchType\.Up[\s\S]*clickVirtualMouseButton/,
  'virtual mouse buttons must distinguish taps from drag selection in one touch path')
expect(remotePage, /Button\(translate\('左键'[\s\S]*?handleVirtualMouseButtonTouch\('left'[\s\S]*?Button\(translate\('右键'[\s\S]*?handleVirtualMouseButtonTouch\('right'/,
  'both virtual mouse buttons must use the conflict-free touch handler')
expect(remotePage, /clickVirtualMouseButtonFallback[\s\S]*virtualMouseLastTouchResolvedAt[\s\S]*clickVirtualMouseButton[\s\S]*handleVirtualMouseButtonTouch\('left'[\s\S]*clickVirtualMouseButtonFallback\('left'/,
  'virtual mouse buttons must provide a deduplicated click fallback')
expect(remotePage, /handleVirtualMouseWheelTouch[\s\S]*virtualMouseWheelTouchMoved[\s\S]*sendVirtualMouseWheel[\s\S]*clickVirtualMouseButton\('middle'\)/,
  'the center wheel must distinguish scrolling from a middle click')
expect(remotePage, /VIRTUAL_MOUSE_WHEEL_BUTTON_STEP:\s*number\s*=\s*3[\s\S]*sendVirtualMouseWheel/,
  'virtual wheel buttons must send a visible multi-step scroll')
expect(remotePage, /Button\('⌄'\)[\s\S]*?\.position\(\{ x: 29, y: 0 \}\)[\s\S]*?\.zIndex\(2\)/,
  'virtual wheel controls must stay above the overlapping mouse drag body')
expect(remotePage, /setKeyboardAvoidMode\(KeyboardAvoidMode\.RESIZE\)/,
  'the keyboard must resize the available area for floating controls')
expect(remotePage, /\.height\(this\.getRemoteCanvasHeight\(\)\)[\s\S]*?minHeight: this\.keyboardViewportHeight[\s\S]*?\.align\(Alignment.Center\)/,
  'the landscape canvas keeps its full height and moves upward inside the clipped available area')
expect(remotePage, /keyboardViewportHeight = this\.isHandheldDevice\(\) \?[\s\S]*?this\.componentHeight/,
  'opening the keyboard must preserve the unscaled canvas on all handheld aspect ratios')
expect(remotePage, /openRemoteKeyboard\(\)[\s\S]*?this\.snapshotRemoteKeyboardViewport\(\)/,
  'opening the keyboard must capture the current viewport before IME resize')
expect(remotePage, /\.align\(Alignment\.Center\)[\s\S]*?\.translate\(\{ y: this\.getKeyboardCanvasShiftY\(\) \}\)/,
  'canvas and both cursor layers must share input-anchor keyboard avoidance')
expect(remotePage, /keyboardToolsCollapsed = !landscape;[\s\S]*?if \(landscape\) this\.remoteToolbarCollapsed = false/,
  'entering handheld landscape must expand both toolbars')

// Execute production orientation/canvas logic: IME resize is not a rotation.
const layoutMethods = remotePage.slice(remotePage.indexOf('  isHandheldLandscape():'),
  remotePage.indexOf('  startToolbarTimer():'))
  .replace(/: number \| string|: boolean|: number|: void/g, '')
const layout = new Function('RustDeskNapi', `return new class {${layoutMethods}}`)({ appendDiagnosticLog() {} })
layout.isHandheldDevice = () => true
Object.assign(layout, { pageWidth: 800, pageHeight: 400, showKeyboardPanel: false,
  keyboardLayoutHeight: 0, keyboardViewportHeight: 0, handheldLayoutInitialized: false,
  keyboardToolsCollapsed: true, remoteToolbarCollapsed: true, showVirtualMouse: false })
layout.handleHandheldLayoutChange()
require('node:assert/strict').equal(layout.keyboardToolsCollapsed, false)
require('node:assert/strict').equal(layout.remoteToolbarCollapsed, false)
layout.keyboardToolsCollapsed = true // Explicit user collapse survives IME show/hide.
Object.assign(layout, { showKeyboardPanel: true, keyboardLayoutHeight: 400,
  keyboardViewportHeight: 350, pageHeight: 170 })
layout.handleHandheldLayoutChange()
require('node:assert/strict').equal(layout.keyboardToolsCollapsed, true)
require('node:assert/strict').equal(layout.getRemoteCanvasHeight(), 350)
// Same remote size and zoom: the fit stays unchanged, center moves up 115vp.
require('node:assert/strict').equal(Math.min(800 / 1920, layout.getRemoteCanvasHeight() / 1080), 350 / 1080)
Object.assign(layout, { pageWidth: 400, pageHeight: 300, keyboardLayoutHeight: 800,
  keyboardViewportHeight: 0 })
require('node:assert/strict').equal(layout.isHandheldLandscape(), false)
require('node:assert/strict').equal(layout.getRemoteCanvasHeight(), '100%')
console.log('PASS landscape expanded defaults and fixed-scale keyboard canvas')

// Exercise the production reorder handler, including moves across multiple rows.
const assert = require('node:assert/strict')
const reorderBody = remotePage.slice(
  remotePage.indexOf('  moveToolbarOrderItem('),
  remotePage.indexOf('  resetToolbarOrder(')
).replace(/: string\[\]|: string|: number|: void/g, '')
const reorder = new Function(`return ({${reorderBody}}).moveToolbarOrderItem`)()
const saved = []
const state = {
  keyboardToolbarOrder: ['ctrl', 'alt', 'shift', 'meta'],
  controlToolbarOrder: ['displays', 'input', 'keyboard', 'disconnect'],
  keyboardMoreOrder: ['Esc', 'Tab', 'Home', 'Ctrl+Alt+Del'],
  saveToolbarOrder(kind) { saved.push(kind) }
}
const original = state.keyboardToolbarOrder
reorder.call(state, 'keyboard', 0, 3)
assert.deepEqual(state.keyboardToolbarOrder, ['alt', 'shift', 'meta', 'ctrl'])
assert.deepEqual(original, ['ctrl', 'alt', 'shift', 'meta'])
reorder.call(state, 'keyboard', 3, 0)
assert.deepEqual(state.keyboardToolbarOrder, original)
reorder.call(state, 'control', 3, 1)
assert.deepEqual(state.controlToolbarOrder, ['displays', 'disconnect', 'input', 'keyboard'])
reorder.call(state, 'keyboardMore', 3, 0)
assert.deepEqual(state.keyboardMoreOrder, ['Ctrl+Alt+Del', 'Esc', 'Tab', 'Home'])
assert.deepEqual(state.keyboardToolbarOrder, original)
assert.deepEqual(state.controlToolbarOrder, ['displays', 'disconnect', 'input', 'keyboard'])
assert.equal(saved.at(-1), 'keyboardMore')
const preferenceMethods = remotePage.slice(
  remotePage.indexOf('  readToolbarOrder('), remotePage.indexOf('  setEdgeAutoPanEnabled(')
).replace(/: string\[\]|: string|: number|: void/g, '')
const options = new Map()
const preferences = new Function('RustDeskNapi', `return new class {${preferenceMethods}}` )({
  getOption(key) { return options.get(key) || '' },
  setOption(key, value) { options.set(key, value) }
})
preferences.saveToolbarOrder.call(state, 'keyboardMore')
assert.equal(options.get('remote-keyboard-more-order'), 'Ctrl+Alt+Del,Esc,Tab,Home')
assert.equal(options.size, 1, 'More-key ordering must not overwrite either main toolbar preference')
assert.deepEqual(preferences.readToolbarOrder('remote-keyboard-more-order',
  ['Esc', 'Tab', 'Home', 'Ctrl+Alt+Del', 'Del']), ['Ctrl+Alt+Del', 'Esc', 'Tab', 'Home', 'Del'])
for (const [from, to] of [[0, 0], [-1, 2], [0, 4], [0, 1.5], [NaN, 1]]) {
  reorder.call(state, 'control', from, to)
}
assert.deepEqual(saved, ['keyboard', 'keyboard', 'control', 'keyboardMore'])
assert.deepEqual(state.controlToolbarOrder, ['displays', 'disconnect', 'input', 'keyboard'])
console.log('PASS native toolbar reorder: cross-row moves, independent lists, immutable updates and persistence')
console.log('PASS remote toolbar, virtual mouse, landscape placement and ordering controls')
