// The Listen lock-screen Practice widget draws Image("PracticeGlyph"). A
// missing or unbundled asset does not fail the build, it renders an empty
// circle on the lock screen, so these check the catalog is wired into the
// ListenControl target's Resources phase and the image is a template.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

test('PracticeGlyph exists as a template image with its file', () => {
  const set = 'ListenControl/Assets.xcassets/PracticeGlyph.imageset';
  const json = JSON.parse(read(`${set}/Contents.json`));
  assert.equal(json.properties['template-rendering-intent'], 'template');
  for (const img of json.images) assert.ok(fs.existsSync(path.join(ROOT, set, img.filename)), img.filename);
  assert.match(read('ListenControl/ListenControlBundle.swift'), /Image\("PracticeGlyph"\)/);
});

test('ListenControl target bundles its asset catalog', () => {
  const pbx = read('Overland.xcodeproj/project.pbxproj');
  const ref = pbx.match(/(\w{24}) \/\* Assets\.xcassets \*\/ = \{isa = PBXFileReference;[^}]*path = ListenControl\/Assets\.xcassets;/);
  assert.ok(ref, 'file reference for ListenControl/Assets.xcassets');
  const build = pbx.match(new RegExp(`(\\w{24}) /\\* Assets\\.xcassets in Resources \\*/ = \\{isa = PBXBuildFile; fileRef = ${ref[1]} `));
  assert.ok(build, 'build file for that reference');
  // The Resources phase the ListenControl native target lists.
  const target = pbx.match(/\/\* ListenControl \*\/ = \{\s*isa = PBXNativeTarget;[\s\S]*?(\w{24}) \/\* Resources \*\//);
  const phase = pbx.match(new RegExp(`${target[1]} /\\* Resources \\*/ = \\{[\\s\\S]*?files = \\(([\\s\\S]*?)\\);`));
  assert.ok(phase[1].includes(build[1]), 'asset catalog in ListenControl Resources phase');
});
