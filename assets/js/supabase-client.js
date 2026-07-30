// supabase-client.js
//
// This project has no bundler/build step (plain static HTML + inline
// scripts), so we load the official supabase-js client straight from a
// CDN as an ES module and construct a single shared client using the
// anon/publishable key from supabase-config.js. This file must be loaded
// with <script type="module"> AFTER supabase-config.js.
//
// The browser client only ever uses the anon/publishable key. The
// service-role key is never referenced anywhere in this static site.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cfg = window.__SUPABASE_CONFIG__;

if (!cfg || !cfg.url || !cfg.anonKey || cfg.url.includes('YOUR-PROJECT-REF')) {
  console.error(
    '[supabase-client] Missing configuration. Copy assets/js/supabase-config.example.js ' +
    'to assets/js/supabase-config.js and fill in your project URL + anon key.'
  );
}

export const supabase = createClient(cfg?.url, cfg?.anonKey, {
  auth: {
    // No authentication system exists in this prototype yet (see the RLS
    // migration for the documented risk). Persisting a session is
    // pointless without login, so we disable it explicitly.
    persistSession: false,
  },
});
