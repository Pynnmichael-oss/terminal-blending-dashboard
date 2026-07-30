-- 00000000000023_revoke_public_execute_on_superseded_rpcs.sql
--
-- Fixes a real gap in the hardening pass: migrations 017/018 revoked
-- EXECUTE on change_blend_case_status and delete_blend_case from
-- `anon, authenticated`, but Postgres grants EXECUTE to the PUBLIC
-- pseudo-role by default when a function is created, and neither
-- migration revoked that. Every role (including anon/authenticated)
-- implicitly inherits PUBLIC's grants, so the previous revoke had no
-- actual effect: has_function_privilege('anon', ..., 'EXECUTE') for both
-- functions still returned true after migration 022, confirmed while
-- writing supabase/tests/05_stage_skip_rejection.sql. In practice this
-- meant the old arbitrary-stage/status RPC and the permanent-delete RPC
-- remained fully callable by anyone holding the anon key the entire
-- time -- undermining the lifecycle-enforcement RPCs and the
-- abandonment-preserves-everything guarantee this pass's other
-- migrations exist to provide.
--
-- The other 21 SECURITY DEFINER functions added in this pass also carry
-- the same implicit PUBLIC grant, but it's a no-op for them: they're
-- intentionally callable by anon/authenticated (the only real caller of
-- this anon-key-only, no-auth browser app) via their own explicit grants
-- already, so PUBLIC having it too adds no new exposure. Only these two
-- superseded functions -- meant to be unreachable -- needed this fix.

revoke execute on function public.change_blend_case_status(uuid, text, smallint, text, text, text) from public;
revoke execute on function public.delete_blend_case(uuid, text) from public;
