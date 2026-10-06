-- ============================================================================
--  NARS catches up when somebody becomes a beneficiary afterwards
--
--  THE GAP THIS CLOSES
--
--  An assessment is what decides whether a person gets care. So the ordinary
--  case is that somebody is assessed BEFORE they are a beneficiary - the
--  assessment is the reason they become one.
--
--  34_nars_feeds_hcis.sql only publishes an outcome when the applicant is
--  already a beneficiary, because there is no HCIS record to attach it to
--  otherwise. It says so plainly on the assessment and stops. But nothing was
--  watching for that person appearing in HCIS later, so the outcome would sit
--  there unpublished for ever and somebody would have to notice by hand.
--
--  After this file, registering a beneficiary in HCIS links any NARS applicant
--  with the same identity number and sends across every completed assessment
--  they already have. Nobody has to remember.
--
--  Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- Send across everything that is completed, matched, and not yet published.
--
-- Also the way to catch up after a setting changes - filling in the hours for
-- a band releases every assessment that was waiting on it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_publish_pending()
RETURNS TABLE (reference TEXT, result TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT a.id, a.reference AS ref
      FROM nars_assessments a
      JOIN nars_applicants ap ON ap.id = a.applicant_id
     WHERE a.status = 'completed'
       AND a.published_at IS NULL
       AND ap.beneficiary_display_id IS NOT NULL
     ORDER BY a.completed_at
  LOOP
    reference := r.ref;
    result := nars_publish_to_hcis(r.id);
    IF result <> 'ok' THEN
      UPDATE nars_assessments SET publish_note = result WHERE id = r.id;
    END IF;
    RETURN NEXT;
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION nars_publish_pending() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION nars_publish_pending() TO authenticated;

-- ---------------------------------------------------------------------------
-- A beneficiary appearing in HCIS is the event we were waiting for.
--
-- Deliberately AFTER, and deliberately quiet: registering a beneficiary must
-- never fail because something on the assessment side went wrong. If the
-- publishing cannot happen the reason is recorded on the assessment, exactly
-- as it is everywhere else.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nars_beneficiary_arrived()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE linked INTEGER;
BEGIN
  UPDATE nars_applicants ap
     SET beneficiary_display_id = NEW.display_id
   WHERE ap.beneficiary_display_id IS NULL
     AND nars_plain_nin(ap.nin) = nars_plain_nin(NEW.nin);
  GET DIAGNOSTICS linked = ROW_COUNT;

  IF linked > 0 THEN
    PERFORM nars_publish_pending();
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- Never block the registration of a beneficiary.
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_nars_beneficiary_arrived ON beneficiaries;
CREATE TRIGGER trg_nars_beneficiary_arrived
AFTER INSERT OR UPDATE OF nin ON beneficiaries
FOR EACH ROW EXECUTE FUNCTION nars_beneficiary_arrived();

-- ---------------------------------------------------------------------------
-- What is waiting, and why. For the dashboard, and for anybody asking
-- "where did that assessment go?".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW nars_awaiting_hcis AS
SELECT a.reference,
       ap.full_name,
       ap.nin,
       a.completed_at,
       a.band,
       coalesce(a.publish_note, 'Waiting.') AS reason
  FROM nars_assessments a
  JOIN nars_applicants ap ON ap.id = a.applicant_id
 WHERE a.status = 'completed'
   AND a.published_at IS NULL;

GRANT SELECT ON nars_awaiting_hcis TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
