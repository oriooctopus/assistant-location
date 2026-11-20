import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');

test('main app is named Superapp on the home screen', () => {
  assert.match(read('App/Info.plist'), /<key>CFBundleDisplayName<\/key>\s*<string>Superapp<\/string>/);
  const pbx = read('Overland.xcodeproj/project.pbxproj');
  assert.doesNotMatch(pbx, /Overland GPS Tracker/);
});
