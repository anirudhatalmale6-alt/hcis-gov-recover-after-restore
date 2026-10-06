-- ============================================================================
--  HCIS - the account-management functions should not answer strangers
--
--  PostgreSQL grants EXECUTE on a new function to PUBLIC by default. So while
--  30_nars_and_access_control.sql took the anonymous role's own grants away,
--  these five kept working for anybody, because PUBLIC still had them:
--
--      hcis_admin_create_user   hcis_admin_update_user
--      hcis_admin_set_status    hcis_admin_set_password
--      hcis_admin_delete_user
--
--  This was NOT an open door. Every one of them checks the session token and
--  refuses anybody who is not a super administrator - an unauthenticated call
--  to create an administrator was tried and came back "Not permitted.", having
--  created nothing. But there is no reason for a stranger to be able to make
--  the attempt at all, or to sit there guessing session tokens against them.
--
--  After this, those calls are refused before they reach any code.
--
--  The grant is removed from PUBLIC rather than from the anonymous role,
--  because taking it from the role is what did not work last time.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname LIKE 'hcis\_admin\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
  END LOOP;
END $$;

-- Changing your own password needs a session, so it needs no anonymous access
-- either. Signing in is the only thing a stranger legitimately does.
DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'hcis_change_password'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Check it before committing: nothing whose name begins hcis_admin_ may be
-- callable without signing in.
-- ---------------------------------------------------------------------------
DO $$
DECLARE still_open TEXT;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO still_open
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND (p.proname LIKE 'hcis\_admin\_%' OR p.proname = 'hcis_change_password')
     AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF still_open IS NOT NULL THEN
    RAISE EXCEPTION
      'These can still be called without signing in: %', still_open;
  END IF;
END $$;

-- And the reverse, so this file cannot lock the administration screen out of
-- its own functions.
DO $$
DECLARE missing TEXT;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO missing
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND (p.proname LIKE 'hcis\_admin\_%' OR p.proname = 'hcis_change_password')
     AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE');
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION
      'Signed-in users can no longer call these, which breaks the administration screen: %', missing;
  END IF;
END $$;

COMMIT;

-- PostgREST reads the database structure once when it starts. Tell it to look
-- again, or it will keep answering from what it learned earlier.
NOTIFY pgrst, 'reload schema';
