// Builds an init-script source string that stands in for the native GL
// bridge (window.webkit.messageHandlers.gl / window.__glReply /
// window.__glThemeChanged) for Playwright tests, per the frozen bridge
// protocol v1. Inject via `context.addInitScript(buildMockBridgeScript(...))`
// (or `page.addInitScript(...)`) BEFORE navigating, so it exists before the
// page's own gl-bridge.js parses.
//
// config shape:
//   boot: the GL_BOOT object to set (or omit/null to leave GL_BOOT undefined,
//         simulating a plain browser with no native host)
//   responses: { [method]: value }        -- resolves the call with `value`
//   errors:    { [method]: 'message' }     -- rejects the call with `message`
//   delays:    { [method]: milliseconds }  -- delay before replying
//   neverReply: [method, ...]              -- swallow the call entirely (timeout)
//
// Any of responses/errors/delays may instead be an ARRAY, to give the Nth
// call to that method (0-indexed) its own value -- e.g.
// `delays: { setTheme: [300, 20] }` makes the FIRST setTheme call reply after
// 300ms and the SECOND after 20ms, so the second reply can land before the
// first even though it was sent later. This is what lets a test exercise a
// stale-reply guard for real, instead of relying on same-tick resolution
// order (which previously made those guards untestable -- both replies just
// resolved in call order and the guard was never on the critical path). A
// call past the end of the array reuses its last entry. Plain (non-array)
// values keep their old meaning unchanged, so existing configs still work.
//
// Every received call is appended to window.__glCallLog ({id, method, params}).
// window.__glMock.configure(partial) merges new config at runtime (e.g. to
// change a response before the next call, or to fire a late reply after a
// timeout has already elapsed).
export function buildMockBridgeScript(config) {
  const initial = JSON.stringify(config || {});
  return `(function () {
    window.GL_BOOT = ${JSON.stringify((config && config.boot) || null)};
    window.__glCallLog = [];
    var cfg = ${initial};
    var pendingTimers = [];
    var callCounts = {}; // per-method call index, for sequenced (array) config values

    // Array config values are sequenced by call index (clamped to the last
    // entry once calls exceed the array length); scalar values apply to
    // every call, exactly as before this per-call feature was added.
    function pickSequenced(val, n) {
      if (Array.isArray(val)) return val.length ? val[Math.min(n, val.length - 1)] : undefined;
      return val;
    }

    function respond(id, method, n) {
      var neverReply = cfg.neverReply || [];
      if (neverReply.indexOf(method) !== -1) return;
      var errVal = cfg.errors ? pickSequenced(cfg.errors[method], n) : undefined;
      var hasError = errVal !== undefined && errVal !== null;
      var resVal = cfg.responses ? pickSequenced(cfg.responses[method], n) : undefined;
      var result = (!hasError && resVal !== undefined) ? resVal : {};
      if (typeof window.__glReply === 'function') {
        window.__glReply(id, hasError ? null : result, hasError ? errVal : null);
      }
    }

    window.webkit = window.webkit || {};
    window.webkit.messageHandlers = window.webkit.messageHandlers || {};
    window.webkit.messageHandlers.gl = {
      postMessage: function (msg) {
        window.__glCallLog.push({ id: msg.id, method: msg.method, params: msg.params });
        var n = callCounts[msg.method] || 0;
        callCounts[msg.method] = n + 1;
        var delayVal = cfg.delays ? pickSequenced(cfg.delays[msg.method], n) : undefined;
        var delay = typeof delayVal === 'number' ? delayVal : 0;
        var t = setTimeout(function () { respond(msg.id, msg.method, n); }, delay);
        pendingTimers.push(t);
      }
    };

    window.__glMock = {
      configure: function (partial) {
        partial = partial || {};
        for (var key in partial) {
          if (key === 'responses' || key === 'errors' || key === 'delays') {
            cfg[key] = Object.assign({}, cfg[key] || {}, partial[key]);
          } else if (key === 'neverReply') {
            cfg.neverReply = partial.neverReply;
          } else {
            cfg[key] = partial[key];
          }
        }
      },
      // Fires a reply for the most recent call to a given method right now,
      // bypassing its configured delay/neverReply -- used to simulate a
      // "late reply after timeout" arriving after a test's own wait.
      replyNow: function (method, result, error) {
        var calls = window.__glCallLog.filter(function (c) { return c.method === method; });
        var last = calls[calls.length - 1];
        if (!last) return;
        window.__glReply(last.id, error ? null : (result !== undefined ? result : {}), error || null);
      }
    };
  })();`;
}
