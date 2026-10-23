// Build-time configuration for the Listen app. CI (ota-listen.yml) overwrites
// this file from the DROP_HOST repo secret before xcodebuild runs; the host
// never lives in git. A local/simulator build keeps the placeholder.
#define GL_BAKED_HOST @"NO_HOST_BAKED_IN"
// The guest build (testflight-listen-guest.yml) also bakes the full page URL, path
// prefix included, and the passcode cookie the server's gate expects, so the guest
// never sees the passcode page. Empty = https://GL_BAKED_HOST:9315/, no cookie.
#define GL_BAKED_BASE_URL @""
#define GL_BAKED_GUEST_COOKIE @""
