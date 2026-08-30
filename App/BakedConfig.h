// Build-time configuration for the main app.
//
// Mirrors ShareToDesktop/ShareConfig.h: the host and token are NOT stored in
// git. CI overwrites this file from the DROP_HOST and DROP_TOKEN repo secrets
// before xcodebuild runs (see .github/workflows/build.yml and ota.yml). A
// local or simulator build keeps the placeholders below, and GLManager then
// leaves whatever is already stored in NSUserDefaults alone rather than
// clobbering a working config with a non-host/non-token.
//
// GL_BAKED_HOST is the one secret value (host only, no port/path); every
// build-time URL in the app (see Shared/GLEndpoints.h, Modules/Events,
// Modules/Todos) composes its own endpoint from this host plus its own
// port/path, so only a single value needs to be injected.
//
// This app has exactly one user, so there is nothing to configure: every
// launch forces the stored endpoint and access token back to these values, so
// the config cannot drift, be mistyped, or be lost across a reinstall.

#define GL_BAKED_HOST @"NO_HOST_BAKED_IN"
#define GL_BAKED_TOKEN @"NO_TOKEN_BAKED_IN"

// The commit this build was compiled from. Baked from $GITHUB_SHA (see
// ota.yml / device-farm-build.yml), not a secret — this exists so a report
// from a running install (GLAppStateReporter) can say exactly what code is
// on the device, instead of only a human-typed build stamp string.
#define GL_BAKED_COMMIT @"NO_COMMIT_BAKED_IN"
