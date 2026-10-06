-- ============================================================================
--  HCIS - make sure one named person can sign in to this box
--
--  Called with:
--      -v usr=...        the username
--      -v pwd=...        the password to set
--      -v role=...       super_admin | health_assessor | ...   (default
--                        health_assessor)
--      -v grp=...        Admin | Health | ...                  (default
--                        Health - NARS checks the GROUP, not the role)
--      -v email=...      -v firstname=...  -v lastname=...     (optional)
--      -v mustchange=yes forces them to pick their own at first sign-in
--      -v mode=...       create-if-missing  (default) | repair
--
--  ---------------------------------------------------------------------------
--  WHY THERE ARE TWO MODES
--
--  This file is used by the recovery, which runs when nobody is certain what
--  state the box is in. Two situations look identical from outside and need
--  opposite handling:
--
--    * the account is gone      -> create it, and tell them the password
--    * the account is there and working -> do not touch it
--
--  The second matters. Overwriting a working password is a change nobody
--  asked for: whoever was using that account is now locked out, and the only
--  person who knows is whoever read the screen. So create-if-missing leaves an
--  existing, active, usable account completely alone, and says that it did.
--
--  repair is the deliberate "I know, reset it anyway" - for when an account
--  survived but no living person knows its password.
--
--  An account that exists but CANNOT be signed into - inactive, locked, or
--  with an empty password - is not a working account, and create-if-missing
--  repairs that one. Leaving it would mean reporting success over a door that
--  is still shut.
--
--  psql does not substitute :'var' inside a dollar-quoted block, so the values
--  go in through set_config first and are read back with current_setting.
-- ============================================================================

\set ON_ERROR_STOP on

\if :{?email}      \else \set email      '' \endif
\if :{?firstname}  \else \set firstname  '' \endif
\if :{?lastname}   \else \set lastname   '' \endif
\if :{?mustchange} \else \set mustchange 'no' \endif
\if :{?role}       \else \set role       'health_assessor' \endif
\if :{?grp}        \else \set grp        'Health' \endif
\if :{?mode}       \else \set mode       'create-if-missing' \endif

BEGIN;

SELECT set_config('acct.usr',   :'usr',        true) AS _ \gset
SELECT set_config('acct.pwd',   :'pwd',        true) AS _ \gset
SELECT set_config('acct.email', :'email',      true) AS _ \gset
SELECT set_config('acct.first', :'firstname',  true) AS _ \gset
SELECT set_config('acct.last',  :'lastname',   true) AS _ \gset
SELECT set_config('acct.must',  :'mustchange', true) AS _ \gset
SELECT set_config('acct.role',  :'role',       true) AS _ \gset
SELECT set_config('acct.grp',   :'grp',        true) AS _ \gset
SELECT set_config('acct.mode',  :'mode',       true) AS _ \gset

DO $$
DECLARE
  v_usr   TEXT := current_setting('acct.usr');
  v_pwd   TEXT := current_setting('acct.pwd');
  v_email TEXT := nullif(current_setting('acct.email'), '');
  v_first TEXT := nullif(current_setting('acct.first'), '');
  v_last  TEXT := nullif(current_setting('acct.last'), '');
  v_must  BOOL := lower(current_setting('acct.must')) IN ('yes','true','y','1');
  v_role  TEXT := current_setting('acct.role');
  v_grp   TEXT := current_setting('acct.grp');
  v_mode  TEXT := lower(current_setting('acct.mode'));
  v_id    TEXT;
  v_row   system_users;
  v_works BOOL;
BEGIN
  IF length(v_pwd) < 10 THEN
    RAISE EXCEPTION 'The password must be at least 10 characters.';
  END IF;
  IF v_mode NOT IN ('create-if-missing', 'repair') THEN
    RAISE EXCEPTION 'mode must be create-if-missing or repair, not "%".', v_mode;
  END IF;

  SELECT * INTO v_row FROM system_users WHERE lower(username) = lower(v_usr);

  IF FOUND THEN
    -- Can somebody actually get in with this account as it stands? Three
    -- things have to be true, and a row existing is none of them.
    v_works := v_row.status = 'active'
               AND coalesce(v_row.password_hash, '') <> ''
               AND (v_row.locked_until IS NULL OR v_row.locked_until < now());

    IF v_mode = 'create-if-missing' AND v_works THEN
      RAISE NOTICE 'Account "%" is already here and usable. NOT TOUCHED - its password is unchanged.', v_usr;
      RETURN;
    END IF;

    UPDATE system_users
       SET user_group           = v_grp,
           role                 = v_role,
           password_hash        = crypt(v_pwd, gen_salt('bf', 10)),
           status               = 'active',
           locked_until         = NULL,
           failed_attempts      = 0,
           must_change_password = v_must,
           -- Only overwrite a name if a real one was supplied, so a repair
           -- does not blank out somebody's details.
           email      = coalesce(v_email, email),
           first_name = coalesce(v_first, first_name),
           last_name  = coalesce(v_last,  last_name)
     WHERE lower(username) = lower(v_usr);

    IF v_works THEN
      RAISE NOTICE 'Account "%" was working and has been RESET as asked.', v_usr;
    ELSE
      RAISE NOTICE 'Account "%" was here but nobody could sign in with it (%). Repaired.',
        v_usr,
        CASE WHEN v_row.status <> 'active' THEN 'it was ' || v_row.status
             WHEN coalesce(v_row.password_hash, '') = '' THEN 'it had no password'
             ELSE 'it was locked' END;
    END IF;
    RETURN;
  END IF;

  -- Not there. display_id is NOT NULL and unique, so it has to be built - and
  -- it has to look like the ones already here rather than invent a third
  -- style. Staff accounts are U001..U044; NARS accounts use U-NARS-XXXXX.
  --
  -- Derived from the username, so re-running gives the same id rather than a
  -- new one each time. Then checked, because "unlikely to collide" is not the
  -- same as "cannot", and a collision would abort on the unique index.
  v_id := 'U-NARS-' || upper(substr(md5(v_usr), 1, 5));
  IF EXISTS (SELECT 1 FROM system_users WHERE display_id = v_id) THEN
    v_id := 'U-NARS-' || upper(substr(md5(v_usr), 1, 10));
  END IF;
  IF EXISTS (SELECT 1 FROM system_users WHERE display_id = v_id) THEN
    RAISE EXCEPTION 'Could not build a free display_id for "%". Tell me and I will pick one by hand.', v_usr;
  END IF;

  INSERT INTO system_users
    (display_id, username, email, first_name, last_name,
     role, user_group, password_hash, status, failed_attempts, must_change_password)
  VALUES
    (v_id, v_usr,
     coalesce(v_email, lower(v_usr) || '@health.gov.sc'),
     coalesce(v_first, initcap(split_part(v_usr, '.', 1))),
     coalesce(v_last,  initcap(NULLIF(split_part(v_usr, '.', 2), '')), 'Assessor'),
     v_role, v_grp,
     crypt(v_pwd, gen_salt('bf', 10)), 'active', 0, v_must);

  RAISE NOTICE 'Created "%" as % in the % group (%).', v_usr, v_role, v_grp, v_id;
END $$;

COMMIT;

-- ---------------------------------------------------------------------------
--  Prove it, WITHOUT calling hcis_login.
--
--  Calling the sign-in function to check a password is a trap on this system.
--  If the signing key is missing it raises, and that error is indistinguishable
--  from a wrong password - which is exactly the state this box is in when the
--  recovery starts. crypt() answers the real question and cannot be confused
--  by anything else being broken.
--
--  "the password above works" reads no when the account was left alone, and
--  that is correct: the password typed at the prompt is not that account's
--  password. The line next to it says so.
-- ---------------------------------------------------------------------------

\echo ''

SELECT username,
       role,
       user_group AS "group",
       status,
       CASE WHEN password_hash = crypt(:'pwd', password_hash)
            THEN 'yes'
            ELSE 'no - this account kept its own password'
       END AS "the password above works",
       CASE WHEN status = 'active' AND coalesce(password_hash,'') <> ''
             AND (locked_until IS NULL OR locked_until < now())
            THEN 'yes'
            ELSE 'NO'
       END AS "somebody can sign in",
       CASE WHEN must_change_password
            THEN 'yes - they pick their own at first sign-in'
            ELSE 'no'
       END AS "must change password"
  FROM system_users
 WHERE lower(username) = lower(:'usr');
