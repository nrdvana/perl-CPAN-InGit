'use strict';
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const script = readFileSync(process.argv[2], 'utf8');
assert.ok(script, 'found the delivered JavaScript');

// A small DOM and controllable fetch/timer queues exercise the delivered script
// without a browser or third-party JavaScript dependencies.
class Element {
  constructor() {
    this.children = [];
    this.dataset = {};
    this.listeners = {};
    this.value = '';
  }
  append(child) { this.children.push(child); }
  replaceChildren(fragment) { this.children = fragment.children; }
  querySelectorAll() { return this.children; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  fire(name) { this.listeners[name]({preventDefault() {}}); }
}

const row = (name, version = '1.00', path = 'A/AU/AUTHOR/Example-1.00.tar.gz') =>
  ({name, version, path, text: `${name}  ${version}  ${path}`});
const tick = () => new Promise(resolve => setImmediate(resolve));

function setup({modules, complete = false, filter = '', next_after = null, tree = 'tree1'}) {
  const elements = Object.fromEntries(['cpan-index', 'module-filter', 'module-rows',
    'module-status', 'load-more', 'module-filter-form'].map(id => [id, new Element()]));
  const root = elements['cpan-index'];
  root.dataset = {filter, tree, complete: String(complete), nextAfter: next_after || '', previousBefore: '',
    jsonUrl: '/pan/test/modules/', authorsUrl: '/pan/test/authors/id/'};
  elements['module-filter'].value = filter;
  elements['module-rows'].children = modules.map(data => {
    const tr = new Element();
    tr.dataset.row = JSON.stringify(data);
    return tr;
  });
  let timerId = 0;
  const timers = new Map();
  const requests = [];
  vm.runInNewContext(script, {
    document: {baseURI: 'https://example.test/pan/test/', getElementById: id => elements[id],
      createElement: () => new Element(), createDocumentFragment: () => new Element()},
    URL, AbortController,
    setTimeout: (fn, delay) => { assert.equal(delay, 150); timers.set(++timerId, fn); return timerId; },
    clearTimeout: id => timers.delete(id),
    fetch: (url, options) => new Promise((resolve, reject) => requests.push({url, options, reject,
      respond: page => resolve({ok: true, json: async () => page})}))
  });
  return {
    elements, requests,
    type(value) { elements['module-filter'].value = value; elements['module-filter'].fire('input'); },
    async flush() { const callbacks = [...timers.values()]; timers.clear(); callbacks.forEach(fn => fn()); await tick(); },
    names() { return elements['module-rows'].children.map(tr => tr.children[0].textContent); },
    more() { elements['load-more'].fire('click'); }
  };
}

async function run() {
  const modules = [row('Example::Alpha'), row('Example::Beta', '2.50', 'L/LO/LOCAL/Beta-2.50.tar.gz')];
  const local = setup({modules, complete: true});
  local.type('AL');
  local.type('aLpHa');
  await local.flush();
  assert.equal(local.requests.length, 0, 'debounced narrowing uses the complete cache');
  assert.deepEqual(local.names(), ['Example::Alpha']);
  local.type('LOCAL');
  await local.flush();
  assert.deepEqual(local.names(), ['Example::Beta'], 'matches distribution paths case-insensitively');
  local.type('2.50');
  await local.flush();
  assert.deepEqual(local.names(), ['Example::Beta'], 'matches versions');
  local.type('[.*');
  await local.flush();
  assert.deepEqual(local.names(), [], 'metacharacters are literal');
  local.type('');
  await local.flush();
  assert.deepEqual(local.names(), ['Example::Alpha', 'Example::Beta'], 'broadening within a complete base cache is safe');

  const partial = setup({modules: [row('Example::Alpha')], next_after: 'Example::Alpha'});
  partial.type('EXAMPLE');
  assert.equal(partial.requests.length, 0, 'does not fetch before the delay');
  await partial.flush();
  assert.equal(partial.requests.length, 1, 'incomplete results require a server filter');
  assert.equal(partial.requests[0].url.searchParams.get('filter'), 'EXAMPLE');
  partial.requests[0].respond({modules: [modules[0]], filter: 'EXAMPLE', tree: 'tree1', complete: false,
    next_after: 'Example::Alpha', previous_before: null});
  await tick();
  partial.more();
  assert.equal(partial.requests[1].url.searchParams.get('after'), 'Example::Alpha', 'pages by module boundary');
  partial.requests[1].respond({modules: [modules[1]], filter: 'EXAMPLE', tree: 'tree1', complete: false,
    next_after: null, previous_before: 'Example::Beta'});
  await tick();
  assert.deepEqual(partial.names(), ['Example::Alpha', 'Example::Beta'], 'appends further modules');
  assert.equal(partial.elements['load-more'].hidden, true, 'hides load-more at the end');
  partial.type('example::BETA');
  await partial.flush();
  assert.equal(partial.requests.length, 2, 'all accumulated pages can now be filtered locally');
  assert.deepEqual(partial.names(), ['Example::Beta']);
  partial.type('AUTHOR');
  await partial.flush();
  assert.equal(partial.requests.length, 3, 'an unrelated filter needs fresh results');

  const races = setup({modules: [], complete: false});
  races.type('old');
  await races.flush();
  races.type('new');
  await races.flush();
  assert.equal(races.requests[0].options.signal.aborted, true, 'aborts stale requests');
  races.requests[1].respond({modules: [row('New')], filter: 'new', tree: 'tree1', complete: true,
    next_after: null, previous_before: null});
  await tick();
  races.requests[0].respond({modules: [row('Old')], filter: 'old', tree: 'tree1', complete: true,
    next_after: null, previous_before: null});
  await tick();
  assert.deepEqual(races.names(), ['New'], 'late responses cannot replace the newer filter');

  const advancing = setup({modules: [row('Old')], next_after: 'Old'});
  advancing.more();
  advancing.requests[0].respond({modules: [row('WrongPage')], filter: '', tree: 'tree2', complete: false,
    next_after: null, previous_before: 'WrongPage'});
  await tick();
  assert.equal(advancing.requests.length, 2, 'branch advancement restarts the listing');
  assert.equal(advancing.requests[1].url.searchParams.has('after'), false);
  advancing.requests[1].respond({modules: [row('Fresh')], filter: '', tree: 'tree2', complete: true,
    next_after: null, previous_before: null});
  await tick();
  assert.deepEqual(advancing.names(), ['Fresh'], 'does not mix trees when appending');

  const errors = setup({modules: [], complete: false});
  errors.type('example');
  await errors.flush();
  errors.requests[0].reject(new Error('Offline'));
  await tick();
  assert.match(errors.elements['module-status'].textContent, /Could not load/);
  errors.type('example::alpha');
  await errors.flush();
  assert.equal(errors.requests.length, 2, 'can fetch again after an error');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
