// Every module that lands in the More grid must ship its own icon in
// more.html's MODULE_ICONS -- the plain-square FALLBACK_ICON is a bug marker,
// not an acceptable default (MODULES.md, "More-grid icons").
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MODULES_DIR = path.join(HERE, '../../Modules');
const VISIBLE_TAB_COUNT = 4; // GLModuleRegistry: first 4 by order are real tab-bar items

function moreModuleIds() {
  const entries = [];
  for (const dir of fs.readdirSync(MODULES_DIR)) {
    const full = path.join(MODULES_DIR, dir);
    if (!fs.statSync(full).isDirectory()) continue;
    for (const f of fs.readdirSync(full).filter((n) => n.endsWith('.m'))) {
      const text = fs.readFileSync(path.join(full, f), 'utf8');
      const order = text.match(/\+\s*\(NSInteger\)\s*moduleOrder\s*\{\s*return\s+(-?\d+)\s*;/);
      const impl = text.match(/@implementation\s+(\w+)/);
      if (order && impl) entries.push([Number(order[1]), `GLModule.${impl[1]}`]);
    }
  }
  entries.sort((a, b) => a[0] - b[0]);
  return entries.slice(VISIBLE_TAB_COUNT).map((e) => e[1]);
}

test('every More-grid module has an entry in MODULE_ICONS', () => {
  const html = fs.readFileSync(path.join(MODULES_DIR, 'WebPages/more.html'), 'utf8');
  const block = html.match(/var MODULE_ICONS = \{([\s\S]*?)\n  \};/);
  assert.ok(block, 'more.html has no MODULE_ICONS object');
  const iconIds = new Set([...block[1].matchAll(/^    '(GLModule\.\w+)'/gm)].map((m) => m[1]));
  const ids = moreModuleIds();
  assert.ok(ids.length >= 5, `expected several More modules, parsed ${ids.length}`);
  const missing = ids.filter((id) => !iconIds.has(id));
  assert.deepEqual(missing, [], `More-grid modules with no MODULE_ICONS entry: ${missing.join(', ')}`);
});
