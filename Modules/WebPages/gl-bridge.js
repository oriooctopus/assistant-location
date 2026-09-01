// Shared bridge client for the GL native<->web protocol v1. Load this as the
// FIRST script in <head>, with no `defer`/`async`, so it runs synchronously
// before the page's own <style>/<body> are parsed -- that ordering is what
// lets a plain `background: var(--gl-bg)` rule in CSS paint the right colour
// on the very first frame (no white flash) instead of racing a themed
// repaint in after load.
//
// Native -> page: window.__glReply(id, result, error) and
// window.__glThemeChanged(state) are both defined here. A page must not
// redefine either -- register a listener via GLBridge.onThemeChanged instead.
(function (global) {
  'use strict';

  // Read straight out of App/Assets.xcassets/GL*.colorset/Contents.json --
  // this is what renders when GL_BOOT.palette is null (first-ever launch,
  // no cached theme yet) or when the bridge is unavailable entirely (plain
  // browser / tests with no mock).
  var DEFAULT_PALETTE = {
    light: {
      bg: '#ffffff', surface: '#f2f2f7', text: '#000000',
      'text-dim': '#3c3c43', accent: '#007aff', danger: '#ff3b30'
    },
    dark: {
      bg: '#0d0f12', surface: '#1a1d22', text: '#ffffff',
      'text-dim': '#b2aeb2', accent: '#0a84ff', danger: '#ff453a'
    }
  };

  var PALETTE_KEYS = ['bg', 'surface', 'text', 'text-dim', 'accent', 'danger'];

  function systemPrefersDark() {
    try {
      return !!(global.matchMedia && global.matchMedia('(prefers-color-scheme: dark)').matches);
    } catch (e) {
      return false;
    }
  }

  function normalizeMode(mode) {
    return mode === 'dark' ? 'dark' : 'light';
  }

  function resolveBoot() {
    var boot = global.GL_BOOT;
    if (boot && typeof boot === 'object') {
      return {
        palette: (boot.palette && typeof boot.palette === 'object') ? boot.palette : null,
        mode: normalizeMode(boot.mode),
        themeId: boot.themeId != null ? boot.themeId : null,
        platform: boot.platform || 'ios'
      };
    }
    return {
      palette: null,
      mode: normalizeMode(systemPrefersDark() ? 'dark' : 'light'),
      themeId: null,
      platform: 'web'
    };
  }

  function applyTheme(palette, mode) {
    var resolvedMode = normalizeMode(mode);
    var fallback = DEFAULT_PALETTE[resolvedMode];
    var p = (palette && typeof palette === 'object') ? palette : fallback;
    var root = global.document.documentElement;
    root.dataset.theme = resolvedMode;
    var resolvedSurface = fallback.surface;
    for (var i = 0; i < PALETTE_KEYS.length; i++) {
      var key = PALETTE_KEYS[i];
      var value = (typeof p[key] === 'string' && p[key]) ? p[key] : fallback[key];
      root.style.setProperty('--gl-' + key, value);
      if (key === 'surface') resolvedSurface = value;
    }
    // Glass pair (design-tokens/build.mjs's NATIVE_COLOR_KEYS comment block
    // documents the source): `surface-translucent` carries color.surface's
    // TRUE alpha-preserving value, present only for themes that opt into
    // glass tiles (fx.backdrop-blur set) -- the plain `surface` above stays
    // the flattened-opaque value every existing consumer already expects.
    // Defaulting `--gl-surface-translucent` to the SAME resolved opaque
    // surface (not a separate fallback each page has to spell out) means a
    // page can write one `background: var(--gl-surface-translucent)` rule
    // that reads as ordinary opaque surface on every non-glass theme and
    // as real glass only where the palette actually supplies it.
    // `--gl-backdrop-blur` defaults to "none", a real (no-op) CSS
    // backdrop-filter value, not an unset custom property -- so
    // `backdrop-filter: var(--gl-backdrop-blur)` is always valid CSS.
    var translucentSurface = (typeof p['surface-translucent'] === 'string' && p['surface-translucent']) ? p['surface-translucent'] : resolvedSurface;
    root.style.setProperty('--gl-surface-translucent', translucentSurface);
    var blur = (typeof p['backdrop-blur'] === 'string' && p['backdrop-blur']) ? p['backdrop-blur'] : 'none';
    root.style.setProperty('--gl-backdrop-blur', blur);
    var gradient = p['bg-gradient'];
    if (gradient && Array.isArray(gradient.stops) && gradient.stops.length) {
      var stops = gradient.stops.map(function (s) {
        var pos = typeof s.position === 'number' ? Math.round(s.position * 100) + '%' : '';
        return s.color + ' ' + pos;
      }).join(', ');
      root.style.setProperty('--gl-bg-image', 'linear-gradient(' + (gradient.angle || 180) + 'deg, ' + stops + ')');
    } else {
      root.style.setProperty('--gl-bg-image', 'none');
    }
  }

  var boot = resolveBoot();
  // Synchronous: must happen before first paint, hence no DOMContentLoaded wait.
  applyTheme(boot.palette, boot.mode);

  var themeListeners = [];
  global.__glThemeChanged = function (state) {
    if (!state || typeof state !== 'object') return;
    applyTheme(state.palette, state.mode);
    if (state.themeId !== undefined) boot.themeId = state.themeId;
    boot.mode = normalizeMode(state.mode);
    boot.palette = (state.palette && typeof state.palette === 'object') ? state.palette : null;
    for (var i = 0; i < themeListeners.length; i++) {
      try { themeListeners[i](state); } catch (e) { /* one bad listener must not break the rest */ }
    }
  };

  var nextId = 1;
  var pending = Object.create(null);

  global.__glReply = function (id, result, error) {
    var entry = pending[id];
    if (!entry) return; // unknown or already-timed-out id: a late reply must never double-render
    delete pending[id];
    global.clearTimeout(entry.timer);
    if (error) entry.reject(new Error(error));
    else entry.resolve(result);
  };

  function bridgeAvailable() {
    return !!(global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers.gl);
  }

  function call(method, params) {
    if (!bridgeAvailable()) {
      return Promise.reject(new Error('bridge unavailable'));
    }
    var id = String(nextId++);
    return new Promise(function (resolve, reject) {
      var timer = global.setTimeout(function () {
        delete pending[id];
        reject(new Error('timeout'));
      }, 5000);
      pending[id] = { resolve: resolve, reject: reject, timer: timer };
      try {
        global.webkit.messageHandlers.gl.postMessage({ id: id, method: method, params: params || {} });
      } catch (e) {
        global.clearTimeout(timer);
        delete pending[id];
        reject(e);
      }
    });
  }

  global.GLBridge = {
    boot: boot,
    call: call,
    isAvailable: bridgeAvailable,
    onThemeChanged: function (fn) { themeListeners.push(fn); },
    applyTheme: applyTheme,
    DEFAULT_PALETTE: DEFAULT_PALETTE
  };
})(window);
