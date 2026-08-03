// Build-time configuration for the share extension.
//
// The token is NOT stored in git. CI overwrites this file from the DROP_TOKEN
// repo secret before xcodebuild runs (see .github/workflows/build.yml). A local
// or simulator build keeps the placeholder below, and the extension refuses to
// upload with it — a build without a baked-in token must fail loudly rather
// than silently posting an unauthenticated request.
//
// App Groups would be the "proper" way to share the token with the container
// app, but that needs a group capability registered with Apple; baking it in at
// build time keeps the provisioning surface to a single extra bundle id.
//
// Path-free, mirroring App/BakedConfig.h's GL_BAKED_BASE_URL: the
// extension's single job is /drop, so ShareViewController.m appends that
// path explicitly rather than baking a full URL here.

#define GLDropBaseURL @"http://100.103.237.24:8302"
#define GLDropToken @"NO_TOKEN_BAKED_IN"
