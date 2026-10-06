-- ============================================================================
--  NARS feeds the renewal gate in HCIS
--
--  HCIS already refuses a service agreement renewal unless there is a needs
--  assessment for that beneficiary dated in the current period:
--
--    "There is no needs assessment for this beneficiary dated within the
--     current period. Policy is that a renewal needs a fresh assessment, so
--     carry one out in the Needs Assessment module first and it will appear
--     here."
--
--  Until now an HCIS officer satisfied that gate by typing four scores -
--  physical, medical, psychological and social - none of which exist on the
--  Health Department's real form. This file makes a completed NARS assessment
--  appear there instead, so the gate opens on the strength of a real
--  interview and nobody in HCIS types anything.
--
--  Nothing in the HCIS application changes. It cannot: that app exists only as
--  a built bundle. Everything here happens underneath it.
--
--  Safe to run more than once. Nothing is deleted.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ===========================================================================
--  1. Matching an applicant to a beneficiary
-- ===========================================================================
-- The two sides write the same number differently. HCIS stores it formatted -
-- 020-0609-1-1-50 - and NARS stores the eleven digits on their own. Comparing
-- them as typed finds nothing, and finding nothing looks exactly like "this
-- person is new", which is the wrong answer for every renewal.
--
-- Checked before relying on it: all 8,859 beneficiaries have a number, every
-- one is 11 digits once punctuation is removed, and all 8,859 are still
-- distinct after removing it. So the stripped number is a safe key.

CREATE OR REPLACE FUNCTION nars_plain_nin(p_nin TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(regexp_replace(coalesce(p_nin, ''), '[^0-9]', '', 'g'), '');
$$;

CREATE INDEX IF NOT EXISTS idx_beneficiaries_plain_nin
  ON beneficiaries (nars_plain_nin(nin));

ALTER TABLE nars_applicants
  ADD COLUMN IF NOT EXISTS beneficiary_display_id TEXT;

COMMENT ON COLUMN nars_applicants.beneficiary_display_id IS
  'The HCIS beneficiary this applicant already is, matched on the identity '
  'number. Empty for somebody applying for care for the first time.';

-- Set the link whenever the number is entered or corrected, so an assessor
-- never has to know that HCIS exists.
CREATE OR REPLACE FUNCTION nars_link_beneficiary()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.beneficiary_display_id := (
    SELECT b.display_id FROM beneficiaries b
     WHERE nars_plain_nin(b.nin) = nars_plain_nin(NEW.nin)
     LIMIT 1
  );
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_nars_link_beneficiary ON nars_applicants;
CREATE TRIGGER trg_nars_link_beneficiary
BEFORE INSERT OR UPDATE OF nin ON nars_applicants
FOR EACH ROW EXECUTE FUNCTION nars_link_beneficiary();

-- Link anything already registered.
UPDATE nars_applicants a
   SET beneficiary_display_id = (
         SELECT b.display_id FROM beneficiaries b
          WHERE nars_plain_nin(b.nin) = nars_plain_nin(a.nin) LIMIT 1)
 WHERE a.beneficiary_display_id IS NULL;

-- ===========================================================================
--  2. What a band is worth in hours
-- ===========================================================================
-- HCIS stores recommended_hours as a plain integer. The assessment produces a
-- band. Two of the four are written down; two are not, and I am not inventing
-- the number of hours of care a person receives.
--
-- Publishing refuses while either is unset, and says which one.

INSERT INTO system_settings (key, value, description) VALUES
  ('nars_hours_none', '0',
   'Hours recorded in HCIS for the band "No home care".'),
  ('nars_hours_60_per_month', '60',
   'Hours recorded in HCIS for "A couple of hours a day" - 60 a month, as written on the assessment form.'),
  ('nars_hours_half_day', '',
   'Hours recorded in HCIS for "Partial care, half day". BLANK - awaiting the Agency. Nothing publishes to HCIS for this band while it is blank.'),
  ('nars_hours_full_time', '',
   'Hours recorded in HCIS for "Full time care". BLANK - awaiting the Agency. Nothing publishes to HCIS for this band while it is blank.')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION nars_hours_for_band(p_hours TEXT)
RETURNS INTEGER
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  k TEXT := CASE p_hours
              WHEN 'none'          THEN 'nars_hours_none'
              WHEN '60-per-month'  THEN 'nars_hours_60_per_month'
              WHEN 'half-day'      THEN 'nars_hours_half_day'
              WHEN 'full-time'     THEN 'nars_hours_full_time'
            END;
  v TEXT;
BEGIN
  IF k IS NULL THEN
    RAISE EXCEPTION 'There is no band called "%".', p_hours;
  END IF;
  SELECT s.value INTO v FROM system_settings s WHERE s.key = k;
  IF v IS NULL OR btrim(v) = '' THEN
    RAISE EXCEPTION
      'The number of hours for this band has not been set yet. Set % in the system settings and this will publish.', k;
  END IF;
  RETURN v::integer;
END $$;

-- ===========================================================================
--  3. Publishing a completed assessment into HCIS
-- ===========================================================================

ALTER TABLE nars_assessments
  ADD COLUMN IF NOT EXISTS published_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS publish_note    TEXT;

COMMENT ON COLUMN nars_assessments.publish_note IS
  'Why this outcome has not reached HCIS yet, in words an assessor can read.';

-- Every column on needs_assessments was declared NOT NULL, including the four
-- domain scores. Those four do not exist on the real form, so there is no
-- honest number to put in them - relaxing them lets the record say nothing
-- rather than say zero, which would read as "no problems found".
ALTER TABLE needs_assessments ALTER COLUMN physical_score      DROP NOT NULL;
ALTER TABLE needs_assessments ALTER COLUMN medical_score       DROP NOT NULL;
ALTER TABLE needs_assessments ALTER COLUMN psychological_score DROP NOT NULL;
ALTER TABLE needs_assessments ALTER COLUMN social_score        DROP NOT NULL;

CREATE OR REPLACE FUNCTION nars_publish_to_hcis(p_assessment UUID)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a   nars_assessments%ROWTYPE;
  ap  nars_applicants%ROWTYPE;
  hrs INTEGER;
  ref TEXT;
BEGIN
  SELECT * INTO a FROM nars_assessments WHERE id = p_assessment;
  IF NOT FOUND THEN RETURN 'That assessment does not exist.'; END IF;

  IF a.status <> 'completed' THEN
    RETURN 'Only a completed assessment goes to HCIS.';
  END IF;

  SELECT * INTO ap FROM nars_applicants WHERE id = a.applicant_id;

  IF ap.beneficiary_display_id IS NULL THEN
    RETURN 'This applicant is not yet a beneficiary in HCIS, so there is no '
        || 'record to attach the outcome to. Once they are registered in HCIS '
        || 'under the same identity number this will go across on its own.';
  END IF;

  BEGIN
    hrs := nars_hours_for_band(a.hours);
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
  END;

  -- Do not publish the same assessment twice.
  IF EXISTS (SELECT 1 FROM needs_assessments WHERE notes LIKE '%' || a.reference || '%') THEN
    RETURN 'Already sent to HCIS.';
  END IF;

  -- The NARS reference already begins NARS-A-, so do not prefix it again.
  ref := a.reference;

  -- The guard on needs_assessments (below) lets this through and refuses
  -- anything typed in by hand.
  PERFORM set_config('nars.publishing', 'on', true);

  INSERT INTO needs_assessments (
    display_id, beneficiary_id, beneficiary_name,
    assessor_id, assessor_name, assessment_date,
    physical_score, medical_score, psychological_score, social_score,
    total_score, recommended_hours, time_frame, notes, status)
  VALUES (
    ref, ap.beneficiary_display_id, ap.full_name,
    coalesce(a.assessor_id::text, ''), coalesce(a.assessor_name, ''), a.assessed_on,
    NULL, NULL, NULL, NULL,
    a.percent, hrs,
    coalesce(a.renewal_months::text || ' months', ''),
    'Carried out by the Health Department on the 20-question assessment, '
      || 'reference ' || a.reference || '. Score ' || a.percent || '% - ' || a.band
      || '. The four domain scores on this screen are not part of that form and '
      || 'are deliberately empty.',
    'completed');

  PERFORM set_config('nars.publishing', 'off', true);

  UPDATE nars_assessments
     SET published_at = now(), publish_note = NULL
   WHERE id = p_assessment;

  RETURN 'ok';
END $$;

REVOKE ALL ON FUNCTION nars_publish_to_hcis(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION nars_publish_to_hcis(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Completing an assessment tries to publish, but is never blocked by it.
--
-- The Health Department finishing their interview must not fail because a
-- setting on the payments side is missing. The reason is recorded on the
-- assessment instead, and publishing can be retried.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_after_completion()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE result TEXT;
BEGIN
  IF NEW.status = 'completed' AND coalesce(OLD.status, '') <> 'completed' THEN
    result := nars_publish_to_hcis(NEW.id);
    IF result <> 'ok' THEN
      UPDATE nars_assessments SET publish_note = result WHERE id = NEW.id;
    END IF;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_nars_after_completion ON nars_assessments;
CREATE TRIGGER trg_nars_after_completion
AFTER UPDATE ON nars_assessments
FOR EACH ROW EXECUTE FUNCTION nars_after_completion();

-- ===========================================================================
--  4. Retiring the old screen - built, but NOT switched on yet
-- ===========================================================================
-- Switching this on refuses any assessment typed into HCIS by hand. It must
-- not be switched on before NARS can actually publish, or there would be no
-- way at all to produce an assessment and every renewal would be stuck.
--
-- To switch it on, when the hours above are set and the first outcome has
-- gone across:
--
--   UPDATE system_settings SET value = 'on' WHERE key = 'nars_owns_assessments';
--
-- To switch it back off, the same with 'off'. No deployment either way.

INSERT INTO system_settings (key, value, description) VALUES
  ('nars_owns_assessments', 'off',
   'When on, assessments can only come from the Health Department''s NARS module and the old HCIS screen refuses to create them. Leave off until NARS is publishing.')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION nars_guard_manual_assessment()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Publishing from NARS sets this for the length of its transaction.
  IF coalesce(current_setting('nars.publishing', true), 'off') = 'on' THEN
    RETURN NEW;
  END IF;
  IF (SELECT value FROM system_settings WHERE key = 'nars_owns_assessments') = 'on' THEN
    RAISE EXCEPTION
      'Needs assessments are now carried out by the Health Department in the NARS module, and appear here on their own once completed. This screen no longer creates them.';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_nars_guard_manual ON needs_assessments;
CREATE TRIGGER trg_nars_guard_manual
BEFORE INSERT OR UPDATE ON needs_assessments
FOR EACH ROW EXECUTE FUNCTION nars_guard_manual_assessment();

COMMIT;

NOTIFY pgrst, 'reload schema';
