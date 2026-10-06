-- ============================================================================
--  HCIS - the Needs Assessment module (NARS), and closing the open door
--
--  TWO THINGS HAPPEN IN THIS FILE.
--
--  1. The database stops handing its contents to anybody who asks.
--
--     Today the "anon" role - the one the website uses before anybody has
--     signed in - holds SELECT, INSERT, UPDATE and DELETE on 21 of the 22
--     tables, and every one of the row security policies says "allow
--     everyone". The login hardening applied in August is real and working,
--     but it sits on top of this, so a request that skips the login entirely
--     is still answered in full.
--
--     After this file a request with no signed-in user reads nothing and
--     writes nothing. The only thing "anon" may still do is call the login
--     functions, which is how anybody gets a session in the first place.
--
--  2. The Health Department gets its own front door, with a wall facing both
--     ways.
--
--       - Health Department staff work in NARS. They cannot read a single
--         beneficiary, care worker or payroll row.
--       - HCIS staff do not get the NARS module at all - no applicant list,
--         no home visit, no interview in progress. A completed assessment
--         becomes visible to them, as an outcome only, so they can process
--         the payment fee. They never see the twenty interview answers.
--
--  HOW A USER IS IDENTIFIED
--
--  Signing in already returns a session token. It now also returns a signed
--  token (a JWT) carrying who the person is and which group they are in. The
--  browser sends that instead of the shared key it uses today, and the
--  database reads the claims out of it. That is the whole point: until now
--  every request arrived as the same anonymous user, so no rule below the
--  browser could tell one member of staff from another.
--
--  WHAT THIS FILE DOES NOT DO
--
--  It does not re-decide which HCIS role may do what. Those rules already
--  exist in the application and are unchanged. This file changes "anyone at
--  all" into "a signed-in member of HCIS staff", and separates Health from
--  HCIS. Tightening the individual HCIS roles is a separate piece of work.
--
--  Safe to run more than once. Nothing is dropped and no data is deleted.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ===========================================================================
--  1. Somewhere to keep the signing secret
-- ===========================================================================
-- PostgREST is told a secret in /etc/postgrest/hcis.conf and uses it to check
-- the tokens it receives. The database needs the same secret to sign them.
-- It lives in its own schema which is NOT exposed through the API, and which
-- no application role may read.

CREATE SCHEMA IF NOT EXISTS auth_private;
REVOKE ALL ON SCHEMA auth_private FROM PUBLIC;

CREATE TABLE IF NOT EXISTS auth_private.config (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
REVOKE ALL ON auth_private.config FROM PUBLIC;

-- The secret itself is NOT written here. Put it in with one line, off the
-- back of the value already in the PostgREST config, and keep the two the
-- same:
--
--   INSERT INTO auth_private.config (key, value) VALUES ('jwt_secret', '...')
--   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
--
-- hcis_login raises a clear error rather than issuing an unusable token if
-- this is missing.

-- ===========================================================================
--  2. Signing a token
-- ===========================================================================
-- A JWT is three pieces joined by dots: a header, the claims, and an HMAC of
-- the first two. base64url is ordinary base64 with two characters swapped and
-- the padding removed.

CREATE OR REPLACE FUNCTION auth_private.url_encode(data BYTEA)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;

CREATE OR REPLACE FUNCTION auth_private.sign_jwt(payload JSON)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = auth_private, public AS $$
DECLARE
  secret    TEXT;
  header    TEXT := auth_private.url_encode(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8'));
  body      TEXT := auth_private.url_encode(convert_to(payload::text, 'utf8'));
  signables TEXT;
BEGIN
  SELECT c.value INTO secret FROM auth_private.config c WHERE c.key = 'jwt_secret';
  IF secret IS NULL OR btrim(secret) = '' THEN
    -- Better to refuse the login than to hand out a token nothing can verify.
    RAISE EXCEPTION
      'The JWT signing secret has not been set. Insert it into auth_private.config as the key jwt_secret, matching jwt-secret in the PostgREST configuration.';
  END IF;
  signables := header || '.' || body;
  RETURN signables || '.' ||
         auth_private.url_encode(hmac(signables, secret, 'sha256'));
END $$;

-- ===========================================================================
--  3. Reading the claims back out
-- ===========================================================================
-- PostgREST verifies the signature itself and puts the claims where these
-- functions can find them. Every one of them fails closed: no token, or a
-- token without the claim, gives an empty string, never a pass.

CREATE OR REPLACE FUNCTION auth_claim(name TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT coalesce(
           nullif(current_setting('request.jwt.claims', true), '')::json ->> name,
           '');
$$;

CREATE OR REPLACE FUNCTION auth_uid()    RETURNS TEXT LANGUAGE sql STABLE AS $$ SELECT auth_claim('sub')   $$;
CREATE OR REPLACE FUNCTION auth_group()  RETURNS TEXT LANGUAGE sql STABLE AS $$ SELECT auth_claim('grp')   $$;
CREATE OR REPLACE FUNCTION auth_urole()  RETURNS TEXT LANGUAGE sql STABLE AS $$ SELECT auth_claim('urole') $$;

CREATE OR REPLACE FUNCTION auth_signed_in() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$ SELECT auth_uid() <> '' $$;

-- The Health Department. Membership is the group on the account, so moving
-- somebody in or out is an ordinary edit on the user, not a code change.
CREATE OR REPLACE FUNCTION auth_is_health() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$ SELECT auth_signed_in() AND auth_group() = 'Health' $$;

-- Everybody else who is signed in: the existing HCIS staff.
CREATE OR REPLACE FUNCTION auth_is_hcis_staff() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$ SELECT auth_signed_in() AND auth_group() <> 'Health' $$;

-- ===========================================================================
--  4. The NARS tables
-- ===========================================================================
-- The existing needs_assessments table was built to a guess - four domains
-- called physical, medical, psychological and social. The Health Department's
-- real form has five groups and twenty questions and does not map onto those
-- four, so NARS gets its own tables. needs_assessments is left alone here
-- rather than dropped; it holds one demo row and can be removed separately
-- once nothing reads it.

CREATE TABLE IF NOT EXISTS nars_applicants (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reference     TEXT UNIQUE NOT NULL,
  nin           TEXT,
  full_name     TEXT NOT NULL,
  date_of_birth DATE,
  sex           TEXT,
  district      TEXT,
  address       TEXT,
  phone         TEXT,
  notes         TEXT,
  registered_by UUID REFERENCES system_users(id),
  registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS nars_home_visits (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  applicant_id   UUID NOT NULL REFERENCES nars_applicants(id) ON DELETE CASCADE,
  visited_on     DATE NOT NULL,
  visitor_id     UUID REFERENCES system_users(id),
  visitor_name   TEXT,
  household_size INTEGER,
  findings       TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_nars_visits_applicant ON nars_home_visits (applicant_id);

CREATE TABLE IF NOT EXISTS nars_assessments (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  applicant_id   UUID NOT NULL REFERENCES nars_applicants(id) ON DELETE CASCADE,
  reference      TEXT UNIQUE NOT NULL,
  assessed_on    DATE NOT NULL DEFAULT current_date,
  assessor_id    UUID REFERENCES system_users(id),
  assessor_name  TEXT,
  -- Which language the interview was conducted in. Worth recording: the two
  -- forms do not yet agree, so it may matter later which one was used.
  language       TEXT NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'kr')),
  answered       INTEGER NOT NULL DEFAULT 0,
  raw_score      INTEGER,
  max_score      INTEGER,
  percent        INTEGER,
  band           TEXT,
  hours          TEXT,
  -- "a renewal basis, eg: 3m/5m/6m etc" - examples, not a rule tied to the
  -- score, so the assessor sets it.
  renewal_months INTEGER CHECK (renewal_months IS NULL OR renewal_months > 0),
  renewal_due    DATE,
  status         TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'completed', 'cancelled')),
  completed_at   TIMESTAMPTZ,
  notes          TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_nars_assessments_applicant ON nars_assessments (applicant_id);
CREATE INDEX IF NOT EXISTS idx_nars_assessments_status    ON nars_assessments (status);

CREATE TABLE IF NOT EXISTS nars_answers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assessment_id   UUID NOT NULL REFERENCES nars_assessments(id) ON DELETE CASCADE,
  question_number INTEGER NOT NULL CHECK (question_number BETWEEN 1 AND 20),
  severity        INTEGER NOT NULL CHECK (severity BETWEEN 0 AND 3),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (assessment_id, question_number)
);
CREATE INDEX IF NOT EXISTS idx_nars_answers_assessment ON nars_answers (assessment_id);

-- ===========================================================================
--  5. The score, computed where the data is
-- ===========================================================================
-- The same rule as the application's scoring module, so the number on the
-- screen and the number in the database cannot drift apart. Rounding is half
-- away from zero - note the cast to numeric, because round() on a double in
-- PostgreSQL rounds half to even and would put a score of 12.5 in a different
-- band to the application.

CREATE OR REPLACE FUNCTION nars_band(p_percent INTEGER)
RETURNS TABLE (band TEXT, hours TEXT)
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
           WHEN p_percent <= 40 THEN 'No home care'
           WHEN p_percent <= 60 THEN 'A couple of hours a day (60 hours a month)'
           WHEN p_percent <= 80 THEN 'Partial care, half day'
           ELSE                      'Full time care'
         END,
         CASE
           WHEN p_percent <= 40 THEN 'none'
           WHEN p_percent <= 60 THEN '60-per-month'
           WHEN p_percent <= 80 THEN 'half-day'
           ELSE                      'full-time'
         END;
$$;

CREATE OR REPLACE FUNCTION nars_recalculate(p_assessment UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n INTEGER; total INTEGER; pct INTEGER; b TEXT; h TEXT;
BEGIN
  SELECT count(*), coalesce(sum(severity), 0) INTO n, total
    FROM nars_answers WHERE assessment_id = p_assessment;

  IF n = 0 THEN
    UPDATE nars_assessments
       SET answered = 0, raw_score = NULL, max_score = NULL,
           percent = NULL, band = NULL, hours = NULL, updated_at = now()
     WHERE id = p_assessment;
    RETURN;
  END IF;

  pct := round((total::numeric / (n * 3)) * 100);
  SELECT nb.band, nb.hours INTO b, h FROM nars_band(pct) nb;

  UPDATE nars_assessments
     SET answered = n, raw_score = total, max_score = n * 3,
         percent = pct, band = b, hours = h, updated_at = now()
   WHERE id = p_assessment;
END $$;

CREATE OR REPLACE FUNCTION nars_answers_changed()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  PERFORM nars_recalculate(coalesce(NEW.assessment_id, OLD.assessment_id));
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_nars_answers_changed ON nars_answers;
CREATE TRIGGER trg_nars_answers_changed
AFTER INSERT OR UPDATE OR DELETE ON nars_answers
FOR EACH ROW EXECUTE FUNCTION nars_answers_changed();

-- ---------------------------------------------------------------------------
-- An assessment cannot be completed part-finished.
--
-- This is the rule that decides when HCIS gets to see it at all, so it is
-- enforced here rather than in the screen. A half-finished interview scores
-- the applicant on whatever happened to be asked, and that must never reach
-- the payment side as though it were a finding.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_guard_completion()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE n INTEGER;
BEGIN
  IF NEW.status = 'completed' AND coalesce(OLD.status, '') <> 'completed' THEN
    SELECT count(*) INTO n FROM nars_answers WHERE assessment_id = NEW.id;
    IF n <> 20 THEN
      RAISE EXCEPTION
        'This assessment has % of 20 questions answered. All twenty must be answered before it can be completed.', n;
    END IF;
    IF NEW.renewal_months IS NULL THEN
      RAISE EXCEPTION 'A renewal period must be set before the assessment can be completed.';
    END IF;
    NEW.completed_at := now();
    -- Adding months to the 31st can land on a day that does not exist;
    -- PostgreSQL clamps rather than rolling into the next month.
    NEW.renewal_due  := (NEW.assessed_on + make_interval(months => NEW.renewal_months))::date;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_nars_guard_completion ON nars_assessments;
CREATE TRIGGER trg_nars_guard_completion
BEFORE UPDATE ON nars_assessments
FOR EACH ROW EXECUTE FUNCTION nars_guard_completion();

-- ===========================================================================
--  6. What HCIS is shown
-- ===========================================================================
-- The outcome, and nothing else. No home visit findings, no interview
-- answers. This is deliberately a view and not a grant on the tables, so the
-- twenty answers are not one query parameter away.

CREATE OR REPLACE VIEW nars_outcomes AS
SELECT a.reference,
       ap.reference AS applicant_reference,
       ap.full_name,
       ap.nin,
       ap.district,
       a.assessed_on,
       a.assessor_name,
       a.percent,
       a.band,
       a.hours,
       a.renewal_months,
       a.renewal_due,
       a.completed_at
  FROM nars_assessments a
  JOIN nars_applicants ap ON ap.id = a.applicant_id
 WHERE a.status = 'completed';

-- ===========================================================================
--  7. Close the door
-- ===========================================================================

-- ---- every table gets row security switched on -----------------------------
DO $$
DECLARE t TEXT;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- ---- remove the blanket "allow everyone" policies --------------------------
-- Every existing policy in this schema currently permits every command to
-- anon and authenticated with no condition. They are replaced below.
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname = 'public'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', p.policyname, p.schemaname, p.tablename);
  END LOOP;
END $$;

-- ---- take back the blanket grants ------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon;

-- anon exists for one purpose: letting somebody who is not yet signed in sign
-- in. Nothing else.
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT EXECUTE ON FUNCTION hcis_login(TEXT, TEXT)              TO anon;
GRANT EXECUTE ON FUNCTION hcis_login_seyid(TEXT, TEXT, TEXT)  TO anon;
GRANT EXECUTE ON FUNCTION hcis_logout(TEXT)                   TO anon, authenticated;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- ---- the HCIS tables -------------------------------------------------------
-- Unchanged in what HCIS staff may do; changed in that they must now be
-- signed in, and that the Health Department is not among them.
-- The list is taken from the database rather than written out here on
-- purpose. A hand-written list is a list that goes stale: the first draft of
-- this file omitted care_workers, which left row security switched on with no
-- policy behind it - closed to everybody, including the people who need it.
-- Anything added to the schema later is covered automatically.
DO $$
DECLARE t TEXT;
BEGIN
  FOR t IN
    SELECT tablename FROM pg_tables
     WHERE schemaname = 'public'
       AND tablename NOT LIKE 'nars\_%'      -- the Health Department's own area
       AND tablename NOT IN ('system_users', -- reached through its view only
                             'user_sessions')-- belongs to the login functions
     ORDER BY tablename
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format($f$
      CREATE POLICY hcis_staff_only ON public.%I
        FOR ALL TO authenticated
        USING (auth_is_hcis_staff())
        WITH CHECK (auth_is_hcis_staff())
    $f$, t);
  END LOOP;
END $$;

-- ---- the NARS tables -------------------------------------------------------
-- The Health Department's own working area. HCIS staff get no grant on these
-- at all, so the module is absent rather than merely hidden.
DO $$
DECLARE
  t TEXT;
  nars_tables TEXT[] := ARRAY['nars_applicants', 'nars_home_visits', 'nars_assessments', 'nars_answers'];
BEGIN
  FOREACH t IN ARRAY nars_tables LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format($f$
      CREATE POLICY health_only ON public.%I
        FOR ALL TO authenticated
        USING (auth_is_health())
        WITH CHECK (auth_is_health())
    $f$, t);
  END LOOP;
END $$;

-- The outcome view is the one place the two sides meet. It is owned by the
-- database owner and so is not itself subject to the policies above - which is
-- exactly why it selects only completed assessments and only outcome columns.
GRANT SELECT ON nars_outcomes TO authenticated;

-- ---- accounts --------------------------------------------------------------
-- The administration screen reads the view, which has never included password
-- hashes. The table itself stays unreachable.
GRANT SELECT ON system_users_view TO authenticated;

-- Sessions belong to the login functions, not to the browser.
REVOKE ALL ON user_sessions FROM anon, authenticated;

-- ===========================================================================
--  8. Check our own work before committing
-- ===========================================================================
-- A table with row security switched on and no policy behind it is closed to
-- everybody. That is safe, but it is also an outage, and it looks identical to
-- a table that is correctly protected until somebody tries to use the screen
-- that needs it. Fail here instead.
DO $$
DECLARE missing TEXT;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO missing
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relkind = 'r'
     AND c.relrowsecurity
     AND c.relname NOT IN ('system_users', 'user_sessions')
     AND NOT EXISTS (SELECT 1 FROM pg_policies p
                      WHERE p.schemaname = 'public' AND p.tablename = c.relname);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION
      'These tables have row security enabled but no policy, so nothing can read them: %', missing;
  END IF;
END $$;

-- And the reverse: nothing may still be readable without signing in.
DO $$
DECLARE open_to_anon TEXT;
BEGIN
  SELECT string_agg(DISTINCT table_name, ', ') INTO open_to_anon
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND grantee = 'anon';
  IF open_to_anon IS NOT NULL THEN
    RAISE EXCEPTION
      'These tables are still granted to the anonymous role: %', open_to_anon;
  END IF;
END $$;

COMMIT;

-- ============================================================================
--  AFTER RUNNING THIS
--
--  1. Put the signing secret in, matching jwt-secret in
--     /etc/postgrest/hcis.conf:
--
--       INSERT INTO auth_private.config (key, value) VALUES ('jwt_secret', '...')
--       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
--
--  2. Apply 31_login_returns_a_token.sql, which makes hcis_login hand back the
--     signed token as well as the session token.
--
--  3. Change the browser to send that token instead of the shared key. Until
--     that is done the site will read nothing - which is the correct
--     behaviour, and the reason these two steps belong in one maintenance
--     window rather than a quiet afternoon.
-- ============================================================================
