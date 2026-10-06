'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
function method(name) {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const context = vm.createContext({});
vm.runInContext(ts.transpile('class Page {' + ['getKeyboardLauncherBase', 'clampKeyboardLauncherOffset'].map(method).join('\n') +
  '} globalThis.Page = Page;'), context);
let count = 0;
for (const [width, height, landscape] of [[360, 800, false], [800, 840, false], [840, 400, true],
  [800, 480, false], [840, 150, true], [1200, 800, true]]) {
  const p = Object.assign(new context.Page(), { pageWidth: width, pageHeight: height,
    isHandheldLandscape: () => landscape, getRemoteToolbarHeight: () => 54 });
  for (const horizontal of [true, false]) {
    const base = p.getKeyboardLauncherBase(horizontal), size = horizontal ? 52 : 46;
    const limit = (horizontal ? width : height) - size - 8;
    for (const offset of [-10000, -600, 0, 600, 10000]) {
      const coordinate = base + p.clampKeyboardLauncherOffset(offset, horizontal);
      assert(coordinate >= 8 && coordinate <= limit, `${width}x${height} offset ${offset}`);
      count++;
    }
  }
  assert(p.getKeyboardLauncherBase(false) + 46 <= height - 8, 'above IME/navigation boundary');
  if (landscape) assert.equal(p.getKeyboardLauncherBase(true), (width - 52) / 2);
  else assert.equal(p.getKeyboardLauncherBase(true), width - 64);
}
const builder = method('buildKeyboardLauncher');
assert(builder.includes(".id('remoteKeyboardLauncher')"));
assert(builder.includes('.focusable(false)'));
assert(builder.includes('this.toggleRemoteKeyboard()'));
assert(builder.includes('this.showKeyboardPanel ? this.controlSelectedBackgroundColor()'));
assert(builder.includes('.accessibilityText('));
assert(builder.includes('PanGesture('));
assert(!builder.includes('remoteToolbarCollapsed') && !builder.includes('keyboardToolsCollapsed'));
assert.match(source, /!this\.fileOnly && this\.isHandheldDevice\(\) &&[\s\S]*this\.buildKeyboardLauncher\(\)/);
const viewport = method('buildRemoteViewport');
assert(viewport.includes('.focusOnTouch(!this.showKeyboardPanel)'));
assert(viewport.includes('.focusable(!this.showKeyboardPanel)'));
assert(viewport.includes('.defaultFocus(!this.showKeyboardPanel)'));
assert(!method('handleRemoteAxis').includes('this.showKeyboardPanel'));
assert(!method('handleRemoteClickFallback').includes('this.showKeyboardPanel'));
assert(method('finishThreeFingerGesture').includes('this.openRemoteKeyboard()'));
assert(method('onBackPress').includes('this.closeRemoteKeyboard()'));
const icon = fs.readFileSync(path.join(root, 'entry/src/main/resources/base/media/keyboard_launcher.svg'), 'utf8');
assert(icon.includes('viewBox="0 0 24 24"'));
assert(!/href=|url\(/.test(icon));
console.log(`PASS floating keyboard launcher: ${count} bounded drag positions, independent visibility, focus and gesture guards`);
