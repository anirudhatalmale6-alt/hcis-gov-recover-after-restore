-- ============================================================================
--  Stop every new table being public the moment it is created
--
--  WHAT HAPPENED
--
--  On 15 September the anonymous role was stripped of every table grant, and
--  an unauthenticated request got 401 on everything. Verified at the time.
--
--  On 16 September I added a view, nars_awaiting_hcis, listing assessments
--  waiting to reach HCIS - reference, NAME, IDENTITY NUMBER, band, reason. I
--  granted SELECT on it to the signed-in role and nothing else.
--
--  A survey the next morning found that view readable by anybody, with no
--  sign-in, over HTTP. Names and identity numbers.
--
--  THE CAUSE
--
--  This database carries default privileges:
--
--    owner=postgres schema=public objtype=r acl={anon=arwd/postgres,
--                                                authenticated=arwd/postgres}
--
--  which is ALTER DEFAULT PRIVILEGES ... GRANT ALL ON TABLES TO anon. Every
--  table and every view created in this schema is therefore granted to the
--  anonymous role at the moment it is created, silently, whatever the person
--  creating it intended.
--
--  A blanket REVOKE removes the grants that exist today. It does nothing about
--  tomorrow's. So the door was closed and then propped open again by the next
--  CREATE VIEW, and it would have happened on every one after that.
--
--  Proved before writing this, by creating a throwaway view and asking:
--    "new view granted to anon: INSERT,SELECT,UPDATE,DELETE"
--
--  AFTER THIS FILE a new table or view is granted to nobody. Anything the
--  application needs must be granted deliberately, by name. If somebody
--  forgets, the screen breaks loudly - which is the right direction to fail.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon;

-- The view that was leaking, and anything else that picked the grant up.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
GRANT SELECT ON nars_awaiting_hcis TO authenticated;
GRANT SELECT ON nars_outcomes      TO authenticated;
GRANT SELECT ON system_users_view  TO authenticated;

-- Signing in is still the one thing somebody not yet signed in may do.
GRANT EXECUTE ON FUNCTION hcis_login(TEXT, TEXT)             TO anon, authenticated;
GRANT EXECUTE ON FUNCTION hcis_login_seyid(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION hcis_logout(TEXT)                  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Check it, including the thing a REVOKE cannot tell you: that a NEW object
-- is no longer born public.
-- ---------------------------------------------------------------------------
DO $$
DECLARE leaked TEXT; still_default TEXT;
BEGIN
  SELECT string_agg(DISTINCT table_name, ', ') INTO leaked
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND grantee = 'anon';
  IF leaked IS NOT NULL THEN
    RAISE EXCEPTION 'Still readable without signing in: %', leaked;
  END IF;

  SELECT string_agg(defaclacl::text, ' ') INTO still_default
    FROM pg_default_acl
   WHERE defaclacl::text LIKE '%anon=%';
  IF still_default IS NOT NULL THEN
    RAISE EXCEPTION 'New tables would still be granted to the anonymous role: %', still_default;
  END IF;
END $$;

-- And prove it for real: make a view, look at who can see it, drop it.
DO $$
DECLARE granted TEXT;
BEGIN
  EXECUTE 'CREATE VIEW nars_default_grant_probe AS SELECT 1 AS x';
  SELECT string_agg(privilege_type, ',') INTO granted
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND grantee = 'anon'
     AND table_name = 'nars_default_grant_probe';
  EXECUTE 'DROP VIEW nars_default_grant_probe';

  IF granted IS NOT NULL THEN
    RAISE EXCEPTION
      'A brand new view is still born readable by the anonymous role (%). The default privileges have not been removed.', granted;
  END IF;
  RAISE NOTICE 'Checked: a new view is now granted to nobody.';
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
