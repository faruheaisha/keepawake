'use strict';

// Historical audit reproduction: fake fetch never resolves; no browser or network used.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'dashboard/app.js'), 'utf8');
const pieces = ['api', 'loadState', 'tick'].map((name) => {
  const found = source.match(new RegExp('async function ' + name + '\\([^]*?\\n\\}'));
  if (!found) throw new Error('Missing function ' + name);
  return found[0];
});
const context = {
  state: { stopping: false }, calls: 0, KA: { lang: 'en' },
  H: { 'X-Ka-Client': 'ka-dashboard' }
};
context.fetch = () => { context.calls++; return new Promise(() => {}); };
vm.createContext(context);
vm.runInContext(pieces.join('\n') + '\ntick(); tick(); tick();', context);
const result = {
  check: 'pending-state-polls', unresolvedRequests: context.calls,
  hasAbortController: /AbortController/.test(source)
};
const out = path.join(root, '_tmp/audit-20261031');
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'frontend-results.json'), JSON.stringify(result, null, 2));
console.log(JSON.stringify(result));
if (context.calls !== 3 || result.hasAbortController) process.exitCode = 1;
