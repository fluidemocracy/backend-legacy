BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.0.1-dev', 4, 0, -1))
  AS "subquery"("string", "major", "minor", "revision");

ALTER TABLE "member" ADD COLUMN "role" BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE "agent" (
        PRIMARY KEY ("controlled_id", "controller_id"),
        "controlled_id"         INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "controller_id"         INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        CONSTRAINT "controlled_id_and_controller_id_differ" CHECK (
            "controlled_id" != "controller_id" ) );
CREATE INDEX "agent_controller_id_idx" ON "agent" ("controller_id");

COMMENT ON TABLE "agent" IS 'Privileges for role accounts';

ALTER TABLE "session" ADD COLUMN "real_member_id" INT4 REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE;

COMMENT ON COLUMN "session"."member_id"         IS 'Reference to member, who is logged in, or role account in use';
COMMENT ON COLUMN "session"."real_member_id"    IS 'Reference to member, who is really logged in (real person rather than role account)';

CREATE TABLE "role_verification" (
        "id"                    SERIAL8         PRIMARY KEY,
        "requested"             TIMESTAMPTZ,
        "request_origin"        JSONB,
        "request_data"          JSONB,
        "requesting_member_id"  INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "requesting_real_member_id"  INT4       REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "verifying_member_id"   INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "verified_member_id"    INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "verified"              TIMESTAMPTZ,
        "verification_data"     JSONB,
        "denied"                TIMESTAMPTZ,
        "comment"               TEXT,
        CONSTRAINT "verified_and_denied_conflict" CHECK (
          "verified" ISNULL OR "denied" ISNULL ) );
CREATE INDEX "role_verification_requested_idx" ON "role_verification" ("requested");
CREATE INDEX "role_verification_open_request_idx" ON "role_verification" ("requested") WHERE "verified" ISNULL AND "denied" ISNULL;
CREATE INDEX "role_verification_requesting_member_id_idx" ON "role_verification" ("requesting_member_id");
CREATE INDEX "role_verification_verified_member_id_idx" ON "role_verification" ("verified_member_id");
CREATE INDEX "role_verification_verified_idx" ON "role_verification" ("verified");
CREATE INDEX "role_verification_denied_idx" ON "role_verification" ("denied");

COMMENT ON TABLE "role_verification" IS 'Request to verify a role account (see table "verification" for documentation of columns not documented for this table)';

COMMENT ON COLUMN "role_verification"."requesting_member_id" IS 'Member role account to verify';
COMMENT ON COLUMN "role_verification"."requesting_real_member_id" IS 'Member account of real person who requested verification';

ALTER TABLE "ignored_area" DROP CONSTRAINT "ignored_area_member_id_fkey";
ALTER TABLE "ignored_area" ADD FOREIGN KEY ("member_id") REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE;

CREATE OR REPLACE VIEW "expired_token" AS
  SELECT * FROM "token" WHERE now() > "expiry" AND NOT (
    "token_type" = 'authorization' AND "used" AND EXISTS (
      SELECT NULL FROM "token" AS "other"
      WHERE "other"."authorization_token_id" = "token"."id" ) );

ALTER TABLE "system_application" RENAME COLUMN "discovery_baseurl" TO "base_url";
ALTER TABLE "system_application" ADD COLUMN "manifest_url" TEXT;

COMMENT ON COLUMN "system_application"."base_url"     IS 'Base URL for users';
COMMENT ON COLUMN "system_application"."manifest_url" IS 'URL referring to a manifest that can be used for application (type/version) discovery';

COMMIT;
