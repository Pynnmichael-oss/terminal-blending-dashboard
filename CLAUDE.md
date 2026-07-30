# Terminal Blending Dashboard

Static, presentation-only copy of the terminal dashboard. Derived from the working
project at `~/projects/Terminal-Dashboard/` (read-only reference — do not edit that
repo from here). No backend: nothing in this repo talks to a server, a database, or
credentials. Pages that normally call `ftw_terminal_server.py` degrade to sample /
mock data when offline, by design.

## Structure

- `index.html` — dashboard home: KPI tiles, Tank Farm panel (5 gasoline tanks —
  ULSD tanks intentionally dropped), Operations tile grid, Quality & Compliance
  tile grid.
- `receipt-schedule.html`, `blend-case-manager.html`, `lab-procedures.html`,
  `operator-proficiency.html`, `rack-demand-forecast.html` — standalone pages
  copied from the source project. Each links back to `index.html` via a
  `.back-link`-style anchor (or, on `blend-case-manager.html`, a plain `<a>` —
  that file has no `.back-link` CSS rule defined, so the link is currently
  unstyled).
- `fuels-snapshot.js`, `t4-schedule.js` — client-side parsers for the "Data Drop"
  feature on `index.html` (FuelsManager .xlsx export, T4 schedule paste). No
  network calls; state lives in the browser only.
- Blend Planner tile links externally to `https://pynnmichael-oss.github.io/blend-planner/`
  rather than a local file.

## Explicitly excluded from this repo

Never copy these over from the source project — this is a static handout, not a
working deployment:
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
