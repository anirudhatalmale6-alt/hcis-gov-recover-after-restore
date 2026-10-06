-- ============================================================================
--  NARS - reference numbers that cannot collide
--
--  Applicants and assessments both carry a human-readable reference that the
--  Health Department will quote on paper and over the phone. Working it out in
--  the browser - count what exists, add one - gives two assessors registering
--  at the same moment the same number, and one of them loses their work to a
--  uniqueness error after they have typed everything in.
--
--  A sequence cannot do that. The number is allocated by the database at the
--  moment the row is written.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE SEQUENCE IF NOT EXISTS nars_applicant_ref_seq;
CREATE SEQUENCE IF NOT EXISTS nars_assessment_ref_seq;

ALTER TABLE nars_applicants
  ALTER COLUMN reference SET DEFAULT
    'NARS-' || to_char(now(), 'YYYY') || '-' ||
    lpad(nextval('nars_applicant_ref_seq')::text, 4, '0');

ALTER TABLE nars_assessments
  ALTER COLUMN reference SET DEFAULT
    'NARS-A-' || to_char(now(), 'YYYY') || '-' ||
    lpad(nextval('nars_assessment_ref_seq')::text, 4, '0');

-- Start each sequence just past anything already in the tables, so running
-- this on a database that already holds records does not collide.
--
-- The third argument is false on purpose. With true, the number given is
-- treated as already used and the NEXT one is handed out - which on an empty
-- table means the very first applicant is numbered 0002. Small thing, but it
-- is the number a person reads down the telephone, and starting at two looks
-- like something was lost.
SELECT setval('nars_applicant_ref_seq',
              coalesce((SELECT max(substring(reference from '(\d+)$')::bigint)
                          FROM nars_applicants), 0) + 1, false);
SELECT setval('nars_assessment_ref_seq',
              coalesce((SELECT max(substring(reference from '(\d+)$')::bigint)
                          FROM nars_assessments), 0) + 1, false);

GRANT USAGE, SELECT ON SEQUENCE nars_applicant_ref_seq   TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE nars_assessment_ref_seq  TO authenticated;

-- ---------------------------------------------------------------------------
-- The dashboard needs counts, and the Health Department cannot be given a
-- free hand over the whole table just to produce them. This returns only
-- numbers, and only for the group it belongs to.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_summary()
RETURNS TABLE (
  applicants          BIGINT,
  awaiting_visit      BIGINT,
  awaiting_interview  BIGINT,
  completed           BIGINT,
  due_for_renewal     BIGINT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    (SELECT count(*) FROM nars_applicants),
    (SELECT count(*) FROM nars_applicants ap
      WHERE NOT EXISTS (SELECT 1 FROM nars_home_visits v WHERE v.applicant_id = ap.id)),
    (SELECT count(*) FROM nars_assessments WHERE status = 'draft'),
    (SELECT count(*) FROM nars_assessments WHERE status = 'completed'),
    (SELECT count(*) FROM nars_assessments
      WHERE status = 'completed' AND renewal_due IS NOT NULL
        AND renewal_due <= current_date + 30)
  WHERE auth_is_health();
$$;

REVOKE ALL ON FUNCTION nars_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION nars_summary() TO authenticated;

COMMIT;
