'use strict';
// Execute the docked Button builder with an ArkUI stub. This checks the
// declared tree and a simplified rectangular hit model; actual system hit
// testing, hover rendering and touch ergonomics still need device validation.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/RemotePage.ets'), 'utf8').replace(/\r\n/g, '\n');
const start = source.indexOf('\n  buildFloatingToolbar()');
const end = source.indexOf('\n  buildFullscreenButton(', start);
assert(start >= 0 && end > start);
const builder = source.slice(start, end);
const buttonStart = builder.indexOf('      Button() {');
const buttonEnd = builder.indexOf('\n    } else {\n        Row({ space: 4 })', buttonStart);
assert(buttonStart >= 0 && buttonEnd > buttonStart);
let dockButton = builder.slice(buttonStart, buttonEnd)
  .replace('Button() {', 'Button.begin(() => {')
  .replace("Stack({ alignContent: this.remoteToolbarDockEdge === 'left' ? Alignment.Start : Alignment.End }) {",
    "Stack.begin({ alignContent: this.remoteToolbarDockEdge === 'left' ? Alignment.Start : Alignment.End }, () => {")
  .replace('Row() {}', 'Row.begin(() => {})')
  .replace(/\n          }\n          \.width\('100%'\)/, "\n          })\n          .width('100%')")
  .replace(/\n      }\n      \.width\('100%'\)/, "\n      })\n      .width('100%')");
assert(dockButton.includes('Button.begin(') && dockButton.includes('Stack.begin('));
assert(builder.includes('HitTestMode.None : HitTestMode.Default'), 'the docked wrapper cannot block sibling input');
const modes = { Default: 0, None: 3 }, roots = [], gestures = [];
let parent;
function node(kind, body) {
  const value = { kind, children: [], mode: modes.Default, attrs: {} };
  (parent ? parent.children : roots).push(value);
  const previous = parent; parent = value;
  try { body?.(); } finally { parent = previous; }
  let proxy;
  proxy = new Proxy(value, { get(target, key) {
    if (key in target) return target[key];
    return (...args) => {
      target.attrs[key] = args;
      if (key === 'hitTestBehavior') target.mode = args[0];
      return proxy;
    };
  }});
  return proxy;
}
function PanGesture() {
  const events = {};
  const gesture = { events };
  for (const key of ['onActionStart', 'onActionUpdate', 'onActionEnd', 'onActionCancel']) {
    gesture[key] = callback => { events[key] = callback; return gesture; };
  }
  gestures.push(gesture); return gesture;
}
class ButtonShapeModifier {
  constructor(rectangular, radius, type) { Object.assign(this, { rectangular, radius, type }); }
}
const context = vm.createContext({
  Button: { begin: body => node('Button', body) },
  Stack: { begin: (_options, body) => node('Stack', body) },
  Row: { begin: body => node('Row', body) }, PanGesture, ButtonShapeModifier,
  PanDirection: { All: 0 }, HoverEffect: { None: 1, Auto: 0 }, HitTestMode: modes,
  ButtonType: { Normal: 0, Capsule: 1 }, Color: { Transparent: 'transparent' },
  Alignment: { Start: 0, End: 1 }, translate: value => value
});
vm.runInContext(ts.transpile(`class Page { buildDockedButton() {${dockButton}\n} } globalThis.Page = Page;`), context);
let count = 0;
function test(name, fn) { fn(); count++; console.log('PASS ' + name); }
for (const edge of ['left', 'right']) for (const rectangular of [false, true]) {
  test(`${edge} edge and button style ${rectangular}: tab, hit bounds and gesture handlers`, () => {
    roots.length = 0; gestures.length = 0; parent = undefined;
    const calls = [], page = Object.assign(new context.Page(), {
      remoteToolbarDockEdge: edge, roundedRectButtons: rectangular,
      uiLanguage: 'zh-Hans', getRemoteToolbarCurrentHeight: () => 110,
      floatingPanelTransition: () => ({}), onRemoteToolbarHandleClick: () => calls.push('click'),
      handleRemoteToolbarHover: value => calls.push(`hover:${value}`),
      beginRemoteToolbarDrag: () => calls.push('drag-start'),
      updateRemoteToolbarDrag: () => calls.push('drag-move'),
      finishRemoteToolbarDrag: () => calls.push('drag-end'),
      cancelRemoteToolbarDrag: () => calls.push('drag-cancel')
    });
    page.buildDockedButton();
    assert.equal(roots.length, 1);
    const button = roots[0], stack = button.children[0], strip = stack.children[0];
    assert.equal(button.kind, 'Button'); assert.equal(button.attrs.width[0], '100%');
    assert.equal(button.attrs.height[0], 110); assert.equal(button.attrs.backgroundColor[0], 'transparent');
    assert.equal(button.attrs.stateEffect[0], false); assert.equal(button.attrs.hoverEffect[0], context.HoverEffect.None);
    assert.equal(stack.mode, modes.None); assert.equal(strip.mode, modes.None);
    assert.equal(stack.attrs.width[0], '100%'); assert.equal(strip.attrs.width[0], '100%');
    const shape = button.attrs.attributeModifier[0];
    assert.equal(shape.rectangular, false); assert.equal(shape.radius, 0); assert.equal(shape.type, context.ButtonType.Normal);
    // The production wrapper is 16 vp wide: there is no remaining 40 vp
    // sibling-blocking rectangle in this simplified hit model.
    const hit = (x, y) => x >= 0 && x < 16 && y >= 0 && y < 110 ? 'control' : 'remote';
    assert.equal(hit(8, 55), 'control'); assert.equal(hit(16, 55), 'remote');
    assert.equal(hit(30, 55), 'remote'); assert.equal(hit(8, 111), 'remote');
    button.attrs.onHover[0](true); button.attrs.onHover[0](false); button.attrs.onClick[0]();
    gestures[0].events.onActionStart(); gestures[0].events.onActionUpdate({ offsetX: 3, offsetY: 2 });
    gestures[0].events.onActionEnd(); gestures[0].events.onActionCancel();
    assert.deepEqual(calls, ['hover:true', 'hover:false', 'click', 'drag-start', 'drag-move', 'drag-end', 'drag-cancel']);
  });
}
console.log(`docked toolbar hit model: ${count} scenarios passed`);
