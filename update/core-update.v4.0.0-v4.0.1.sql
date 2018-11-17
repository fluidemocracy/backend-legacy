BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.0.1-dev', 4, 0, -1))
  AS "subquery"("string", "major", "minor", "revision");

ALTER TABLE "member" ADD COLUMN "unsubscribe_secret" TEXT;

COMMENT ON COLUMN "member"."unsubscribe_secret" IS 'Secret string to be used for a List-Unsubscribe mail header';

ALTER TABLE "member" ADD COLUMN "role" BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE "agent" (
        PRIMARY KEY ("controlled_id", "controller_id"),
        "controlled_id"         INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "controller_id"         INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "accepted"              BOOLEAN,
        CONSTRAINT "controlled_id_and_controller_id_differ" CHECK (
            "controlled_id" != "controller_id" ) );
CREATE INDEX "agent_controller_id_idx" ON "agent" ("controller_id");

COMMENT ON TABLE "agent" IS 'Privileges for role accounts';

COMMENT ON COLUMN "agent"."accepted" IS 'If "accepted" is NULL, then the member was invited to be an agent, but has not reacted yet. If it is TRUE, the member has accepted the invitation, if it is FALSE, the member has rejected the invitation.';

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

CREATE OR REPLACE FUNCTION "write_event_initiative_revoked_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row"  "issue"%ROWTYPE;
      "area_row"   "area"%ROWTYPE;
      "draft_id_v" "draft"."id"%TYPE;
    BEGIN
      IF OLD."revoked" ISNULL AND NEW."revoked" NOTNULL THEN
        -- NOTE: lock for primary key update to avoid new drafts
        PERFORM NULL FROM "initiative" WHERE "id" = NEW."id" FOR UPDATE;
        SELECT * INTO "issue_row" FROM "issue"
          WHERE "id" = NEW."issue_id" FOR SHARE;
        SELECT * INTO "area_row" FROM "area"
          WHERE "id" = "issue_row"."area_id" FOR SHARE;
        -- NOTE: FOR SHARE cannot be used with DISTINCT in view "current_draft"
        PERFORM NULL FROM "draft" WHERE "initiative_id" = NEW."id" FOR SHARE;
        SELECT "id" INTO "draft_id_v" FROM "current_draft"
          WHERE "initiative_id" = NEW."id";
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

COMMIT;
