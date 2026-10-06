'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = page.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
};
// Filled path data from Material Icons at 737e3324305806514d7909874fa1818ae1808232.
// Only fill colors and non-rendering transparent paths may differ from upstream.
const assets = [
  ['screens', 'remote_menu_screens', 'tv', '5fc16a85240ac7166ab889b1dc748661315bbeefff70b348311c462924cbb2bc'],
  ['input', 'remote_menu_input', 'mouse', 'f4dfcd32cbbc3e6047d3a81b2a97d9feb59ea917b1663389b2778ca9f0430513'],
  ['keyboard', 'keyboard_launcher', 'keyboard', 'c2c75887f4e8d0848086a1f44c978b5b167a17a11e98243bea30e353339c7fdb'],
  ['view', 'remote_menu_view', 'settings_overscan', 'a70aa928b4e62693adf2c15a875212c1429eea6aca411c18eb25bbcc01a07397'],
  ['more', 'remote_menu_more', 'more_vert', '7877e63449976aa4301ea696fec3684cdc4de2d7048568d7e2684bc4f4eb3440'],
  ['disconnect', 'remote_menu_disconnect', 'close', 'fb647fe7ff5d7c8b418820fdd543892ca9766af885ad6ff4920958bab998ff34'],
];
for (const [category, name, upstream, digest] of assets) {
  const svg = read('entry/src/main/resources/base/media/' + name + '.svg');
  assert(svg.includes('viewBox="0 0 24 24"'), name);
  assert(svg.includes('Material Icons ' + upstream + ', Apache-2.0.'), name);
  assert(!/href\s*=|url\(|<script|<image|<rect|stroke=/.test(svg), name);
  const paths = [...svg.matchAll(/<path\s+fill="(#[0-9A-Fa-f]{6})"\s+d="([^"]+)"\s*\/>/g)];
  assert.equal(paths.length, 1, name);
  assert.equal(paths[0][1], category === 'disconnect' ? '#D84A4A' : '#4A607E');
  assert.equal(crypto.createHash('sha256').update(paths[0][2]).digest('hex'), digest, name);
  assert(method('controlMenuIcon').includes("app.media." + name), name);
}
const context = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/theme/RustDeskTheme.ets')), context);
context.RustDeskTheme = context.exports.RustDeskTheme;
vm.runInNewContext(ts.transpile('class Page {' +
  ['controlMenuSelected', 'controlMenuIconColor', 'controlSelectedTextColor'].map(method).join('\n') +
  '} exports.Page = Page;'), context);
const theme = context.RustDeskTheme;
let states = 0;
for (const dark of [false, true]) {
  for (const selected of [false, true]) {
    const p = Object.assign(new context.exports.Page(), {
      isDarkMode: dark, controlMenu: selected ? 'screens' : '',
      showKeyboardPanel: selected, keyboardToolsCollapsed: !selected,
    });
    for (const [category] of assets) {
      p.controlMenu = selected ? category : '';
      assert.equal(p.controlMenuIconColor(category), category === 'disconnect'
        ? (dark ? theme.CONTROL_DANGER_ICON_DARK : theme.ERROR)
        : selected ? (dark ? theme.CONTROL_SELECTED_TEXT_DARK : theme.CONTROL_SELECTED_TEXT)
          : dark ? theme.CONTROL_ICON_DARK : theme.CONTROL_ICON);
      states++;
    }
  }
}
function luminance(hex) {
  const rgb = hex.match(/[a-f\d]{2}/gi).map(s => parseInt(s, 16) / 255)
    .map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}
for (const [fg, bg] of [[theme.CONTROL_ICON, '#FFFFFF'], [theme.CONTROL_ICON_DARK, theme.CARD_DARK],
  [theme.CONTROL_SELECTED_TEXT, theme.CONTROL_SELECTED_BG],
  [theme.CONTROL_SELECTED_TEXT_DARK, theme.CONTROL_SELECTED_BG_DARK],
  [theme.ERROR, '#FFFFFF'], [theme.CONTROL_DANGER_ICON_DARK, theme.CARD_DARK]]) {
  const a = luminance(fg), b = luminance(bg);
  assert((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05) >= 3, `${fg} / ${bg} icon contrast`);
}
const builder = method('buildControlCategoryButton');
assert(builder.includes('.width(20).height(20)'));
assert(builder.includes('.fillColor(this.controlMenuIconColor(category))'));
assert(builder.includes('.hitTestBehavior(HitTestMode.None)'));
assert(builder.includes('this.controlSelectedBackgroundColor()'));
for (const action of ['this.toggleRemoteKeyboard()', 'this.disconnectSession()', 'this.toggleControlMenu(category)']) {
  assert(builder.includes(action), action);
}
assert(method('buildUnifiedControlItems').includes(".accessibilityText(translate('组合键'"));
const license = read('entry/src/main/resources/rawfile/licenses/material-icons-Apache-2.0.txt');
assert(license.includes('Apache License') && license.includes('Version 2.0'));
console.log(`PASS remote-control icons: ${assets.length} upstream paths, ${states} theme/selection states, contrast, action and license guards`);
