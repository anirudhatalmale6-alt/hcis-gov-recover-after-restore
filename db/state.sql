-- ============================================================================
--  HCIS - what is on this box right now
--
--  Reads only. Changes nothing that outlives the connection. Safe to run at
--  any time, including in the middle of someone else's work.
--
--  This is the single place that decides whether a thing is present. Both the
--  "what is missing" check and the recovery itself read their answers from
--  here, so the two can never disagree about the state of the box - which they
--  would eventually, if each carried its own copy of these tests.
--
--  Output is one row per item, pipe-separated:
--
--      kind | item | present
--
--  kind is one of:
--      core      a table HCIS cannot work without. A missing one means this
--                database is NOT HCIS, and nothing here should be applied.
--      change    one of the thirteen database updates.
--      account   a sign-in that has to exist for somebody to get back in.
--      data      rows that exist nowhere else and cannot be regenerated.
--
--  present is the word yes or the word no. Not a count and not a code: the
--  PowerShell side matches on the word, and whoever reads the screen sees the
--  same word.
--
--  ---------------------------------------------------------------------------
--  WHY THIS IS WRITTEN AS A BLOCK OF CODE RATHER THAN ONE PLAIN QUERY
--
--  I wrote it as a plain query first and it was wrong. PostgreSQL parses a
--  whole statement before it runs any of it, so
--
--      to_regclass('public.nars_applicants') IS NOT NULL
--      AND (SELECT count(*) FROM nars_applicants) > 0
--
--  does NOT protect itself. If the table is absent the statement fails to
--  parse and the entire report dies - a file whose only job is to report
--  missing things, defeated by the first missing thing.
--
--  So every read of a table goes through EXECUTE, which is parsed at the
--  moment it runs and therefore only when the table is known to be there.
--  Tests that ask the catalogue instead are safe as they stand.
--
--  The same applies to has_table_privilege and has_function_privilege: both
--  RAISE if the table, or the role, does not exist. Both are guarded.
-- ============================================================================

-- QUIET first, or psql announces each \pset on its own line and the caller has
-- to recognise those as not-a-result. client_min_messages likewise: the
-- DROP TABLE IF EXISTS below is normal and its notice is not news.
\set QUIET on
\pset format unaligned
\pset fieldsep '|'
\pset tuples_only on
\pset footer off
SET client_min_messages = warning;

-- Temporary, so nothing persistent is created. It disappears when this
-- connection closes, which is the moment this file finishes.
DROP TABLE IF EXISTS _hcis_state;
CREATE TEMP TABLE _hcis_state (
  seq     SERIAL,
  kind    TEXT,
  item    TEXT,
  present TEXT
);

DO $report$
DECLARE
  v_n        BIGINT;
  v_core_ok  BOOLEAN := TRUE;
  v_anon     BOOLEAN := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon');
  t          TEXT;
BEGIN
  -- ---- the tables HCIS cannot work without ------------------------------
  FOREACH t IN ARRAY ARRAY[
      'system_users', 'beneficiaries', 'care_workers', 'leave_requests',
      'needs_assessments', 'payroll_records', 'system_settings',
      'service_agreements'
  ] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      INSERT INTO _hcis_state (kind, item, present) VALUES ('core', t, 'yes');
    ELSE
      INSERT INTO _hcis_state (kind, item, present) VALUES ('core', t, 'no');
      v_core_ok := FALSE;
    END IF;
  END LOOP;

  -- If this is not HCIS, stop here. Reporting which of our updates are
  -- "missing" from somebody else's database would be noise at best, and at
  -- worst would read as an instruction to apply them to it.
  IF NOT v_core_ok THEN
    INSERT INTO _hcis_state (kind, item, present)
    VALUES ('verdict', 'this database is not HCIS', 'no');
    RETURN;
  END IF;

  -- ---- the thirteen updates ---------------------------------------------
  --
  -- One marker each: something that update created and nothing else does, so
  -- its presence means that file has run on this database.
  --
  -- Deliberately NOT a version table. A version number records what somebody
  -- SAID was applied. These record what is actually there. After a restore
  -- those two answers differ, and the second is the one that matters.

  -- 30
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '30 - sign-in plumbing and the NARS tables',
         CASE WHEN to_regclass('auth_private.config')     IS NOT NULL
               AND to_regclass('public.nars_applicants')  IS NOT NULL
               AND to_regclass('public.nars_assessments') IS NOT NULL
               AND to_regclass('public.nars_answers')     IS NOT NULL
              THEN 'yes' ELSE 'no' END;

  -- 31
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '31 - signing in issues a token',
         CASE WHEN EXISTS (
                SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'auth_private' AND p.proname = 'claims_for')
              THEN 'yes' ELSE 'no' END;

  -- 32
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '32 - NARS reference numbers',
         CASE WHEN to_regclass('public.nars_applicant_ref_seq')  IS NOT NULL
               AND to_regclass('public.nars_assessment_ref_seq') IS NOT NULL
              THEN 'yes' ELSE 'no' END;

  -- 33. A grant, not an object: the test is that the anonymous role can no
  -- longer call the account-management functions. has_function_privilege
  -- raises if the role is absent, so that is checked first.
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '33 - account management needs a session',
         CASE WHEN v_anon
               AND EXISTS (
                     SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.proname = 'hcis_admin_create_user')
               AND NOT EXISTS (
                     SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public'
                        AND p.proname LIKE 'hcis\_admin\_%'
                        AND has_function_privilege('anon', p.oid, 'EXECUTE'))
              THEN 'yes' ELSE 'no' END;

  -- 34
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '34 - a completed assessment reaches HCIS',
         CASE WHEN EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'nars_applicants'
                   AND column_name = 'beneficiary_display_id')
              THEN 'yes' ELSE 'no' END;

  -- 35
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '35 - assessments waiting for a beneficiary catch up',
         CASE WHEN to_regclass('public.nars_awaiting_hcis') IS NOT NULL
              THEN 'yes' ELSE 'no' END;

  -- 36
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '36 - an assessment is released by a person',
         CASE WHEN EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'nars_assessments'
                   AND column_name = 'released_at')
              THEN 'yes' ELSE 'no' END;

  -- 37. Reads a row, so it goes through EXECUTE. system_settings is a core
  -- table and was proved present above, but the rule is the rule: a table read
  -- in this file is read dynamically, so nobody has to remember which reads
  -- are safe.
  EXECUTE 'SELECT count(*) FROM public.system_settings WHERE key = $1'
     INTO v_n USING 'nars_band_1_max';
  INSERT INTO _hcis_state (kind, item, present)
  VALUES ('change', '37 - the score bands are settings, not code',
          CASE WHEN v_n > 0 THEN 'yes' ELSE 'no' END);

  -- 38. The security one, and the only marker here I got wrong twice.
  --
  -- First attempt asked "can the anonymous role read payroll_records?". That
  -- reads yes as soon as update 30 has run, because 30 revokes the role's own
  -- grants. It would have reported 38 as applied on a box where it had not
  -- been - the worst kind of wrong, since 38 is the one that closed the
  -- read-everything-without-signing-in hole.
  --
  -- What 38 alone does is remove the DEFAULT privileges, so that a table or
  -- view created in future is born granted to nobody. Revoking a grant and
  -- stopping the next one being handed out are different things, and only the
  -- second is 38's.
  --
  -- Second attempt looked right and still proved nothing, because the database
  -- I was testing against had no default grant to remove. On the real box a
  -- brand new view is born readable by anon - that is why the file exists. The
  -- test environment was at fault, not the test.
  --
  -- 38 proves this at the time it runs by creating a throwaway view, looking
  -- at who can read it and dropping it again. That is the better test, and it
  -- is not available here: this file does not write, so it cannot make a view
  -- to ask about. Reading pg_default_acl answers the same question one step
  -- removed.
  INSERT INTO _hcis_state (kind, item, present)
  VALUES ('change', '38 - a new table is not born readable by strangers',
          CASE WHEN NOT v_anon THEN 'yes'
               WHEN EXISTS (SELECT 1 FROM pg_default_acl
                             WHERE defaclacl::text LIKE '%anon=%') THEN 'no'
               ELSE 'yes' END);

  -- 39. Another one I got wrong first time, caught the same way.
  --
  -- I looked for the due_for_renewal column, which reads yes from update 32
  -- onwards - 32 creates this function with exactly those five columns. 39
  -- does not change the shape, it changes the arithmetic: "awaiting a visit"
  -- stops counting people who have already been assessed. So the marker has to
  -- be in the body, and the second lookup it added is the only thing that
  -- aliases nars_assessments.
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '39 - the dashboard counts honestly',
         CASE WHEN EXISTS (
                SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'nars_summary'
                   AND p.prosrc LIKE '%nars_assessments a%')
              THEN 'yes' ELSE 'no' END;

  -- 40
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '40 - NIN written the way the Agency writes it',
         CASE WHEN EXISTS (
                SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'nars_house_nin')
              THEN 'yes' ELSE 'no' END;

  -- 41. The one that silently stops everybody. Every other line above can read
  -- yes and if this one reads no, not one person can sign in to this box.
  IF to_regclass('auth_private.config') IS NULL THEN
    v_n := 0;
  ELSE
    EXECUTE 'SELECT count(*) FROM auth_private.config
              WHERE key = $1 AND btrim(coalesce(value, '''')) <> '''''
       INTO v_n USING 'jwt_secret';
  END IF;
  INSERT INTO _hcis_state (kind, item, present)
  VALUES ('change', '41 - THE TOKEN SIGNING KEY',
          CASE WHEN v_n > 0 THEN 'yes' ELSE 'no' END);

  -- 42
  INSERT INTO _hcis_state (kind, item, present)
  SELECT 'change', '42 - a refused sign-in says why',
         CASE WHEN EXISTS (
                SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = 'hcis_login_hint')
              THEN 'yes' ELSE 'no' END;

  -- ---- can anybody get in ------------------------------------------------
  --
  -- password_hash <> '' matters. A row with an empty hash is an account on
  -- paper and a locked door in practice, and it would otherwise count.

  EXECUTE 'SELECT count(*) FROM public.system_users
            WHERE role = $1 AND status = $2 AND password_hash <> '''''
     INTO v_n USING 'super_admin', 'active';
  INSERT INTO _hcis_state (kind, item, present)
  VALUES ('account', 'somebody can administer this box',
          CASE WHEN v_n > 0 THEN 'yes' ELSE 'no' END);

  EXECUTE 'SELECT count(*) FROM public.system_users
            WHERE user_group = $1 AND status = $2 AND password_hash <> '''''
     INTO v_n USING 'Health', 'active';
  INSERT INTO _hcis_state (kind, item, present)
  VALUES ('account', 'somebody can use the Needs Assessment module',
          CASE WHEN v_n > 0 THEN 'yes' ELSE 'no' END);

  -- ---- the rows that cannot be rebuilt by any script ---------------------
  --
  -- Structure and content are different losses. If the NARS tables come back
  -- empty then the updates worked and the work done in people's homes did
  -- not - 660 answers given by real people, which exist in no spreadsheet.
  IF to_regclass('public.nars_applicants') IS NULL THEN
    v_n := 0;
  ELSE
    EXECUTE 'SELECT count(*) FROM public.nars_applicants' INTO v_n;
  END IF;
  INSERT INTO _hcis_state (kind, item, present)
  VALUES ('data', 'assessment records (people assessed)',
          CASE WHEN v_n > 0 THEN 'yes' ELSE 'no' END);

  IF to_regclass('public.nars_answers') IS NULL THEN
    v_n := 0;
  ELSE
    EXECUTE 'SELECT count(*) FROM public.nars_answers' INTO v_n;
  END IF;
  INSERT INTO _hcis_state (kind, item, present)
  VALUES ('data', 'assessment answers (given in people''s homes)',
          CASE WHEN v_n > 0 THEN 'yes' ELSE 'no' END);
END
$report$;

SELECT kind, item, present FROM _hcis_state ORDER BY seq;
