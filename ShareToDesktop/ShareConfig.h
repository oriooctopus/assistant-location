// Build-time configuration for the share extension.
//
// The host and token are NOT stored in git. CI overwrites this file from the
// DROP_HOST and DROP_TOKEN repo secrets before xcodebuild runs (see
// .github/workflows/build.yml and ota.yml). A local or simulator build keeps
// the placeholders below, and the extension refuses to upload with them — a
// build without a baked-in host/token must fail loudly rather than silently
// posting an unauthenticated (or unreachable) request.
//
// This extension is a separate build target without header-search access to
// App/BakedConfig.h, so it gets its own host macro (same DROP_HOST secret,
// substituted directly by CI) rather than importing GL_BAKED_HOST.
//
// App Groups would be the "proper" way to share the token with the container
// app, but that needs a group capability registered with Apple; baking it in at
// build time keeps the provisioning surface to a single extra bundle id.
//
// Path-free, mirroring App/BakedConfig.h's GL_BAKED_HOST: the extension's
// single job is /drop, so ShareViewController.m composes host + port + path
// itself rather than baking a full URL here.

#define GLDropHost @"NO_HOST_BAKED_IN"
#define GLDropToken @"NO_TOKEN_BAKED_IN"
