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

#define GL_BAKED_ENDPOINT @"http://100.103.237.24:8302/overland"
#define GL_BAKED_TOKEN @"NO_TOKEN_BAKED_IN"
