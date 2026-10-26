// Placeholder. The ota-due and testflight-due workflows overwrite this file at build time from the DUE_SERVER_URL secret; never commit the result.
// The bearer token is not baked: it comes from the in-app login and lives in the Keychain (Keychain.swift).
enum Baked {
    static let server = "NO_SERVER_BAKED_IN"
}
