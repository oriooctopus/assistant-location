// Loads ListsApp/web/lists-dict.js then lists-core.js the way the browser does
// (classic scripts, globals ListsDict / ListsCore). Same approach as gripes-load.mjs.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../ListsApp/web');
for (const f of ['lists-dict.js', 'lists-core.js']) {
  const file = path.join(dir, f);
  vm.runInThisContext(fs.readFileSync(file, 'utf8'), { filename: file });
}
if (!globalThis.ListsCore || !globalThis.ListsDict) throw new Error('lists scripts did not define their globals');
export default globalThis.ListsCore;
export const Dict = globalThis.ListsDict;
