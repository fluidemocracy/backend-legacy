BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.0.1', 4, 0, 1))
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
