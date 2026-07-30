-- 00000000000010_blend_plans_tank_no_nullable.sql
--
-- Blend-Planner (github.com/Pynnmichael-oss/Blend-Planner) is the actual
-- upstream producer of blend_plans rows. It only knows a short tank id/label
-- (e.g. "TK55" / "Tank 55") from its terminal config -- it has no concept of
-- the physical tank asset tag (e.g. "23155") that the execution/Case Manager
-- side uses. Rather than require Blend-Planner to fabricate that value,
-- relax the constraint so it can be omitted.

alter table public.blend_plans alter column tank_no drop not null;

comment on column public.blend_plans.tank_no is
  'Physical tank asset tag (e.g. 23155). Optional -- Blend-Planner only knows the short tank id/label, not this asset numbering.';
