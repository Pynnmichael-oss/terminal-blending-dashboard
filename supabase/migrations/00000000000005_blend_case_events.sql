-- 00000000000005_blend_case_events.sql
--
-- blend_case_events is the append-only operational history for a case,
-- matching state.cases[].log[] in the app (event(who, text, type)).
-- Rows are only ever inserted, never updated or deleted -- there is
-- deliberately no updated_at column and no UPDATE/DELETE policy granted
-- (see RLS migration).

create table if not exists public.blend_case_events (
  id                uuid primary key default gen_random_uuid(),
  blend_case_id     uuid not null references public.blend_cases (id) on delete cascade,
  event_type        text not null default 'note'
                       check (event_type in (
                         'created', 'stage_change', 'status_change', 'hold',
                         'note', 'delivery', 'gauge', 'certification', 'system'
                       )),
  previous_status   text,
  new_status        text,
  previous_stage    smallint,
  new_stage         smallint,
  message           text not null, -- human-readable text (c.log[].text)
  event_data        jsonb not null default '{}'::jsonb,
  created_by        text not null default 'system', -- c.log[].who
  created_at        timestamptz not null default now()
);

comment on table public.blend_case_events is
  'Append-only audit trail for a blend case (case audit trail panel). Mirrors state.cases[].log[]; insert-only by design.';

create index if not exists blend_case_events_case_idx on public.blend_case_events (blend_case_id, created_at desc);
create index if not exists blend_case_events_type_idx on public.blend_case_events (event_type);
