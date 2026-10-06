-- HCIS - install the token signing key
--
-- Called with:   -v secret="..."
--
-- From migration 31 onwards, signing in issues a signed token as well as a
-- session row. The database signs it, PostgREST verifies it, and the two must
-- use the same key. If the key is absent the sign-in function refuses outright
-- rather than handing out a token nothing can check - which is correct, but it
-- means that until this file has run, NOBODY CAN SIGN IN.
--
-- The value is not written into this file. It is read off the PostgREST
-- configuration on the machine this is being run on, so the two cannot
-- disagree. See set-jwt-secret.ps1.

\set ON_ERROR_STOP on

-- The BEGIN matters. set_config with is_local = true lasts for the current
-- transaction, and without an explicit one each statement is its own
-- transaction - so the value was gone before the DO block below could read it.
BEGIN;

-- \gset rather than a plain SELECT, so the key is never echoed to the screen
-- or into a log file.
SELECT set_config('hcis.secret', :'secret', true) AS _ \gset

DO $$
DECLARE
  v_secret TEXT := current_setting('hcis.secret');
BEGIN
  IF btrim(coalesce(v_secret, '')) = '' THEN
    RAISE EXCEPTION
      'No signing key was supplied. Read jwt-secret out of the PostgREST configuration on this machine and pass it in.';
  END IF;

  -- PostgREST rejects a key shorter than this, so catch it here rather than
  -- after the whole package has run.
  IF length(v_secret) < 32 THEN
    RAISE EXCEPTION
      'The signing key is only % characters. PostgREST requires at least 32.', length(v_secret);
  END IF;

  INSERT INTO auth_private.config (key, value)
  VALUES ('jwt_secret', v_secret)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END $$;

COMMIT;

\echo ''
\echo '=== signing key ==='
-- Never print the key itself. Its length and fingerprint are enough to compare
-- against the PostgREST side if they ever drift apart.
SELECT length(value)                     AS key_length,
       substr(md5(value), 1, 8)          AS fingerprint,
       'installed'                       AS status
  FROM auth_private.config
 WHERE key = 'jwt_secret';
