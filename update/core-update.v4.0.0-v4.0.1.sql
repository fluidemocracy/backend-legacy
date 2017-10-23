BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.0.1', 4, 0, 1))
  AS "subquery"("string", "major", "minor", "revision");

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
