'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8').replace(/\r\n/g, '\n');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const svg = read('entry/src/main/resources/base/media/remote_keyboard_expand.svg');
const upstreamPath = 'M16.59 8.59L12 13.17 7.41 8.59 6 10l6 6 6-6z';
assert(svg.includes('Material Icons expand_more, Apache-2.0.'));
assert(svg.includes('viewBox="0 0 24 24"'));
assert(!/href\s*=|url\(|<script|<image|<text/.test(svg));
const paths = [...svg.matchAll(/<path fill="([^"]+)" d="([^"]+)"\/>/g)];
assert.equal(paths.length, 1);
assert.equal(paths[0][1], '#4A607E');
assert.equal(crypto.createHash('sha256').update(paths[0][2]).digest('hex'),
  crypto.createHash('sha256').update(upstreamPath).digest('hex'));
assert(read('entry/src/main/resources/rawfile/licenses/material-icons-Apache-2.0.txt').includes('Version 2.0'));

const group = method('buildUnifiedControlItems');
const primary = method('buildControlCategoryButton');
assert(!group.includes("Button('⌄'"), 'Do not use a font character for the dropdown');
assert(group.includes("Image($r('app.media.remote_keyboard_expand'))"));
assert(group.includes('.width(14).height(14)'));
assert(group.includes('.fillColor(this.controlMenuIconColor(category))'));
assert(group.includes('.rotate({ angle: this.keyboardToolsCollapsed ? 0 : 180 })'));
assert(group.includes('.animation({ duration: 200, curve: Curve.EaseOut })'));
assert(group.includes(".id('remoteKeyboardShortcutToggle')"));
assert(group.includes('.width(28).height(this.getRemoteToolbarButtonHeight() + 8)'));
assert(group.includes('.width(this.adaptiveToolbarButtonWidth(vertical ? 80 : 68))'));
assert(group.includes('.alignItems(VerticalAlign.Center)'));
assert(group.includes('Divider().vertical(true).width(1).height(16)'));
assert((group.match(/hitTestBehavior\(HitTestMode.None\)/g) || []).length === 2);
assert(group.includes(".accessibilityText(translate('组合键'"));
assert(group.includes("this.keyboardToolsCollapsed ? '展开' : '收起'"));
assert(group.includes('.backgroundColor(this.controlMenuSelected(category) ? this.controlSelectedBackgroundColor() : Color.Transparent)'));
assert(group.includes('.borderRadius(10)') && group.includes('.clip(true)'));
assert(primary.includes(".layoutWeight(category === 'keyboard' ? 1 : 0)"));
assert(primary.includes(".backgroundColor(category !== 'keyboard' && this.controlMenuSelected(category)"));
assert(primary.includes(".border({ width: category !== 'keyboard' && this.controlMenuSelected(category)"));
assert(primary.includes('this.toggleRemoteKeyboard()'));

const context = { exports: {}, Curve: { EaseOut: 'ease-out' } };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/theme/RustDeskTheme.ets')), context);
context.RustDeskTheme = context.exports.RustDeskTheme;
vm.runInNewContext(ts.transpile('class Page {' + ['controlMenuSelected', 'controlMenuIconColor',
  'controlSelectedTextColor', 'adaptiveToolbarButtonWidth', 'getRemoteToolbarButtonHeight',
  'setFloatingPanelCollapsed'].map(method).join('\n') + '} exports.Page = Page;'), context);
const clickBody = group.match(/\.onClick\(\(\) => \{([\s\S]*?)\n\s*\}\)/)[1];
assert(!/toggleRemoteKeyboard|releaseVirtualModifiers|refocusRemoteKeyboard/.test(clickBody));
const click = new Function(clickBody);
let checks = 0;
for (const dark of [false, true]) {
  for (const keyboardOpen of [false, true]) {
    for (const collapsed of [false, true]) {
      const animations = [];
      const page = Object.assign(new context.exports.Page(), {
        isDarkMode: dark, showKeyboardPanel: keyboardOpen, keyboardToolsCollapsed: collapsed,
        uiFontScale: 1, remoteToolbarCollapsed: true,
        setControlMenu(value) { this.controlMenu = value; },
        getUIContext: () => ({ animateTo(options, callback) { animations.push(options); callback(); } }),
        schedulePcToolbarAutoCollapse() { throw new Error('Do not alter control toolbar'); }
      });
      assert.equal(page.controlMenuSelected('keyboard'), keyboardOpen || !collapsed);
      const theme = context.RustDeskTheme;
      assert.equal(page.controlMenuIconColor('keyboard'), keyboardOpen || !collapsed
        ? dark ? theme.CONTROL_SELECTED_TEXT_DARK : theme.CONTROL_SELECTED_TEXT
        : dark ? theme.CONTROL_ICON_DARK : theme.CONTROL_ICON);
      click.call(page);
      assert.equal(page.keyboardToolsCollapsed, !collapsed);
      assert.equal(page.showKeyboardPanel, keyboardOpen, 'Arrow must not show/hide the IME');
      assert.equal(page.remoteToolbarCollapsed, true);
      assert.equal(page.controlMenu, '');
      assert.equal(animations.length, 1);
      assert.equal(animations[0].duration, 200);
      assert.equal(animations[0].curve, 'ease-out');
      checks++;
    }
  }
}
const geometry = new context.exports.Page();
for (const vertical of [false, true]) {
  for (const scale of [1, 1.15, 1.3, 1.5, 1.75, 2, 2.4]) {
    for (const selected of [false, true]) {
      geometry.uiFontScale = scale;
      const width = geometry.adaptiveToolbarButtonWidth(vertical ? 80 : 68);
      const height = geometry.getRemoteToolbarButtonHeight() + 8;
      const primaryWidth = width - 28 - 1 - (selected ? 2 : 0);
      assert(primaryWidth >= Math.max(24, 22 * scale + 4), 'Keyboard glyph/label must fit beside the divider');
      assert(height >= 48 && height > 16 && 28 > 14);
      checks++;
    }
  }
}
console.log(`PASS keyboard expand icon: upstream vector, unified split-button styling, independent actions, animated state and ${checks} theme/layout cases`);
