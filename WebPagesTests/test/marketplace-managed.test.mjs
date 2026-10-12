// Wiring guard: the Marketplace app must load questions.html through the managed-page
// cache (bundle floor + server updates), not straight from the bundle, and the events
// server must be able to publish it (the whole WebPages/ dir is one manifest set).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

test('MarketplaceViewController loads via GLWebPageCache, not the bundle directly', () => {
  const m = read('MarketplaceApp/MarketplaceViewController.m');
  assert.match(m, /#import "GLWebPageCache\.h"/);
  assert.match(m, /GLWebPageCacheActiveDirectory\(\)/);
  assert.match(m, /GLWebPageCacheCheckForUpdates\(/);
  assert.doesNotMatch(m, /URLForResource:@"questions"/);
});

test('cache bundle-floor lookup can anchor on questions.html (Marketplace bundles no more.html)', () => {
  assert.match(read('Shared/GLWebPageCache.h'), /@\[@"more", @"questions"\]/);
});

test('Marketplace target can import Shared/GLWebPageCache.h and still bundles the floor files', () => {
  assert.match(read('scripts/add_marketplace_app.rb'), /\$\(SRCROOT\)\/Shared/);
  const pbx = read('Overland.xcodeproj/project.pbxproj');
  assert.equal(pbx.split('"$(SRCROOT)/Shared",\n\t\t\t\t\t"$(SRCROOT)/MarketplaceApp"').length - 1, 2);
});

test('questions.html + its siblings exist in WebPages/ for the manifest to publish', () => {
  for (const f of ['questions.html', 'page.css', 'gl-bridge.js']) {
    assert.ok(fs.existsSync(path.join(ROOT, 'Modules/WebPages', f)), f);
  }
});
