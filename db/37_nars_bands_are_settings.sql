-- ============================================================================
--  The score bands become settings, not code
--
--  The client expects amendments after the demo presentation. The hours per
--  band were already settings, so those are a one-line change. The CUT-OFFS
--  were not - 40, 60 and 80 were written into the scoring function, so moving
--  one meant a migration.
--
--  That is the wrong shape for a number a committee argues about. After this
--  file, changing where a band starts is four words in the settings table and
--  takes effect on the next assessment.
--
--  WHAT DOES NOT CHANGE: assessments already completed keep the band they were
--  given. A decision made under the rules of the day stands, and re-banding
--  history silently would alter what somebody was told they qualified for.
--  Re-scoring old assessments, if it is ever wanted, should be a deliberate
--  act with its own record.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

INSERT INTO system_settings (key, value, description) VALUES
  ('nars_band_1_max', '40',
   'Highest score that still means "No home care". From the assessment form.'),
  ('nars_band_2_max', '60',
   'Highest score for "A couple of hours a day". From the assessment form.'),
  ('nars_band_3_max', '80',
   'Highest score for "Partial care, half day". Above this is full time care.')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION nars_band(p_percent INTEGER)
RETURNS TABLE (band TEXT, hours TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE b1 INTEGER; b2 INTEGER; b3 INTEGER;
BEGIN
  SELECT value::integer INTO b1 FROM system_settings WHERE key = 'nars_band_1_max';
  SELECT value::integer INTO b2 FROM system_settings WHERE key = 'nars_band_2_max';
  SELECT value::integer INTO b3 FROM system_settings WHERE key = 'nars_band_3_max';

  -- A band that starts before the one below it ends would put a score in two
  -- bands at once, or in none - which is exactly the fault we corrected on the
  -- paper form. Refuse loudly rather than score somebody against nonsense.
  IF b1 IS NULL OR b2 IS NULL OR b3 IS NULL THEN
    RAISE EXCEPTION 'The score bands are not set. Expected nars_band_1_max, nars_band_2_max and nars_band_3_max in the settings.';
  END IF;
  IF NOT (b1 > 0 AND b1 < b2 AND b2 < b3 AND b3 < 100) THEN
    RAISE EXCEPTION
      'The score bands must climb and stay inside 0 to 100. They are currently %, % and %.', b1, b2, b3;
  END IF;

  RETURN QUERY SELECT
    CASE WHEN p_percent <= b1 THEN 'No home care'
         WHEN p_percent <= b2 THEN 'A couple of hours a day (60 hours a month)'
         WHEN p_percent <= b3 THEN 'Partial care, half day'
         ELSE                      'Full time care' END,
    CASE WHEN p_percent <= b1 THEN 'none'
         WHEN p_percent <= b2 THEN '60-per-month'
         WHEN p_percent <= b3 THEN 'half-day'
         ELSE                      'full-time' END;
END $$;

-- ---------------------------------------------------------------------------
-- Check the settings produce the same answers the form does, before
-- committing. If somebody edits these later this same query is how to check
-- them again.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r RECORD; wrong TEXT := '';
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      (0,'No home care'), (40,'No home care'),
      (41,'A couple of hours a day (60 hours a month)'), (60,'A couple of hours a day (60 hours a month)'),
      (61,'Partial care, half day'), (80,'Partial care, half day'),
      (81,'Full time care'), (100,'Full time care')
    ) AS t(pct, expected)
  LOOP
    IF (SELECT b.band FROM nars_band(r.pct) b) <> r.expected THEN
      wrong := wrong || format('%s%% gave "%s", expected "%s". ',
                               r.pct, (SELECT b.band FROM nars_band(r.pct) b), r.expected);
    END IF;
  END LOOP;
  IF wrong <> '' THEN
    RAISE EXCEPTION 'The bands do not match the assessment form: %', wrong;
  END IF;
END $$;

-- And every score from 0 to 100 must land in exactly one band.
DO $$
DECLARE pct INTEGER; n INTEGER;
BEGIN
  FOR pct IN 0..100 LOOP
    SELECT count(*) INTO n FROM nars_band(pct);
    IF n <> 1 THEN
      RAISE EXCEPTION 'A score of %%% falls in % bands, not one.', pct, n;
    END IF;
  END LOOP;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
