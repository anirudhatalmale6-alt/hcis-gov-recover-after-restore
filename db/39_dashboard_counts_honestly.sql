-- ============================================================================
--  "Awaiting a home visit" must not count people already assessed
--
--  Loading the Health Department's 32 existing records exposed this. Those
--  interviews were carried out on paper, so no home visit was ever recorded
--  against them - which made the dashboard say:
--
--      Awaiting a home visit .... 32
--      Assessments completed .... 33
--
--  Both numbers were correct and together they were nonsense. Nobody is
--  waiting for a visit if their interview is already finished.
--
--  A waiting list should mean "these need doing". Anything else is a number
--  somebody has to explain, and on a demo screen it is the number they get
--  asked about.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

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

    -- Still needs a visit: no visit recorded AND no finished assessment.
    (SELECT count(*) FROM nars_applicants ap
      WHERE NOT EXISTS (SELECT 1 FROM nars_home_visits v
                         WHERE v.applicant_id = ap.id)
        AND NOT EXISTS (SELECT 1 FROM nars_assessments a
                         WHERE a.applicant_id = ap.id AND a.status = 'completed')),

    (SELECT count(*) FROM nars_assessments WHERE status = 'draft'),
    (SELECT count(*) FROM nars_assessments WHERE status = 'completed'),
    (SELECT count(*) FROM nars_assessments
      WHERE status = 'completed' AND renewal_due IS NOT NULL
        AND renewal_due <= current_date + 30)
  WHERE auth_is_health();
$$;

REVOKE ALL ON FUNCTION nars_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION nars_summary() TO authenticated;

-- ---------------------------------------------------------------------------
-- Check it against the data that is actually there, before committing.
-- ---------------------------------------------------------------------------
DO $$
DECLARE waiting BIGINT; done BIGINT; total BIGINT;
BEGIN
  SELECT count(*) INTO total FROM nars_applicants;
  SELECT count(*) INTO done FROM nars_assessments WHERE status = 'completed';
  SELECT count(*) INTO waiting FROM nars_applicants ap
   WHERE NOT EXISTS (SELECT 1 FROM nars_home_visits v WHERE v.applicant_id = ap.id)
     AND NOT EXISTS (SELECT 1 FROM nars_assessments a
                      WHERE a.applicant_id = ap.id AND a.status = 'completed');

  IF waiting > total - done THEN
    RAISE EXCEPTION
      'The waiting list (%) is larger than the number of people who have not been assessed (%).',
      waiting, total - done;
  END IF;
  RAISE NOTICE 'Dashboard: % applicants, % assessed, % genuinely waiting for a visit.',
               total, done, waiting;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
