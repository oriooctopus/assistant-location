// Build-time configuration for the main app.
//
// Mirrors ShareToDesktop/ShareConfig.h: the token is NOT stored in git. CI
// overwrites this file from the DROP_TOKEN repo secret before xcodebuild runs
// (see .github/workflows/build.yml). A local or simulator build keeps the
// placeholder below, and GLManager then leaves whatever is already stored in
// NSUserDefaults alone rather than clobbering a working config with a
// non-token.
//
// This app has exactly one user, so there is nothing to configure: every
// launch forces the stored endpoint and access token back to these values, so
// the config cannot drift, be mistyped, or be lost across a reinstall.
//
// Deliberately path-free: this base URL is shared app-wide config, and
// baking a feature-specific path (e.g. "/overland") in here invites other
// features to derive their own path from it by string surgery. Each
// feature builds its own full URL via GLEndpointURL(path) — see
// Shared/GLEndpoints.h.

#define GL_BAKED_BASE_URL @"http://100.103.237.24:8302"
#define GL_BAKED_TOKEN @"NO_TOKEN_BAKED_IN"
