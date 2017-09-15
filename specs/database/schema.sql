--
-- PostgreSQL database dump
--

-- Dumped from database version 9.6.4
-- Dumped by pg_dump version 9.6.1

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: core; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA core;


--
-- Name: platform_service; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA platform_service;


--
-- Name: platform_service_api; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA platform_service_api;


--
-- Name: plpgsql; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plpgsql; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL procedural language';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


SET search_path = core, pg_catalog;

--
-- Name: jwt_token; Type: TYPE; Schema: core; Owner: -
--

CREATE TYPE jwt_token AS (
	token text
);


--
-- Name: algorithm_sign(text, text, text); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION algorithm_sign(signables text, secret text, algorithm text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  alg AS (
    SELECT CASE
      WHEN algorithm = 'HS256' THEN 'sha256'
      WHEN algorithm = 'HS384' THEN 'sha384'
      WHEN algorithm = 'HS512' THEN 'sha512'
      ELSE '' END AS id)  -- hmac throws error
SELECT core.url_encode(hmac(signables, secret, alg.id)) FROM alg;
$$;


--
-- Name: current_user_id(); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION current_user_id() RETURNS integer
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN nullif(current_setting('request.jwt.claim.user_id'), '')::integer;
EXCEPTION
WHEN others THEN
  RETURN NULL::integer;
END
    $$;


--
-- Name: FUNCTION current_user_id(); Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON FUNCTION current_user_id() IS 'Returns the user_id decoded on jwt';


--
-- Name: gen_jwt_token(json); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION gen_jwt_token(json) RETURNS jwt_token
    LANGUAGE sql STABLE
    AS $_$
        select core.sign($1, core.get_setting('jwt_secret'));
    $_$;


--
-- Name: FUNCTION gen_jwt_token(json); Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON FUNCTION gen_jwt_token(json) IS 'Generate a signed jwt';


--
-- Name: get_setting(character varying); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION get_setting(character varying) RETURNS text
    LANGUAGE sql STABLE
    AS $_$
        select value from core.core_settings cs where cs.name = $1
    $_$;


--
-- Name: FUNCTION get_setting(character varying); Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON FUNCTION get_setting(character varying) IS 'Get a value from a core settings on database';


--
-- Name: is_owner_or_admin(integer); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION is_owner_or_admin(integer) RETURNS boolean
    LANGUAGE sql STABLE
    AS $_$
        SELECT
            core.current_user_id() = $1
            OR current_user = 'admin';
    $_$;


--
-- Name: FUNCTION is_owner_or_admin(integer); Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON FUNCTION is_owner_or_admin(integer) IS 'Check if current_role is admin or passed id match with current_user_id';


--
-- Name: sign(json, text, text); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION sign(payload json, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  header AS (
    SELECT core.url_encode(convert_to('{"alg":"' || algorithm || '","typ":"JWT"}', 'utf8')) AS data
    ),
  payload AS (
    SELECT core.url_encode(convert_to(payload::text, 'utf8')) AS data
    ),
  signables AS (
    SELECT header.data || '.' || payload.data AS data FROM header, payload
    )
SELECT
    signables.data || '.' ||
    core.algorithm_sign(signables.data, secret, algorithm) FROM signables;
$$;


--
-- Name: url_decode(text); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION url_decode(data text) RETURNS bytea
    LANGUAGE sql
    AS $$
WITH t AS (SELECT translate(data, '-_', '+/') AS trans),
     rem AS (SELECT length(t.trans) % 4 AS remainder FROM t) -- compute padding size
    SELECT decode(
        t.trans ||
        CASE WHEN rem.remainder > 0
           THEN repeat('=', (4 - rem.remainder))
           ELSE '' END,
    'base64') FROM t, rem;
$$;


--
-- Name: url_encode(bytea); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION url_encode(data bytea) RETURNS text
    LANGUAGE sql
    AS $$
    SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;


--
-- Name: verify(text, text, text); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION verify(token text, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS TABLE(header json, payload json, valid boolean)
    LANGUAGE sql
    AS $$
  SELECT
    convert_from(core.url_decode(r[1]), 'utf8')::json AS header,
    convert_from(core.url_decode(r[2]), 'utf8')::json AS payload,
    r[3] = core.algorithm_sign(r[1] || '.' || r[2], secret, algorithm) AS valid
  FROM regexp_split_to_array(token, '\.') r;
$$;


SET search_path = platform_service, pg_catalog;

--
-- Name: user_in_platform(integer, integer); Type: FUNCTION; Schema: platform_service; Owner: -
--

CREATE FUNCTION user_in_platform(user_id integer, platform_id integer) RETURNS boolean
    LANGUAGE sql STABLE
    AS $_$
        select exists(select true from platform_service.platform_users pu where pu.user_id = $1 and pu.platform_id = $2);
    $_$;


--
-- Name: FUNCTION user_in_platform(user_id integer, platform_id integer); Type: COMMENT; Schema: platform_service; Owner: -
--

COMMENT ON FUNCTION user_in_platform(user_id integer, platform_id integer) IS 'Check if inputed user has access on inputed platform';


SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: platforms; Type: TABLE; Schema: platform_service; Owner: -
--

CREATE TABLE platforms (
    id integer NOT NULL,
    name text NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    token uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE platforms; Type: COMMENT; Schema: platform_service; Owner: -
--

COMMENT ON TABLE platforms IS 'hold platforms names/configurations';


SET search_path = platform_service_api, pg_catalog;

--
-- Name: create_platform(text); Type: FUNCTION; Schema: platform_service_api; Owner: -
--

CREATE FUNCTION create_platform(name text) RETURNS platform_service.platforms
    LANGUAGE plpgsql
    AS $_$
        declare
            platform platform_service.platforms;
        begin
            insert into platform_service.platforms(name)
                values($1)
            returning * into platform;

            insert into platform_service.platform_users (user_id, platform_id)
                values (core.current_user_id(), platform.id);

            return platform;
        end;
    $_$;


--
-- Name: FUNCTION create_platform(name text); Type: COMMENT; Schema: platform_service_api; Owner: -
--

COMMENT ON FUNCTION create_platform(name text) IS 'Create a new platform on current logged platform user';


SET search_path = platform_service, pg_catalog;

--
-- Name: platform_api_keys; Type: TABLE; Schema: platform_service; Owner: -
--

CREATE TABLE platform_api_keys (
    id integer NOT NULL,
    platform_id integer NOT NULL,
    token text NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    disabled_at timestamp without time zone
);


--
-- Name: platform_users; Type: TABLE; Schema: platform_service; Owner: -
--

CREATE TABLE platform_users (
    id integer NOT NULL,
    user_id integer NOT NULL,
    platform_id integer NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE platform_users; Type: COMMENT; Schema: platform_service; Owner: -
--

COMMENT ON TABLE platform_users IS 'Manage platform user with platform';


SET search_path = platform_service_api, pg_catalog;

--
-- Name: api_keys; Type: VIEW; Schema: platform_service_api; Owner: -
--

CREATE VIEW api_keys AS
 SELECT pak.id,
    pak.platform_id,
    pak.token,
    pak.created_at,
    pak.disabled_at
   FROM (platform_service.platform_api_keys pak
     JOIN platform_service.platform_users pu ON ((pu.platform_id = pak.platform_id)))
  WHERE (core.is_owner_or_admin(pu.user_id) AND (pak.disabled_at IS NULL));


--
-- Name: VIEW api_keys; Type: COMMENT; Schema: platform_service_api; Owner: -
--

COMMENT ON VIEW api_keys IS 'List all api keys from platform that user have access';


--
-- Name: generate_api_key(integer); Type: FUNCTION; Schema: platform_service_api; Owner: -
--

CREATE FUNCTION generate_api_key(platform_id integer) RETURNS api_keys
    LANGUAGE plpgsql
    AS $_$
        declare
            _platform_token uuid;
            _result platform_service.platform_api_keys;
        begin
            if not platform_service.user_in_platform(current_user_id(), $1) then
                raise exception 'insufficient permissions to do this action';
            end if;

            select token from platform_service.platforms p where p.id = $1
                into _platform_token;

            insert into platform_service.platform_api_keys(platform_id, token)
                values ($1, core.gen_jwt_token(json_build_object(
                    'role', 'platform_user',
                    'platform_token', _platform_token,
                    'gen_at', extract(epoch from now())::integer
                )))
            returning * into _result;

            return _result;
        end;
    $_$;


--
-- Name: FUNCTION generate_api_key(platform_id integer); Type: COMMENT; Schema: platform_service_api; Owner: -
--

COMMENT ON FUNCTION generate_api_key(platform_id integer) IS 'Generate a new API_KEY for given platform';


--
-- Name: login(text, text); Type: FUNCTION; Schema: platform_service_api; Owner: -
--

CREATE FUNCTION login(email text, password text) RETURNS core.jwt_token
    LANGUAGE plpgsql
    AS $_$
declare
    _user platform_service.users;
    result core.jwt_token;
begin
    select
        u.*
    from platform_service.users u
        where lower(u.email) = lower($1)
            and u.password = crypt($2, u.password)
        into _user;

    if _user is null then
        raise invalid_password using message = 'invalid user or password';
    end if;

    select core.gen_jwt_token(
        row_to_json(r)
    ) as token
    from (
        select
            'platform_user' as role,
            _user.id as user_id,
            extract(epoch from now())::integer + (60*60)*2 as exp
    ) r
    into result;

    return result;
end;
$_$;


--
-- Name: FUNCTION login(email text, password text); Type: COMMENT; Schema: platform_service_api; Owner: -
--

COMMENT ON FUNCTION login(email text, password text) IS 'Handles with platform users authentication';


--
-- Name: sign_up(text, text, text); Type: FUNCTION; Schema: platform_service_api; Owner: -
--

CREATE FUNCTION sign_up(name text, email text, password text) RETURNS core.jwt_token
    LANGUAGE plpgsql
    AS $$
    declare
        _user platform_service.users;
        result core.jwt_token;
    begin
        insert into platform_service.users(name, email, password)
            values (name, email, crypt(password, gen_salt('bf')))
            returning * into _user;

        select core.gen_jwt_token(
            row_to_json(r)
        ) as token
        from (
            select
                'platform_user' as role,
                _user.id as user_id,
                extract(epoch from now())::integer + (60*60)*2 as exp
        ) r
        into result;

        return result;
    end;
$$;


--
-- Name: FUNCTION sign_up(name text, email text, password text); Type: COMMENT; Schema: platform_service_api; Owner: -
--

COMMENT ON FUNCTION sign_up(name text, email text, password text) IS 'Handles with creation of new platform users';


SET search_path = public, pg_catalog;

--
-- Name: diesel_manage_updated_at(regclass); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION diesel_manage_updated_at(_tbl regclass) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    EXECUTE format('CREATE TRIGGER set_updated_at BEFORE UPDATE ON %s
                    FOR EACH ROW EXECUTE PROCEDURE diesel_set_updated_at()', _tbl);
END;
$$;


--
-- Name: diesel_set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION diesel_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (
        NEW IS DISTINCT FROM OLD AND
        NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at
    ) THEN
        NEW.updated_at := current_timestamp;
    END IF;
    RETURN NEW;
END;
$$;


SET search_path = core, pg_catalog;

--
-- Name: core_settings; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core_settings (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    value text NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE core_settings; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core_settings IS 'hold global settings for another services';


--
-- Name: core_settings_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: core_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core_settings_id_seq OWNED BY core_settings.id;


SET search_path = platform_service, pg_catalog;

--
-- Name: platform_api_keys_id_seq; Type: SEQUENCE; Schema: platform_service; Owner: -
--

CREATE SEQUENCE platform_api_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platform_api_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: platform_service; Owner: -
--

ALTER SEQUENCE platform_api_keys_id_seq OWNED BY platform_api_keys.id;


--
-- Name: platform_users_id_seq; Type: SEQUENCE; Schema: platform_service; Owner: -
--

CREATE SEQUENCE platform_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platform_users_id_seq; Type: SEQUENCE OWNED BY; Schema: platform_service; Owner: -
--

ALTER SEQUENCE platform_users_id_seq OWNED BY platform_users.id;


--
-- Name: platforms_id_seq; Type: SEQUENCE; Schema: platform_service; Owner: -
--

CREATE SEQUENCE platforms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platforms_id_seq; Type: SEQUENCE OWNED BY; Schema: platform_service; Owner: -
--

ALTER SEQUENCE platforms_id_seq OWNED BY platforms.id;


--
-- Name: users; Type: TABLE; Schema: platform_service; Owner: -
--

CREATE TABLE users (
    id integer NOT NULL,
    email text NOT NULL,
    password text NOT NULL,
    name text NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    email_confirmed_at timestamp without time zone,
    disabled_at timestamp without time zone,
    CONSTRAINT users_email_check CHECK ((email ~* '^.+@.+\..+$'::text)),
    CONSTRAINT users_name_check CHECK ((length(name) < 255)),
    CONSTRAINT users_password_check CHECK ((length(password) < 512))
);


--
-- Name: TABLE users; Type: COMMENT; Schema: platform_service; Owner: -
--

COMMENT ON TABLE users IS 'Platform admin users';


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: platform_service; Owner: -
--

CREATE SEQUENCE users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: platform_service; Owner: -
--

ALTER SEQUENCE users_id_seq OWNED BY users.id;


SET search_path = public, pg_catalog;

--
-- Name: __diesel_schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE __diesel_schema_migrations (
    version character varying(50) NOT NULL,
    run_on timestamp without time zone DEFAULT now() NOT NULL
);


SET search_path = core, pg_catalog;

--
-- Name: core_settings id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core_settings ALTER COLUMN id SET DEFAULT nextval('core_settings_id_seq'::regclass);


SET search_path = platform_service, pg_catalog;

--
-- Name: platform_api_keys id; Type: DEFAULT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_api_keys ALTER COLUMN id SET DEFAULT nextval('platform_api_keys_id_seq'::regclass);


--
-- Name: platform_users id; Type: DEFAULT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_users ALTER COLUMN id SET DEFAULT nextval('platform_users_id_seq'::regclass);


--
-- Name: platforms id; Type: DEFAULT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platforms ALTER COLUMN id SET DEFAULT nextval('platforms_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY users ALTER COLUMN id SET DEFAULT nextval('users_id_seq'::regclass);


SET search_path = core, pg_catalog;

--
-- Name: core_settings core_settings_name_key; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core_settings
    ADD CONSTRAINT core_settings_name_key UNIQUE (name);


--
-- Name: core_settings core_settings_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core_settings
    ADD CONSTRAINT core_settings_pkey PRIMARY KEY (id);


SET search_path = platform_service, pg_catalog;

--
-- Name: platform_api_keys platform_api_keys_pkey; Type: CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_api_keys
    ADD CONSTRAINT platform_api_keys_pkey PRIMARY KEY (id);


--
-- Name: platform_api_keys platform_api_keys_token_key; Type: CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_api_keys
    ADD CONSTRAINT platform_api_keys_token_key UNIQUE (token);


--
-- Name: platform_users platform_users_pkey; Type: CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_users
    ADD CONSTRAINT platform_users_pkey PRIMARY KEY (id);


--
-- Name: platforms platforms_pkey; Type: CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platforms
    ADD CONSTRAINT platforms_pkey PRIMARY KEY (id);


--
-- Name: platforms platforms_token_key; Type: CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platforms
    ADD CONSTRAINT platforms_token_key UNIQUE (token);


--
-- Name: users uidx_users_email; Type: CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY users
    ADD CONSTRAINT uidx_users_email UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: platform_users uuidx_user_and_platform; Type: CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_users
    ADD CONSTRAINT uuidx_user_and_platform UNIQUE (user_id, platform_id);


SET search_path = public, pg_catalog;

--
-- Name: __diesel_schema_migrations __diesel_schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY __diesel_schema_migrations
    ADD CONSTRAINT __diesel_schema_migrations_pkey PRIMARY KEY (version);


SET search_path = core, pg_catalog;

--
-- Name: core_settings set_updated_at; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON core_settings FOR EACH ROW EXECUTE PROCEDURE public.diesel_set_updated_at();


SET search_path = platform_service, pg_catalog;

--
-- Name: platforms set_updated_at; Type: TRIGGER; Schema: platform_service; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON platforms FOR EACH ROW EXECUTE PROCEDURE public.diesel_set_updated_at();


--
-- Name: users set_updated_at; Type: TRIGGER; Schema: platform_service; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE PROCEDURE public.diesel_set_updated_at();


--
-- Name: platform_users set_updated_at; Type: TRIGGER; Schema: platform_service; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON platform_users FOR EACH ROW EXECUTE PROCEDURE public.diesel_set_updated_at();


--
-- Name: platform_api_keys platform_api_keys_platform_id_fkey; Type: FK CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_api_keys
    ADD CONSTRAINT platform_api_keys_platform_id_fkey FOREIGN KEY (platform_id) REFERENCES platforms(id);


--
-- Name: platform_users platform_users_platform_id_fkey; Type: FK CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_users
    ADD CONSTRAINT platform_users_platform_id_fkey FOREIGN KEY (platform_id) REFERENCES platforms(id);


--
-- Name: platform_users platform_users_user_id_fkey; Type: FK CONSTRAINT; Schema: platform_service; Owner: -
--

ALTER TABLE ONLY platform_users
    ADD CONSTRAINT platform_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id);


--
-- Name: core; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA core TO anonymous;
GRANT USAGE ON SCHEMA core TO scoped_user;
GRANT USAGE ON SCHEMA core TO postgrest;
GRANT USAGE ON SCHEMA core TO platform_user;


--
-- Name: platform_service; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA platform_service TO anonymous;
GRANT USAGE ON SCHEMA platform_service TO admin;
GRANT USAGE ON SCHEMA platform_service TO postgrest;
GRANT USAGE ON SCHEMA platform_service TO platform_user;


--
-- Name: platform_service_api; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA platform_service_api TO anonymous;
GRANT USAGE ON SCHEMA platform_service_api TO admin;
GRANT USAGE ON SCHEMA platform_service_api TO postgrest;
GRANT USAGE ON SCHEMA platform_service_api TO platform_user;


--
-- Name: platforms; Type: ACL; Schema: platform_service; Owner: -
--

GRANT SELECT,INSERT ON TABLE platforms TO admin;
GRANT SELECT,INSERT ON TABLE platforms TO platform_user;


SET search_path = platform_service_api, pg_catalog;

--
-- Name: create_platform(text); Type: ACL; Schema: platform_service_api; Owner: -
--

GRANT ALL ON FUNCTION create_platform(name text) TO platform_user;


SET search_path = platform_service, pg_catalog;

--
-- Name: platform_api_keys; Type: ACL; Schema: platform_service; Owner: -
--

GRANT SELECT,INSERT ON TABLE platform_api_keys TO admin;
GRANT SELECT,INSERT ON TABLE platform_api_keys TO platform_user;


--
-- Name: platform_users; Type: ACL; Schema: platform_service; Owner: -
--

GRANT SELECT,INSERT ON TABLE platform_users TO admin;
GRANT SELECT,INSERT ON TABLE platform_users TO platform_user;


SET search_path = platform_service_api, pg_catalog;

--
-- Name: api_keys; Type: ACL; Schema: platform_service_api; Owner: -
--

GRANT SELECT ON TABLE api_keys TO admin;
GRANT SELECT ON TABLE api_keys TO platform_user;


--
-- Name: generate_api_key(integer); Type: ACL; Schema: platform_service_api; Owner: -
--

GRANT ALL ON FUNCTION generate_api_key(platform_id integer) TO admin;
GRANT ALL ON FUNCTION generate_api_key(platform_id integer) TO platform_user;


--
-- Name: login(text, text); Type: ACL; Schema: platform_service_api; Owner: -
--

GRANT ALL ON FUNCTION login(email text, password text) TO anonymous;


--
-- Name: sign_up(text, text, text); Type: ACL; Schema: platform_service_api; Owner: -
--

GRANT ALL ON FUNCTION sign_up(name text, email text, password text) TO anonymous;


SET search_path = core, pg_catalog;

--
-- Name: core_settings; Type: ACL; Schema: core; Owner: -
--

GRANT SELECT ON TABLE core_settings TO platform_user;
GRANT SELECT ON TABLE core_settings TO anonymous;
GRANT SELECT ON TABLE core_settings TO scoped_user;


SET search_path = platform_service, pg_catalog;

--
-- Name: platform_api_keys_id_seq; Type: ACL; Schema: platform_service; Owner: -
--

GRANT SELECT,UPDATE ON SEQUENCE platform_api_keys_id_seq TO admin;
GRANT SELECT,UPDATE ON SEQUENCE platform_api_keys_id_seq TO platform_user;


--
-- Name: platform_users_id_seq; Type: ACL; Schema: platform_service; Owner: -
--

GRANT ALL ON SEQUENCE platform_users_id_seq TO admin;
GRANT ALL ON SEQUENCE platform_users_id_seq TO platform_user;


--
-- Name: platforms_id_seq; Type: ACL; Schema: platform_service; Owner: -
--

GRANT ALL ON SEQUENCE platforms_id_seq TO admin;
GRANT ALL ON SEQUENCE platforms_id_seq TO platform_user;


--
-- Name: users; Type: ACL; Schema: platform_service; Owner: -
--

GRANT SELECT,INSERT ON TABLE users TO anonymous;
GRANT SELECT,INSERT ON TABLE users TO admin;
GRANT SELECT,INSERT ON TABLE users TO platform_user;


--
-- Name: users_id_seq; Type: ACL; Schema: platform_service; Owner: -
--

GRANT ALL ON SEQUENCE users_id_seq TO admin;
GRANT ALL ON SEQUENCE users_id_seq TO platform_user;
GRANT ALL ON SEQUENCE users_id_seq TO anonymous;


--
-- PostgreSQL database dump complete
--

