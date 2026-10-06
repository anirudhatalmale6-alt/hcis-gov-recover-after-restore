-- ============================================================================
--  NARS - load the assessment records onto this box
--
--  Called with:   -v file='C:/HCIS/recover/nars-data/nars_records_YYYYMMDD.sql'
--
--  The records are 34 people assessed, 36 assessments and 677 answers given in
--  those people's homes. They exist in the NARS database and nowhere else - no
--  spreadsheet has them, and no script can regenerate them. Everything else in
--  this package rebuilds structure; this is the only part that carries work.
--
--  The data file is NOT in this package and never will be: it holds real
--  names, real national identity numbers and real answers about people's
--  health. This package is published; that file is carried between the two
--  machines by hand and deleted afterwards.
--
--  ---------------------------------------------------------------------------
--  WHAT THIS REFUSES TO DO
--
--  It will not load on top of existing NARS rows. If the target already holds
--  assessments then either this has already run, or the box has real work on
--  it, and in both cases loading a snapshot over the top would replace newer
--  records with older ones. It stops and says so.
--
--  ---------------------------------------------------------------------------
--  THE REFERENCES TO STAFF ACCOUNTS
--
--  Four columns point at system_users: who registered an applicant, who
--  assessed, who released, who made the home visit. Those are ids from the
--  OTHER box, and the same person has a different id here - so loading them
--  unchanged fails on the foreign key, and that is the right behaviour rather
--  than a row pointing at nobody.
--
--  So: the constraints are dropped, the rows are loaded, every reference that
--  does not resolve on this box is set to NULL, and the constraints are put
--  back from the definitions captured out of the catalogue first - not from
--  definitions typed in here, which would drift the day somebody changes one.
--
--  All of it inside one transaction. PostgreSQL makes DDL transactional, so a
--  failure anywhere - including inside the data file - rolls back the dropped
--  constraints along with everything else. There is no window in which this
--  box is left without them.
-- ============================================================================

\set ON_ERROR_STOP on
\timing off

BEGIN;

-- ---- 1. is this the right kind of box, and is it empty? -------------------
DO $$
DECLARE v_n BIGINT;
BEGIN
  IF to_regclass('public.nars_applicants') IS NULL
     OR to_regclass('public.nars_assessments') IS NULL
     OR to_regclass('public.nars_answers') IS NULL
     OR to_regclass('public.nars_home_visits') IS NULL THEN
    RAISE EXCEPTION
      'The NARS tables are not on this box. Run the database updates first - this loads records into tables that have to exist already.';
  END IF;

  SELECT (SELECT count(*) FROM nars_applicants)
       + (SELECT count(*) FROM nars_assessments)
       + (SELECT count(*) FROM nars_answers)
       INTO v_n;

  IF v_n > 0 THEN
    RAISE EXCEPTION
      'This box already holds % NARS rows. Nothing has been loaded. Loading a snapshot on top of existing records would put older work over newer - if you are certain the rows here are not wanted, say so and I will give you a separate script that clears them deliberately.', v_n;
  END IF;

  -- The score bands have to be in place BEFORE any answer is loaded.
  --
  -- Inserting an answer fires nars_answers_changed, which recalculates the
  -- assessment, which reads the three band settings and raises if they are
  -- absent. Update 37 installs them, so in the proper order this is already
  -- true - but when it was not, the failure arrived as six lines of trigger
  -- stack naming a function nobody has heard of, half way through loading,
  -- rather than as a sentence. This says it in one line and before anything
  -- has been written.
  SELECT count(*) INTO v_n FROM system_settings
   WHERE key IN ('nars_band_1_max', 'nars_band_2_max', 'nars_band_3_max');
  IF v_n < 3 THEN
    RAISE EXCEPTION
      'The score bands are not set on this box, and loading an answer recalculates the assessment, which needs them. Run the database updates first (update 37 installs them). Nothing has been loaded.';
  END IF;
END $$;

-- ---- 2. remember the constraints exactly as they are ----------------------
CREATE TEMP TABLE _fk_backup AS
SELECT c.conname::text        AS name,
       rel.relname::text      AS table_name,
       pg_get_constraintdef(c.oid) AS definition
  FROM pg_constraint c
  JOIN pg_class rel ON rel.oid = c.conrelid
  JOIN pg_class ref ON ref.oid = c.confrelid
  JOIN pg_namespace n ON n.oid = rel.relnamespace
 WHERE c.contype = 'f'
   AND n.nspname = 'public'
   AND rel.relname LIKE 'nars\_%'
   AND ref.relname = 'system_users';

DO $$
DECLARE v_n INT;
BEGIN
  SELECT count(*) INTO v_n FROM _fk_backup;
  RAISE NOTICE 'Holding % foreign key(s) to put back afterwards.', v_n;
END $$;

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT * FROM _fk_backup LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.table_name, r.name);
  END LOOP;
END $$;

-- ---- 3. the records ------------------------------------------------------
\echo '  loading the records...'
\i :file

-- ---- 4. references that do not resolve on this box -----------------------
--
-- Counted before and after, and reported. "Set some to NULL" with no number
-- is not something anybody can check.
DO $$
DECLARE v_a INT; v_b INT; v_c INT; v_d INT;
BEGIN
  UPDATE nars_applicants SET registered_by = NULL
   WHERE registered_by IS NOT NULL
     AND registered_by NOT IN (SELECT id FROM system_users);
  v_a := COALESCE((SELECT count(*) FROM nars_applicants WHERE registered_by IS NULL), 0);

  UPDATE nars_assessments SET assessor_id = NULL
   WHERE assessor_id IS NOT NULL
     AND assessor_id NOT IN (SELECT id FROM system_users);
  UPDATE nars_assessments SET released_by = NULL
   WHERE released_by IS NOT NULL
     AND released_by NOT IN (SELECT id FROM system_users);

  UPDATE nars_home_visits SET visitor_id = NULL
   WHERE visitor_id IS NOT NULL
     AND visitor_id NOT IN (SELECT id FROM system_users);

  SELECT count(*) INTO v_b FROM nars_assessments WHERE assessor_id IS NOT NULL;
  SELECT count(*) INTO v_c FROM nars_assessments WHERE released_by IS NOT NULL;
  SELECT count(*) INTO v_d FROM nars_home_visits WHERE visitor_id IS NOT NULL;

  RAISE NOTICE 'Staff attribution kept where the account exists here: % assessor, % released, % visit.',
    v_b, v_c, v_d;
END $$;

-- ---- 5. put the constraints back, and prove they are back ----------------
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT * FROM _fk_backup LOOP
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I %s',
                   r.table_name, r.name, r.definition);
  END LOOP;
END $$;

DO $$
DECLARE v_want INT; v_have INT; v_missing TEXT;
BEGIN
  SELECT count(*) INTO v_want FROM _fk_backup;

  SELECT count(*), string_agg(b.name, ', ')
    INTO v_have, v_missing
    FROM _fk_backup b
   WHERE NOT EXISTS (
           SELECT 1 FROM pg_constraint c
             JOIN pg_class rel ON rel.oid = c.conrelid
            WHERE c.conname = b.name AND rel.relname = b.table_name);

  IF v_have > 0 THEN
    -- Raising here rolls the whole thing back, data included. Better an empty
    -- box than one carrying records with the rules switched off.
    RAISE EXCEPTION 'These foreign keys were not restored: %. Nothing has been loaded.', v_missing;
  END IF;
  RAISE NOTICE 'All % foreign key(s) back in place.', v_want;
END $$;

-- ---- 6. and that the rows arrived ---------------------------------------
DO $$
DECLARE v_app INT; v_ass INT; v_ans INT;
BEGIN
  SELECT count(*) INTO v_app FROM nars_applicants;
  SELECT count(*) INTO v_ass FROM nars_assessments;
  SELECT count(*) INTO v_ans FROM nars_answers;
  IF v_app = 0 OR v_ass = 0 OR v_ans = 0 THEN
    RAISE EXCEPTION
      'The load finished but the tables are still empty (% applicants, % assessments, % answers). The data file is probably the wrong one.',
      v_app, v_ass, v_ans;
  END IF;
END $$;

DROP TABLE _fk_backup;

COMMIT;

\echo ''
\echo '  ---------------------------------------------------------'
\echo '  WHAT IS NOW ON THIS BOX'
\echo '  ---------------------------------------------------------'

SELECT (SELECT count(*) FROM nars_applicants)  AS "people assessed",
       (SELECT count(*) FROM nars_assessments) AS "assessments",
       (SELECT count(*) FROM nars_assessments WHERE status = 'completed')
                                               AS "of those, completed",
       (SELECT count(*) FROM nars_answers)     AS "answers",
       (SELECT count(*) FROM nars_home_visits) AS "home visits";

-- The assessments that had already been released into HCIS on the other box.
-- Releasing is what creates the beneficiary record, and that is not carried
-- here: it belongs to HCIS's own data, not to NARS. So these show as released
-- and have nothing on the HCIS side of this box yet. One button each in the
-- Needs Assessment screen puts that right, and it is better done by a person
-- who can see the result than by a script writing into beneficiary records.
\echo ''
\echo '  Already released on the other box - these need releasing again here,'
\echo '  one button each in the Needs Assessment screen:'

SELECT a.reference,
       coalesce(ap.full_name, '(name not recorded)') AS applicant
  FROM nars_assessments a
  LEFT JOIN nars_applicants ap ON ap.id = a.applicant_id
 WHERE a.released_at IS NOT NULL
 ORDER BY a.reference;

NOTIFY pgrst, 'reload schema';
