-- 00000000000009_dev_seed.sql
--
-- Small, idempotent development seed: one proposed plan + one open case
-- with a delivery and an event, enough to validate that the Blend Case
-- Manager list/detail views load real Supabase data end to end. Safe to
-- re-run (guarded by not-exists checks); does not touch the RPCs.

insert into public.blend_plans (
  plan_code, label, grade, tank, tank_no, window_start, window_end,
  est_pumpable_bbl, est_tov_bbl, incoming_rvp, target_rvp, butane_bbl,
  trucks, blended_rvp, truck_start, truck_finish, status, source_week, assumption
)
select
  'PLAN-2026-W31-02', 'Blend 2', 'REGULAR', 'TK 56', '23156',
  '2026-07-29 00:00', '2026-07-29 17:59',
  28217, 32624, 8.076, 8.85, 585,
  4, 8.850, '2026-07-29 00:00', '2026-07-29 11:59',
  'proposed', '07/28/2026',
  'Based on planned receipts, rack liftings, and estimated incoming-batch RVP.'
where not exists (
  select 1 from public.blend_plans where plan_code = 'PLAN-2026-W31-02'
);

do $$
declare
  v_case_id uuid;
begin
  if not exists (select 1 from public.blend_cases where case_number = 'BL-2026-0312') then
    select (public.create_blend_case(
      p_case_number => 'BL-2026-0312',
      p_operator => 'D. Bass',
      p_pq => 'S. Anderson',
      p_tank => 'TK 55',
      p_grade => 'REGULAR',
      p_tank_no => '23155',
      p_row_label => 'Blend 1',
      p_planned_est_vol_bbl => 43312,
      p_planned_est_rvp => 8.200,
      p_created_by => 'D. Bass',
      p_deliveries => '[]'::jsonb
    )).id into v_case_id;
  end if;
end $$;
