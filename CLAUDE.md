# Terminal Blending Dashboard

Presentation copy of the terminal dashboard. Derived from the working project at
`~/projects/Terminal-Dashboard/` (read-only reference — do not edit that repo from
here). Pages that normally call `ftw_terminal_server.py` still degrade to sample /
mock data when offline, by design — but Blend Case Manager and Blend Planner now
talk to a real Supabase project (prototype backend, added 2026-08-03/04).

## Development

This is a static, build-free site (no `package.json`, no bundler, no linter,
no JS test runner) deployed as-is via GitHub Pages — every HTML/JS file is
served verbatim. There is nothing to `npm install` or `npm run build`.

- **Run locally:** any static file server from the repo root, e.g.
  `python3 -m http.server`, then open `index.html` / `blend-case-manager.html`
  in a browser. Pages that hit Supabase need real network access to
  `*.supabase.co` and the `esm.sh` CDN (module imports for the Supabase JS
  client aren't vendored).
- **Tests:** no client-side test suite. The only automated tests are plain-SQL
  integration scripts in `supabase/tests/` (`01_...sql`–`08_...sql`) that
  exercise the Postgres RPCs directly — each wraps itself in
  `begin; ... rollback;` so it's safe to re-run against the live project. Run
  one with `psql "$DATABASE_URL" -f supabase/tests/01_concurrent_tank_conflict.sql`,
  via the Supabase SQL Editor, or the Supabase MCP `execute_sql` tool. See
  `supabase/tests/README.md` for what each file covers and why they're plain
  SQL rather than pgTAP.
- Before touching a page's Supabase wiring, read `docs/supabase-persistence.md`
  (full history of the persistence/hardening work, RPC surface, and known
  gaps) and `docs/prototype-backend-reset.md` (current data model). Both are
  long and narrate *why*, not just *what* — skim for the relevant section
  rather than re-deriving it from the HTML.

### Supabase prototype backend

- `assets/js/supabase-config.js` — checked-in project URL + publishable/anon key.
  This is intentional (see comment in the file): the site has no build step, so
  the anon key has to be a real committed value. Safe to expose per Supabase's
  design — access is enforced by Row Level Security, not by secrecy of this key.
  The service-role key must NEVER go in this file or anywhere else in this repo.
- `assets/js/supabase-client.js` — thin ES-module wrapper that constructs the
  Supabase client from `window.__SUPABASE_CONFIG__` (set by `supabase-config.js`).
- `assets/js/blend-repository.js` — compatibility adapter that keeps the existing
  `window.BlendRepo` API so `blend-case-manager.html` didn't need a workflow
  rewrite; internally does direct table ops against `blend_plans`, `blend_cases`,
  `terminal_state`. Load order matters and is fixed in `blend-case-manager.html`'s
  `<head>`: `supabase-config.js` (plain script) → `supabase-client.js` (module) →
  `blend-repository.js` (module) → the page's own inline `<script>`, which awaits
  a `blend-repo-ready` event before calling anything on `window.BlendRepo`.
- `supabase/migrations/` — numbered, ordered migrations (`00000000000001_...`
  through the current highest) that reflect the *live* project's actual schema
  history; each one is a real change that was applied and documented (often in
  `docs/supabase-persistence.md`). Don't reverse-engineer current schema from
  `prototype-reset.sql` alone — check the latest migrations for anything added
  since.
- `supabase/prototype-reset.sql` — schema for a *fresh* Supabase project. Do not
  run against the old project — it doesn't migrate old prototype data.
- `docs/prototype-backend-reset.md` — data model, planner→case transfer fields,
  setup steps, and deferred work (Storage-bucket file attachments not yet wired).
- The Blend Planner (separate repo, deployed at
  `pynnmichael-oss.github.io/blend-planner/`) must point at the same Supabase
  project URL/key for the planner→case-manager handoff to work. The planner's
  CI (`deploy-pages.yml`) fails the build if the production bundle references
  the retired Supabase project instead of the current one — see that repo's
  CLAUDE.md.

## Structure

- `index.html` — dashboard home: KPI tiles, Tank Farm panel (5 gasoline tanks —
  ULSD tanks intentionally dropped), Operations tile grid, Quality & Compliance
  tile grid.
- `receipt-schedule.html`, `blend-case-manager.html`, `lab-procedures.html`,
  `operator-proficiency.html`, `rack-demand-forecast.html` — standalone pages
  copied from the source project. Each links back to `index.html` via a
  `.back-link`-style anchor (`blend-case-manager.html` now has its own styled
  `← Dashboard` link — `.dashboard-only` class, not `.back-link` — this was
  previously unstyled/plain).
- `blend-case-manager.html` (currently V8.10.2) — beyond the working case
  view, has a dedicated `#archive` view (real `<table>`, reached via the
  header's "Closed Blends →" button) that closed blends move to instead of
  rendering inline; a "Closed Blends"/"Open records" toggle round-trips
  between the two. Planner-queue rows support soft-delete
  (`BlendRepo.updateBlendPlan(id, {status:'cancelled'})`, using the plan's
  `dbId` uuid — not the human-readable `plan_code`). Case abandonment is
  blocked once any truck delivery is `status:'complete'`, both client-side
  and in `abandonBlendCase` server-side.
- `fuels-snapshot.js`, `t4-schedule.js` — client-side parsers for the "Data Drop"
  feature on `index.html` (FuelsManager .xlsx export, T4 schedule paste). No
  network calls; state lives in the browser only.
- Blend Planner tile links externally to `https://pynnmichael-oss.github.io/blend-planner/`
  rather than a local file.
- `data/tanks.json` and `fuels-snapshot.js` are also **overwritten wholesale by
  CI** — `.github/workflows/update-tank-data.yml` fires on a `repository_dispatch`
  (`update_tank_data`), rebuilds both files from the dispatch payload, and pushes
  the commit itself. Hand-edits to either file will be silently clobbered by the
  next dispatch; treat `fuels-snapshot.js`'s generated content as owned by that
  workflow, not by hand. `.github/workflows/set-current-dashboard-date.yml`
  similarly rewrites the dashboard's static header date on every push to
  `master` that touches the workflow file itself.

## Explicitly excluded from this repo

Never copy these over from the source project — this repo runs its own Supabase
prototype backend (above), not the source project's local server/DB stack:
`ftw_terminal_server.py`, `ftw_terminal.db`, `ftw_terminal_data.json`,
`google-credentials.json`, `migrate_json_to_sqlite.py`, `venv/`, `.claude/`,
`CLAUDE.md` (the source project's own), `coa-review.html`, `spec-reference.html`,
`requirements.txt`, `start_server.sh`.

## Known gaps

- "Blend Documentation" tile on `index.html` links to `href="#"` — no dedicated
  page exists in the source project either. Flag before inventing content for it.
- "Sampling / Testing" tile links to an external PowerApps form, not a local page.

## Conventions

- When pulling a new tile or page from the source project, copy its markup/icons
  verbatim rather than rewriting — keeps visual consistency with the rest of the
  dashboard.
- Show a diff-style summary of HTML changes before committing.
- Repo: `github.com/Pynnmichael-oss/terminal-blending-dashboard` (public).
