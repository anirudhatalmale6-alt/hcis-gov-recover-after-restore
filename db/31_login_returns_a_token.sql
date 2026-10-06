-- ============================================================================
--  HCIS - signing in now hands back a token that identifies the person
--
--  Until now every request from the website arrived as the same anonymous
--  user, whoever was signed in. That is why no rule underneath the browser
--  could tell one member of staff from another, and why the role model in the
--  application governed what was drawn on screen and nothing else.
--
--  hcis_login and hcis_login_seyid keep everything they returned before and
--  add one more column, access_token. The browser sends that on every request
--  in place of the shared key. The database reads the claims out of it and
--  the policies in 30_nars_and_access_control.sql do the rest.
--
--  The session token is unchanged and still governs the account-management
--  functions, so nothing that works today stops working because of this file.
--
--  Run 30_nars_and_access_control.sql first. Safe to run more than once.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- The claims PostgREST will act on. "role" must name a real database role -
-- it is the one PostgREST switches to - and the rest is what our own policies
-- read.
CREATE OR REPLACE FUNCTION auth_private.claims_for(u system_users, p_expires TIMESTAMPTZ)
RETURNS JSON
LANGUAGE sql STABLE AS $$
  SELECT json_build_object(
    'role',  'authenticated',
    'sub',   u.id::text,
    'grp',   coalesce(u.user_group, ''),
    'urole', coalesce(u.role, ''),
    'name',  btrim(coalesce(u.first_name, '') || ' ' || coalesce(u.last_name, '')),
    'exp',   extract(epoch FROM p_expires)::bigint
  );
$$;

-- The return type gains a column, so the old function has to go first.
DROP FUNCTION IF EXISTS hcis_login(TEXT, TEXT);

CREATE FUNCTION hcis_login(p_identifier TEXT, p_password TEXT)
RETURNS TABLE (
  token UUID, display_id TEXT, username TEXT, email TEXT,
  first_name TEXT, last_name TEXT, role TEXT, user_group TEXT,
  must_change_password BOOLEAN, expires_at TIMESTAMPTZ,
  access_token TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  u     system_users%ROWTYPE;
  ident TEXT := lower(btrim(coalesce(p_identifier, '')));
  tok   UUID;
  exp   TIMESTAMPTZ := now() + interval '8 hours';
BEGIN
  IF ident = '' OR coalesce(p_password, '') = '' THEN RETURN; END IF;

  -- Staff sign in with either the username or their email address. Prefer an
  -- exact username match so a username can never be shadowed by somebody
  -- else's email. The table must be aliased: this function declares output
  -- columns called username and email.
  SELECT su.* INTO u FROM system_users su
   WHERE lower(su.username) = ident OR lower(su.email) = ident
   ORDER BY (lower(su.username) = ident) DESC
   LIMIT 1;

  IF NOT FOUND THEN RETURN; END IF;
  IF u.status <> 'active' THEN RETURN; END IF;
  IF u.locked_until IS NOT NULL AND u.locked_until > now() THEN RETURN; END IF;
  IF coalesce(u.password_hash, '') = '' THEN RETURN; END IF;

  IF crypt(p_password, u.password_hash) <> u.password_hash THEN
    UPDATE system_users
       SET failed_attempts = failed_attempts + 1,
           locked_until = CASE WHEN failed_attempts + 1 >= 8
                               THEN now() + interval '15 minutes'
                               ELSE locked_until END
     WHERE id = u.id;
    RETURN;
  END IF;

  DELETE FROM user_sessions s WHERE s.expires_at < now();
  INSERT INTO user_sessions (user_id, expires_at) VALUES (u.id, exp)
  RETURNING user_sessions.token INTO tok;

  UPDATE system_users
     SET last_login = now(), failed_attempts = 0, locked_until = NULL
   WHERE id = u.id;

  RETURN QUERY SELECT tok, u.display_id, u.username, u.email,
                      u.first_name, u.last_name, u.role, u.user_group,
                      u.must_change_password, exp,
                      auth_private.sign_jwt(auth_private.claims_for(u, exp));
END $$;

-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS hcis_login_seyid(TEXT, TEXT, TEXT);

CREATE FUNCTION hcis_login_seyid(p_email TEXT, p_username TEXT, p_sub TEXT)
RETURNS TABLE (
  token UUID, display_id TEXT, username TEXT, email TEXT,
  first_name TEXT, last_name TEXT, role TEXT, user_group TEXT,
  must_change_password BOOLEAN, expires_at TIMESTAMPTZ,
  access_token TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  u   system_users%ROWTYPE;
  tok UUID;
  exp TIMESTAMPTZ := now() + interval '8 hours';
BEGIN
  SELECT su.* INTO u FROM system_users su
   WHERE su.status = 'active'
     AND (   (coalesce(p_sub, '')      <> '' AND su.seyid_sub = p_sub)
          OR (coalesce(p_email, '')    <> '' AND lower(su.email) = lower(p_email))
          OR (coalesce(p_username, '') <> '' AND lower(su.username) = lower(p_username)))
   ORDER BY (su.seyid_sub IS NOT NULL AND su.seyid_sub = p_sub) DESC,
            (lower(su.email) = lower(coalesce(p_email, ''))) DESC
   LIMIT 1;

  IF NOT FOUND THEN RETURN; END IF;

  DELETE FROM user_sessions s WHERE s.expires_at < now();
  INSERT INTO user_sessions (user_id, expires_at) VALUES (u.id, exp)
  RETURNING user_sessions.token INTO tok;

  UPDATE system_users
     SET last_login = now(), seyid_sub = coalesce(p_sub, seyid_sub)
   WHERE id = u.id;

  RETURN QUERY SELECT tok, u.display_id, u.username, u.email,
                      u.first_name, u.last_name, u.role, u.user_group,
                      u.must_change_password, exp,
                      auth_private.sign_jwt(auth_private.claims_for(u, exp));
END $$;

-- Only somebody not yet signed in needs to call these.
REVOKE ALL ON FUNCTION hcis_login(TEXT, TEXT)             FROM PUBLIC;
REVOKE ALL ON FUNCTION hcis_login_seyid(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hcis_login(TEXT, TEXT)             TO anon, authenticated;
GRANT EXECUTE ON FUNCTION hcis_login_seyid(TEXT, TEXT, TEXT) TO anon, authenticated;

COMMIT;
