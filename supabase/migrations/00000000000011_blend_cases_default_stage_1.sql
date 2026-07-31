-- The app's own case model (makeCase() in blend-case-manager.html) has
-- always defaulted a freshly-created case to stage 1 (Open Gauge & Sample).
-- Stage 0 ("Plan Source") is a pure display label for where a case came
-- from -- it has no action button and no case is ever meant to actually
-- sit there. The blend_cases table incorrectly defaulted new rows to
-- stage 0, which silently traps every newly promoted case on an inert
-- read-only panel (and makes recordOpenGauge()'s `c.stage !== 1` guard
-- fail silently). Fix the default going forward.
alter table public.blend_cases alter column stage set default 1;
comment on column public.blend_cases.stage is
  'App lifecycle position, 0-9 (see STAGES in blend-case-manager.html). Defaults to 1 (Open Gauge & Sample) -- stage 0 (Plan Source) is a display-only label a live case should never actually be created at.';
