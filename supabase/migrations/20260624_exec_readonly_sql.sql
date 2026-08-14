-- ────────────────────────────────────────────────────────────────────
-- 20260624_exec_readonly_sql
-- ────────────────────────────────────────────────────────────────────
--
-- Backs the assistant's `run_read_query` tool with a Postgres RPC
-- that can execute any SELECT the model needs, safely.
--
-- Safety layers (defence in depth):
--
--   Layer 1 — client (edge function, in TypeScript):
--     • Rejects non-SELECT statements via regex before the RPC call
--     • Blocks references to auth.*, storage.*, realtime.*, cron.*,
--       pg_*, vault.*, information_schema.* schemas
--     • Auto-appends `LIMIT 200` if the query doesn't have one
--     • Strips sensitive columns (encrypted_password, token_hash,
--       refresh_token, secret_key etc.) from every row before
--       returning to the model
--
--   Layer 2 — this function (Postgres, SECURITY DEFINER not needed):
--     • Wraps the user SQL as `SELECT jsonb_agg(row_to_json(t))
--       FROM (<user_sql>) t`. This inline subquery makes it
--       structurally impossible to run INSERT / UPDATE / DELETE /
--       DDL because those cannot appear as a subquery in Postgres
--       (data-modifying CTEs are also rejected when nested).
--     • `SET statement_timeout = '10s'` at function-definition level
--       stops runaway queries.
--
--   Layer 3 — grants:
--     • Only `service_role` can EXECUTE this function. That means
--       only the edge function backend (which has SUPABASE_SERVICE_
--       ROLE_KEY) can invoke it. Neither `anon` nor `authenticated`
--       (i.e. the Flutter client using the anon key + a user JWT)
--       can call it directly.
--
-- What the function does NOT do:
--   • No column filtering — that's the client's job (needs the row
--     shape to strip specific column names case-insensitively).
--   • No authentication check — the edge function has already
--     validated the caller as admin|trainer before dispatching.
--     `auth.uid()` inside this function would be NULL anyway because
--     the edge function calls with the service_role key.
--
-- Additive + idempotent.
-- ────────────────────────────────────────────────────────────────────

create or replace function public.exec_readonly_sql(query text)
returns jsonb
language plpgsql
set statement_timeout to '10s'
as $$
declare
  result jsonb;
begin
  -- Wrap the user query as a subquery. Postgres rejects INSERT/UPDATE/
  -- DELETE/DDL in a subquery position, so if `query` contains a DML
  -- statement the outer SELECT fails at parse time rather than
  -- mutating data.
  execute format(
    'select coalesce(jsonb_agg(row_to_json(t)), ''[]''::jsonb) from (%s) t',
    query
  ) into result;
  return coalesce(result, '[]'::jsonb);
exception
  when others then
    -- Return the error as JSON so the edge function can surface it
    -- to the model without crashing the request.
    return jsonb_build_object(
      'eroare', SQLERRM,
      'sqlstate', SQLSTATE
    );
end;
$$;

comment on function public.exec_readonly_sql(text) is
  'Executes an arbitrary SELECT as a subquery and returns the rows as jsonb. '
  'Called by the tth_assistant edge function''s run_read_query tool. '
  'Safe because DML/DDL cannot appear as a subquery in Postgres, and '
  'statement_timeout is capped at 10s. Only callable by service_role.';

-- Lock down execution to service_role only. Anon + authenticated
-- users must not be able to call this via PostgREST directly.
revoke all on function public.exec_readonly_sql(text) from public;
revoke all on function public.exec_readonly_sql(text) from anon;
revoke all on function public.exec_readonly_sql(text) from authenticated;
grant execute on function public.exec_readonly_sql(text) to service_role;
