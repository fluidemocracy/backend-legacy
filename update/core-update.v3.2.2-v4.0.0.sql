ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'unit_created';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'unit_updated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'unit_removed';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'subject_area_created';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'subject_area_updated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'subject_area_removed';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'policy_created';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'policy_updated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'policy_removed';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'suggestion_removed';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'member_activated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'member_removed';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'member_active';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'member_name_updated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'member_profile_updated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'member_image_updated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'interest';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'initiator';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'support';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'support_updated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'suggestion_rated';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'delegation';
ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'contact';


BEGIN;


CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.0-dev', 4, 0, -1))
  AS "subquery"("string", "major", "minor", "revision");


ALTER TABLE "system_setting" ADD COLUMN "snapshot_retention" INTERVAL;

COMMENT ON COLUMN "system_setting"."snapshot_retention" IS 'Unreferenced snapshots are retained for the given period of time after creation; set to NULL for infinite retention.';
 
 
CREATE TABLE "member_profile" (
        "member_id"             INT4            PRIMARY KEY REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "formatting_engine"     TEXT,
        "statement"             TEXT,
        "profile"               JSONB,
        "profile_text_data"     TEXT,
        "text_search_data"      TSVECTOR );
CREATE INDEX "member_profile_text_search_data_idx" ON "member_profile" USING gin ("text_search_data");
CREATE TRIGGER "update_text_search_data"
  BEFORE INSERT OR UPDATE ON "member_profile"
  FOR EACH ROW EXECUTE PROCEDURE
  tsvector_update_trigger('text_search_data', 'pg_catalog.simple',
    'statement', 'profile_text_data');

COMMENT ON COLUMN "member_profile"."formatting_engine" IS 'Allows different formatting engines (i.e. wiki formats) to be used for "member_profile"."statement"';
COMMENT ON COLUMN "member_profile"."statement"         IS 'Freely chosen text of the member for his/her profile';
COMMENT ON COLUMN "member_profile"."profile"           IS 'Additional profile data as JSON document';
COMMENT ON COLUMN "member_profile"."profile_text_data" IS 'Text data from "profile" field for full text search';


INSERT INTO "member_profile"
  ( "member_id", "formatting_engine", "statement", "profile")
  SELECT
    "id" AS "member_id",
    "formatting_engine",
    "statement",
    json_build_object(
      'organizational_unit', "organizational_unit",
      'internal_posts', "internal_posts",
      'realname', "realname",
      'birthday', to_char("birthday", 'YYYY-MM-DD'),
      'address', "address",
      'email', "email",
      'xmpp_address', "xmpp_address",
      'website', "website",
      'phone', "phone",
      'mobile_phone', "mobile_phone",
      'profession', "profession",
      'external_memberships', "external_memberships",
      'external_posts', "external_posts"
    ) AS "profile"
  FROM "member";

UPDATE "member_profile" SET "profile_text_data" =
  coalesce(("profile"->>'organizational_unit') || ' ', '') ||
  coalesce(("profile"->>'internal_posts') || ' ', '') ||
  coalesce(("profile"->>'realname') || ' ', '') ||
  coalesce(("profile"->>'birthday') || ' ', '') ||
  coalesce(("profile"->>'address') || ' ', '') ||
  coalesce(("profile"->>'email') || ' ', '') ||
  coalesce(("profile"->>'xmpp_address') || ' ', '') ||
  coalesce(("profile"->>'website') || ' ', '') ||
  coalesce(("profile"->>'phone') || ' ', '') ||
  coalesce(("profile"->>'mobile_phone') || ' ', '') ||
  coalesce(("profile"->>'profession') || ' ', '') ||
  coalesce(("profile"->>'external_memberships') || ' ', '') ||
  coalesce(("profile"->>'external_posts') || ' ', '');


DROP VIEW "newsletter_to_send";
DROP VIEW "scheduled_notification_to_send";
DROP VIEW "member_to_notify";
DROP VIEW "member_eligible_to_be_notified";


ALTER TABLE "member" DROP COLUMN "organizational_unit";
ALTER TABLE "member" DROP COLUMN "internal_posts";
ALTER TABLE "member" DROP COLUMN "realname";
ALTER TABLE "member" DROP COLUMN "birthday";
ALTER TABLE "member" DROP COLUMN "address";
ALTER TABLE "member" DROP COLUMN "email";
ALTER TABLE "member" DROP COLUMN "xmpp_address";
ALTER TABLE "member" DROP COLUMN "website";
ALTER TABLE "member" DROP COLUMN "phone";
ALTER TABLE "member" DROP COLUMN "mobile_phone";
ALTER TABLE "member" DROP COLUMN "profession";
ALTER TABLE "member" DROP COLUMN "external_memberships";
ALTER TABLE "member" DROP COLUMN "external_posts";
ALTER TABLE "member" DROP COLUMN "formatting_engine";
ALTER TABLE "member" DROP COLUMN "statement";

ALTER TABLE "member" ADD COLUMN "location" JSONB;
COMMENT ON COLUMN "member"."location" IS 'Geographic location on earth as GeoJSON object';
CREATE INDEX "member_location_idx" ON "member" USING gist ((GeoJSON_to_ecluster("location")));

DROP TRIGGER "update_text_search_data" ON "member";
CREATE TRIGGER "update_text_search_data"
  BEFORE INSERT OR UPDATE ON "member"
  FOR EACH ROW EXECUTE PROCEDURE
  tsvector_update_trigger('text_search_data', 'pg_catalog.simple',
    "name", "identification");
 

CREATE VIEW "member_eligible_to_be_notified" AS
  SELECT * FROM "member"
  WHERE "activated" NOTNULL AND "locked" = FALSE;

COMMENT ON VIEW "member_eligible_to_be_notified" IS 'Filtered "member" table containing only activated and non-locked members (used as helper view for "member_to_notify" and "newsletter_to_send")';


CREATE VIEW "member_to_notify" AS
  SELECT * FROM "member_eligible_to_be_notified"
  WHERE "disable_notifications" = FALSE;

COMMENT ON VIEW "member_to_notify" IS 'Filtered "member" table containing only members that are eligible to and wish to receive notifications; NOTE: "notify_email" may still be NULL and might need to be checked by frontend (this allows other means of messaging)';


CREATE VIEW "scheduled_notification_to_send" AS
  SELECT * FROM (
    SELECT
      "id" AS "recipient_id",
      now() - CASE WHEN "notification_dow" ISNULL THEN
        ( "notification_sent"::DATE + CASE
          WHEN EXTRACT(HOUR FROM "notification_sent") < "notification_hour"
          THEN 0 ELSE 1 END
        )::TIMESTAMP + '1 hour'::INTERVAL * "notification_hour"
      ELSE
        ( "notification_sent"::DATE +
          ( 7 + "notification_dow" -
            EXTRACT(DOW FROM
              ( "notification_sent"::DATE + CASE
                WHEN EXTRACT(HOUR FROM "notification_sent") < "notification_hour"
                THEN 0 ELSE 1 END
              )::TIMESTAMP + '1 hour'::INTERVAL * "notification_hour"
            )::INTEGER
          ) % 7 +
          CASE
            WHEN EXTRACT(HOUR FROM "notification_sent") < "notification_hour"
            THEN 0 ELSE 1
          END
        )::TIMESTAMP + '1 hour'::INTERVAL * "notification_hour"
      END AS "pending"
    FROM (
      SELECT
        "id",
        COALESCE("notification_sent", "activated") AS "notification_sent",
        "notification_dow",
        "notification_hour"
      FROM "member_to_notify"
      WHERE "notification_hour" NOTNULL
    ) AS "subquery1"
  ) AS "subquery2"
  WHERE "pending" > '0'::INTERVAL;

COMMENT ON VIEW "scheduled_notification_to_send" IS 'Set of members where a scheduled notification mail is pending';

COMMENT ON COLUMN "scheduled_notification_to_send"."recipient_id" IS '"id" of the member who needs to receive a notification mail';
COMMENT ON COLUMN "scheduled_notification_to_send"."pending"      IS 'Duration for which the notification mail has already been pending';


CREATE VIEW "newsletter_to_send" AS
  SELECT
    "member"."id" AS "recipient_id",
    "newsletter"."id" AS "newsletter_id",
    "newsletter"."published"
  FROM "newsletter" CROSS JOIN "member_eligible_to_be_notified" AS "member"
  LEFT JOIN "privilege" ON
    "privilege"."member_id" = "member"."id" AND
    "privilege"."unit_id" = "newsletter"."unit_id" AND
    "privilege"."voting_right" = TRUE
  LEFT JOIN "subscription" ON
    "subscription"."member_id" = "member"."id" AND
    "subscription"."unit_id" = "newsletter"."unit_id"
  WHERE "newsletter"."published" <= now()
  AND "newsletter"."sent" ISNULL
  AND (
    "member"."disable_notifications" = FALSE OR
    "newsletter"."include_all_members" = TRUE )
  AND (
    "newsletter"."unit_id" ISNULL OR
    "privilege"."member_id" NOTNULL OR
    "subscription"."member_id" NOTNULL );

COMMENT ON VIEW "newsletter_to_send" IS 'List of "newsletter_id"s for each member that are due to be sent out';

COMMENT ON COLUMN "newsletter"."published" IS 'Timestamp when the newsletter was supposed to be sent out (can be used for ordering)';


DROP VIEW "expired_session";
DROP TABLE "session";


CREATE TABLE "session" (
        UNIQUE ("member_id", "id"),  -- index needed for foreign-key on table "token"
        "id"                    SERIAL8         PRIMARY KEY,
        "ident"                 TEXT            NOT NULL UNIQUE,
        "additional_secret"     TEXT,
        "logout_token"          TEXT,
        "expiry"                TIMESTAMPTZ     NOT NULL DEFAULT now() + '24 hours',
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE SET NULL,
        "authority"             TEXT,
        "authority_uid"         TEXT,
        "authority_login"       TEXT,
        "needs_delegation_check" BOOLEAN        NOT NULL DEFAULT FALSE,
        "lang"                  TEXT );
CREATE INDEX "session_expiry_idx" ON "session" ("expiry");

COMMENT ON TABLE "session" IS 'Sessions, i.e. for a web-frontend or API layer';

COMMENT ON COLUMN "session"."ident"             IS 'Secret session identifier (i.e. random string)';
COMMENT ON COLUMN "session"."additional_secret" IS 'Additional field to store a secret, which can be used against CSRF attacks';
COMMENT ON COLUMN "session"."logout_token"      IS 'Optional token to authorize logout through external component';
COMMENT ON COLUMN "session"."member_id"         IS 'Reference to member, who is logged in';
COMMENT ON COLUMN "session"."authority"         IS 'Temporary store for "member"."authority" during member account creation';
COMMENT ON COLUMN "session"."authority_uid"     IS 'Temporary store for "member"."authority_uid" during member account creation';
COMMENT ON COLUMN "session"."authority_login"   IS 'Temporary store for "member"."authority_login" during member account creation';
COMMENT ON COLUMN "session"."needs_delegation_check" IS 'Set to TRUE, if member must perform a delegation check to proceed with login; see column "last_delegation_check" in "member" table';
COMMENT ON COLUMN "session"."lang"              IS 'Language code of the selected language';


CREATE TYPE "authflow" AS ENUM ('code', 'token');

COMMENT ON TYPE "authflow" IS 'OAuth 2.0 flows: ''code'' = Authorization Code flow, ''token'' = Implicit flow';


CREATE TABLE "system_application" (
        "id"                    SERIAL4         PRIMARY KEY,
        "name"                  TEXT            NOT NULL,
        "client_id"             TEXT            NOT NULL UNIQUE,
        "default_redirect_uri"  TEXT            NOT NULL,
        "cert_common_name"      TEXT,
        "client_cred_scope"     TEXT,
        "flow"                  "authflow",
        "automatic_scope"       TEXT,
        "permitted_scope"       TEXT,
        "forbidden_scope"       TEXT );

COMMENT ON TABLE "system_application" IS 'OAuth 2.0 clients that are registered by the system administrator';

COMMENT ON COLUMN "system_application"."name"              IS 'Human readable name of application';
COMMENT ON COLUMN "system_application"."client_id"         IS 'OAuth 2.0 "client_id"';
COMMENT ON COLUMN "system_application"."cert_common_name"  IS 'Value for CN field of TLS client certificate';
COMMENT ON COLUMN "system_application"."client_cred_scope" IS 'Space-separated list of scopes; If set, Client Credentials Grant is allowed; value determines scope';
COMMENT ON COLUMN "system_application"."flow"              IS 'If set to ''code'' or ''token'', then Authorization Code or Implicit flow is allowed respectively';
COMMENT ON COLUMN "system_application"."automatic_scope"   IS 'Space-separated list of scopes; Automatically granted scope for Authorization Code or Implicit flow';
COMMENT ON COLUMN "system_application"."permitted_scope"   IS 'Space-separated list of scopes; If set, scope that members may grant to the application is limited to the given value';
COMMENT ON COLUMN "system_application"."forbidden_scope"   IS 'Space-separated list of scopes that may not be granted to the application by a member';


CREATE TABLE "system_application_redirect_uri" (
        PRIMARY KEY ("system_application_id", "redirect_uri"),
        "system_application_id" INT4            REFERENCES "system_application" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "redirect_uri"          TEXT );

COMMENT ON TABLE "system_application_redirect_uri" IS 'Additional OAuth 2.0 redirection endpoints, which may be selected through the "redirect_uri" GET parameter';


CREATE TABLE "dynamic_application_scope" (
        PRIMARY KEY ("redirect_uri", "flow", "scope"),
        "redirect_uri"          TEXT,
        "flow"                  TEXT,
        "scope"                 TEXT,
        "expiry"                TIMESTAMPTZ     NOT NULL DEFAULT now() + '24 hours' );
CREATE INDEX "dynamic_application_scope_redirect_uri_scope_idx" ON "dynamic_application_scope" ("redirect_uri", "flow", "scope");
CREATE INDEX "dynamic_application_scope_expiry_idx" ON "dynamic_application_scope" ("expiry");

COMMENT ON TABLE "dynamic_application_scope" IS 'Dynamic OAuth 2.0 client registration data';

COMMENT ON COLUMN "dynamic_application_scope"."redirect_uri" IS 'Redirection endpoint for which the registration has been done';
COMMENT ON COLUMN "dynamic_application_scope"."flow"         IS 'OAuth 2.0 flow for which the registration has been done (see also "system_application"."flow")';
COMMENT ON COLUMN "dynamic_application_scope"."scope"        IS 'Single scope without space characters (use multiple rows for more scopes)';
COMMENT ON COLUMN "dynamic_application_scope"."expiry"       IS 'Expiry unless renewed';


CREATE TABLE "member_application" (
        "id"                    SERIAL4         PRIMARY KEY,
        UNIQUE ("system_application_id", "member_id"),
        UNIQUE ("domain", "member_id"),
        "member_id"             INT4            NOT NULL REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "system_application_id" INT4            REFERENCES "system_application" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "domain"                TEXT,
        "session_id"            INT8,
        FOREIGN KEY ("member_id", "session_id") REFERENCES "session" ("member_id", "id") ON DELETE CASCADE ON UPDATE CASCADE,
        "scope"                 TEXT            NOT NULL,
        CONSTRAINT "system_application_or_domain_but_not_both" CHECK (
          ("system_application_id" NOTNULL AND "domain" ISNULL) OR
          ("system_application_id" ISNULL AND "domain" NOTNULL) ) );
CREATE INDEX "member_application_member_id_idx" ON "member_application" ("member_id");

COMMENT ON TABLE "member_application" IS 'Application authorized by a member';

COMMENT ON COLUMN "member_application"."system_application_id" IS 'If set, then application is a system application';
COMMENT ON COLUMN "member_application"."domain"                IS 'If set, then application is a dynamically registered OAuth 2.0 client; value is set to client''s domain';
COMMENT ON COLUMN "member_application"."session_id"            IS 'If set, registration ends with session';
COMMENT ON COLUMN "member_application"."scope"                 IS 'Granted scope as space-separated list of strings';


CREATE TYPE "token_type" AS ENUM ('authorization', 'refresh', 'access');

COMMENT ON TYPE "token_type" IS 'Types for entries in "token" table';


CREATE TABLE "token" (
        "id"                    SERIAL8         PRIMARY KEY,
        "token"                 TEXT            NOT NULL UNIQUE,
        "token_type"            "token_type"    NOT NULL,
        "authorization_token_id" INT8           REFERENCES "token" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            NOT NULL REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "system_application_id" INT4            REFERENCES "system_application" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "domain"                TEXT,
        FOREIGN KEY ("member_id", "domain") REFERENCES "member_application" ("member_id", "domain") ON DELETE CASCADE ON UPDATE CASCADE,
        "session_id"            INT8,
        FOREIGN KEY ("member_id", "session_id") REFERENCES "session" ("member_id", "id") ON DELETE RESTRICT ON UPDATE CASCADE,  -- NOTE: deletion through "detach_token_from_session" trigger on table "session"
        "redirect_uri"          TEXT,
        "redirect_uri_explicit" BOOLEAN,
        "created"               TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "expiry"                TIMESTAMPTZ     DEFAULT now() + '1 hour',
        "used"                  BOOLEAN         NOT NULL DEFAULT FALSE,
        "scope"                 TEXT            NOT NULL,
        CONSTRAINT "access_token_needs_expiry"
          CHECK ("token_type" != 'access'::"token_type" OR "expiry" NOTNULL),
        CONSTRAINT "authorization_token_needs_redirect_uri"
          CHECK ("token_type" != 'authorization'::"token_type" OR ("redirect_uri" NOTNULL AND "redirect_uri_explicit" NOTNULL) ) );
CREATE INDEX "token_member_id_idx" ON "token" ("member_id");
CREATE INDEX "token_authorization_token_id_idx" ON "token" ("authorization_token_id");
CREATE INDEX "token_expiry_idx" ON "token" ("expiry");

COMMENT ON TABLE "token" IS 'Issued OAuth 2.0 authorization codes and access/refresh tokens';

COMMENT ON COLUMN "token"."token"                  IS 'String secret (the actual token)';
COMMENT ON COLUMN "token"."authorization_token_id" IS 'Reference to authorization token if tokens were originally created by Authorization Code flow (allows deletion if code is used twice)';
COMMENT ON COLUMN "token"."system_application_id"  IS 'If set, then application is a system application';
COMMENT ON COLUMN "token"."domain"                 IS 'If set, then application is a dynamically registered OAuth 2.0 client; value is set to client''s domain';
COMMENT ON COLUMN "token"."session_id"             IS 'If set, then token is tied to a session; Deletion of session sets value to NULL (via trigger) and removes all scopes without suffix ''_detached''';
COMMENT ON COLUMN "token"."redirect_uri"           IS 'Authorization codes must be bound to a specific redirect URI';
COMMENT ON COLUMN "token"."redirect_uri_explicit"  IS 'True if ''redirect_uri'' parameter was explicitly specified during authorization request of the Authorization Code flow (since RFC 6749 requires it to be included in the access token request in this case)';
COMMENT ON COLUMN "token"."expiry"                 IS 'Point in time when code or token expired; In case of "used" authorization codes, authorization code must not be deleted as long as tokens exist which refer to the authorization code';
COMMENT ON COLUMN "token"."used"                   IS 'Can be set to TRUE for authorization codes that have been used (enables deletion of authorization codes that were used twice)';
COMMENT ON COLUMN "token"."scope"                  IS 'Scope as space-separated list of strings (detached scopes are marked with ''_detached'' suffix)';


CREATE TABLE "token_scope" (
        PRIMARY KEY ("token_id", "index"),
        "token_id"              INT8            REFERENCES "token" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "index"                 INT4,
        "scope"                 TEXT            NOT NULL );

COMMENT ON TABLE "token_scope" IS 'Additional scopes for an authorization code if ''scope1'', ''scope2'', etc. parameters were used during Authorization Code flow to request several access and refresh tokens at once';


ALTER TABLE "policy" ADD COLUMN "issue_quorum" INT4 CHECK ("issue_quorum" >= 1);
ALTER TABLE "policy" ADD COLUMN "initiative_quorum" INT4 CHECK ("initiative_quorum" >= 1);

UPDATE "policy" SET "issue_quorum" = 1 WHERE "issue_quorum_num" NOTNULL;
UPDATE "policy" SET "initiative_quorum" = 1;

ALTER TABLE "policy" ALTER COLUMN "initiative_quorum" SET NOT NULL;

ALTER TABLE "policy" DROP CONSTRAINT "timing";
ALTER TABLE "policy" DROP CONSTRAINT "issue_quorum_if_and_only_if_not_polling";
ALTER TABLE "policy" ADD CONSTRAINT
  "issue_quorum_if_and_only_if_not_polling" CHECK (
    "polling" = ("issue_quorum"     ISNULL) AND
    "polling" = ("issue_quorum_num" ISNULL) AND
    "polling" = ("issue_quorum_den" ISNULL)
  );
ALTER TABLE "policy" ADD CONSTRAINT
  "min_admission_time_smaller_than_max_admission_time" CHECK (
    "min_admission_time" < "max_admission_time"
  );
ALTER TABLE "policy" ADD CONSTRAINT
  "timing_null_or_not_null_constraints" CHECK (
    ( "polling" = FALSE AND
      "min_admission_time" NOTNULL AND "max_admission_time" NOTNULL AND
      "discussion_time" NOTNULL AND
      "verification_time" NOTNULL AND
      "voting_time" NOTNULL ) OR
    ( "polling" = TRUE AND
      "min_admission_time" ISNULL AND "max_admission_time" ISNULL AND
      "discussion_time" NOTNULL AND
      "verification_time" NOTNULL AND
      "voting_time" NOTNULL ) OR
    ( "polling" = TRUE AND
      "min_admission_time" ISNULL AND "max_admission_time" ISNULL AND
      "discussion_time" ISNULL AND
      "verification_time" ISNULL AND
      "voting_time" ISNULL )
  );

COMMENT ON COLUMN "policy"."min_admission_time"    IS 'Minimum duration of issue state ''admission''; Minimum time an issue stays open; Note: should be considerably smaller than "max_admission_time"';
COMMENT ON COLUMN "policy"."issue_quorum"          IS 'Absolute number of supporters needed by an initiative to be "accepted", i.e. pass from ''admission'' to ''discussion'' state';
COMMENT ON COLUMN "policy"."issue_quorum_num"      IS 'Numerator of supporter quorum to be reached by an initiative to be "accepted", i.e. pass from ''admission'' to ''discussion'' state (Note: further requirements apply, see quorum columns of "area" table)';
COMMENT ON COLUMN "policy"."issue_quorum_den"      IS 'Denominator of supporter quorum to be reached by an initiative to be "accepted", i.e. pass from ''admission'' to ''discussion'' state (Note: further requirements apply, see quorum columns of "area" table)';
COMMENT ON COLUMN "policy"."initiative_quorum"     IS 'Absolute number of satisfied supporters to be reached by an initiative to be "admitted" for voting';
COMMENT ON COLUMN "policy"."initiative_quorum_num" IS 'Numerator of satisfied supporter quorum to be reached by an initiative to be "admitted" for voting';
COMMENT ON COLUMN "policy"."initiative_quorum_den" IS 'Denominator of satisfied supporter quorum to be reached by an initiative to be "admitted" for voting';


ALTER TABLE "unit" ADD COLUMN "region" JSONB;

CREATE INDEX "unit_region_idx" ON "unit" USING gist ((GeoJSON_to_ecluster("region")));

COMMENT ON COLUMN "unit"."member_count" IS 'Count of members as determined by column "voting_right" in table "privilege" (only active members counted)';
COMMENT ON COLUMN "unit"."region"       IS 'Scattered (or hollow) polygon represented as an array of polygons indicating valid coordinates for initiatives of issues with this policy';
 

DROP INDEX "area_unit_id_idx";
ALTER TABLE "area" ADD UNIQUE ("unit_id", "id");

ALTER TABLE "area" ADD COLUMN "quorum_standard" NUMERIC  NOT NULL DEFAULT 2 CHECK ("quorum_standard" >= 0);
ALTER TABLE "area" ADD COLUMN "quorum_issues"   NUMERIC  NOT NULL DEFAULT 1 CHECK ("quorum_issues" > 0);
ALTER TABLE "area" ADD COLUMN "quorum_time"     INTERVAL NOT NULL DEFAULT '1 day' CHECK ("quorum_time" > '0'::INTERVAL);
ALTER TABLE "area" ADD COLUMN "quorum_exponent" NUMERIC  NOT NULL DEFAULT 0.5 CHECK ("quorum_exponent" BETWEEN 0 AND 1);
ALTER TABLE "area" ADD COLUMN "quorum_factor"   NUMERIC  NOT NULL DEFAULT 2 CHECK ("quorum_factor" >= 1);
ALTER TABLE "area" ADD COLUMN "quorum_den"      INT4     CHECK ("quorum_den" > 0);
ALTER TABLE "area" ADD COLUMN "issue_quorum"    INT4;
ALTER TABLE "area" ADD COLUMN "region"          JSONB;

ALTER TABLE "area" DROP COLUMN "direct_member_count";
ALTER TABLE "area" DROP COLUMN "member_weight";

CREATE INDEX "area_region_idx" ON "area" USING gist ((GeoJSON_to_ecluster("region")));

COMMENT ON COLUMN "area"."quorum_standard"    IS 'Parameter for dynamic issue quorum: default quorum';
COMMENT ON COLUMN "area"."quorum_issues"      IS 'Parameter for dynamic issue quorum: number of open issues for default quorum';
COMMENT ON COLUMN "area"."quorum_time"        IS 'Parameter for dynamic issue quorum: discussion, verification, and voting time of open issues to result in the given default quorum (open issues with shorter time will increase quorum and open issues with longer time will reduce quorum if "quorum_exponent" is greater than zero)';
COMMENT ON COLUMN "area"."quorum_exponent"    IS 'Parameter for dynamic issue quorum: set to zero to ignore duration of open issues, set to one to fully take duration of open issues into account; defaults to 0.5';
COMMENT ON COLUMN "area"."quorum_factor"      IS 'Parameter for dynamic issue quorum: factor to increase dynamic quorum when a number of "quorum_issues" issues with "quorum_time" duration of discussion, verification, and voting phase are added to the number of open admitted issues';
COMMENT ON COLUMN "area"."quorum_den"         IS 'Parameter for dynamic issue quorum: when set, dynamic quorum is multiplied with "issue"."population" and divided by "quorum_den" (and then rounded up)';
COMMENT ON COLUMN "area"."issue_quorum"       IS 'Additional dynamic issue quorum based on the number of open accepted issues; automatically calculated by function "issue_admission"';
COMMENT ON COLUMN "area"."external_reference" IS 'Opaque data field to store an external reference';
COMMENT ON COLUMN "area"."region"             IS 'Scattered (or hollow) polygon represented as an array of polygons indicating valid coordinates for initiatives of issues with this policy';
 
 
CREATE TABLE "snapshot" (
        UNIQUE ("issue_id", "id"),  -- index needed for foreign-key on table "issue"
        "id"                    SERIAL8         PRIMARY KEY,
        "calculated"            TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "population"            INT4,
        "area_id"               INT4            NOT NULL REFERENCES "area" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "issue_id"              INT4 );         -- NOTE: following (cyclic) reference is added later through ALTER command: REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE

COMMENT ON TABLE "snapshot" IS 'Point in time when a snapshot of one or more issues (see table "snapshot_issue") and their supporter situation is taken';

 
CREATE TABLE "snapshot_population" (
        PRIMARY KEY ("snapshot_id", "member_id"),
        "snapshot_id"           INT8            REFERENCES "snapshot" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE );

COMMENT ON TABLE "snapshot_population" IS 'Members with voting right relevant for a snapshot';


ALTER TABLE "issue" ADD UNIQUE ("area_id", "id");
DROP INDEX "issue_area_id_idx";
ALTER TABLE "issue" ADD UNIQUE ("policy_id", "id");
DROP INDEX "issue_policy_id_idx";

ALTER TABLE "issue" RENAME COLUMN "snapshot" TO "calculated";

ALTER TABLE "issue" ADD COLUMN "latest_snapshot_id"      INT8 REFERENCES "snapshot" ("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "issue" ADD COLUMN "admission_snapshot_id"   INT8 REFERENCES "snapshot" ("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "issue" ADD COLUMN "half_freeze_snapshot_id" INT8;
ALTER TABLE "issue" ADD COLUMN "full_freeze_snapshot_id" INT8;

ALTER TABLE "issue" ADD FOREIGN KEY ("id", "half_freeze_snapshot_id")
  REFERENCES "snapshot" ("issue_id", "id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "issue" ADD FOREIGN KEY ("id", "full_freeze_snapshot_id")
  REFERENCES "snapshot" ("issue_id", "id") ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE "issue" DROP CONSTRAINT "last_snapshot_on_full_freeze";
ALTER TABLE "issue" DROP CONSTRAINT "freeze_requires_snapshot";
ALTER TABLE "issue" DROP CONSTRAINT "set_both_or_none_of_snapshot_and_latest_snapshot_event";

CREATE INDEX "issue_state_idx" ON "issue" ("state");
CREATE INDEX "issue_latest_snapshot_id" ON "issue" ("latest_snapshot_id");
CREATE INDEX "issue_admission_snapshot_id" ON "issue" ("admission_snapshot_id");
CREATE INDEX "issue_half_freeze_snapshot_id" ON "issue" ("half_freeze_snapshot_id");
CREATE INDEX "issue_full_freeze_snapshot_id" ON "issue" ("full_freeze_snapshot_id");

COMMENT ON COLUMN "issue"."accepted"                IS 'Point in time, when the issue was accepted for further discussion (see columns "issue_quorum_num" and "issue_quorum_den" of table "policy" and quorum columns of table "area")';
COMMENT ON COLUMN "issue"."calculated"              IS 'Point in time, when most recent snapshot and "population" and *_count values were calculated (NOTE: value is equal to "snapshot"."calculated" of snapshot with "id"="issue"."latest_snapshot_id")';
COMMENT ON COLUMN "issue"."latest_snapshot_id"      IS 'Snapshot id of most recent snapshot';
COMMENT ON COLUMN "issue"."admission_snapshot_id"   IS 'Snapshot id when issue as accepted or canceled in admission phase';
COMMENT ON COLUMN "issue"."half_freeze_snapshot_id" IS 'Snapshot id at end of discussion phase';
COMMENT ON COLUMN "issue"."full_freeze_snapshot_id" IS 'Snapshot id at end of verification phase';
COMMENT ON COLUMN "issue"."population"              IS 'Count of members in "snapshot_population" table with "snapshot_id" equal to "issue"."latest_snapshot_id"';


ALTER TABLE "snapshot" ADD FOREIGN KEY ("issue_id") REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE;


ALTER TABLE "initiative" DROP CONSTRAINT "initiative_suggested_initiative_id_fkey";
ALTER TABLE "initiative" ADD FOREIGN KEY ("suggested_initiative_id") REFERENCES "initiative" ("id") ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "initiative" ADD COLUMN "location" JSONB;
ALTER TABLE "initiative" ADD COLUMN "draft_text_search_data" TSVECTOR;

CREATE INDEX "initiative_location_idx" ON "initiative" USING gist ((GeoJSON_to_ecluster("location")));
CREATE INDEX "initiative_draft_text_search_data_idx" ON "initiative" USING gin ("draft_text_search_data");

COMMENT ON COLUMN "initiative"."location"               IS 'Geographic location of initiative as GeoJSON object (automatically copied from most recent draft)';


ALTER TABLE "draft" ADD COLUMN "location" JSONB;

CREATE INDEX "draft_location_idx" ON "draft" USING gist ((GeoJSON_to_ecluster("location")));

COMMENT ON COLUMN "draft"."location" IS 'Geographic location of initiative as GeoJSON object (automatically copied to "initiative" table if draft is most recent)';


ALTER TABLE "suggestion" ADD COLUMN "location" JSONB;

CREATE INDEX "suggestion_location_idx" ON "suggestion" USING gist ((GeoJSON_to_ecluster("location")));

COMMENT ON COLUMN "suggestion"."location"                 IS 'Geographic location of suggestion as GeoJSON object';


CREATE TABLE "temporary_suggestion_counts" (
        "id"                    INT8            PRIMARY KEY, -- NOTE: no referential integrity due to performance/locking issues; REFERENCES "suggestion" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "minus2_unfulfilled_count" INT4         NOT NULL,
        "minus2_fulfilled_count"   INT4         NOT NULL,
        "minus1_unfulfilled_count" INT4         NOT NULL,
        "minus1_fulfilled_count"   INT4         NOT NULL,
        "plus1_unfulfilled_count"  INT4         NOT NULL,
        "plus1_fulfilled_count"    INT4         NOT NULL,
        "plus2_unfulfilled_count"  INT4         NOT NULL,
        "plus2_fulfilled_count"    INT4         NOT NULL );

COMMENT ON TABLE "temporary_suggestion_counts" IS 'Holds certain calculated values (suggestion counts) temporarily until they can be copied into table "suggestion"';

COMMENT ON COLUMN "temporary_suggestion_counts"."id"  IS 'References "suggestion" ("id") but has no referential integrity trigger associated, due to performance/locking issues';


ALTER TABLE "interest" DROP CONSTRAINT "interest_member_id_fkey";
ALTER TABLE "interest" ADD FOREIGN KEY ("member_id") REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE;


ALTER TABLE "initiator" DROP CONSTRAINT "initiator_member_id_fkey";
ALTER TABLE "initiator" ADD FOREIGN KEY ("member_id") REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE;


ALTER TABLE "delegation" DROP CONSTRAINT "delegation_trustee_id_fkey";
ALTER TABLE "delegation" ADD FOREIGN KEY ("trustee_id") REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE;


CREATE TABLE "snapshot_issue" (
        PRIMARY KEY ("snapshot_id", "issue_id"),
        "snapshot_id"           INT8            REFERENCES "snapshot" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE );
CREATE INDEX "snapshot_issue_issue_id_idx" ON "snapshot_issue" ("issue_id");

COMMENT ON TABLE "snapshot_issue" IS 'List of issues included in a snapshot';

COMMENT ON COLUMN "snapshot_issue"."issue_id" IS 'Issue being part of the snapshot; Trigger "delete_snapshot_on_partial_delete" on "snapshot_issue" table will delete snapshot if an issue of the snapshot is deleted.';


ALTER TABLE "direct_interest_snapshot" RENAME TO "direct_interest_snapshot_old";  -- TODO!
ALTER INDEX "direct_interest_snapshot_pkey" RENAME TO "direct_interest_snapshot_old_pkey";
ALTER INDEX "direct_interest_snapshot_member_id_idx" RENAME TO "direct_interest_snapshot_old_member_id_idx";

ALTER TABLE "delegating_interest_snapshot" RENAME TO "delegating_interest_snapshot_old";  -- TODO!
ALTER INDEX "delegating_interest_snapshot_pkey" RENAME TO "delegating_interest_snapshot_old_pkey";
ALTER INDEX "delegating_interest_snapshot_member_id_idx" RENAME TO "delegating_interest_snapshot_old_member_id_idx";

ALTER TABLE "direct_supporter_snapshot" RENAME TO "direct_supporter_snapshot_old";  -- TODO!
ALTER INDEX "direct_supporter_snapshot_pkey" RENAME TO "direct_supporter_snapshot_old_pkey";
ALTER INDEX "direct_supporter_snapshot_member_id_idx" RENAME TO "direct_supporter_snapshot_old_member_id_idx";


CREATE TABLE "direct_interest_snapshot" (
        PRIMARY KEY ("snapshot_id", "issue_id", "member_id"),
        "snapshot_id"           INT8,
        "issue_id"              INT4,
        FOREIGN KEY ("snapshot_id", "issue_id")
          REFERENCES "snapshot_issue" ("snapshot_id", "issue_id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE RESTRICT,
        "weight"                INT4 );
CREATE INDEX "direct_interest_snapshot_member_id_idx" ON "direct_interest_snapshot" ("member_id");

COMMENT ON TABLE "direct_interest_snapshot" IS 'Snapshot of active members having an "interest" in the "issue"; for corrections refer to column "issue_notice" of "issue" table';

COMMENT ON COLUMN "direct_interest_snapshot"."weight" IS 'Weight of member (1 or higher) according to "delegating_interest_snapshot"';


CREATE TABLE "delegating_interest_snapshot" (
        PRIMARY KEY ("snapshot_id", "issue_id", "member_id"),
        "snapshot_id"           INT8,
        "issue_id"              INT4,
        FOREIGN KEY ("snapshot_id", "issue_id")
          REFERENCES "snapshot_issue" ("snapshot_id", "issue_id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE RESTRICT,
        "weight"                INT4,
        "scope"              "delegation_scope" NOT NULL,
        "delegate_member_ids"   INT4[]          NOT NULL );
CREATE INDEX "delegating_interest_snapshot_member_id_idx" ON "delegating_interest_snapshot" ("member_id");

COMMENT ON TABLE "delegating_interest_snapshot" IS 'Delegations increasing the weight of entries in the "direct_interest_snapshot" table; for corrections refer to column "issue_notice" of "issue" table';

COMMENT ON COLUMN "delegating_interest_snapshot"."member_id"           IS 'Delegating member';
COMMENT ON COLUMN "delegating_interest_snapshot"."weight"              IS 'Intermediate weight';
COMMENT ON COLUMN "delegating_interest_snapshot"."delegate_member_ids" IS 'Chain of members who act as delegates; last entry referes to "member_id" column of table "direct_interest_snapshot"';


CREATE TABLE "direct_supporter_snapshot" (
        PRIMARY KEY ("snapshot_id", "initiative_id", "member_id"),
        "snapshot_id"           INT8,
        "issue_id"              INT4            NOT NULL,
        FOREIGN KEY ("snapshot_id", "issue_id")
          REFERENCES "snapshot_issue" ("snapshot_id", "issue_id") ON DELETE CASCADE ON UPDATE CASCADE,
        "initiative_id"         INT4,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE RESTRICT,
        "draft_id"              INT8            NOT NULL,
        "informed"              BOOLEAN         NOT NULL,
        "satisfied"             BOOLEAN         NOT NULL,
        FOREIGN KEY ("issue_id", "initiative_id") REFERENCES "initiative" ("issue_id", "id") ON DELETE CASCADE ON UPDATE CASCADE,
        FOREIGN KEY ("initiative_id", "draft_id") REFERENCES "draft" ("initiative_id", "id") ON DELETE NO ACTION ON UPDATE CASCADE,
        FOREIGN KEY ("snapshot_id", "issue_id", "member_id") REFERENCES "direct_interest_snapshot" ("snapshot_id", "issue_id", "member_id") ON DELETE CASCADE ON UPDATE CASCADE );
CREATE INDEX "direct_supporter_snapshot_member_id_idx" ON "direct_supporter_snapshot" ("member_id");

COMMENT ON TABLE "direct_supporter_snapshot" IS 'Snapshot of supporters of initiatives (weight is stored in "direct_interest_snapshot"); for corrections refer to column "issue_notice" of "issue" table';

COMMENT ON COLUMN "direct_supporter_snapshot"."issue_id"  IS 'WARNING: No index: For selections use column "initiative_id" and join via table "initiative" where neccessary';
COMMENT ON COLUMN "direct_supporter_snapshot"."informed"  IS 'Supporter has seen the latest draft of the initiative';
COMMENT ON COLUMN "direct_supporter_snapshot"."satisfied" IS 'Supporter has no "critical_opinion"s';
 

ALTER TABLE "non_voter" DROP CONSTRAINT "non_voter_pkey";
DROP INDEX "non_voter_member_id_idx";

ALTER TABLE "non_voter" ADD PRIMARY KEY ("member_id", "issue_id");
CREATE INDEX "non_voter_issue_id_idx" ON "non_voter" ("issue_id");


ALTER TABLE "event" ADD COLUMN "other_member_id" INT4    REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "event" ADD COLUMN "scope"           "delegation_scope";
ALTER TABLE "event" ADD COLUMN "unit_id"         INT4    REFERENCES "unit" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "event" ADD COLUMN "area_id"         INT4;
ALTER TABLE "event" ADD COLUMN "policy_id"       INT4    REFERENCES "policy" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "event" ADD COLUMN "boolean_value"   BOOLEAN;
ALTER TABLE "event" ADD COLUMN "numeric_value"   INT4;
ALTER TABLE "event" ADD COLUMN "text_value"      TEXT;
ALTER TABLE "event" ADD COLUMN "old_text_value"  TEXT;

ALTER TABLE "event" ADD FOREIGN KEY ("unit_id", "area_id") REFERENCES "area" ("unit_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "event" ADD FOREIGN KEY ("area_id", "issue_id") REFERENCES "issue" ("area_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "event" ADD FOREIGN KEY ("policy_id", "issue_id") REFERENCES "issue" ("policy_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "event" DROP CONSTRAINT "event_initiative_id_fkey1";
ALTER TABLE "event" DROP CONSTRAINT "null_constr_for_issue_state_changed";
ALTER TABLE "event" DROP CONSTRAINT "null_constr_for_initiative_creation_or_revocation_or_new_draft";
ALTER TABLE "event" DROP CONSTRAINT "null_constr_for_suggestion_creation";

UPDATE "event" SET "unit_id" = "area"."unit_id", "area_id" = "issue"."area_id"
  FROM "issue", "area"
  WHERE "issue"."id" = "event"."issue_id" AND "area"."id" = "issue"."area_id";

ALTER TABLE "event" ADD CONSTRAINT "constr_for_issue_state_changed" CHECK (
          "event" != 'issue_state_changed' OR (
            "member_id"       ISNULL  AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   ISNULL  AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   ISNULL  AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_initiative_creation_or_revocation_or_new_draft" CHECK (
          "event" NOT IN (
            'initiative_created_in_new_issue',
            'initiative_created_in_existing_issue',
            'initiative_revoked',
            'new_draft_created'
          ) OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   NOTNULL AND
            "draft_id"        NOTNULL AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   ISNULL  AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_suggestion_creation" CHECK (
          "event" != 'suggestion_created' OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   NOTNULL AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   NOTNULL AND
            "boolean_value"   ISNULL  AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_suggestion_removal" CHECK (
          "event" != 'suggestion_removed' OR (
            "member_id"       ISNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   NOTNULL AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   NOTNULL AND
            "boolean_value"   ISNULL  AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_value_less_member_event" CHECK (
          "event" NOT IN (
            'member_activated',
            'member_removed',
            'member_profile_updated',
            'member_image_updated'
          ) OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         ISNULL  AND
            "area_id"         ISNULL  AND
            "policy_id"       ISNULL  AND
            "issue_id"        ISNULL  AND
            "state"           ISNULL  AND
            "initiative_id"   ISNULL  AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   ISNULL  AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_member_active" CHECK (
          "event" != 'member_active' OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         ISNULL  AND
            "area_id"         ISNULL  AND
            "policy_id"       ISNULL  AND
            "issue_id"        ISNULL  AND
            "state"           ISNULL  AND
            "initiative_id"   ISNULL  AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   NOTNULL AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_member_name_updated" CHECK (
          "event" != 'member_name_updated' OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         ISNULL  AND
            "area_id"         ISNULL  AND
            "policy_id"       ISNULL  AND
            "issue_id"        ISNULL  AND
            "state"           ISNULL  AND
            "initiative_id"   ISNULL  AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   ISNULL  AND
            "numeric_value"   ISNULL  AND
            "text_value"      NOTNULL AND
            "old_text_value"  NOTNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_interest" CHECK (
          "event" != 'interest' OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   ISNULL  AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   NOTNULL AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_initiator" CHECK (
          "event" != 'initiator' OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   NOTNULL AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   NOTNULL AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_support" CHECK (
          "event" != 'support' OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   NOTNULL AND
            ("draft_id" NOTNULL) = ("boolean_value" = TRUE) AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   NOTNULL AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_support_updated" CHECK (
          "event" != 'support_updated' OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   NOTNULL AND
            "draft_id"        NOTNULL AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   ISNULL  AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_suggestion_rated" CHECK (
          "event" != 'suggestion_rated' OR (
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "unit_id"         NOTNULL AND
            "area_id"         NOTNULL AND
            "policy_id"       NOTNULL AND
            "issue_id"        NOTNULL AND
            "state"           NOTNULL AND
            "initiative_id"   NOTNULL AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   NOTNULL AND
            ("boolean_value" NOTNULL) = ("numeric_value" != 0) AND
            "numeric_value"   NOTNULL AND
            "numeric_value" IN (-2, -1, 0, 1, 2) AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_delegation" CHECK (
          "event" != 'delegation' OR (
            "member_id"       NOTNULL AND
            ("other_member_id" NOTNULL) OR ("boolean_value" = FALSE) AND
            "scope"           NOTNULL AND
            "unit_id"         NOTNULL AND
            ("area_id"  NOTNULL) = ("scope" != 'unit'::"delegation_scope") AND
            "policy_id"       ISNULL  AND
            ("issue_id" NOTNULL) = ("scope" = 'issue'::"delegation_scope") AND
            ("state"    NOTNULL) = ("scope" = 'issue'::"delegation_scope") AND
            "initiative_id"   ISNULL  AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   NOTNULL AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));
ALTER TABLE "event" ADD CONSTRAINT "constr_for_contact" CHECK (
          "event" != 'contact' OR (
            "member_id"       NOTNULL AND
            "other_member_id" NOTNULL AND
            "scope"           ISNULL  AND
            "unit_id"         ISNULL  AND
            "area_id"         ISNULL  AND
            "policy_id"       ISNULL  AND
            "issue_id"        ISNULL  AND
            "state"           ISNULL  AND
            "initiative_id"   ISNULL  AND
            "draft_id"        ISNULL  AND
            "suggestion_id"   ISNULL  AND
            "boolean_value"   NOTNULL AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));


ALTER TABLE "notification_event_sent" RENAME TO "event_processed";
ALTER INDEX "notification_event_sent_singleton_idx" RENAME TO "event_processed_singleton_idx";

COMMENT ON TABLE "event_processed" IS 'This table stores one row with the last event_id, for which event handlers have been executed (e.g. notifications having been sent out)';
COMMENT ON INDEX "event_processed_singleton_idx" IS 'This index ensures that "event_processed" only contains one row maximum.';


CREATE FUNCTION "write_event_unit_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "event_v" "event_type";
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF OLD."active" = FALSE AND NEW."active" = FALSE THEN
          RETURN NULL;
        ELSIF OLD."active" = TRUE AND NEW."active" = FALSE THEN
          "event_v" := 'unit_removed';
        ELSE
          "event_v" := 'unit_updated';
        END IF;
      ELSE
        "event_v" := 'unit_created';
      END IF;
      INSERT INTO "event" ("event", "unit_id") VALUES ("event_v", NEW."id");
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_unit" AFTER INSERT OR UPDATE ON "unit"
  FOR EACH ROW EXECUTE PROCEDURE "write_event_unit_trigger"();

COMMENT ON FUNCTION "write_event_unit_trigger"() IS 'Implementation of trigger "write_event_unit" on table "unit"';
COMMENT ON TRIGGER "write_event_unit" ON "unit"  IS 'Create entry in "event" table on new or changed/disabled units';


CREATE FUNCTION "write_event_area_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "event_v" "event_type";
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF OLD."active" = FALSE AND NEW."active" = FALSE THEN
          RETURN NULL;
        ELSIF OLD."active" = TRUE AND NEW."active" = FALSE THEN
          "event_v" := 'area_removed';
        ELSE
          "event_v" := 'area_updated';
        END IF;
      ELSE
        "event_v" := 'area_created';
      END IF;
      INSERT INTO "event" ("event", "area_id") VALUES ("event_v", NEW."id");
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_area" AFTER INSERT OR UPDATE ON "area"
  FOR EACH ROW EXECUTE PROCEDURE "write_event_area_trigger"();

COMMENT ON FUNCTION "write_event_area_trigger"() IS 'Implementation of trigger "write_event_area" on table "area"';
COMMENT ON TRIGGER "write_event_area" ON "area"  IS 'Create entry in "event" table on new or changed/disabled areas';


CREATE FUNCTION "write_event_policy_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "event_v" "event_type";
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF OLD."active" = FALSE AND NEW."active" = FALSE THEN
          RETURN NULL;
        ELSIF OLD."active" = TRUE AND NEW."active" = FALSE THEN
          "event_v" := 'policy_removed';
        ELSE
          "event_v" := 'policy_updated';
        END IF;
      ELSE
        "event_v" := 'policy_created';
      END IF;
      INSERT INTO "event" ("event", "policy_id") VALUES ("event_v", NEW."id");
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_policy" AFTER INSERT OR UPDATE ON "policy"
  FOR EACH ROW EXECUTE PROCEDURE "write_event_policy_trigger"();

COMMENT ON FUNCTION "write_event_policy_trigger"()  IS 'Implementation of trigger "write_event_policy" on table "policy"';
COMMENT ON TRIGGER "write_event_policy" ON "policy" IS 'Create entry in "event" table on new or changed/disabled policies';


CREATE OR REPLACE FUNCTION "write_event_issue_state_changed_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "area_row" "area"%ROWTYPE;
    BEGIN
      IF NEW."state" != OLD."state" THEN
        SELECT * INTO "area_row" FROM "area" WHERE "id" = NEW."area_id"
          FOR SHARE;
        INSERT INTO "event" (
            "event",
            "unit_id", "area_id", "policy_id", "issue_id", "state"
          ) VALUES (
            'issue_state_changed',
            "area_row"."unit_id", NEW."area_id", NEW."policy_id",
            NEW."id", NEW."state"
          );
      END IF;
      RETURN NULL;
    END;
  $$;


CREATE OR REPLACE FUNCTION "write_event_initiative_or_draft_created_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "initiative_row" "initiative"%ROWTYPE;
      "issue_row"      "issue"%ROWTYPE;
      "area_row"       "area"%ROWTYPE;
      "event_v"        "event_type";
    BEGIN
      SELECT * INTO "initiative_row" FROM "initiative"
        WHERE "id" = NEW."initiative_id" FOR SHARE;
      SELECT * INTO "issue_row" FROM "issue"
        WHERE "id" = "initiative_row"."issue_id" FOR SHARE;
      SELECT * INTO "area_row" FROM "area"
        WHERE "id" = "issue_row"."area_id" FOR SHARE;
      IF EXISTS (
        SELECT NULL FROM "draft"
        WHERE "initiative_id" = NEW."initiative_id" AND "id" != NEW."id"
        FOR SHARE
      ) THEN
        "event_v" := 'new_draft_created';
      ELSE
        IF EXISTS (
          SELECT NULL FROM "initiative"
          WHERE "issue_id" = "initiative_row"."issue_id"
          AND "id" != "initiative_row"."id"
          FOR SHARE
        ) THEN
          "event_v" := 'initiative_created_in_existing_issue';
        ELSE
          "event_v" := 'initiative_created_in_new_issue';
        END IF;
      END IF;
      INSERT INTO "event" (
          "event", "member_id",
          "unit_id", "area_id", "policy_id", "issue_id", "state",
          "initiative_id", "draft_id"
        ) VALUES (
          "event_v", NEW."author_id",
          "area_row"."unit_id", "issue_row"."area_id", "issue_row"."policy_id",
          "initiative_row"."issue_id", "issue_row"."state",
          NEW."initiative_id", NEW."id"
        );
      RETURN NULL;
    END;
  $$;


CREATE OR REPLACE FUNCTION "write_event_initiative_revoked_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row"  "issue"%ROWTYPE;
      "area_row"   "area"%ROWTYPE;
      "draft_id_v" "draft"."id"%TYPE;
    BEGIN
      IF OLD."revoked" ISNULL AND NEW."revoked" NOTNULL THEN
        SELECT * INTO "issue_row" FROM "issue"
          WHERE "id" = NEW."issue_id" FOR SHARE;
        SELECT * INTO "area_row" FROM "area"
          WHERE "id" = "issue_row"."area_id" FOR SHARE;
        SELECT "id" INTO "draft_id_v" FROM "current_draft"
          WHERE "initiative_id" = NEW."id" FOR SHARE;
        INSERT INTO "event" (
            "event", "member_id",
            "unit_id", "area_id", "policy_id", "issue_id", "state",
            "initiative_id", "draft_id"
          ) VALUES (
            'initiative_revoked', NEW."revoked_by_member_id",
            "area_row"."unit_id", "issue_row"."area_id",
            "issue_row"."policy_id",
            NEW."issue_id", "issue_row"."state",
            NEW."id", "draft_id_v"
          );
      END IF;
      RETURN NULL;
    END;
  $$;


CREATE OR REPLACE FUNCTION "write_event_suggestion_created_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "initiative_row" "initiative"%ROWTYPE;
      "issue_row"      "issue"%ROWTYPE;
      "area_row"       "area"%ROWTYPE;
    BEGIN
      SELECT * INTO "initiative_row" FROM "initiative"
        WHERE "id" = NEW."initiative_id" FOR SHARE;
      SELECT * INTO "issue_row" FROM "issue"
        WHERE "id" = "initiative_row"."issue_id" FOR SHARE;
      SELECT * INTO "area_row" FROM "area"
        WHERE "id" = "issue_row"."area_id" FOR SHARE;
      INSERT INTO "event" (
          "event", "member_id",
          "unit_id", "area_id", "policy_id", "issue_id", "state",
          "initiative_id", "suggestion_id"
        ) VALUES (
          'suggestion_created', NEW."author_id",
          "area_row"."unit_id", "issue_row"."area_id", "issue_row"."policy_id",
          "initiative_row"."issue_id", "issue_row"."state",
          NEW."initiative_id", NEW."id"
        );
      RETURN NULL;
    END;
  $$;

 
CREATE FUNCTION "write_event_suggestion_removed_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "initiative_row" "initiative"%ROWTYPE;
      "issue_row"      "issue"%ROWTYPE;
      "area_row"       "area"%ROWTYPE;
    BEGIN
      SELECT * INTO "initiative_row" FROM "initiative"
        WHERE "id" = OLD."initiative_id" FOR SHARE;
      IF "initiative_row"."id" NOTNULL THEN
        SELECT * INTO "issue_row" FROM "issue"
          WHERE "id" = "initiative_row"."issue_id" FOR SHARE;
        SELECT * INTO "area_row" FROM "area"
          WHERE "id" = "issue_row"."area_id" FOR SHARE;
        INSERT INTO "event" (
            "event",
            "unit_id", "area_id", "policy_id", "issue_id", "state",
            "initiative_id", "suggestion_id"
          ) VALUES (
            'suggestion_removed',
            "area_row"."unit_id", "issue_row"."area_id",
            "issue_row"."policy_id",
            "initiative_row"."issue_id", "issue_row"."state",
            OLD."initiative_id", OLD."id"
          );
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_suggestion_removed"
  AFTER DELETE ON "suggestion" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_suggestion_removed_trigger"();

COMMENT ON FUNCTION "write_event_suggestion_removed_trigger"()      IS 'Implementation of trigger "write_event_suggestion_removed" on table "issue"';
COMMENT ON TRIGGER "write_event_suggestion_removed" ON "suggestion" IS 'Create entry in "event" table on suggestion creation';


CREATE FUNCTION "write_event_member_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NEW."activated" NOTNULL THEN
          INSERT INTO "event" ("event", "member_id")
            VALUES ('member_activated', NEW."id");
        END IF;
        IF NEW."active" THEN
          INSERT INTO "event" ("event", "member_id", "boolean_value")
            VALUES ('member_active', NEW."id", TRUE);
        END IF;
      ELSIF TG_OP = 'UPDATE' THEN
        IF OLD."id" != NEW."id" THEN
          RAISE EXCEPTION 'Cannot change member ID';
        END IF;
        IF OLD."name" != NEW."name" THEN
          INSERT INTO "event" (
            "event", "member_id", "text_value", "old_text_value"
          ) VALUES (
            'member_name_updated', NEW."id", NEW."name", OLD."name"
          );
        END IF;
        IF OLD."active" != NEW."active" THEN
          INSERT INTO "event" ("event", "member_id", "boolean_value") VALUES (
            'member_active', NEW."id", NEW."active"
          );
        END IF;
        IF
          OLD."activated" NOTNULL AND
          NEW."last_login"      ISNULL AND
          NEW."login"           ISNULL AND
          NEW."authority_login" ISNULL AND
          NEW."locked"          = TRUE
        THEN
          INSERT INTO "event" ("event", "member_id")
            VALUES ('member_removed', NEW."id");
        END IF;
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_member"
  AFTER INSERT OR UPDATE ON "member" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_member_trigger"();

COMMENT ON FUNCTION "write_event_member_trigger"()  IS 'Implementation of trigger "write_event_member" on table "member"';
COMMENT ON TRIGGER "write_event_member" ON "member" IS 'Create entries in "event" table on insertion to member table';


CREATE FUNCTION "write_event_member_profile_updated_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
        IF EXISTS (SELECT NULL FROM "member" WHERE "id" = OLD."member_id") THEN
          INSERT INTO "event" ("event", "member_id") VALUES (
            'member_profile_updated', OLD."member_id"
          );
        END IF;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        IF OLD."member_id" = NEW."member_id" THEN
          RETURN NULL;
        END IF;
      END IF;
      IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        INSERT INTO "event" ("event", "member_id") VALUES (
          'member_profile_updated', NEW."member_id"
        );
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_member_profile_updated"
  AFTER INSERT OR UPDATE OR DELETE ON "member_profile"
  FOR EACH ROW EXECUTE PROCEDURE
  "write_event_member_profile_updated_trigger"();

COMMENT ON FUNCTION "write_event_member_profile_updated_trigger"()          IS 'Implementation of trigger "write_event_member_profile_updated" on table "member_profile"';
COMMENT ON TRIGGER "write_event_member_profile_updated" ON "member_profile" IS 'Creates entries in "event" table on member profile update';


CREATE FUNCTION "write_event_member_image_updated_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
        IF NOT OLD."scaled" THEN
          IF EXISTS (SELECT NULL FROM "member" WHERE "id" = OLD."member_id") THEN
            INSERT INTO "event" ("event", "member_id") VALUES (
              'member_image_updated', OLD."member_id"
            );
          END IF;
        END IF;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        IF
          OLD."member_id" = NEW."member_id" AND
          OLD."scaled" = NEW."scaled"
        THEN
          RETURN NULL;
        END IF;
      END IF;
      IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        IF NOT NEW."scaled" THEN
          INSERT INTO "event" ("event", "member_id") VALUES (
            'member_image_updated', NEW."member_id"
          );
        END IF;
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_member_image_updated"
  AFTER INSERT OR UPDATE OR DELETE ON "member_image"
  FOR EACH ROW EXECUTE PROCEDURE
  "write_event_member_image_updated_trigger"();

COMMENT ON FUNCTION "write_event_member_image_updated_trigger"()        IS 'Implementation of trigger "write_event_member_image_updated" on table "member_image"';
COMMENT ON TRIGGER "write_event_member_image_updated" ON "member_image" IS 'Creates entries in "event" table on member image update';


CREATE FUNCTION "write_event_interest_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row" "issue"%ROWTYPE;
      "area_row"  "area"%ROWTYPE;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF OLD = NEW THEN
          RETURN NULL;
        END IF;
      END IF;
      IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
        SELECT * INTO "issue_row" FROM "issue"
          WHERE "id" = OLD."issue_id" FOR SHARE;
        SELECT * INTO "area_row" FROM "area"
          WHERE "id" = "issue_row"."area_id" FOR SHARE;
        IF "issue_row"."id" NOTNULL THEN
          INSERT INTO "event" (
              "event", "member_id",
              "unit_id", "area_id", "policy_id", "issue_id", "state",
              "boolean_value"
            ) VALUES (
              'interest', OLD."member_id",
              "area_row"."unit_id", "issue_row"."area_id",
              "issue_row"."policy_id",
              OLD."issue_id", "issue_row"."state",
              FALSE
            );
        END IF;
      END IF;
      IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        SELECT * INTO "issue_row" FROM "issue"
          WHERE "id" = NEW."issue_id" FOR SHARE;
        SELECT * INTO "area_row" FROM "area"
          WHERE "id" = "issue_row"."area_id" FOR SHARE;
        INSERT INTO "event" (
            "event", "member_id",
            "unit_id", "area_id", "policy_id", "issue_id", "state",
            "boolean_value"
          ) VALUES (
            'interest', NEW."member_id",
            "area_row"."unit_id", "issue_row"."area_id",
            "issue_row"."policy_id",
            NEW."issue_id", "issue_row"."state",
            TRUE
          );
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_interest"
  AFTER INSERT OR UPDATE OR DELETE ON "interest" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_interest_trigger"();

COMMENT ON FUNCTION "write_event_interest_trigger"()  IS 'Implementation of trigger "write_event_interest_inserted" on table "interest"';
COMMENT ON TRIGGER "write_event_interest" ON "interest" IS 'Create entry in "event" table on adding or removing interest';


CREATE FUNCTION "write_event_initiator_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "initiative_row" "initiative"%ROWTYPE;
      "issue_row"      "issue"%ROWTYPE;
      "area_row"       "area"%ROWTYPE;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF
          OLD."initiative_id" = NEW."initiative_id" AND
          OLD."member_id" = NEW."member_id" AND
          coalesce(OLD."accepted", FALSE) = coalesce(NEW."accepted", FALSE)
        THEN
          RETURN NULL;
        END IF;
      END IF;
      IF (TG_OP = 'DELETE' OR TG_OP = 'UPDATE') AND NOT "accepted_v" THEN
        IF coalesce(OLD."accepted", FALSE) = TRUE THEN
          SELECT * INTO "initiative_row" FROM "initiative"
            WHERE "id" = OLD."initiative_id" FOR SHARE;
          IF "initiative_row"."id" NOTNULL THEN
            SELECT * INTO "issue_row" FROM "issue"
              WHERE "id" = "initiative_row"."issue_id" FOR SHARE;
            SELECT * INTO "area_row" FROM "area"
              WHERE "id" = "issue_row"."area_id" FOR SHARE;
            INSERT INTO "event" (
                "event", "member_id",
                "unit_id", "area_id", "policy_id", "issue_id", "state",
                "initiative_id", "boolean_value"
              ) VALUES (
                'initiator', OLD."member_id",
                "area_row"."unit_id", "issue_row"."area_id",
                "issue_row"."policy_id",
                "issue_row"."id", "issue_row"."state",
                OLD."initiative_id", FALSE
              );
          END IF;
        END IF;
      END IF;
      IF TG_OP = 'UPDATE' AND NOT "rejected_v" THEN
        IF coalesce(NEW."accepted", FALSE) = TRUE THEN
          SELECT * INTO "initiative_row" FROM "initiative"
            WHERE "id" = NEW."initiative_id" FOR SHARE;
          SELECT * INTO "issue_row" FROM "issue"
            WHERE "id" = "initiative_row"."issue_id" FOR SHARE;
          SELECT * INTO "area_row" FROM "area"
            WHERE "id" = "issue_row"."area_id" FOR SHARE;
          INSERT INTO "event" (
              "event", "member_id",
              "unit_id", "area_id", "policy_id", "issue_id", "state",
              "initiative_id", "boolean_value"
            ) VALUES (
              'initiator', NEW."member_id",
              "area_row"."unit_id", "issue_row"."area_id",
              "issue_row"."policy_id",
              "issue_row"."id", "issue_row"."state",
              NEW."initiative_id", TRUE
            );
        END IF;
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_initiator"
  AFTER UPDATE OR DELETE ON "initiator" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_initiator_trigger"();

COMMENT ON FUNCTION "write_event_initiator_trigger"()     IS 'Implementation of trigger "write_event_initiator" on table "initiator"';
COMMENT ON TRIGGER "write_event_initiator" ON "initiator" IS 'Create entry in "event" table when accepting or removing initiatorship (NOTE: trigger does not fire on INSERT to avoid events on initiative creation)';


CREATE FUNCTION "write_event_support_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row" "issue"%ROWTYPE;
      "area_row"  "area"%ROWTYPE;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF
          OLD."initiative_id" = NEW."initiative_id" AND
          OLD."member_id" = NEW."member_id"
        THEN
          IF OLD."draft_id" != NEW."draft_id" THEN
            SELECT * INTO "issue_row" FROM "issue"
              WHERE "id" = NEW."issue_id" FOR SHARE;
            SELECT * INTO "area_row" FROM "area"
              WHERE "id" = "issue_row"."area_id" FOR SHARE;
            INSERT INTO "event" (
                "event", "member_id",
                "unit_id", "area_id", "policy_id", "issue_id", "state",
                "initiative_id", "draft_id"
              ) VALUES (
                'support_updated', NEW."member_id",
                "area_row"."unit_id", "issue_row"."area_id",
                "issue_row"."policy_id",
                "issue_row"."id", "issue_row"."state",
                NEW."initiative_id", NEW."draft_id"
              );
          END IF;
          RETURN NULL;
        END IF;
      END IF;
      IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
        IF EXISTS (
          SELECT NULL FROM "initiative" WHERE "id" = OLD."initiative_id"
          FOR SHARE
        ) THEN
          SELECT * INTO "issue_row" FROM "issue"
            WHERE "id" = OLD."issue_id" FOR SHARE;
          SELECT * INTO "area_row" FROM "area"
            WHERE "id" = "issue_row"."area_id" FOR SHARE;
          INSERT INTO "event" (
              "event", "member_id",
              "unit_id", "area_id", "policy_id", "issue_id", "state",
              "initiative_id", "boolean_value"
            ) VALUES (
              'support', OLD."member_id",
              "area_row"."unit_id", "issue_row"."area_id",
              "issue_row"."policy_id",
              "issue_row"."id", "issue_row"."state",
              OLD."initiative_id", FALSE
            );
        END IF;
      END IF;
      IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        SELECT * INTO "issue_row" FROM "issue"
          WHERE "id" = NEW."issue_id" FOR SHARE;
        SELECT * INTO "area_row" FROM "area"
          WHERE "id" = "issue_row"."area_id" FOR SHARE;
        INSERT INTO "event" (
            "event", "member_id",
            "unit_id", "area_id", "policy_id", "issue_id", "state",
            "initiative_id", "draft_id", "boolean_value"
          ) VALUES (
            'support', NEW."member_id",
            "area_row"."unit_id", "issue_row"."area_id",
            "issue_row"."policy_id",
            "issue_row"."id", "issue_row"."state",
            NEW."initiative_id", NEW."draft_id", TRUE
          );
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_support"
  AFTER INSERT OR UPDATE OR DELETE ON "supporter" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_support_trigger"();

COMMENT ON FUNCTION "write_event_support_trigger"()     IS 'Implementation of trigger "write_event_support" on table "supporter"';
COMMENT ON TRIGGER "write_event_support" ON "supporter" IS 'Create entry in "event" table when adding, updating, or removing support';


CREATE FUNCTION "write_event_suggestion_rated_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "same_pkey_v"    BOOLEAN = FALSE;
      "initiative_row" "initiative"%ROWTYPE;
      "issue_row"      "issue"%ROWTYPE;
      "area_row"       "area"%ROWTYPE;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF
          OLD."suggestion_id" = NEW."suggestion_id" AND
          OLD."member_id"     = NEW."member_id"
        THEN
          IF
            OLD."degree"    = NEW."degree" AND
            OLD."fulfilled" = NEW."fulfilled"
          THEN
            RETURN NULL;
          END IF;
          "same_pkey_v" := TRUE;
        END IF;
      END IF;
      IF (TG_OP = 'DELETE' OR TG_OP = 'UPDATE') AND NOT "same_pkey_v" THEN
        IF EXISTS (
          SELECT NULL FROM "suggestion" WHERE "id" = OLD."suggestion_id"
          FOR SHARE
        ) THEN
          SELECT * INTO "initiative_row" FROM "initiative"
            WHERE "id" = OLD."initiative_id" FOR SHARE;
          SELECT * INTO "issue_row" FROM "issue"
            WHERE "id" = "initiative_row"."issue_id" FOR SHARE;
          SELECT * INTO "area_row" FROM "area"
            WHERE "id" = "issue_row"."area_id" FOR SHARE;
          INSERT INTO "event" (
              "event", "member_id",
              "unit_id", "area_id", "policy_id", "issue_id", "state",
              "initiative_id", "suggestion_id",
              "boolean_value", "numeric_value"
            ) VALUES (
              'suggestion_rated', OLD."member_id",
              "area_row"."unit_id", "issue_row"."area_id",
              "issue_row"."policy_id",
              "initiative_row"."issue_id", "issue_row"."state",
              OLD."initiative_id", OLD."suggestion_id",
              NULL, 0
            );
        END IF;
      END IF;
      IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        SELECT * INTO "initiative_row" FROM "initiative"
          WHERE "id" = NEW."initiative_id" FOR SHARE;
        SELECT * INTO "issue_row" FROM "issue"
          WHERE "id" = "initiative_row"."issue_id" FOR SHARE;
        SELECT * INTO "area_row" FROM "area"
          WHERE "id" = "issue_row"."area_id" FOR SHARE;
        INSERT INTO "event" (
            "event", "member_id",
            "unit_id", "area_id", "policy_id", "issue_id", "state",
            "initiative_id", "suggestion_id",
            "boolean_value", "numeric_value"
          ) VALUES (
            'suggestion_rated', NEW."member_id",
            "area_row"."unit_id", "issue_row"."area_id",
            "issue_row"."policy_id",
            "initiative_row"."issue_id", "issue_row"."state",
            NEW."initiative_id", NEW."suggestion_id",
            NEW."fulfilled", NEW."degree"
          );
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_suggestion_rated"
  AFTER INSERT OR UPDATE OR DELETE ON "opinion" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_suggestion_rated_trigger"();

COMMENT ON FUNCTION "write_event_suggestion_rated_trigger"()   IS 'Implementation of trigger "write_event_suggestion_rated" on table "opinion"';
COMMENT ON TRIGGER "write_event_suggestion_rated" ON "opinion" IS 'Create entry in "event" table when adding, updating, or removing support';


CREATE FUNCTION "write_event_delegation_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row" "issue"%ROWTYPE;
      "area_row"  "area"%ROWTYPE;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF EXISTS (
          SELECT NULL FROM "member" WHERE "id" = OLD."truster_id"
        ) AND (CASE OLD."scope"
          WHEN 'unit'::"delegation_scope" THEN EXISTS (
            SELECT NULL FROM "unit" WHERE "id" = OLD."unit_id"
          )
          WHEN 'area'::"delegation_scope" THEN EXISTS (
            SELECT NULL FROM "area" WHERE "id" = OLD."area_id"
          )
          WHEN 'issue'::"delegation_scope" THEN EXISTS (
            SELECT NULL FROM "issue" WHERE "id" = OLD."issue_id"
          )
        END) THEN
          SELECT * INTO "issue_row" FROM "issue"
            WHERE "id" = OLD."issue_id" FOR SHARE;
          SELECT * INTO "area_row" FROM "area"
            WHERE "id" = COALESCE(OLD."area_id", "issue_row"."area_id")
            FOR SHARE;
          INSERT INTO "event" (
              "event", "member_id", "scope",
              "unit_id", "area_id", "issue_id", "state",
              "boolean_value"
            ) VALUES (
              'delegation', OLD."truster_id", OLD."scope",
              COALESCE(OLD."unit_id", "area_row"."unit_id"), "area_row"."id",
              OLD."issue_id", "issue_row"."state",
              FALSE
            );
        END IF;
      ELSE
        SELECT * INTO "issue_row" FROM "issue"
          WHERE "id" = NEW."issue_id" FOR SHARE;
        SELECT * INTO "area_row" FROM "area"
          WHERE "id" = COALESCE(NEW."area_id", "issue_row"."area_id")
          FOR SHARE;
        INSERT INTO "event" (
            "event", "member_id", "other_member_id", "scope",
            "unit_id", "area_id", "issue_id", "state",
            "boolean_value"
          ) VALUES (
            'delegation', NEW."truster_id", NEW."trustee_id", NEW."scope",
            COALESCE(NEW."unit_id", "area_row"."unit_id"), "area_row"."id",
            NEW."issue_id", "issue_row"."state",
            TRUE
          );
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_delegation"
  AFTER INSERT OR UPDATE OR DELETE ON "delegation" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_delegation_trigger"();

COMMENT ON FUNCTION "write_event_delegation_trigger"()      IS 'Implementation of trigger "write_event_delegation" on table "delegation"';
COMMENT ON TRIGGER "write_event_delegation" ON "delegation" IS 'Create entry in "event" table when adding, updating, or removing a delegation';


CREATE FUNCTION "write_event_contact_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF
          OLD."member_id"       = NEW."member_id" AND
          OLD."other_member_id" = NEW."other_member_id" AND
          OLD."public"          = NEW."public"
        THEN
          RETURN NULL;
        END IF;
      END IF;
      IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
        IF OLD."public" THEN
          IF EXISTS (
            SELECT NULL FROM "member" WHERE "id" = OLD."member_id"
            FOR SHARE
          ) AND EXISTS (
            SELECT NULL FROM "member" WHERE "id" = OLD."other_member_id"
            FOR SHARE
          ) THEN
            INSERT INTO "event" (
                "event", "member_id", "other_member_id", "boolean_value"
              ) VALUES (
                'contact', OLD."member_id", OLD."other_member_id", FALSE
              );
          END IF;
        END IF;
      END IF;
      IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        IF NEW."public" THEN
          INSERT INTO "event" (
              "event", "member_id", "other_member_id", "boolean_value"
            ) VALUES (
              'contact', NEW."member_id", NEW."other_member_id", TRUE
            );
        END IF;
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_contact"
  AFTER INSERT OR UPDATE OR DELETE ON "contact" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_contact_trigger"();

COMMENT ON FUNCTION "write_event_contact_trigger"()   IS 'Implementation of trigger "write_event_contact" on table "contact"';
COMMENT ON TRIGGER "write_event_contact" ON "contact" IS 'Create entry in "event" table when adding or removing public contacts';


CREATE FUNCTION "send_event_notify_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      EXECUTE 'NOTIFY "event", ''' || NEW."event" || '''';
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "send_notify"
  AFTER INSERT OR UPDATE ON "event" FOR EACH ROW EXECUTE PROCEDURE
  "send_event_notify_trigger"();


CREATE FUNCTION "delete_extended_scope_tokens_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "system_application_row" "system_application"%ROWTYPE;
    BEGIN
      IF OLD."system_application_id" NOTNULL THEN
        SELECT * FROM "system_application" INTO "system_application_row"
          WHERE "id" = OLD."system_application_id";
        DELETE FROM "token"
          WHERE "member_id" = OLD."member_id"
          AND "system_application_id" = OLD."system_application_id"
          AND NOT COALESCE(
            regexp_split_to_array("scope", E'\\s+') <@
            regexp_split_to_array(
              "system_application_row"."automatic_scope", E'\\s+'
            ),
            FALSE
          );
      END IF;
      RETURN OLD;
    END;
  $$;

CREATE TRIGGER "delete_extended_scope_tokens"
  BEFORE DELETE ON "member_application" FOR EACH ROW EXECUTE PROCEDURE
  "delete_extended_scope_tokens_trigger"();


CREATE FUNCTION "detach_token_from_session_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      UPDATE "token" SET "session_id" = NULL
        WHERE "session_id" = OLD."id";
      RETURN OLD;
    END;
  $$;

CREATE TRIGGER "detach_token_from_session"
  BEFORE DELETE ON "session" FOR EACH ROW EXECUTE PROCEDURE
  "detach_token_from_session_trigger"();


CREATE FUNCTION "delete_non_detached_scope_with_session_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NEW."session_id" ISNULL THEN
        SELECT coalesce(string_agg("element", ' '), '') INTO NEW."scope"
          FROM unnest(regexp_split_to_array(NEW."scope", E'\\s+')) AS "element"
          WHERE "element" LIKE '%_detached';
      END IF;
      RETURN NEW;
    END;
  $$;

CREATE TRIGGER "delete_non_detached_scope_with_session"
  BEFORE INSERT OR UPDATE ON "token" FOR EACH ROW EXECUTE PROCEDURE
  "delete_non_detached_scope_with_session_trigger"();


CREATE FUNCTION "delete_token_with_empty_scope_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NEW."scope" = '' THEN
        DELETE FROM "token" WHERE "id" = NEW."id";
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "delete_token_with_empty_scope"
  AFTER INSERT OR UPDATE ON "token" FOR EACH ROW EXECUTE PROCEDURE
  "delete_token_with_empty_scope_trigger"();


CREATE FUNCTION "delete_snapshot_on_partial_delete_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF
          OLD."snapshot_id" = NEW."snapshot_id" AND
          OLD."issue_id" = NEW."issue_id"
        THEN
          RETURN NULL;
        END IF;
      END IF;
      DELETE FROM "snapshot" WHERE "id" = OLD."snapshot_id";
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "delete_snapshot_on_partial_delete"
  AFTER UPDATE OR DELETE ON "snapshot_issue"
  FOR EACH ROW EXECUTE PROCEDURE
  "delete_snapshot_on_partial_delete_trigger"();

COMMENT ON FUNCTION "delete_snapshot_on_partial_delete_trigger"()          IS 'Implementation of trigger "delete_snapshot_on_partial_delete" on table "snapshot_issue"';
COMMENT ON TRIGGER "delete_snapshot_on_partial_delete" ON "snapshot_issue" IS 'Deletes whole snapshot if one issue is deleted from the snapshot';


CREATE FUNCTION "copy_current_draft_data"
  ("initiative_id_p" "initiative"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      PERFORM NULL FROM "initiative" WHERE "id" = "initiative_id_p"
        FOR UPDATE;
      UPDATE "initiative" SET
        "location" = "draft"."location",
        "draft_text_search_data" = "draft"."text_search_data"
        FROM "current_draft" AS "draft"
        WHERE "initiative"."id" = "initiative_id_p"
        AND "draft"."initiative_id" = "initiative_id_p";
    END;
  $$;

COMMENT ON FUNCTION "copy_current_draft_data"
  ( "initiative"."id"%TYPE )
  IS 'Helper function for function "copy_current_draft_data_trigger"';


CREATE FUNCTION "copy_current_draft_data_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF TG_OP='DELETE' THEN
        PERFORM "copy_current_draft_data"(OLD."initiative_id");
      ELSE
        IF TG_OP='UPDATE' THEN
          IF COALESCE(OLD."inititiave_id" != NEW."initiative_id", TRUE) THEN
            PERFORM "copy_current_draft_data"(OLD."initiative_id");
          END IF;
        END IF;
        PERFORM "copy_current_draft_data"(NEW."initiative_id");
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "copy_current_draft_data"
  AFTER INSERT OR UPDATE OR DELETE ON "draft"
  FOR EACH ROW EXECUTE PROCEDURE
  "copy_current_draft_data_trigger"();

COMMENT ON FUNCTION "copy_current_draft_data_trigger"() IS 'Implementation of trigger "copy_current_draft_data" on table "draft"';
COMMENT ON TRIGGER "copy_current_draft_data" ON "draft" IS 'Copy certain fields from most recent "draft" to "initiative"';


CREATE VIEW "area_quorum" AS
  SELECT
    "area"."id" AS "area_id",
    ceil(
      "area"."quorum_standard"::FLOAT8 * "quorum_factor"::FLOAT8 ^ (
        coalesce(
          ( SELECT sum(
              ( extract(epoch from "area"."quorum_time")::FLOAT8 /
                extract(epoch from
                  ("issue"."accepted"-"issue"."created") +
                  "issue"."discussion_time" +
                  "issue"."verification_time" +
                  "issue"."voting_time"
                )::FLOAT8
              ) ^ "area"."quorum_exponent"::FLOAT8
            )
            FROM "issue" JOIN "policy"
            ON "issue"."policy_id" = "policy"."id"
            WHERE "issue"."area_id" = "area"."id"
            AND "issue"."accepted" NOTNULL
            AND "issue"."closed" ISNULL
            AND "policy"."polling" = FALSE
          )::FLOAT8, 0::FLOAT8
        ) / "area"."quorum_issues"::FLOAT8 - 1::FLOAT8
      ) * CASE WHEN "area"."quorum_den" ISNULL THEN 1 ELSE (
        SELECT "snapshot"."population"
        FROM "snapshot"
        WHERE "snapshot"."area_id" = "area"."id"
        AND "snapshot"."issue_id" ISNULL
        ORDER BY "snapshot"."id" DESC
        LIMIT 1
      ) END / coalesce("area"."quorum_den", 1)

    )::INT4 AS "issue_quorum"
  FROM "area";

COMMENT ON VIEW "area_quorum" IS 'Area-based quorum considering number of open (accepted) issues';


CREATE VIEW "area_with_unaccepted_issues" AS
  SELECT DISTINCT ON ("area"."id") "area".*
  FROM "area" JOIN "issue" ON "area"."id" = "issue"."area_id"
  WHERE "issue"."state" = 'admission';

COMMENT ON VIEW "area_with_unaccepted_issues" IS 'All areas with unaccepted open issues (needed for issue admission system)';


DROP VIEW "area_member_count";


DROP TABLE "membership";


DROP FUNCTION "membership_weight"
  ( "area_id_p"         "area"."id"%TYPE,
    "member_id_p"       "member"."id"%TYPE );


DROP FUNCTION "membership_weight_with_skipping"
  ( "area_id_p"         "area"."id"%TYPE,
    "member_id_p"       "member"."id"%TYPE,
    "skip_member_ids_p" INT4[] );  -- TODO: ordering/cascade


CREATE OR REPLACE VIEW "issue_delegation" AS
  SELECT DISTINCT ON ("issue"."id", "delegation"."truster_id")
    "issue"."id" AS "issue_id",
    "delegation"."id",
    "delegation"."truster_id",
    "delegation"."trustee_id",
    "delegation"."scope"
  FROM "issue"
  JOIN "area"
    ON "area"."id" = "issue"."area_id"
  JOIN "delegation"
    ON "delegation"."unit_id" = "area"."unit_id"
    OR "delegation"."area_id" = "area"."id"
    OR "delegation"."issue_id" = "issue"."id"
  JOIN "member"
    ON "delegation"."truster_id" = "member"."id"
  JOIN "privilege"
    ON "area"."unit_id" = "privilege"."unit_id"
    AND "delegation"."truster_id" = "privilege"."member_id"
  WHERE "member"."active" AND "privilege"."voting_right"
  ORDER BY
    "issue"."id",
    "delegation"."truster_id",
    "delegation"."scope" DESC;


CREATE VIEW "unit_member" AS
  SELECT
    "unit"."id"   AS "unit_id",
    "member"."id" AS "member_id"
  FROM "privilege"
  JOIN "unit"   ON "unit_id"     = "privilege"."unit_id"
  JOIN "member" ON "member"."id" = "privilege"."member_id"
  WHERE "privilege"."voting_right" AND "member"."active";

COMMENT ON VIEW "unit_member" IS 'Active members with voting right in a unit';
 
 
CREATE OR REPLACE VIEW "unit_member_count" AS
  SELECT
    "unit"."id" AS "unit_id",
    count("unit_member"."member_id") AS "member_count"
  FROM "unit" LEFT JOIN "unit_member"
  ON "unit"."id" = "unit_member"."unit_id"
  GROUP BY "unit"."id";
 
COMMENT ON VIEW "unit_member_count" IS 'View used to update "member_count" column of "unit" table';


CREATE OR REPLACE VIEW "opening_draft" AS
  SELECT DISTINCT ON ("initiative_id") * FROM "draft"
  ORDER BY "initiative_id", "id";
 
 
CREATE OR REPLACE VIEW "current_draft" AS
  SELECT DISTINCT ON ("initiative_id") * FROM "draft"
  ORDER BY "initiative_id", "id" DESC;
 

CREATE OR REPLACE VIEW "issue_supporter_in_admission_state" AS
  SELECT
    "area"."unit_id",
    "issue"."area_id",
    "issue"."id" AS "issue_id",
    "supporter"."member_id",
    "direct_interest_snapshot"."weight"
  FROM "issue"
  JOIN "area" ON "area"."id" = "issue"."area_id"
  JOIN "supporter" ON "supporter"."issue_id" = "issue"."id"
  JOIN "direct_interest_snapshot"
    ON "direct_interest_snapshot"."snapshot_id" = "issue"."latest_snapshot_id"
    AND "direct_interest_snapshot"."issue_id" = "issue"."id"
    AND "direct_interest_snapshot"."member_id" = "supporter"."member_id"
  WHERE "issue"."state" = 'admission'::"issue_state";


CREATE OR REPLACE VIEW "individual_suggestion_ranking" AS
  SELECT
    "opinion"."initiative_id",
    "opinion"."member_id",
    "direct_interest_snapshot"."weight",
    CASE WHEN
      ("opinion"."degree" = 2 AND "opinion"."fulfilled" = FALSE) OR
      ("opinion"."degree" = -2 AND "opinion"."fulfilled" = TRUE)
    THEN 1 ELSE
      CASE WHEN
        ("opinion"."degree" = 1 AND "opinion"."fulfilled" = FALSE) OR
        ("opinion"."degree" = -1 AND "opinion"."fulfilled" = TRUE)
      THEN 2 ELSE
        CASE WHEN
          ("opinion"."degree" = 2 AND "opinion"."fulfilled" = TRUE) OR
          ("opinion"."degree" = -2 AND "opinion"."fulfilled" = FALSE)
        THEN 3 ELSE 4 END
      END
    END AS "preference",
    "opinion"."suggestion_id"
  FROM "opinion"
  JOIN "initiative" ON "initiative"."id" = "opinion"."initiative_id"
  JOIN "issue" ON "issue"."id" = "initiative"."issue_id"
  JOIN "direct_interest_snapshot"
    ON "direct_interest_snapshot"."snapshot_id" = "issue"."latest_snapshot_id"
    AND "direct_interest_snapshot"."issue_id" = "issue"."id"
    AND "direct_interest_snapshot"."member_id" = "opinion"."member_id";


CREATE VIEW "expired_session" AS
  SELECT * FROM "session" WHERE now() > "expiry";

CREATE RULE "delete" AS ON DELETE TO "expired_session" DO INSTEAD
  DELETE FROM "session" WHERE "id" = OLD."id";

COMMENT ON VIEW "expired_session" IS 'View containing all expired sessions where DELETE is possible';
COMMENT ON RULE "delete" ON "expired_session" IS 'Rule allowing DELETE on rows in "expired_session" view, i.e. DELETE FROM "expired_session"';


CREATE VIEW "expired_token" AS
  SELECT * FROM "token" WHERE now() > "expiry" AND NOT (
    "token_type" = 'authorization' AND "used" AND EXISTS (
      SELECT NULL FROM "token" AS "other"
      WHERE "other"."authorization_token_id" = "id" ) );

CREATE RULE "delete" AS ON DELETE TO "expired_token" DO INSTEAD
  DELETE FROM "token" WHERE "id" = OLD."id";

COMMENT ON VIEW "expired_token" IS 'View containing all expired tokens where DELETE is possible; Note that used authorization codes must not be deleted if still referred to by other tokens';


CREATE VIEW "unused_snapshot" AS
  SELECT "snapshot".* FROM "snapshot"
  LEFT JOIN "issue"
  ON "snapshot"."id" = "issue"."latest_snapshot_id"
  OR "snapshot"."id" = "issue"."admission_snapshot_id"
  OR "snapshot"."id" = "issue"."half_freeze_snapshot_id"
  OR "snapshot"."id" = "issue"."full_freeze_snapshot_id"
  WHERE "issue"."id" ISNULL;

CREATE RULE "delete" AS ON DELETE TO "unused_snapshot" DO INSTEAD
  DELETE FROM "snapshot" WHERE "id" = OLD."id";

COMMENT ON VIEW "unused_snapshot" IS 'Snapshots that are not referenced by any issue (either as latest snapshot or as snapshot at phase/state change)';


CREATE VIEW "expired_snapshot" AS
  SELECT "unused_snapshot".* FROM "unused_snapshot" CROSS JOIN "system_setting"
  WHERE "unused_snapshot"."calculated" <
    now() - "system_setting"."snapshot_retention";

CREATE RULE "delete" AS ON DELETE TO "expired_snapshot" DO INSTEAD
  DELETE FROM "snapshot" WHERE "id" = OLD."id";

COMMENT ON VIEW "expired_snapshot" IS 'Contains "unused_snapshot"s that are older than "system_setting"."snapshot_retention" (for deletion)';


COMMENT ON COLUMN "delegation_chain_row"."participation" IS 'In case of delegation chains for issues: interest; for area and global delegation chains: always null';


CREATE OR REPLACE FUNCTION "delegation_chain"
  ( "member_id_p"           "member"."id"%TYPE,
    "unit_id_p"             "unit"."id"%TYPE,
    "area_id_p"             "area"."id"%TYPE,
    "issue_id_p"            "issue"."id"%TYPE,
    "simulate_trustee_id_p" "member"."id"%TYPE DEFAULT NULL,
    "simulate_default_p"    BOOLEAN            DEFAULT FALSE )
  RETURNS SETOF "delegation_chain_row"
  LANGUAGE 'plpgsql' STABLE AS $$
    DECLARE
      "scope_v"            "delegation_scope";
      "unit_id_v"          "unit"."id"%TYPE;
      "area_id_v"          "area"."id"%TYPE;
      "issue_row"          "issue"%ROWTYPE;
      "visited_member_ids" INT4[];  -- "member"."id"%TYPE[]
      "loop_member_id_v"   "member"."id"%TYPE;
      "output_row"         "delegation_chain_row";
      "output_rows"        "delegation_chain_row"[];
      "simulate_v"         BOOLEAN;
      "simulate_here_v"    BOOLEAN;
      "delegation_row"     "delegation"%ROWTYPE;
      "row_count"          INT4;
      "i"                  INT4;
      "loop_v"             BOOLEAN;
    BEGIN
      IF "simulate_trustee_id_p" NOTNULL AND "simulate_default_p" THEN
        RAISE EXCEPTION 'Both "simulate_trustee_id_p" is set, and "simulate_default_p" is true';
      END IF;
      IF "simulate_trustee_id_p" NOTNULL OR "simulate_default_p" THEN
        "simulate_v" := TRUE;
      ELSE
        "simulate_v" := FALSE;
      END IF;
      IF
        "unit_id_p" NOTNULL AND
        "area_id_p" ISNULL AND
        "issue_id_p" ISNULL
      THEN
        "scope_v" := 'unit';
        "unit_id_v" := "unit_id_p";
      ELSIF
        "unit_id_p" ISNULL AND
        "area_id_p" NOTNULL AND
        "issue_id_p" ISNULL
      THEN
        "scope_v" := 'area';
        "area_id_v" := "area_id_p";
        SELECT "unit_id" INTO "unit_id_v"
          FROM "area" WHERE "id" = "area_id_v";
      ELSIF
        "unit_id_p" ISNULL AND
        "area_id_p" ISNULL AND
        "issue_id_p" NOTNULL
      THEN
        SELECT INTO "issue_row" * FROM "issue" WHERE "id" = "issue_id_p";
        IF "issue_row"."id" ISNULL THEN
          RETURN;
        END IF;
        IF "issue_row"."closed" NOTNULL THEN
          IF "simulate_v" THEN
            RAISE EXCEPTION 'Tried to simulate delegation chain for closed issue.';
          END IF;
          FOR "output_row" IN
            SELECT * FROM
            "delegation_chain_for_closed_issue"("member_id_p", "issue_id_p")
          LOOP
            RETURN NEXT "output_row";
          END LOOP;
          RETURN;
        END IF;
        "scope_v" := 'issue';
        SELECT "area_id" INTO "area_id_v"
          FROM "issue" WHERE "id" = "issue_id_p";
        SELECT "unit_id" INTO "unit_id_v"
          FROM "area"  WHERE "id" = "area_id_v";
      ELSE
        RAISE EXCEPTION 'Exactly one of unit_id_p, area_id_p, or issue_id_p must be NOTNULL.';
      END IF;
      "visited_member_ids" := '{}';
      "loop_member_id_v"   := NULL;
      "output_rows"        := '{}';
      "output_row"."index"         := 0;
      "output_row"."member_id"     := "member_id_p";
      "output_row"."member_valid"  := TRUE;
      "output_row"."participation" := FALSE;
      "output_row"."overridden"    := FALSE;
      "output_row"."disabled_out"  := FALSE;
      "output_row"."scope_out"     := NULL;
      LOOP
        IF "visited_member_ids" @> ARRAY["output_row"."member_id"] THEN
          "loop_member_id_v" := "output_row"."member_id";
        ELSE
          "visited_member_ids" :=
            "visited_member_ids" || "output_row"."member_id";
        END IF;
        IF "output_row"."participation" ISNULL THEN
          "output_row"."overridden" := NULL;
        ELSIF "output_row"."participation" THEN
          "output_row"."overridden" := TRUE;
        END IF;
        "output_row"."scope_in" := "output_row"."scope_out";
        "output_row"."member_valid" := EXISTS (
          SELECT NULL FROM "member" JOIN "privilege"
          ON "privilege"."member_id" = "member"."id"
          AND "privilege"."unit_id" = "unit_id_v"
          WHERE "id" = "output_row"."member_id"
          AND "member"."active" AND "privilege"."voting_right"
        );
        "simulate_here_v" := (
          "simulate_v" AND
          "output_row"."member_id" = "member_id_p"
        );
        "delegation_row" := ROW(NULL);
        IF "output_row"."member_valid" OR "simulate_here_v" THEN
          IF "scope_v" = 'unit' THEN
            IF NOT "simulate_here_v" THEN
              SELECT * INTO "delegation_row" FROM "delegation"
                WHERE "truster_id" = "output_row"."member_id"
                AND "unit_id" = "unit_id_v";
            END IF;
          ELSIF "scope_v" = 'area' THEN
            IF "simulate_here_v" THEN
              IF "simulate_trustee_id_p" ISNULL THEN
                SELECT * INTO "delegation_row" FROM "delegation"
                  WHERE "truster_id" = "output_row"."member_id"
                  AND "unit_id" = "unit_id_v";
              END IF;
            ELSE
              SELECT * INTO "delegation_row" FROM "delegation"
                WHERE "truster_id" = "output_row"."member_id"
                AND (
                  "unit_id" = "unit_id_v" OR
                  "area_id" = "area_id_v"
                )
                ORDER BY "scope" DESC;
            END IF;
          ELSIF "scope_v" = 'issue' THEN
            IF "issue_row"."fully_frozen" ISNULL THEN
              "output_row"."participation" := EXISTS (
                SELECT NULL FROM "interest"
                WHERE "issue_id" = "issue_id_p"
                AND "member_id" = "output_row"."member_id"
              );
            ELSE
              IF "output_row"."member_id" = "member_id_p" THEN
                "output_row"."participation" := EXISTS (
                  SELECT NULL FROM "direct_voter"
                  WHERE "issue_id" = "issue_id_p"
                  AND "member_id" = "output_row"."member_id"
                );
              ELSE
                "output_row"."participation" := NULL;
              END IF;
            END IF;
            IF "simulate_here_v" THEN
              IF "simulate_trustee_id_p" ISNULL THEN
                SELECT * INTO "delegation_row" FROM "delegation"
                  WHERE "truster_id" = "output_row"."member_id"
                  AND (
                    "unit_id" = "unit_id_v" OR
                    "area_id" = "area_id_v"
                  )
                  ORDER BY "scope" DESC;
              END IF;
            ELSE
              SELECT * INTO "delegation_row" FROM "delegation"
                WHERE "truster_id" = "output_row"."member_id"
                AND (
                  "unit_id" = "unit_id_v" OR
                  "area_id" = "area_id_v" OR
                  "issue_id" = "issue_id_p"
                )
                ORDER BY "scope" DESC;
            END IF;
          END IF;
        ELSE
          "output_row"."participation" := FALSE;
        END IF;
        IF "simulate_here_v" AND "simulate_trustee_id_p" NOTNULL THEN
          "output_row"."scope_out" := "scope_v";
          "output_rows" := "output_rows" || "output_row";
          "output_row"."member_id" := "simulate_trustee_id_p";
        ELSIF "delegation_row"."trustee_id" NOTNULL THEN
          "output_row"."scope_out" := "delegation_row"."scope";
          "output_rows" := "output_rows" || "output_row";
          "output_row"."member_id" := "delegation_row"."trustee_id";
        ELSIF "delegation_row"."scope" NOTNULL THEN
          "output_row"."scope_out" := "delegation_row"."scope";
          "output_row"."disabled_out" := TRUE;
          "output_rows" := "output_rows" || "output_row";
          EXIT;
        ELSE
          "output_row"."scope_out" := NULL;
          "output_rows" := "output_rows" || "output_row";
          EXIT;
        END IF;
        EXIT WHEN "loop_member_id_v" NOTNULL;
        "output_row"."index" := "output_row"."index" + 1;
      END LOOP;
      "row_count" := array_upper("output_rows", 1);
      "i"      := 1;
      "loop_v" := FALSE;
      LOOP
        "output_row" := "output_rows"["i"];
        EXIT WHEN "output_row" ISNULL;  -- NOTE: ISNULL and NOT ... NOTNULL produce different results!
        IF "loop_v" THEN
          IF "i" + 1 = "row_count" THEN
            "output_row"."loop" := 'last';
          ELSIF "i" = "row_count" THEN
            "output_row"."loop" := 'repetition';
          ELSE
            "output_row"."loop" := 'intermediate';
          END IF;
        ELSIF "output_row"."member_id" = "loop_member_id_v" THEN
          "output_row"."loop" := 'first';
          "loop_v" := TRUE;
        END IF;
        IF "scope_v" = 'unit' THEN
          "output_row"."participation" := NULL;
        END IF;
        RETURN NEXT "output_row";
        "i" := "i" + 1;
      END LOOP;
      RETURN;
    END;
  $$;


CREATE OR REPLACE FUNCTION "get_initiatives_for_notification"
  ( "recipient_id_p" "member"."id"%TYPE )
  RETURNS SETOF "initiative_for_notification"
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "result_row"           "initiative_for_notification"%ROWTYPE;
      "last_draft_id_v"      "draft"."id"%TYPE;
      "last_suggestion_id_v" "suggestion"."id"%TYPE;
    BEGIN
      PERFORM "require_transaction_isolation"();
      PERFORM NULL FROM "member" WHERE "id" = "recipient_id_p" FOR UPDATE;
      FOR "result_row" IN
        SELECT * FROM "initiative_for_notification"
        WHERE "recipient_id" = "recipient_id_p"
      LOOP
        SELECT "id" INTO "last_draft_id_v" FROM "draft"
          WHERE "draft"."initiative_id" = "result_row"."initiative_id"
          ORDER BY "id" DESC LIMIT 1;
        SELECT "id" INTO "last_suggestion_id_v" FROM "suggestion"
          WHERE "suggestion"."initiative_id" = "result_row"."initiative_id"
          ORDER BY "id" DESC LIMIT 1;
        INSERT INTO "notification_initiative_sent"
          ("member_id", "initiative_id", "last_draft_id", "last_suggestion_id")
          VALUES (
            "recipient_id_p",
            "result_row"."initiative_id",
            "last_draft_id_v",
            "last_suggestion_id_v" )
          ON CONFLICT ("member_id", "initiative_id") DO UPDATE SET
            "last_draft_id" = "last_draft_id_v",
            "last_suggestion_id" = "last_suggestion_id_v";
        RETURN NEXT "result_row";
      END LOOP;
      DELETE FROM "notification_initiative_sent"
        USING "initiative", "issue"
        WHERE "notification_initiative_sent"."member_id" = "recipient_id_p"
        AND "initiative"."id" = "notification_initiative_sent"."initiative_id"
        AND "issue"."id" = "initiative"."issue_id"
        AND ( "issue"."closed" NOTNULL OR "issue"."fully_frozen" NOTNULL );
      UPDATE "member" SET
        "notification_counter" = "notification_counter" + 1,
        "notification_sent" = now()
        WHERE "id" = "recipient_id_p";
      RETURN;
    END;
  $$;


CREATE OR REPLACE FUNCTION "calculate_member_counts"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      PERFORM "require_transaction_isolation"();
      DELETE FROM "member_count";
      INSERT INTO "member_count" ("total_count")
        SELECT "total_count" FROM "member_count_view";
      UPDATE "unit" SET "member_count" = "view"."member_count"
        FROM "unit_member_count" AS "view"
        WHERE "view"."unit_id" = "unit"."id";
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "calculate_member_counts"() IS 'Updates "member_count" table and "member_count" column of table "area" by materializing data from views "member_count_view" and "unit_member_count"';


CREATE FUNCTION "calculate_area_quorum"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      PERFORM "dont_require_transaction_isolation"();
      UPDATE "area" SET "issue_quorum" = "view"."issue_quorum"
        FROM "area_quorum" AS "view"
        WHERE "view"."area_id" = "area"."id";
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "calculate_area_quorum"() IS 'Calculate column "issue_quorum" in table "area" from view "area_quorum"';


DROP VIEW "remaining_harmonic_initiative_weight_summands";
DROP VIEW "remaining_harmonic_supporter_weight";


CREATE VIEW "remaining_harmonic_supporter_weight" AS
  SELECT
    "direct_interest_snapshot"."snapshot_id",
    "direct_interest_snapshot"."issue_id",
    "direct_interest_snapshot"."member_id",
    "direct_interest_snapshot"."weight" AS "weight_num",
    count("initiative"."id") AS "weight_den"
  FROM "issue"
  JOIN "direct_interest_snapshot"
    ON "issue"."latest_snapshot_id" = "direct_interest_snapshot"."snapshot_id"
    AND "issue"."id" = "direct_interest_snapshot"."issue_id"
  JOIN "initiative"
    ON "issue"."id" = "initiative"."issue_id"
    AND "initiative"."harmonic_weight" ISNULL
  JOIN "direct_supporter_snapshot"
    ON "issue"."latest_snapshot_id" = "direct_supporter_snapshot"."snapshot_id"
    AND "initiative"."id" = "direct_supporter_snapshot"."initiative_id"
    AND "direct_interest_snapshot"."member_id" = "direct_supporter_snapshot"."member_id"
    AND (
      "direct_supporter_snapshot"."satisfied" = TRUE OR
      coalesce("initiative"."admitted", FALSE) = FALSE
    )
  GROUP BY
    "direct_interest_snapshot"."snapshot_id",
    "direct_interest_snapshot"."issue_id",
    "direct_interest_snapshot"."member_id",
    "direct_interest_snapshot"."weight";


CREATE VIEW "remaining_harmonic_initiative_weight_summands" AS
  SELECT
    "initiative"."issue_id",
    "initiative"."id" AS "initiative_id",
    "initiative"."admitted",
    sum("remaining_harmonic_supporter_weight"."weight_num") AS "weight_num",
    "remaining_harmonic_supporter_weight"."weight_den"
  FROM "remaining_harmonic_supporter_weight"
  JOIN "initiative"
    ON "remaining_harmonic_supporter_weight"."issue_id" = "initiative"."issue_id"
    AND "initiative"."harmonic_weight" ISNULL
  JOIN "direct_supporter_snapshot"
    ON "remaining_harmonic_supporter_weight"."snapshot_id" = "direct_supporter_snapshot"."snapshot_id"
    AND "initiative"."id" = "direct_supporter_snapshot"."initiative_id"
    AND "remaining_harmonic_supporter_weight"."member_id" = "direct_supporter_snapshot"."member_id"
    AND (
      "direct_supporter_snapshot"."satisfied" = TRUE OR
      coalesce("initiative"."admitted", FALSE) = FALSE
    )
  GROUP BY
    "initiative"."issue_id",
    "initiative"."id",
    "initiative"."admitted",
    "remaining_harmonic_supporter_weight"."weight_den";


DROP FUNCTION "create_population_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE );


DROP FUNCTION "weight_of_added_delegations_for_population_snapshot"
  ( "issue_id_p"            "issue"."id"%TYPE,
    "member_id_p"           "member"."id"%TYPE,
    "delegate_member_ids_p" "delegating_population_snapshot"."delegate_member_ids"%TYPE );


DROP FUNCTION "weight_of_added_delegations_for_interest_snapshot"
  ( "issue_id_p"            "issue"."id"%TYPE,
    "member_id_p"           "member"."id"%TYPE,
    "delegate_member_ids_p" "delegating_interest_snapshot"."delegate_member_ids"%TYPE );


CREATE FUNCTION "weight_of_added_delegations_for_snapshot"
  ( "snapshot_id_p"         "snapshot"."id"%TYPE,
    "issue_id_p"            "issue"."id"%TYPE,
    "member_id_p"           "member"."id"%TYPE,
    "delegate_member_ids_p" "delegating_interest_snapshot"."delegate_member_ids"%TYPE )
  RETURNS "direct_interest_snapshot"."weight"%TYPE
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_delegation_row"  "issue_delegation"%ROWTYPE;
      "delegate_member_ids_v" "delegating_interest_snapshot"."delegate_member_ids"%TYPE;
      "weight_v"              INT4;
      "sub_weight_v"          INT4;
    BEGIN
      PERFORM "require_transaction_isolation"();
      "weight_v" := 0;
      FOR "issue_delegation_row" IN
        SELECT * FROM "issue_delegation"
        WHERE "trustee_id" = "member_id_p"
        AND "issue_id" = "issue_id_p"
      LOOP
        IF NOT EXISTS (
          SELECT NULL FROM "direct_interest_snapshot"
          WHERE "snapshot_id" = "snapshot_id_p"
          AND "issue_id" = "issue_id_p"
          AND "member_id" = "issue_delegation_row"."truster_id"
        ) AND NOT EXISTS (
          SELECT NULL FROM "delegating_interest_snapshot"
          WHERE "snapshot_id" = "snapshot_id_p"
          AND "issue_id" = "issue_id_p"
          AND "member_id" = "issue_delegation_row"."truster_id"
        ) THEN
          "delegate_member_ids_v" :=
            "member_id_p" || "delegate_member_ids_p";
          INSERT INTO "delegating_interest_snapshot" (
              "snapshot_id",
              "issue_id",
              "member_id",
              "scope",
              "delegate_member_ids"
            ) VALUES (
              "snapshot_id_p",
              "issue_id_p",
              "issue_delegation_row"."truster_id",
              "issue_delegation_row"."scope",
              "delegate_member_ids_v"
            );
          "sub_weight_v" := 1 +
            "weight_of_added_delegations_for_snapshot"(
              "snapshot_id_p",
              "issue_id_p",
              "issue_delegation_row"."truster_id",
              "delegate_member_ids_v"
            );
          UPDATE "delegating_interest_snapshot"
            SET "weight" = "sub_weight_v"
            WHERE "snapshot_id" = "snapshot_id_p"
            AND "issue_id" = "issue_id_p"
            AND "member_id" = "issue_delegation_row"."truster_id";
          "weight_v" := "weight_v" + "sub_weight_v";
        END IF;
      END LOOP;
      RETURN "weight_v";
    END;
  $$;

COMMENT ON FUNCTION "weight_of_added_delegations_for_snapshot"
  ( "snapshot"."id"%TYPE,
    "issue"."id"%TYPE,
    "member"."id"%TYPE,
    "delegating_interest_snapshot"."delegate_member_ids"%TYPE )
  IS 'Helper function for "fill_snapshot" function';


DROP FUNCTION "create_interest_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE );


DROP FUNCTION "create_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE );


CREATE FUNCTION "take_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE,
    "area_id_p"  "area"."id"%TYPE = NULL )
  RETURNS "snapshot"."id"%TYPE
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "area_id_v"     "area"."id"%TYPE;
      "unit_id_v"     "unit"."id"%TYPE;
      "snapshot_id_v" "snapshot"."id"%TYPE;
      "issue_id_v"    "issue"."id"%TYPE;
      "member_id_v"   "member"."id"%TYPE;
    BEGIN
      IF "issue_id_p" NOTNULL AND "area_id_p" NOTNULL THEN
        RAISE EXCEPTION 'One of "issue_id_p" and "area_id_p" must be NULL';
      END IF;
      PERFORM "require_transaction_isolation"();
      IF "issue_id_p" ISNULL THEN
        "area_id_v" := "area_id_p";
      ELSE
        SELECT "area_id" INTO "area_id_v"
          FROM "issue" WHERE "id" = "issue_id_p";
      END IF;
      SELECT "unit_id" INTO "unit_id_v" FROM "area" WHERE "id" = "area_id_p";
      INSERT INTO "snapshot" ("area_id", "issue_id")
        VALUES ("area_id_v", "issue_id_p")
        RETURNING "id" INTO "snapshot_id_v";
      INSERT INTO "snapshot_population" ("snapshot_id", "member_id")
        SELECT "snapshot_id_v", "member_id"
        FROM "unit_member" WHERE "unit_id" = "unit_id_v";
      UPDATE "snapshot" SET
        "population" = (
          SELECT count(1) FROM "snapshot_population"
          WHERE "snapshot_id" = "snapshot_id_v"
        ) WHERE "id" = "snapshot_id_v";
      FOR "issue_id_v" IN
        SELECT "id" FROM "issue"
        WHERE CASE WHEN "issue_id_p" ISNULL THEN
          "area_id" = "area_id_p" AND
          "state" = 'admission'
        ELSE
          "id" = "issue_id_p"
        END
      LOOP
        INSERT INTO "snapshot_issue" ("snapshot_id", "issue_id")
          VALUES ("snapshot_id_v", "issue_id_v");
        INSERT INTO "direct_interest_snapshot"
          ("snapshot_id", "issue_id", "member_id")
          SELECT
            "snapshot_id_v" AS "snapshot_id",
            "issue_id_v"    AS "issue_id",
            "member"."id"   AS "member_id"
          FROM "issue"
          JOIN "area" ON "issue"."area_id" = "area"."id"
          JOIN "interest" ON "issue"."id" = "interest"."issue_id"
          JOIN "member" ON "interest"."member_id" = "member"."id"
          JOIN "privilege"
            ON "privilege"."unit_id" = "area"."unit_id"
            AND "privilege"."member_id" = "member"."id"
          WHERE "issue"."id" = "issue_id_v"
          AND "member"."active" AND "privilege"."voting_right";
        FOR "member_id_v" IN
          SELECT "member_id" FROM "direct_interest_snapshot"
          WHERE "snapshot_id" = "snapshot_id_v"
          AND "issue_id" = "issue_id_v"
        LOOP
          UPDATE "direct_interest_snapshot" SET
            "weight" = 1 +
              "weight_of_added_delegations_for_snapshot"(
                "snapshot_id_v",
                "issue_id_v",
                "member_id_v",
                '{}'
              )
            WHERE "snapshot_id" = "snapshot_id_v"
            AND "issue_id" = "issue_id_v"
            AND "member_id" = "member_id_v";
        END LOOP;
        INSERT INTO "direct_supporter_snapshot"
          ( "snapshot_id", "issue_id", "initiative_id", "member_id",
            "draft_id", "informed", "satisfied" )
          SELECT
            "snapshot_id_v"         AS "snapshot_id",
            "issue_id_v"            AS "issue_id",
            "initiative"."id"       AS "initiative_id",
            "supporter"."member_id" AS "member_id",
            "supporter"."draft_id"  AS "draft_id",
            "supporter"."draft_id" = "current_draft"."id" AS "informed",
            NOT EXISTS (
              SELECT NULL FROM "critical_opinion"
              WHERE "initiative_id" = "initiative"."id"
              AND "member_id" = "supporter"."member_id"
            ) AS "satisfied"
          FROM "initiative"
          JOIN "supporter"
          ON "supporter"."initiative_id" = "initiative"."id"
          JOIN "current_draft"
          ON "initiative"."id" = "current_draft"."initiative_id"
          JOIN "direct_interest_snapshot"
          ON "snapshot_id_v" = "direct_interest_snapshot"."snapshot_id"
          AND "supporter"."member_id" = "direct_interest_snapshot"."member_id"
          AND "initiative"."issue_id" = "direct_interest_snapshot"."issue_id"
          WHERE "initiative"."issue_id" = "issue_id_v";
        DELETE FROM "temporary_suggestion_counts";
        INSERT INTO "temporary_suggestion_counts"
          ( "id",
            "minus2_unfulfilled_count", "minus2_fulfilled_count",
            "minus1_unfulfilled_count", "minus1_fulfilled_count",
            "plus1_unfulfilled_count", "plus1_fulfilled_count",
            "plus2_unfulfilled_count", "plus2_fulfilled_count" )
          SELECT
            "suggestion"."id",
            ( SELECT coalesce(sum("di"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "di"
              ON "di"."snapshot_id" = "snapshot_id_v"
              AND "di"."issue_id" = "issue_id_v"
              AND "di"."member_id" = "opinion"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion"."id"
              AND "opinion"."degree" = -2
              AND "opinion"."fulfilled" = FALSE
            ) AS "minus2_unfulfilled_count",
            ( SELECT coalesce(sum("di"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "di"
              ON "di"."snapshot_id" = "snapshot_id_v"
              AND "di"."issue_id" = "issue_id_v"
              AND "di"."member_id" = "opinion"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion"."id"
              AND "opinion"."degree" = -2
              AND "opinion"."fulfilled" = TRUE
            ) AS "minus2_fulfilled_count",
            ( SELECT coalesce(sum("di"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "di"
              ON "di"."snapshot_id" = "snapshot_id_v"
              AND "di"."issue_id" = "issue_id_v"
              AND "di"."member_id" = "opinion"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion"."id"
              AND "opinion"."degree" = -1
              AND "opinion"."fulfilled" = FALSE
            ) AS "minus1_unfulfilled_count",
            ( SELECT coalesce(sum("di"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "di"
              ON "di"."snapshot_id" = "snapshot_id_v"
              AND "di"."issue_id" = "issue_id_v"
              AND "di"."member_id" = "opinion"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion"."id"
              AND "opinion"."degree" = -1
              AND "opinion"."fulfilled" = TRUE
            ) AS "minus1_fulfilled_count",
            ( SELECT coalesce(sum("di"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "di"
              ON "di"."snapshot_id" = "snapshot_id_v"
              AND "di"."issue_id" = "issue_id_v"
              AND "di"."member_id" = "opinion"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion"."id"
              AND "opinion"."degree" = 1
              AND "opinion"."fulfilled" = FALSE
            ) AS "plus1_unfulfilled_count",
            ( SELECT coalesce(sum("di"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "di"
              ON "di"."snapshot_id" = "snapshot_id_v"
              AND "di"."issue_id" = "issue_id_v"
              AND "di"."member_id" = "opinion"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion"."id"
              AND "opinion"."degree" = 1
              AND "opinion"."fulfilled" = TRUE
            ) AS "plus1_fulfilled_count",
            ( SELECT coalesce(sum("di"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "di"
              ON "di"."snapshot_id" = "snapshot_id_v"
              AND "di"."issue_id" = "issue_id_v"
              AND "di"."member_id" = "opinion"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion"."id"
              AND "opinion"."degree" = 2
              AND "opinion"."fulfilled" = FALSE
            ) AS "plus2_unfulfilled_count",
            ( SELECT coalesce(sum("di"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "di"
              ON "di"."snapshot_id" = "snapshot_id_v"
              AND "di"."issue_id" = "issue_id_v"
              AND "di"."member_id" = "opinion"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion"."id"
              AND "opinion"."degree" = 2
              AND "opinion"."fulfilled" = TRUE
            ) AS "plus2_fulfilled_count"
            FROM "suggestion" JOIN "initiative"
            ON "suggestion"."initiative_id" = "initiative"."id"
            WHERE "initiative"."issue_id" = "issue_id_v";
      END LOOP;
      RETURN "snapshot_id_v";
    END;
  $$;

COMMENT ON FUNCTION "take_snapshot"
  ( "issue"."id"%TYPE,
    "area"."id"%TYPE )
  IS 'This function creates a new interest/supporter snapshot of a particular issue, or, if the first argument is NULL, for all issues in ''admission'' phase of the area given as second argument. It must be executed with TRANSACTION ISOLATION LEVEL REPEATABLE READ. The snapshot must later be finished by calling "finish_snapshot" for every issue.';


DROP FUNCTION "set_snapshot_event"
  ( "issue_id_p" "issue"."id"%TYPE,
    "event_p" "snapshot_event" );


CREATE FUNCTION "finish_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "snapshot_id_v" "snapshot"."id"%TYPE;
    BEGIN
      -- NOTE: function does not require snapshot isolation but we don't call
      --       "dont_require_snapshot_isolation" here because this function is
      --       also invoked by "check_issue"
      LOCK TABLE "snapshot" IN EXCLUSIVE MODE;
      SELECT "id" INTO "snapshot_id_v" FROM "snapshot"
        ORDER BY "id" DESC LIMIT 1;
      UPDATE "issue" SET
        "calculated" = "snapshot"."calculated",
        "latest_snapshot_id" = "snapshot_id_v",
        "population" = "snapshot"."population"
        FROM "snapshot"
        WHERE "issue"."id" = "issue_id_p"
        AND "snapshot"."id" = "snapshot_id_v";
      UPDATE "initiative" SET
        "supporter_count" = (
          SELECT coalesce(sum("di"."weight"), 0)
          FROM "direct_interest_snapshot" AS "di"
          JOIN "direct_supporter_snapshot" AS "ds"
          ON "di"."member_id" = "ds"."member_id"
          WHERE "di"."snapshot_id" = "snapshot_id_v"
          AND "di"."issue_id" = "issue_id_p"
          AND "ds"."snapshot_id" = "snapshot_id_v"
          AND "ds"."initiative_id" = "initiative"."id"
        ),
        "informed_supporter_count" = (
          SELECT coalesce(sum("di"."weight"), 0)
          FROM "direct_interest_snapshot" AS "di"
          JOIN "direct_supporter_snapshot" AS "ds"
          ON "di"."member_id" = "ds"."member_id"
          WHERE "di"."snapshot_id" = "snapshot_id_v"
          AND "di"."issue_id" = "issue_id_p"
          AND "ds"."snapshot_id" = "snapshot_id_v"
          AND "ds"."initiative_id" = "initiative"."id"
          AND "ds"."informed"
        ),
        "satisfied_supporter_count" = (
          SELECT coalesce(sum("di"."weight"), 0)
          FROM "direct_interest_snapshot" AS "di"
          JOIN "direct_supporter_snapshot" AS "ds"
          ON "di"."member_id" = "ds"."member_id"
          WHERE "di"."snapshot_id" = "snapshot_id_v"
          AND "di"."issue_id" = "issue_id_p"
          AND "ds"."snapshot_id" = "snapshot_id_v"
          AND "ds"."initiative_id" = "initiative"."id"
          AND "ds"."satisfied"
        ),
        "satisfied_informed_supporter_count" = (
          SELECT coalesce(sum("di"."weight"), 0)
          FROM "direct_interest_snapshot" AS "di"
          JOIN "direct_supporter_snapshot" AS "ds"
          ON "di"."member_id" = "ds"."member_id"
          WHERE "di"."snapshot_id" = "snapshot_id_v"
          AND "di"."issue_id" = "issue_id_p"
          AND "ds"."snapshot_id" = "snapshot_id_v"
          AND "ds"."initiative_id" = "initiative"."id"
          AND "ds"."informed"
          AND "ds"."satisfied"
        )
        WHERE "issue_id" = "issue_id_p";
      UPDATE "suggestion" SET
        "minus2_unfulfilled_count" = "temp"."minus2_unfulfilled_count",
        "minus2_fulfilled_count"   = "temp"."minus2_fulfilled_count",
        "minus1_unfulfilled_count" = "temp"."minus1_unfulfilled_count",
        "minus1_fulfilled_count"   = "temp"."minus1_fulfilled_count",
        "plus1_unfulfilled_count"  = "temp"."plus1_unfulfilled_count",
        "plus1_fulfilled_count"    = "temp"."plus1_fulfilled_count",
        "plus2_unfulfilled_count"  = "temp"."plus2_unfulfilled_count",
        "plus2_fulfilled_count"    = "temp"."plus2_fulfilled_count"
        FROM "temporary_suggestion_counts" AS "temp", "initiative"
        WHERE "temp"."id" = "suggestion"."id"
        AND "initiative"."issue_id" = "issue_id_p"
        AND "suggestion"."initiative_id" = "initiative"."id";
      DELETE FROM "temporary_suggestion_counts";
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "finish_snapshot"
  ( "issue"."id"%TYPE )
  IS 'After calling "take_snapshot", this function "finish_snapshot" needs to be called for every issue in the snapshot (separate function calls keep locking time minimal)';

 
CREATE FUNCTION "issue_admission"
  ( "area_id_p" "area"."id"%TYPE )
  RETURNS BOOLEAN
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_id_v" "issue"."id"%TYPE;
    BEGIN
      PERFORM "dont_require_transaction_isolation"();
      LOCK TABLE "snapshot" IN EXCLUSIVE MODE;
      UPDATE "area" SET "issue_quorum" = "view"."issue_quorum"
        FROM "area_quorum" AS "view"
        WHERE "area"."id" = "view"."area_id"
        AND "area"."id" = "area_id_p";
      SELECT "id" INTO "issue_id_v" FROM "issue_for_admission"
        WHERE "area_id" = "area_id_p";
      IF "issue_id_v" ISNULL THEN RETURN FALSE; END IF;
      UPDATE "issue" SET
        "admission_snapshot_id" = "latest_snapshot_id",
        "state"                 = 'discussion',
        "accepted"              = now(),
        "phase_finished"        = NULL
        WHERE "id" = "issue_id_v";
      RETURN TRUE;
    END;
  $$;

COMMENT ON FUNCTION "issue_admission"
  ( "area"."id"%TYPE )
  IS 'Checks if an issue in the area can be admitted for further discussion; returns TRUE on success in which case the function must be called again until it returns FALSE';


CREATE OR REPLACE FUNCTION "check_issue"
  ( "issue_id_p" "issue"."id"%TYPE,
    "persist"    "check_issue_persistence" )
  RETURNS "check_issue_persistence"
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row"         "issue"%ROWTYPE;
      "last_calculated_v" "snapshot"."calculated"%TYPE;
      "policy_row"        "policy"%ROWTYPE;
      "initiative_row"    "initiative"%ROWTYPE;
      "state_v"           "issue_state";
    BEGIN
      PERFORM "require_transaction_isolation"();
      IF "persist" ISNULL THEN
        SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p"
          FOR UPDATE;
        SELECT "calculated" INTO "last_calculated_v"
          FROM "snapshot" JOIN "snapshot_issue"
          ON "snapshot"."id" = "snapshot_issue"."snapshot_id"
          WHERE "snapshot_issue"."issue_id" = "issue_id_p";
        IF "issue_row"."closed" NOTNULL THEN
          RETURN NULL;
        END IF;
        "persist"."state" := "issue_row"."state";
        IF
          ( "issue_row"."state" = 'admission' AND "last_calculated_v" >=
            "issue_row"."created" + "issue_row"."max_admission_time" ) OR
          ( "issue_row"."state" = 'discussion' AND now() >=
            "issue_row"."accepted" + "issue_row"."discussion_time" ) OR
          ( "issue_row"."state" = 'verification' AND now() >=
            "issue_row"."half_frozen" + "issue_row"."verification_time" ) OR
          ( "issue_row"."state" = 'voting' AND now() >=
            "issue_row"."fully_frozen" + "issue_row"."voting_time" )
        THEN
          "persist"."phase_finished" := TRUE;
        ELSE
          "persist"."phase_finished" := FALSE;
        END IF;
        IF
          NOT EXISTS (
            -- all initiatives are revoked
            SELECT NULL FROM "initiative"
            WHERE "issue_id" = "issue_id_p" AND "revoked" ISNULL
          ) AND (
            -- and issue has not been accepted yet
            "persist"."state" = 'admission' OR
            -- or verification time has elapsed
            ( "persist"."state" = 'verification' AND
              "persist"."phase_finished" ) OR
            -- or no initiatives have been revoked lately
            NOT EXISTS (
              SELECT NULL FROM "initiative"
              WHERE "issue_id" = "issue_id_p"
              AND now() < "revoked" + "issue_row"."verification_time"
            )
          )
        THEN
          "persist"."issue_revoked" := TRUE;
        ELSE
          "persist"."issue_revoked" := FALSE;
        END IF;
        IF "persist"."phase_finished" OR "persist"."issue_revoked" THEN
          UPDATE "issue" SET "phase_finished" = now()
            WHERE "id" = "issue_row"."id";
          RETURN "persist";
        ELSIF
          "persist"."state" IN ('admission', 'discussion', 'verification')
        THEN
          RETURN "persist";
        ELSE
          RETURN NULL;
        END IF;
      END IF;
      IF
        "persist"."state" IN ('admission', 'discussion', 'verification') AND
        coalesce("persist"."snapshot_created", FALSE) = FALSE
      THEN
        IF "persist"."state" != 'admission' THEN
          PERFORM "take_snapshot"("issue_id_p");
          PERFORM "finish_snapshot"("issue_id_p");
        END IF;
        "persist"."snapshot_created" = TRUE;
        IF "persist"."phase_finished" THEN
          IF "persist"."state" = 'admission' THEN
            UPDATE "issue" SET "admission_snapshot_id" = "latest_snapshot_id";
          ELSIF "persist"."state" = 'discussion' THEN
            UPDATE "issue" SET "half_freeze_snapshot_id" = "latest_snapshot_id";
          ELSIF "persist"."state" = 'verification' THEN
            UPDATE "issue" SET "full_freeze_snapshot_id" = "latest_snapshot_id";
            SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p";
            SELECT * INTO "policy_row" FROM "policy"
              WHERE "id" = "issue_row"."policy_id";
            FOR "initiative_row" IN
              SELECT * FROM "initiative"
              WHERE "issue_id" = "issue_id_p" AND "revoked" ISNULL
              FOR UPDATE
            LOOP
              IF
                "initiative_row"."polling" OR (
                  "initiative_row"."satisfied_supporter_count" > 
                  "policy_row"."initiative_quorum" AND
                  "initiative_row"."satisfied_supporter_count" *
                  "policy_row"."initiative_quorum_den" >=
                  "issue_row"."population" * "policy_row"."initiative_quorum_num"
                )
              THEN
                UPDATE "initiative" SET "admitted" = TRUE
                  WHERE "id" = "initiative_row"."id";
              ELSE
                UPDATE "initiative" SET "admitted" = FALSE
                  WHERE "id" = "initiative_row"."id";
              END IF;
            END LOOP;
          END IF;
        END IF;
        RETURN "persist";
      END IF;
      IF
        "persist"."state" IN ('admission', 'discussion', 'verification') AND
        coalesce("persist"."harmonic_weights_set", FALSE) = FALSE
      THEN
        PERFORM "set_harmonic_initiative_weights"("issue_id_p");
        "persist"."harmonic_weights_set" = TRUE;
        IF
          "persist"."phase_finished" OR
          "persist"."issue_revoked" OR
          "persist"."state" = 'admission'
        THEN
          RETURN "persist";
        ELSE
          RETURN NULL;
        END IF;
      END IF;
      IF "persist"."issue_revoked" THEN
        IF "persist"."state" = 'admission' THEN
          "state_v" := 'canceled_revoked_before_accepted';
        ELSIF "persist"."state" = 'discussion' THEN
          "state_v" := 'canceled_after_revocation_during_discussion';
        ELSIF "persist"."state" = 'verification' THEN
          "state_v" := 'canceled_after_revocation_during_verification';
        END IF;
        UPDATE "issue" SET
          "state"          = "state_v",
          "closed"         = "phase_finished",
          "phase_finished" = NULL
          WHERE "id" = "issue_id_p";
        RETURN NULL;
      END IF;
      IF "persist"."state" = 'admission' THEN
        SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p"
          FOR UPDATE;
        IF "issue_row"."phase_finished" NOTNULL THEN
          UPDATE "issue" SET
            "state"          = 'canceled_issue_not_accepted',
            "closed"         = "phase_finished",
            "phase_finished" = NULL
            WHERE "id" = "issue_id_p";
        END IF;
        RETURN NULL;
      END IF;
      IF "persist"."phase_finished" THEN
        IF "persist"."state" = 'discussion' THEN
          UPDATE "issue" SET
            "state"          = 'verification',
            "half_frozen"    = "phase_finished",
            "phase_finished" = NULL
            WHERE "id" = "issue_id_p";
          RETURN NULL;
        END IF;
        IF "persist"."state" = 'verification' THEN
          SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p"
            FOR UPDATE;
          SELECT * INTO "policy_row" FROM "policy"
            WHERE "id" = "issue_row"."policy_id";
          IF EXISTS (
            SELECT NULL FROM "initiative"
            WHERE "issue_id" = "issue_id_p" AND "admitted" = TRUE
          ) THEN
            UPDATE "issue" SET
              "state"          = 'voting',
              "fully_frozen"   = "phase_finished",
              "phase_finished" = NULL
              WHERE "id" = "issue_id_p";
          ELSE
            UPDATE "issue" SET
              "state"          = 'canceled_no_initiative_admitted',
              "fully_frozen"   = "phase_finished",
              "closed"         = "phase_finished",
              "phase_finished" = NULL
              WHERE "id" = "issue_id_p";
            -- NOTE: The following DELETE statements have effect only when
            --       issue state has been manipulated
            DELETE FROM "direct_voter"     WHERE "issue_id" = "issue_id_p";
            DELETE FROM "delegating_voter" WHERE "issue_id" = "issue_id_p";
            DELETE FROM "battle"           WHERE "issue_id" = "issue_id_p";
          END IF;
          RETURN NULL;
        END IF;
        IF "persist"."state" = 'voting' THEN
          IF coalesce("persist"."closed_voting", FALSE) = FALSE THEN
            PERFORM "close_voting"("issue_id_p");
            "persist"."closed_voting" = TRUE;
            RETURN "persist";
          END IF;
          PERFORM "calculate_ranks"("issue_id_p");
          RETURN NULL;
        END IF;
      END IF;
      RAISE WARNING 'should not happen';
      RETURN NULL;
    END;
  $$;


CREATE OR REPLACE FUNCTION "check_everything"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "area_id_v"     "area"."id"%TYPE;
      "snapshot_id_v" "snapshot"."id"%TYPE;
      "issue_id_v"    "issue"."id"%TYPE;
      "persist_v"     "check_issue_persistence";
    BEGIN
      RAISE WARNING 'Function "check_everything" should only be used for development and debugging purposes';
      DELETE FROM "expired_session";
      DELETE FROM "expired_token";
      DELETE FROM "expired_snapshot";
      PERFORM "check_activity"();
      PERFORM "calculate_member_counts"();
      FOR "area_id_v" IN SELECT "id" FROM "area_with_unaccepted_issues" LOOP
        SELECT "take_snapshot"(NULL, "area_id_v") INTO "snapshot_id_v";
        PERFORM "finish_snapshot"("issue_id") FROM "snapshot_issue"
          WHERE "snapshot_id" = "snapshot_id_v";
        LOOP
          EXIT WHEN "issue_admission"("area_id_v") = FALSE;
        END LOOP;
      END LOOP;
      FOR "issue_id_v" IN SELECT "id" FROM "open_issue" LOOP
        "persist_v" := NULL;
        LOOP
          "persist_v" := "check_issue"("issue_id_v", "persist_v");
          EXIT WHEN "persist_v" ISNULL;
        END LOOP;
      END LOOP;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "check_everything"() IS 'Amongst other regular tasks, this function performs "check_issue" for every open issue. Use this function only for development and debugging purposes, as you may run into locking and/or serialization problems in productive environments. For production, use lf_update binary instead';


CREATE OR REPLACE FUNCTION "clean_issue"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF EXISTS (
        SELECT NULL FROM "issue" WHERE "id" = "issue_id_p" AND "cleaned" ISNULL
      ) THEN
        -- override protection triggers:
        INSERT INTO "temporary_transaction_data" ("key", "value")
          VALUES ('override_protection_triggers', TRUE::TEXT);
        -- clean data:
        DELETE FROM "delegating_voter"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "direct_voter"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "delegating_interest_snapshot"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "direct_interest_snapshot"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "non_voter"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "delegation"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "supporter"
          USING "initiative"  -- NOTE: due to missing index on issue_id
          WHERE "initiative"."issue_id" = "issue_id_p"
          AND "supporter"."initiative_id" = "initiative_id";
        -- mark issue as cleaned:
        UPDATE "issue" SET "cleaned" = now() WHERE "id" = "issue_id_p";
        -- finish overriding protection triggers (avoids garbage):
        DELETE FROM "temporary_transaction_data"
          WHERE "key" = 'override_protection_triggers';
      END IF;
      RETURN;
    END;
  $$;


CREATE OR REPLACE FUNCTION "delete_member"("member_id_p" "member"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      UPDATE "member" SET
        "last_login"                   = NULL,
        "last_delegation_check"        = NULL,
        "login"                        = NULL,
        "password"                     = NULL,
        "authority"                    = NULL,
        "authority_uid"                = NULL,
        "authority_login"              = NULL,
        "locked"                       = TRUE,
        "active"                       = FALSE,
        "notify_email"                 = NULL,
        "notify_email_unconfirmed"     = NULL,
        "notify_email_secret"          = NULL,
        "notify_email_secret_expiry"   = NULL,
        "notify_email_lock_expiry"     = NULL,
        "disable_notifications"        = TRUE,
        "notification_counter"         = DEFAULT,
        "notification_sample_size"     = 0,
        "notification_dow"             = NULL,
        "notification_hour"            = NULL,
        "login_recovery_expiry"        = NULL,
        "password_reset_secret"        = NULL,
        "password_reset_secret_expiry" = NULL,
        "location"                     = NULL
        WHERE "id" = "member_id_p";
      -- "text_search_data" is updated by triggers
      DELETE FROM "setting"            WHERE "member_id" = "member_id_p";
      DELETE FROM "setting_map"        WHERE "member_id" = "member_id_p";
      DELETE FROM "member_relation_setting" WHERE "member_id" = "member_id_p";
      DELETE FROM "member_image"       WHERE "member_id" = "member_id_p";
      DELETE FROM "contact"            WHERE "member_id" = "member_id_p";
      DELETE FROM "ignored_member"     WHERE "member_id" = "member_id_p";
      DELETE FROM "session"            WHERE "member_id" = "member_id_p";
      DELETE FROM "area_setting"       WHERE "member_id" = "member_id_p";
      DELETE FROM "issue_setting"      WHERE "member_id" = "member_id_p";
      DELETE FROM "ignored_initiative" WHERE "member_id" = "member_id_p";
      DELETE FROM "initiative_setting" WHERE "member_id" = "member_id_p";
      DELETE FROM "suggestion_setting" WHERE "member_id" = "member_id_p";
      DELETE FROM "delegation"         WHERE "truster_id" = "member_id_p";
      DELETE FROM "non_voter"          WHERE "member_id" = "member_id_p";
      DELETE FROM "direct_voter" USING "issue"
        WHERE "direct_voter"."issue_id" = "issue"."id"
        AND "issue"."closed" ISNULL
        AND "member_id" = "member_id_p";
      RETURN;
    END;
  $$;


CREATE OR REPLACE FUNCTION "delete_private_data"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      DELETE FROM "temporary_transaction_data";
      DELETE FROM "member" WHERE "activated" ISNULL;
      UPDATE "member" SET
        "invite_code"                  = NULL,
        "invite_code_expiry"           = NULL,
        "admin_comment"                = NULL,
        "last_login"                   = NULL,
        "last_delegation_check"        = NULL,
        "login"                        = NULL,
        "password"                     = NULL,
        "authority"                    = NULL,
        "authority_uid"                = NULL,
        "authority_login"              = NULL,
        "lang"                         = NULL,
        "notify_email"                 = NULL,
        "notify_email_unconfirmed"     = NULL,
        "notify_email_secret"          = NULL,
        "notify_email_secret_expiry"   = NULL,
        "notify_email_lock_expiry"     = NULL,
        "disable_notifications"        = TRUE,
        "notification_counter"         = DEFAULT,
        "notification_sample_size"     = 0,
        "notification_dow"             = NULL,
        "notification_hour"            = NULL,
        "login_recovery_expiry"        = NULL,
        "password_reset_secret"        = NULL,
        "password_reset_secret_expiry" = NULL,
        "location"                     = NULL;
      -- "text_search_data" is updated by triggers
      DELETE FROM "setting";
      DELETE FROM "setting_map";
      DELETE FROM "member_relation_setting";
      DELETE FROM "member_image";
      DELETE FROM "contact";
      DELETE FROM "ignored_member";
      DELETE FROM "session";
      DELETE FROM "area_setting";
      DELETE FROM "issue_setting";
      DELETE FROM "ignored_initiative";
      DELETE FROM "initiative_setting";
      DELETE FROM "suggestion_setting";
      DELETE FROM "non_voter";
      DELETE FROM "direct_voter" USING "issue"
        WHERE "direct_voter"."issue_id" = "issue"."id"
        AND "issue"."closed" ISNULL;
      RETURN;
    END;
  $$;


CREATE TEMPORARY TABLE "old_snapshot" AS
  SELECT "ordered".*, row_number() OVER () AS "snapshot_id"
  FROM (
    SELECT * FROM (
      SELECT
        "id" AS "issue_id",
        'end_of_admission'::"snapshot_event" AS "event",
        "accepted" AS "calculated"
      FROM "issue" WHERE "accepted" NOTNULL
      UNION ALL
      SELECT
        "id" AS "issue_id",
        'half_freeze'::"snapshot_event" AS "event",
        "half_frozen" AS "calculated"
      FROM "issue" WHERE "half_frozen" NOTNULL
      UNION ALL
      SELECT
        "id" AS "issue_id",
        'full_freeze'::"snapshot_event" AS "event",
        "fully_frozen" AS "calculated"
      FROM "issue" WHERE "fully_frozen" NOTNULL
    ) AS "unordered"
    ORDER BY "calculated", "issue_id", "event"
  ) AS "ordered";


INSERT INTO "snapshot" ("id", "calculated", "population", "area_id", "issue_id")
  SELECT
    "old_snapshot"."snapshot_id" AS "id",
    "old_snapshot"."calculated",
    ( SELECT COALESCE(sum("weight"), 0)
      FROM "direct_population_snapshot" "dps"
      WHERE "dps"."issue_id" = "old_snapshot"."issue_id"
      AND   "dps"."event"    = "old_snapshot"."event"
    ) AS "population",
    "issue"."area_id" AS "area_id",
    "issue"."id" AS "issue_id"
  FROM "old_snapshot" JOIN "issue"
  ON "old_snapshot"."issue_id" = "issue"."id";


INSERT INTO "snapshot_issue" ("snapshot_id", "issue_id")
  SELECT "id" AS "snapshot_id", "issue_id" FROM "snapshot";


INSERT INTO "snapshot_population" ("snapshot_id", "member_id")
  SELECT
    "old_snapshot"."snapshot_id",
    "direct_population_snapshot"."member_id"
  FROM "old_snapshot" JOIN "direct_population_snapshot"
  ON "old_snapshot"."issue_id" = "direct_population_snapshot"."issue_id"
  AND "old_snapshot"."event" = "direct_population_snapshot"."event";

INSERT INTO "snapshot_population" ("snapshot_id", "member_id")
  SELECT
    "old_snapshot"."snapshot_id",
    "delegating_population_snapshot"."member_id"
  FROM "old_snapshot" JOIN "delegating_population_snapshot"
  ON "old_snapshot"."issue_id" = "delegating_population_snapshot"."issue_id"
  AND "old_snapshot"."event" = "delegating_population_snapshot"."event";


INSERT INTO "direct_interest_snapshot"
  ("snapshot_id", "issue_id", "member_id", "weight")
  SELECT
    "old_snapshot"."snapshot_id",
    "old_snapshot"."issue_id",
    "direct_interest_snapshot_old"."member_id",
    "direct_interest_snapshot_old"."weight"
  FROM "old_snapshot" JOIN "direct_interest_snapshot_old"
  ON "old_snapshot"."issue_id" = "direct_interest_snapshot_old"."issue_id"
  AND "old_snapshot"."event" = "direct_interest_snapshot_old"."event";

INSERT INTO "delegating_interest_snapshot"
  ( "snapshot_id", "issue_id",
    "member_id", "weight", "scope", "delegate_member_ids" )
  SELECT
    "old_snapshot"."snapshot_id",
    "old_snapshot"."issue_id",
    "delegating_interest_snapshot_old"."member_id",
    "delegating_interest_snapshot_old"."weight",
    "delegating_interest_snapshot_old"."scope",
    "delegating_interest_snapshot_old"."delegate_member_ids"
  FROM "old_snapshot" JOIN "delegating_interest_snapshot_old"
  ON "old_snapshot"."issue_id" = "delegating_interest_snapshot_old"."issue_id"
  AND "old_snapshot"."event" = "delegating_interest_snapshot_old"."event";

INSERT INTO "direct_supporter_snapshot"
  ( "snapshot_id", "issue_id",
    "initiative_id", "member_id", "draft_id", "informed", "satisfied" )
  SELECT
    "old_snapshot"."snapshot_id",
    "old_snapshot"."issue_id",
    "direct_supporter_snapshot_old"."initiative_id",
    "direct_supporter_snapshot_old"."member_id",
    "direct_supporter_snapshot_old"."draft_id",
    "direct_supporter_snapshot_old"."informed",
    "direct_supporter_snapshot_old"."satisfied"
  FROM "old_snapshot" JOIN "direct_supporter_snapshot_old"
  ON "old_snapshot"."issue_id" = "direct_supporter_snapshot_old"."issue_id"
  AND "old_snapshot"."event" = "direct_supporter_snapshot_old"."event";


ALTER TABLE "issue" DISABLE TRIGGER USER;  -- NOTE: required to modify table later

UPDATE "issue" SET "latest_snapshot_id" = "snapshot"."id"
  FROM (
    SELECT DISTINCT ON ("issue_id") "issue_id", "id"
    FROM "snapshot" ORDER BY "issue_id", "id" DESC
  ) AS "snapshot"
  WHERE "snapshot"."issue_id" = "issue"."id";

UPDATE "issue" SET "admission_snapshot_id" = "old_snapshot"."snapshot_id"
  FROM "old_snapshot"
  WHERE "old_snapshot"."issue_id" = "issue"."id"
  AND "old_snapshot"."event" = 'end_of_admission';

UPDATE "issue" SET "half_freeze_snapshot_id" = "old_snapshot"."snapshot_id"
  FROM "old_snapshot"
  WHERE "old_snapshot"."issue_id" = "issue"."id"
  AND "old_snapshot"."event" = 'half_freeze';

UPDATE "issue" SET "full_freeze_snapshot_id" = "old_snapshot"."snapshot_id"
  FROM "old_snapshot"
  WHERE "old_snapshot"."issue_id" = "issue"."id"
  AND "old_snapshot"."event" = 'full_freeze';

ALTER TABLE "issue" ENABLE TRIGGER USER;


DROP TABLE "old_snapshot";

DROP TABLE "direct_supporter_snapshot_old";
DROP TABLE "delegating_interest_snapshot_old";
DROP TABLE "direct_interest_snapshot_old";
DROP TABLE "delegating_population_snapshot";
DROP TABLE "direct_population_snapshot";


DROP VIEW "open_issue";


ALTER TABLE "issue" DROP COLUMN "latest_snapshot_event";


CREATE VIEW "open_issue" AS
  SELECT * FROM "issue" WHERE "closed" ISNULL;

COMMENT ON VIEW "open_issue" IS 'All open issues';


-- NOTE: create "issue_for_admission" view after altering table "issue"
CREATE VIEW "issue_for_admission" AS
  SELECT DISTINCT ON ("issue"."area_id")
    "issue".*,
    max("initiative"."supporter_count") AS "max_supporter_count"
  FROM "issue"
  JOIN "policy" ON "issue"."policy_id" = "policy"."id"
  JOIN "initiative" ON "issue"."id" = "initiative"."issue_id"
  JOIN "area" ON "issue"."area_id" = "area"."id"
  WHERE "issue"."state" = 'admission'::"issue_state"
  AND now() >= "issue"."created" + "issue"."min_admission_time"
  AND "initiative"."supporter_count" >= "policy"."issue_quorum"
  AND "initiative"."supporter_count" * "policy"."issue_quorum_den" >=
      "issue"."population" * "policy"."issue_quorum_num"
  AND "initiative"."supporter_count" >= "area"."issue_quorum"
  AND "initiative"."revoked" ISNULL
  GROUP BY "issue"."id"
  ORDER BY "issue"."area_id", "max_supporter_count" DESC, "issue"."id";

COMMENT ON VIEW "issue_for_admission" IS 'Contains up to 1 issue per area eligible to pass from ''admission'' to ''discussion'' state; needs to be recalculated after admitting the issue in this view';


DROP TYPE "snapshot_event";


ALTER TABLE "issue" ADD CONSTRAINT "snapshot_required" CHECK (
  ("half_frozen" ISNULL OR "half_freeze_snapshot_id" NOTNULL) AND
  ("fully_frozen" ISNULL OR "full_freeze_snapshot_id" NOTNULL) );


COMMIT;
