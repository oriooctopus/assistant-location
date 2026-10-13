// Loads GripesApp/web/gripes-core.js the way the browser does (classic script,
// global GripesCore). require() cannot be used: an ancestor package.json has
// "type": "module", so Node would parse the .js as ESM and export nothing.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const file = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../GripesApp/web/gripes-core.js');
// Same realm as the tests (runInThisContext): a separate vm context would make
// every returned array fail assert.deepStrictEqual on prototype identity.
vm.runInThisContext(fs.readFileSync(file, 'utf8'), { filename: file });
if (!globalThis.GripesCore) throw new Error('gripes-core.js did not define GripesCore');
export default globalThis.GripesCore;
