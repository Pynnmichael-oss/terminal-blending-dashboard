// Fort Worth Blend Case Manager -- Supabase connection config.
// This key is the anon/public key: safe to ship in a browser bundle.
// All privileged mutation logic lives server-side in Postgres RPC
// functions (see supabase/migrations); this key can only SELECT the
// underlying tables directly and EXECUTE the whitelisted RPCs.
window.__SUPABASE_CONFIG__ = {
  url: 'https://iefjhifomettmfkxidsq.supabase.co',
  anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImllZmpoaWZvbWV0dG1ma3hpZHNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU3Nzk5MjIsImV4cCI6MjEwMTM1NTkyMn0.z9xjUi_jCnKFprjBFvefcnaUY4RIFfGhd-3WVEbrcE0'
};
