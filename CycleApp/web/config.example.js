// Copy to config.js (gitignored) and fill in. The build step generates config.js
// from the private env file; nothing real is ever committed.
window.CYCLE_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT.supabase.co',
  supabaseAnonKey: 'YOUR-ANON-KEY',   // anon key only; the service key never ships in the client
  boxUrl: 'https://YOUR-BOX-HOST/cycle' // rewrite + backup server; empty string disables both
};
