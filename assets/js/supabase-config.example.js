// supabase-config.example.js
//
// This is a static site with no build step, so there is no process.env /
// bundler to inject environment variables into the browser bundle. The
// convention used here instead:
//
//   1. Copy this file to `supabase-config.js` (same folder).
//   2. Fill in your project's URL and anon/publishable key below.
//   3. `supabase-config.js` is gitignored -- it never gets committed.
//
// Only the PUBLIC anon/publishable key belongs here. It is safe to expose
// in browser code by design (Supabase enforces access via Row Level
// Security policies, not by keeping this key secret). The service-role key
// must NEVER be put in this file or anywhere else under this static site --
// it belongs only in a trusted server environment, which this prototype
// does not have.
window.__SUPABASE_CONFIG__ = {
  url: 'https://YOUR-PROJECT-REF.supabase.co',
  anonKey: 'YOUR-ANON-OR-PUBLISHABLE-KEY',
};
