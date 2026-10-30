// Execute the production target/activation scripts against a tiny synthetic DOM.
// The fixture changes during the same gap that the real cursor animation leaves.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const swift = readFileSync(new URL('../KestrelWebKit/BrowserOperator.swift', import.meta.url), 'utf8');
function script(name) {
  const expression = new RegExp('private static let ' + name + ' = #"""\\n([\\s\\S]*?)\\n    """#', 'u');
  const source = swift.match(expression)?.[1];
  assert.ok(source, `Could not extract ${name}`);
  return source.replaceAll('__KESTREL_TOKEN__', JSON.stringify('fixture-token'))
    .replaceAll('__KESTREL_QUERY__', JSON.stringify('Continue'));
}
const clicked = [];
function button(id) {
  return {
    isConnected: true, disabled: false, innerText: 'Continue', textContent: 'Continue', value: '', title: '',
    getAttribute: () => null,
    matches: () => false, closest: () => null, contains: () => false,
    getBoundingClientRect: () => ({ x: 10, y: 10, width: 100, height: 30, left: 10, top: 10, right: 110, bottom: 40 }),
    scrollIntoView: () => {},
    click: () => clicked.push(id),
  };
}
const original = button('original');
let nodes = [original];
const context = vm.createContext({
  document: { querySelectorAll: () => nodes, elementFromPoint: () => nodes[0] },
  window: {
    innerWidth: 800, innerHeight: 600,
    getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }),
    setTimeout: callback => { callback(); },
  },
});
const target = await vm.runInContext(script('clickTextTargetTemplate'), context);
assert.equal(JSON.parse(target).width, 100);
// A new matching control is inserted before the target while the cursor moves.
nodes = [button('inserted-during-animation'), original];
const performed = vm.runInContext(script('clickTextTemplate'), context);
console.log(JSON.stringify({ initiallyUnique: true, performed, clicked }));
assert.equal(performed, false);
assert.deepEqual(clicked, []);
nodes = [original];
await vm.runInContext(script('clickTextTargetTemplate'), context);
assert.equal(vm.runInContext(script('clickTextTemplate'), context), true);
assert.equal(vm.runInContext(script('clickTextTemplate'), context), false);
assert.deepEqual(clicked, ['original']);
