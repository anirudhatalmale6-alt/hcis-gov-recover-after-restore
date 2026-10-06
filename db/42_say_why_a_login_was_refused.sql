-- Tell someone WHY they were refused, without telling a stranger anything.
--
-- hcis_login refuses for four different reasons and returns zero rows for all
-- of them: no such account, account not active, account locked out, wrong
-- password. The screen says the same sentence every time.
--
-- On 30 September 2026 that cost the client his afternoon. He reset his
-- password, the reset PROVED the new password signed in through the API, and
-- the browser then refused him - because he had already tripped the eight
-- attempt lockout. A correct password and a locked account look identical from
-- the login screen, so he kept trying, which kept the lock alive.
--
-- The obvious fix - have the login say "this account is locked" - would tell
-- anybody which usernames exist on the system. So this does not do that.
--
-- It only explains itself to someone who ALREADY PROVED they know the
-- password. Get the password wrong and you learn nothing at all, exactly as
-- before. Get it right and you are told what is standing in your way, because
-- at that point you are obviously entitled to know.
--
-- Additive: hcis_login is not touched, so nothing that exists today changes
-- behaviour or shape. The front end can call this when a sign-in fails, and
-- until it does, everything carries on as it is.

\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION hcis_login_hint(p_identifier TEXT, p_password TEXT)
RETURNS TABLE (reason TEXT, message TEXT, minutes_left INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  u     system_users%ROWTYPE;
  ident TEXT := lower(trim(coalesce(p_identifier, '')));
BEGIN
  IF ident = '' OR coalesce(p_password, '') = '' THEN
    RETURN QUERY SELECT 'unknown'::TEXT,
      'Those details were not recognised.'::TEXT, NULL::INT;
    RETURN;
  END IF;

  SELECT su.* INTO u FROM system_users su
   WHERE lower(su.username) = ident OR lower(su.email) = ident
   ORDER BY (lower(su.username) = ident) DESC
   LIMIT 1;

  -- No such account, or the password is wrong: say nothing useful. These two
  -- must be indistinguishable, or this becomes a way to enumerate usernames.
  IF NOT FOUND
     OR coalesce(u.password_hash, '') = ''
     OR crypt(p_password, u.password_hash) <> u.password_hash THEN
    RETURN QUERY SELECT 'unknown'::TEXT,
      'Those details were not recognised.'::TEXT, NULL::INT;
    RETURN;
  END IF;

  -- Past this point the caller has proved they know the password, so they are
  -- entitled to know what is blocking them.

  IF u.locked_until IS NOT NULL AND u.locked_until > now() THEN
    RETURN QUERY SELECT 'locked'::TEXT,
      format('Your password is correct, but this account is locked after too many failed attempts. Try again in %s minute(s).',
             GREATEST(1, CEIL(EXTRACT(EPOCH FROM (u.locked_until - now())) / 60)::INT))::TEXT,
      GREATEST(1, CEIL(EXTRACT(EPOCH FROM (u.locked_until - now())) / 60)::INT);
    RETURN;
  END IF;

  IF u.status <> 'active' THEN
    RETURN QUERY SELECT 'inactive'::TEXT,
      'Your password is correct, but this account has been switched off. Ask an administrator to re-enable it.'::TEXT,
      NULL::INT;
    RETURN;
  END IF;

  -- Password right, nothing blocking: the sign-in should have worked, so the
  -- fault is further along - the API, the schema cache, the network.
  RETURN QUERY SELECT 'ok'::TEXT,
    'Your password is correct and nothing is blocking this account. If sign-in still fails the problem is not your login.'::TEXT,
    NULL::INT;
END $$;

REVOKE ALL ON FUNCTION hcis_login_hint(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hcis_login_hint(TEXT, TEXT) TO anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
