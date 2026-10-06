-- ============================================================================
--  Releasing an assessment to HCIS - a decision, not a side effect
--
--  Agreed with the client:
--    * a supervisor presses "send to HCIS" rather than it happening by itself,
--      because this writes a citizen into the benefits register
--    * 41 and above qualify
--    * 0 to 40 is "no home care" but stays on record, because an applicant
--      may appeal
--
--  So a score of 0 to 40 can still be released - somebody has to be able to
--  act on a successful appeal - but only with a reason written down. The
--  system does not refuse it and does not pretend it qualified.
--
--  Renewals are unchanged: somebody who is ALREADY a beneficiary has their
--  outcome go across on completion, as before. There is no new person being
--  entered into the register, so there is nothing to decide.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

ALTER TABLE nars_assessments
  ADD COLUMN IF NOT EXISTS released_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS released_by     UUID REFERENCES system_users(id),
  ADD COLUMN IF NOT EXISTS release_reason  TEXT;

COMMENT ON COLUMN nars_assessments.release_reason IS
  'Why a supervisor released this to HCIS. Required when the score is 0 to 40, '
  'which does not qualify - normally an appeal.';

-- ---------------------------------------------------------------------------
-- New beneficiary numbers.
--
-- Every one of the 8,859 existing records is B followed by five digits, so new
-- ones follow that. From a sequence, not from max()+1 worked out in the
-- application - two supervisors releasing at the same moment would otherwise
-- both be handed the same number and one would lose.
-- ---------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS nars_beneficiary_seq;
SELECT setval('nars_beneficiary_seq',
              coalesce((SELECT max(substring(display_id from 2)::bigint)
                          FROM beneficiaries
                         WHERE display_id ~ '^B[0-9]+$'), 0) + 1,
              false);

CREATE OR REPLACE FUNCTION nars_next_beneficiary_id()
RETURNS TEXT LANGUAGE sql AS $$
  SELECT 'B' || lpad(nextval('nars_beneficiary_seq')::text, 5, '0');
$$;

-- ---------------------------------------------------------------------------
-- The release itself.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_release_to_hcis(p_assessment UUID, p_reason TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a        nars_assessments%ROWTYPE;
  ap       nars_applicants%ROWTYPE;
  new_id      TEXT;
  who         UUID;
  outcome     TEXT;
  gone_across BOOLEAN;
BEGIN
  -- Only the Health Department releases their own work. The policies would
  -- stop anybody else reading these rows anyway; this refuses plainly rather
  -- than behaving as though the assessment did not exist.
  IF NOT auth_is_health() THEN
    RETURN 'Only the Health Department can send an assessment to HCIS.';
  END IF;
  who := nullif(auth_uid(), '')::uuid;

  SELECT * INTO a FROM nars_assessments WHERE id = p_assessment;
  IF NOT FOUND THEN RETURN 'That assessment does not exist.'; END IF;

  IF a.status <> 'completed' THEN
    RETURN 'Finish the interview first - only a completed assessment can be sent.';
  END IF;
  IF a.released_at IS NOT NULL OR a.published_at IS NOT NULL THEN
    RETURN 'This has already been sent to HCIS.';
  END IF;

  SELECT * INTO ap FROM nars_applicants WHERE id = a.applicant_id;

  -- 0 to 40 does not qualify. It can still be sent - an appeal has to be able
  -- to go somewhere - but not silently.
  IF a.hours = 'none' AND btrim(coalesce(p_reason, '')) = '' THEN
    RETURN 'This assessment scored ' || a.percent || '%, which is no home care. '
        || 'It can still be sent to HCIS, for an appeal or for the record, but '
        || 'please write down the reason first.';
  END IF;

  -- Already a beneficiary: nothing new is being created, just send the outcome.
  IF ap.beneficiary_display_id IS NOT NULL THEN
    outcome := nars_publish_to_hcis(p_assessment);
  ELSE
    -- A new person. This is the row that enters them into the register, and
    -- it starts as an application - submitted, eligibility pending - which is
    -- what HCIS's own screens already expect and count.
    new_id := nars_next_beneficiary_id();

    INSERT INTO beneficiaries (
      display_id, first_name, last_name, nin, date_of_birth, gender,
      district, address, phone, status, eligibility)
    VALUES (
      new_id,
      split_part(btrim(ap.full_name), ' ', 1),
      nullif(btrim(substring(btrim(ap.full_name) from position(' ' in btrim(ap.full_name)) + 1)), ''),
      ap.nin, ap.date_of_birth, coalesce(ap.sex, ''),
      coalesce(ap.district, ''), coalesce(ap.address, ''), coalesce(ap.phone, ''),
      'submitted', 'pending');

    -- The trigger from 35 links and publishes on its own once the beneficiary
    -- exists, so by here the outcome is usually already across.
    SELECT beneficiary_display_id INTO ap.beneficiary_display_id
      FROM nars_applicants WHERE id = ap.id;

    SELECT published_at IS NOT NULL INTO gone_across
      FROM nars_assessments WHERE id = p_assessment;
    outcome := CASE WHEN gone_across THEN 'ok'
                    ELSE nars_publish_to_hcis(p_assessment) END;
  END IF;

  IF outcome <> 'ok' THEN
    RETURN outcome;
  END IF;

  UPDATE nars_assessments
     SET released_at = now(), released_by = who,
         release_reason = nullif(btrim(coalesce(p_reason, '')), '')
   WHERE id = p_assessment;

  RETURN 'ok';
END $$;

REVOKE ALL ON FUNCTION nars_release_to_hcis(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION nars_release_to_hcis(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Completing no longer sends a NEW applicant across by itself.
--
-- A renewal still does - that person is already in the register and nothing is
-- being decided. For somebody new, the outcome waits for a supervisor.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_after_completion()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE result TEXT; already_known BOOLEAN;
BEGIN
  IF NEW.status = 'completed' AND coalesce(OLD.status, '') <> 'completed' THEN
    SELECT beneficiary_display_id IS NOT NULL INTO already_known
      FROM nars_applicants WHERE id = NEW.applicant_id;

    IF already_known THEN
      result := nars_publish_to_hcis(NEW.id);
      IF result <> 'ok' THEN
        UPDATE nars_assessments SET publish_note = result WHERE id = NEW.id;
      END IF;
    ELSE
      UPDATE nars_assessments
         SET publish_note = 'Ready to send to HCIS. This person is not in HCIS yet, '
                         || 'so sending it will register them as a new application.'
       WHERE id = NEW.id;
    END IF;
  END IF;
  RETURN NULL;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
