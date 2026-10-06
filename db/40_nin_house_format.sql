-- ============================================================================
--  A beneficiary created by NARS must store its identity number the same way
--  as the other 8,859
--
--  WHAT WENT WRONG
--
--  NARS stores identity numbers as eleven plain digits, because an assessor
--  types them off a card with the punctuation and the registration screen
--  strips it. HCIS stores them formatted: 020-0609-1-1-50. Every one of the
--  8,859 existing beneficiaries is in that shape.
--
--  When NARS registers a new applicant in HCIS it passed its own plain value
--  straight through, so the first record it created - B08860 - was the only
--  one out of 8,860 stored as 12345678901.
--
--  It LOOKED correct, which is why it nearly went unnoticed: the HCIS screen
--  formats the number for display, so it showed as 123-4567-8-9-01 in the
--  list. The stored value was the odd one out, and an exact search on the
--  number as displayed found nothing.
--
--  Every beneficiary NARS created from now on would have had the same fault.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 999-9999-9-9-99 - the shape HCIS uses. Anything that is not eleven digits
-- is handed back untouched rather than being forced into a pattern it does
-- not fit.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_house_nin(p_nin TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN nars_plain_nin(p_nin) IS NULL THEN p_nin
    WHEN length(nars_plain_nin(p_nin)) <> 11 THEN p_nin
    ELSE substr(nars_plain_nin(p_nin), 1, 3) || '-'
      || substr(nars_plain_nin(p_nin), 4, 4) || '-'
      || substr(nars_plain_nin(p_nin), 8, 1) || '-'
      || substr(nars_plain_nin(p_nin), 9, 1) || '-'
      || substr(nars_plain_nin(p_nin), 10, 2)
  END;
$$;

-- ---------------------------------------------------------------------------
-- Put the one record that is already wrong into the house format.
--
-- The matching between NARS and HCIS strips punctuation on both sides, so
-- this does not break the link - but it does fire the catch-up trigger, which
-- is harmless: publishing checks whether the outcome has already gone across.
-- ---------------------------------------------------------------------------
UPDATE beneficiaries
   SET nin = nars_house_nin(nin), updated_at = now()
 WHERE nin ~ '^[0-9]{11}$';

-- ---------------------------------------------------------------------------
-- And stop it happening again. Same function as before, one line different.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_release_to_hcis(p_assessment UUID, p_reason TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a           nars_assessments%ROWTYPE;
  ap          nars_applicants%ROWTYPE;
  new_id      TEXT;
  who         UUID;
  outcome     TEXT;
  gone_across BOOLEAN;
BEGIN
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

  IF a.hours = 'none' AND btrim(coalesce(p_reason, '')) = '' THEN
    RETURN 'This assessment scored ' || a.percent || '%, which is no home care. '
        || 'It can still be sent to HCIS, for an appeal or for the record, but '
        || 'please write down the reason first.';
  END IF;

  IF ap.beneficiary_display_id IS NOT NULL THEN
    outcome := nars_publish_to_hcis(p_assessment);
  ELSE
    new_id := nars_next_beneficiary_id();

    INSERT INTO beneficiaries (
      display_id, first_name, last_name, nin, date_of_birth, gender,
      district, address, phone, status, eligibility)
    VALUES (
      new_id,
      split_part(btrim(ap.full_name), ' ', 1),
      nullif(btrim(substring(btrim(ap.full_name) from position(' ' in btrim(ap.full_name)) + 1)), ''),
      nars_house_nin(ap.nin),          -- <- the house format, not ours
      ap.date_of_birth, coalesce(ap.sex, ''),
      coalesce(ap.district, ''), coalesce(ap.address, ''), coalesce(ap.phone, ''),
      'submitted', 'pending');

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
-- Check it before committing: every beneficiary in the house format, and the
-- links still intact.
-- ---------------------------------------------------------------------------
DO $$
DECLARE odd BIGINT; orphaned BIGINT;
BEGIN
  SELECT count(*) INTO odd FROM beneficiaries
   WHERE nin IS NOT NULL AND btrim(nin) <> ''
     AND nin !~ '^[0-9]{3}-[0-9]{4}-[0-9]-[0-9]-[0-9]{2}$';
  IF odd > 0 THEN
    RAISE EXCEPTION '% beneficiaries are still not in the house format.', odd;
  END IF;

  SELECT count(*) INTO orphaned FROM nars_applicants ap
   WHERE ap.beneficiary_display_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM beneficiaries b
                      WHERE b.display_id = ap.beneficiary_display_id);
  IF orphaned > 0 THEN
    RAISE EXCEPTION '% applicants now point at a beneficiary that does not exist.', orphaned;
  END IF;

  RAISE NOTICE 'All beneficiary identity numbers are in the house format, links intact.';
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
