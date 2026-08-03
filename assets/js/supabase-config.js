// supabase-config.js
// This file IS committed to the repo (unlike a typical .env file) because
// this is a plain static site served by GitHub Pages with no build step --
// there is nothing to inject environment variables at deploy time, so the
// config has to be a real, checked-in file for the deployed site to work.
// This is safe: it contains only the project URL and the anon/publishable
// key, which Supabase is explicitly designed to expose in browser code --
// access is enforced by Row Level Security policies, not by keeping this
// key secret. The service-role key must NEVER go in this file or anywhere
// else in this static site.
window.__SUPABASE_CONFIG__ = {
  url: 'https://iefjhifomettmfkxidsq.supabase.co',
  anonKey: 'sb_publishable_cSSRdJIb_72crwXcy5wscg_lDQWJn-4',
};
