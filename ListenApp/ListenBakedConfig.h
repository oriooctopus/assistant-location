// Build-time configuration for the Listen app. CI (ota-listen.yml) overwrites
// this file from the DROP_HOST repo secret before xcodebuild runs; the host
// never lives in git. A local/simulator build keeps the placeholder.
#define GL_BAKED_HOST @"NO_HOST_BAKED_IN"
