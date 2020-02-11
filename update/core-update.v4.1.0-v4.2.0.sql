CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.2.0-incomplete-update', 4, 2, -1))
  AS "subquery"("string", "major", "minor", "revision");

ALTER TYPE "event_type" ADD VALUE IF NOT EXISTS 'posting_created';

BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.2.0', 4, 2, 0))
  AS "subquery"("string", "major", "minor", "revision");

DROP VIEW "newsletter_to_send";
DROP VIEW "scheduled_notification_to_send";
DROP VIEW "member_contingent_left";
DROP VIEW "member_contingent";
DROP VIEW "expired_snapshot";
DROP VIEW "current_draft";
DROP VIEW "opening_draft";
DROP VIEW "area_with_unaccepted_issues";
DROP VIEW "member_to_notify";
DROP VIEW "member_eligible_to_be_notified";

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS conflux;

DROP FUNCTION "text_search_query" (TEXT);

ALTER TABLE "system_setting" DROP COLUMN "snapshot_retention";

CREATE TABLE "file" (
        "id"                    SERIAL8         PRIMARY KEY,
        UNIQUE ("content_type", "hash"),
        "content_type"          TEXT            NOT NULL,
        "hash"                  TEXT            NOT NULL,
        "data"                  BYTEA           NOT NULL,
        "preview_content_type"  TEXT,
        "preview_data"          BYTEA );

COMMENT ON TABLE "file" IS 'Table holding file contents for draft attachments';

COMMENT ON COLUMN "file"."content_type"         IS 'Content type of "data"';
COMMENT ON COLUMN "file"."hash"                 IS 'Hash of "data" to avoid storing duplicates where content-type and data is identical';
COMMENT ON COLUMN "file"."data"                 IS 'Binary content';
COMMENT ON COLUMN "file"."preview_content_type" IS 'Content type of "preview_data"';
COMMENT ON COLUMN "file"."preview_data"         IS 'Preview (e.g. preview image)';

ALTER TABLE "member" DROP COLUMN "text_search_data";
DROP TRIGGER "update_text_search_data" ON "member";

CREATE INDEX "member_useterms_member_id_contract_identifier" ON "member_useterms" ("member_id", "contract_identifier");

ALTER TABLE "member_profile" DROP COLUMN "text_search_data";
DROP TRIGGER "update_text_search_data" ON "member_profile";

ALTER TABLE "contact" ADD COLUMN "following" BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN "contact"."following" IS 'TRUE = actions of contact are shown in personal timeline';

ALTER TABLE "unit" DROP COLUMN "text_search_data";
DROP TRIGGER "update_text_search_data" ON "unit";

ALTER TABLE "area" DROP COLUMN "text_search_data";
DROP TRIGGER "update_text_search_data" ON "area";

DROP INDEX "issue_accepted_idx";
DROP INDEX "issue_half_frozen_idx";
DROP INDEX "issue_fully_frozen_idx";
ALTER INDEX "issue_created_idx_open" RENAME TO "issue_open_created_idx";
DROP INDEX "issue_closed_idx_canceled";
ALTER INDEX "issue_latest_snapshot_id" RENAME TO "issue_latest_snapshot_id_idx";
ALTER INDEX "issue_admission_snapshot_id" RENAME TO "issue_admission_snapshot_id_idx";
ALTER INDEX "issue_half_freeze_snapshot_id" RENAME TO "issue_half_freeze_snapshot_id_idx";
ALTER INDEX "issue_full_freeze_snapshot_id" RENAME TO "issue_full_freeze_snapshot_id_idx";

ALTER TABLE "initiative" ADD COLUMN "content" TEXT;
ALTER TABLE "initiative" DROP COLUMN "text_search_data";
ALTER TABLE "initiative" DROP COLUMN "draft_text_search_data";
DROP INDEX "initiative_revoked_idx";
DROP TRIGGER "update_text_search_data" ON "initiative";

COMMENT ON COLUMN "initiative"."content" IS 'Initiative text (automatically copied from most recent draft)';

ALTER TABLE "battle" DROP CONSTRAINT "initiative_ids_not_equal";
ALTER TABLE "battle" ADD CONSTRAINT "initiative_ids_not_equal" CHECK (
  "winning_initiative_id" != "losing_initiative_id" AND
  ("winning_initiative_id" NOTNULL OR "losing_initiative_id" NOTNULL) );

ALTER TABLE "draft" DROP COLUMN "text_search_data";
DROP TRIGGER "update_text_search_data" ON "draft";

CREATE TABLE "draft_attachment" (
        "id"                    SERIAL8         PRIMARY KEY,
        "draft_id"              INT8            REFERENCES "draft" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "file_id"               INT8            REFERENCES "file" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "title"                 TEXT,
        "description"           TEXT );

COMMENT ON TABLE "draft_attachment" IS 'Binary attachments for a draft (images, PDF file, etc.); Implicitly ordered through ''id'' column';

ALTER TABLE "suggestion" DROP COLUMN "text_search_data";
DROP TRIGGER "update_text_search_data" ON "suggestion";

ALTER TABLE "direct_voter" DROP COLUMN "text_search_data";
DROP TRIGGER "update_text_search_data" ON "direct_voter";

CREATE TABLE "posting" (
        UNIQUE ("author_id", "id"),  -- index needed for foreign-key on table "posting_lexeme"
        "id"                    SERIAL8         PRIMARY KEY,
        "author_id"             INT4            NOT NULL REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "created"               TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "message"               TEXT            NOT NULL,
        "unit_id"               INT4            REFERENCES "unit" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "area_id"               INT4,
        FOREIGN KEY ("unit_id", "area_id") REFERENCES "area" ("unit_id", "id") ON DELETE CASCADE ON UPDATE CASCADE,
        "policy_id"             INT4            REFERENCES "policy" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        FOREIGN KEY ("area_id", "issue_id") REFERENCES "issue" ("area_id", "id") ON DELETE CASCADE ON UPDATE CASCADE,
        FOREIGN KEY ("policy_id", "issue_id") REFERENCES "issue" ("policy_id", "id") ON DELETE CASCADE ON UPDATE CASCADE,
        "initiative_id"         INT4,
        "suggestion_id"         INT8,
        -- NOTE: no referential integrity for suggestions because those are
        --       actually deleted
        -- FOREIGN KEY ("initiative_id", "suggestion_id")
        --   REFERENCES "suggestion" ("initiative_id", "id")
        --   ON DELETE CASCADE ON UPDATE CASCADE,
        CONSTRAINT "area_requires_unit" CHECK (
          "area_id" ISNULL OR "unit_id" NOTNULL ),
        CONSTRAINT "policy_set_when_issue_set" CHECK (
          ("policy_id" NOTNULL) = ("issue_id" NOTNULL) ),
        CONSTRAINT "issue_requires_area" CHECK (
          "issue_id" ISNULL OR "area_id" NOTNULL ),
        CONSTRAINT "initiative_requires_issue" CHECK (
          "initiative_id" ISNULL OR "issue_id" NOTNULL ),
        CONSTRAINT "suggestion_requires_initiative" CHECK (
          "suggestion_id" ISNULL OR "initiative_id" NOTNULL ) );
CREATE INDEX "posting_global_idx" ON "posting" USING gist ((pstamp("author_id", "id")));
CREATE INDEX "posting_unit_idx" ON "posting" USING gist ("unit_id", (pstamp("author_id", "id"))) WHERE "unit_id" NOTNULL;
CREATE INDEX "posting_area_idx" ON "posting" USING gist ("area_id", (pstamp("author_id", "id"))) WHERE "area_id" NOTNULL;
CREATE INDEX "posting_policy_idx" ON "posting" USING gist ("policy_id", (pstamp("author_id", "id"))) WHERE "policy_id" NOTNULL;
CREATE INDEX "posting_issue_idx" ON "posting" USING gist ("issue_id", (pstamp("author_id", "id"))) WHERE "issue_id" NOTNULL;
CREATE INDEX "posting_initiative_idx" ON "posting" USING gist ("initiative_id", (pstamp("author_id", "id"))) WHERE "initiative_id" NOTNULL;
CREATE INDEX "posting_suggestion_idx" ON "posting" USING gist ("suggestion_id", (pstamp("author_id", "id"))) WHERE "suggestion_id" NOTNULL;
COMMENT ON TABLE "posting" IS 'Text postings of members; a text posting may optionally be associated to a unit, area, policy, issue, initiative, or suggestion';

CREATE TABLE "posting_lexeme" (
        PRIMARY KEY ("posting_id", "lexeme"),
        FOREIGN KEY ("posting_id", "author_id") REFERENCES "posting" ("id", "author_id") ON DELETE CASCADE ON UPDATE CASCADE,
        "posting_id"            INT8,
        "lexeme"                TEXT,
        "author_id"             INT4 );
CREATE INDEX "posting_lexeme_idx" ON "posting_lexeme" USING gist ("lexeme", (pstamp("author_id", "posting_id")));

COMMENT ON TABLE "posting_lexeme" IS 'Helper table to allow searches for hashtags.';

ALTER TABLE "event" ADD COLUMN "posting_id" INT8 REFERENCES "posting" ("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "event" DROP CONSTRAINT "constr_for_issue_state_changed";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_initiative_creation_or_revocation_or_new_draft";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_suggestion_creation";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_suggestion_removal";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_value_less_member_event";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_member_active";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_member_name_updated";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_interest";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_initiator";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_support";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_support_updated";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_suggestion_rated";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_delegation";
ALTER TABLE "event" DROP CONSTRAINT "constr_for_contact";
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_issue_state_changed" CHECK (
          "event" != 'issue_state_changed' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_initiative_creation_or_revocation_or_new_draft" CHECK (
          "event" NOT IN (
            'initiative_created_in_new_issue',
            'initiative_created_in_existing_issue',
            'initiative_revoked',
            'new_draft_created'
          ) OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_suggestion_creation" CHECK (
          "event" != 'suggestion_created' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_suggestion_removal" CHECK (
          "event" != 'suggestion_deleted' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_value_less_member_event" CHECK (
          "event" NOT IN (
            'member_activated',
            'member_deleted',
            'member_profile_updated',
            'member_image_updated'
          ) OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_member_active" CHECK (
          "event" != 'member_active' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_member_name_updated" CHECK (
          "event" != 'member_name_updated' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_interest" CHECK (
          "event" != 'interest' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_initiator" CHECK (
          "event" != 'initiator' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_support" CHECK (
          "event" != 'support' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_support_updated" CHECK (
          "event" != 'support_updated' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_suggestion_rated" CHECK (
          "event" != 'suggestion_rated' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_delegation" CHECK (
          "event" != 'delegation' OR (
            "posting_id"      ISNULL  AND
            "member_id"       NOTNULL AND
            (("other_member_id" ISNULL) OR ("boolean_value" = TRUE)) AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_contact" CHECK (
          "event" != 'contact' OR (
            "posting_id"      ISNULL  AND
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
ALTER TABLE "event" ADD
        CONSTRAINT "constr_for_posting_created" CHECK (
          "event" != 'posting_created' OR (
            "posting_id"      NOTNULL AND
            "member_id"       NOTNULL AND
            "other_member_id" ISNULL  AND
            "scope"           ISNULL  AND
            "state"           ISNULL  AND
            ("area_id" ISNULL OR "unit_id" NOTNULL) AND
            ("policy_id" NOTNULL) = ("issue_id" NOTNULL) AND
            ("issue_id" ISNULL OR "area_id" NOTNULL) AND
            ("state" NOTNULL) = ("issue_id" NOTNULL) AND
            ("initiative_id" ISNULL OR "issue_id" NOTNULL) AND
            "draft_id"        ISNULL  AND
            ("suggestion_id" ISNULL OR "initiative_id" NOTNULL) AND
            "boolean_value"   ISNULL  AND
            "numeric_value"   ISNULL  AND
            "text_value"      ISNULL  AND
            "old_text_value"  ISNULL ));

CREATE INDEX "event_tl_global_idx" ON "event" USING gist ((pstamp("member_id", "id")));
CREATE INDEX "event_tl_unit_idx" ON "event" USING gist ("unit_id", (pstamp("member_id", "id"))) WHERE "unit_id" NOTNULL;
CREATE INDEX "event_tl_area_idx" ON "event" USING gist ("area_id", (pstamp("member_id", "id"))) WHERE "area_id" NOTNULL;
CREATE INDEX "event_tl_policy_idx" ON "event" USING gist ("policy_id", (pstamp("member_id", "id"))) WHERE "policy_id" NOTNULL;
CREATE INDEX "event_tl_issue_idx" ON "event" USING gist ("issue_id", (pstamp("member_id", "id"))) WHERE "issue_id" NOTNULL;
CREATE INDEX "event_tl_initiative_idx" ON "event" USING gist ("initiative_id", (pstamp("member_id", "id"))) WHERE "initiative_id" NOTNULL;
CREATE INDEX "event_tl_suggestion_idx" ON "event" USING gist ("suggestion_id", (pstamp("member_id", "id"))) WHERE "suggestion_id" NOTNULL;

CREATE OR REPLACE FUNCTION "highlight"
  ( "body_p"       TEXT,
    "query_text_p" TEXT )
  RETURNS TEXT
  LANGUAGE 'plpgsql' IMMUTABLE AS $$
    BEGIN
      RETURN ts_headline(
        replace(replace("body_p", e'\\', e'\\\\'), '*', e'\\*'),
        "plainto_tsquery"("query_text_p"),
        'StartSel=* StopSel=* HighlightAll=TRUE' );
    END;
  $$;

CREATE FUNCTION "to_tsvector"("member") RETURNS TSVECTOR
  LANGUAGE SQL IMMUTABLE AS $$ SELECT to_tsvector(concat_ws(' ',
    $1."name",
    $1."identification"
  )) $$;
CREATE INDEX "member_to_tsvector_idx" ON "member" USING gin
  (("to_tsvector"("member".*)));

CREATE FUNCTION "to_tsvector"("member_profile") RETURNS TSVECTOR
  LANGUAGE SQL IMMUTABLE AS $$ SELECT to_tsvector(concat_ws(' ',
    $1."statement",
    $1."profile_text_data"
  )) $$;
CREATE INDEX "member_profile_to_tsvector_idx" ON "member_profile" USING gin
  (("to_tsvector"("member_profile".*)));

CREATE FUNCTION "to_tsvector"("unit") RETURNS TSVECTOR
  LANGUAGE SQL IMMUTABLE AS $$ SELECT to_tsvector(concat_ws(' ',
    $1."name",
    $1."description"
  )) $$;
CREATE INDEX "unit_to_tsvector_idx" ON "unit" USING gin
  (("to_tsvector"("unit".*)));

CREATE FUNCTION "to_tsvector"("area") RETURNS TSVECTOR
  LANGUAGE SQL IMMUTABLE AS $$ SELECT to_tsvector(concat_ws(' ',
    $1."name",
    $1."description"
  )) $$;
CREATE INDEX "area_to_tsvector_idx" ON "area" USING gin
  (("to_tsvector"("area".*)));

CREATE FUNCTION "to_tsvector"("initiative") RETURNS TSVECTOR
  LANGUAGE SQL IMMUTABLE AS $$ SELECT to_tsvector(concat_ws(' ',
    $1."name",
    $1."content"
  )) $$;
CREATE INDEX "initiative_to_tsvector_idx" ON "initiative" USING gin
  (("to_tsvector"("initiative".*)));

CREATE FUNCTION "to_tsvector"("draft") RETURNS TSVECTOR
  LANGUAGE SQL IMMUTABLE AS $$ SELECT to_tsvector(concat_ws(' ',
    $1."content"
  )) $$;
CREATE INDEX "draft_to_tsvector_idx" ON "draft" USING gin
  (("to_tsvector"("draft".*)));

CREATE FUNCTION "to_tsvector"("suggestion") RETURNS TSVECTOR
  LANGUAGE SQL IMMUTABLE AS $$ SELECT to_tsvector(concat_ws(' ',
    $1."name",
    $1."content"
  )) $$;
CREATE INDEX "suggestion_to_tsvector_idx" ON "suggestion" USING gin
  (("to_tsvector"("suggestion".*)));

CREATE FUNCTION "to_tsvector"("direct_voter") RETURNS TSVECTOR
  LANGUAGE SQL IMMUTABLE AS $$ SELECT to_tsvector(concat_ws(' ',
    $1."comment"
  )) $$;
CREATE INDEX "direct_voter_to_tsvector_idx" ON "direct_voter" USING gin
  (("to_tsvector"("direct_voter".*)));

CREATE FUNCTION "update_posting_lexeme_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "lexeme_v" TEXT;
    BEGIN
      IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
        DELETE FROM "posting_lexeme" WHERE "posting_id" = OLD."id";
      END IF;
      IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        FOR "lexeme_v" IN
          SELECT regexp_matches[1]
          FROM regexp_matches(NEW."message", '#[^\s.,;:]+')
        LOOP
          INSERT INTO "posting_lexeme" ("posting_id", "author_id", "lexeme")
            VALUES (
              NEW."id",
              NEW."author_id",
              "lexeme_v" )
            ON CONFLICT ("posting_id", "lexeme") DO NOTHING;
        END LOOP;
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "update_posting_lexeme"
  AFTER INSERT OR UPDATE OR DELETE ON "posting"
  FOR EACH ROW EXECUTE PROCEDURE "update_posting_lexeme_trigger"();

COMMENT ON FUNCTION "update_posting_lexeme_trigger"()  IS 'Implementation of trigger "update_posting_lexeme" on table "posting"';
COMMENT ON TRIGGER "update_posting_lexeme" ON "posting" IS 'Keeps table "posting_lexeme" up to date';

CREATE FUNCTION "write_event_posting_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      INSERT INTO "event" (
          "event", "posting_id", "member_id",
          "unit_id", "area_id", "policy_id",
          "issue_id", "initiative_id", "suggestion_id"
        ) VALUES (
          'posting_created', NEW."id", NEW."author_id",
          NEW."unit_id", NEW."area_id", NEW."policy_id",
          NEW."issue_id", NEW."initiative_id", NEW."suggestion_id"
        );
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_posting"
  AFTER INSERT ON "posting" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_posting_trigger"();

COMMENT ON FUNCTION "write_event_posting_trigger"()   IS 'Implementation of trigger "write_event_posting" on table "posting"';
COMMENT ON TRIGGER "write_event_posting" ON "posting" IS 'Create entry in "event" table when creating a new posting';

CREATE FUNCTION "file_requires_reference_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT NULL FROM "draft_attachment" WHERE "file_id" = NEW."id"
      ) THEN
        RAISE EXCEPTION 'Cannot create an unreferenced file.' USING
          ERRCODE = 'integrity_constraint_violation',
          HINT    = 'Create file and its reference in another table within the same transaction.';
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE CONSTRAINT TRIGGER "file_requires_reference"
  AFTER INSERT OR UPDATE ON "file" DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE PROCEDURE
  "file_requires_reference_trigger"();

COMMENT ON FUNCTION "file_requires_reference_trigger"() IS 'Implementation of trigger "file_requires_reference" on table "file"';
COMMENT ON TRIGGER "file_requires_reference" ON "file"  IS 'Ensure that files are always referenced';

CREATE FUNCTION "last_reference_deletes_file_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "reference_lost" BOOLEAN;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        "reference_lost" := TRUE;
      ELSE
        "reference_lost" := NEW."file_id" != OLD."file_id";
      END IF;
      IF
        "reference_lost" AND NOT EXISTS (
          SELECT NULL FROM "draft_attachment" WHERE "file_id" = OLD."file_id"
        )
      THEN
        DELETE FROM "file" WHERE "id" = OLD."file_id";
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE CONSTRAINT TRIGGER "last_reference_deletes_file"
  AFTER UPDATE OR DELETE ON "draft_attachment" DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE PROCEDURE
  "last_reference_deletes_file_trigger"();

COMMENT ON FUNCTION "last_reference_deletes_file_trigger"()            IS 'Implementation of trigger "last_reference_deletes_file" on table "draft_attachment"';
COMMENT ON TRIGGER "last_reference_deletes_file" ON "draft_attachment" IS 'Removing the last reference to a file deletes the file';

CREATE OR REPLACE FUNCTION "copy_current_draft_data"
  ("initiative_id_p" "initiative"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      PERFORM NULL FROM "initiative" WHERE "id" = "initiative_id_p"
        FOR UPDATE;
      UPDATE "initiative" SET
        "location" = "draft"."location",
        "content"  = "draft"."content"
        FROM "current_draft" AS "draft"
        WHERE "initiative"."id" = "initiative_id_p"
        AND "draft"."initiative_id" = "initiative_id_p";
    END;
  $$;

CREATE VIEW "follower" AS
  SELECT
    "id" AS "follower_id",
    ( SELECT ARRAY["member"."id"] || array_agg("contact"."other_member_id")
      FROM "contact"
      WHERE "contact"."member_id" = "member"."id" AND "contact"."following" )
      AS "following_ids"
  FROM "member";

COMMENT ON VIEW "follower" IS 'Provides the contacts of each member that are being followed (including the member itself) as an array of IDs';

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
          WHERE "snapshot_issue"."issue_id" = "issue_id_p"
          ORDER BY "snapshot"."id" DESC;
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
        ELSE
          UPDATE "issue" SET "issue_quorum" = "issue_quorum"."issue_quorum"
            FROM "issue_quorum"
            WHERE "id" = "issue_id_p"
            AND "issue_quorum"."issue_id" = "issue_id_p";
        END IF;
        "persist"."snapshot_created" = TRUE;
        IF "persist"."phase_finished" THEN
          IF "persist"."state" = 'admission' THEN
            UPDATE "issue" SET "admission_snapshot_id" = "latest_snapshot_id"
              WHERE "id" = "issue_id_p";
          ELSIF "persist"."state" = 'discussion' THEN
            UPDATE "issue" SET "half_freeze_snapshot_id" = "latest_snapshot_id"
              WHERE "id" = "issue_id_p";
          ELSIF "persist"."state" = 'verification' THEN
            UPDATE "issue" SET "full_freeze_snapshot_id" = "latest_snapshot_id"
              WHERE "id" = "issue_id_p";
            SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p";
            FOR "initiative_row" IN
              SELECT * FROM "initiative"
              WHERE "issue_id" = "issue_id_p" AND "revoked" ISNULL
              FOR UPDATE
            LOOP
              IF
                "initiative_row"."polling" OR
                "initiative_row"."satisfied_supporter_count" >=
                "issue_row"."initiative_quorum"
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
      DELETE FROM "unused_snapshot";
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
      DELETE FROM "unused_snapshot";
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
        "deleted"                      = coalesce("deleted", now()),
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
        "notification_sent"            = NULL,
        "login_recovery_expiry"        = NULL,
        "password_reset_secret"        = NULL,
        "password_reset_secret_expiry" = NULL,
        "location"                     = NULL
        WHERE "id" = "member_id_p";
      DELETE FROM "member_settings"    WHERE "member_id" = "member_id_p";
      DELETE FROM "member_profile"     WHERE "member_id" = "member_id_p";
      DELETE FROM "rendered_member_statement" WHERE "member_id" = "member_id_p";
      DELETE FROM "member_image"       WHERE "member_id" = "member_id_p";
      DELETE FROM "contact"            WHERE "member_id" = "member_id_p";
      DELETE FROM "ignored_member"     WHERE "member_id" = "member_id_p";
      DELETE FROM "session"            WHERE "member_id" = "member_id_p";
      DELETE FROM "member_application" WHERE "member_id" = "member_id_p";
      DELETE FROM "token"              WHERE "member_id" = "member_id_p";
      DELETE FROM "subscription"       WHERE "member_id" = "member_id_p";
      DELETE FROM "ignored_area"       WHERE "member_id" = "member_id_p";
      DELETE FROM "ignored_initiative" WHERE "member_id" = "member_id_p";
      DELETE FROM "delegation"         WHERE "truster_id" = "member_id_p";
      DELETE FROM "non_voter"          WHERE "member_id" = "member_id_p";
      DELETE FROM "direct_voter" USING "issue"
        WHERE "direct_voter"."issue_id" = "issue"."id"
        AND "issue"."closed" ISNULL
        AND "member_id" = "member_id_p";
      DELETE FROM "notification_initiative_sent" WHERE "member_id" = "member_id_p";
      RETURN;
    END;
  $$;

CREATE OR REPLACE FUNCTION "delete_private_data"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      DELETE FROM "temporary_transaction_data";
      DELETE FROM "temporary_suggestion_counts";
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
        "notification_sent"            = NULL,
        "login_recovery_expiry"        = NULL,
        "password_reset_secret"        = NULL,
        "password_reset_secret_expiry" = NULL,
        "location"                     = NULL;
      DELETE FROM "verification";
      DELETE FROM "member_settings";
      DELETE FROM "member_useterms";
      DELETE FROM "member_profile";
      DELETE FROM "rendered_member_statement";
      DELETE FROM "member_image";
      DELETE FROM "contact";
      DELETE FROM "ignored_member";
      DELETE FROM "session";
      DELETE FROM "system_application";
      DELETE FROM "system_application_redirect_uri";
      DELETE FROM "dynamic_application_scope";
      DELETE FROM "member_application";
      DELETE FROM "token";
      DELETE FROM "subscription";
      DELETE FROM "ignored_area";
      DELETE FROM "ignored_initiative";
      DELETE FROM "non_voter";
      DELETE FROM "direct_voter" USING "issue"
        WHERE "direct_voter"."issue_id" = "issue"."id"
        AND "issue"."closed" ISNULL;
      DELETE FROM "event_processed";
      DELETE FROM "notification_initiative_sent";
      DELETE FROM "newsletter";
      RETURN;
    END;
  $$;

CREATE VIEW "member_eligible_to_be_notified" AS
  SELECT * FROM "member"
  WHERE "activated" NOTNULL AND "locked" = FALSE;

COMMENT ON VIEW "member_eligible_to_be_notified" IS 'Filtered "member" table containing only activated and non-locked members (used as helper view for "member_to_notify" and "newsletter_to_send")';

CREATE VIEW "member_to_notify" AS
  SELECT * FROM "member_eligible_to_be_notified"
  WHERE "disable_notifications" = FALSE;

COMMENT ON VIEW "member_to_notify" IS 'Filtered "member" table containing only members that are eligible to and wish to receive notifications; NOTE: "notify_email" may still be NULL and might need to be checked by frontend (this allows other means of messaging)';

CREATE VIEW "area_with_unaccepted_issues" AS
  SELECT DISTINCT ON ("area"."id") "area".*
  FROM "area" JOIN "issue" ON "area"."id" = "issue"."area_id"
  WHERE "issue"."state" = 'admission';

COMMENT ON VIEW "area_with_unaccepted_issues" IS 'All areas with unaccepted open issues (needed for issue admission system)';

CREATE VIEW "opening_draft" AS
  SELECT DISTINCT ON ("initiative_id") * FROM "draft"
  ORDER BY "initiative_id", "id";

COMMENT ON VIEW "opening_draft" IS 'First drafts of all initiatives';

CREATE VIEW "current_draft" AS
  SELECT DISTINCT ON ("initiative_id") * FROM "draft"
  ORDER BY "initiative_id", "id" DESC;

COMMENT ON VIEW "current_draft" IS 'All latest drafts for each initiative';

CREATE VIEW "member_contingent" AS
  SELECT
    "member"."id" AS "member_id",
    "contingent"."polling",
    "contingent"."time_frame",
    CASE WHEN "contingent"."text_entry_limit" NOTNULL THEN
      (
        SELECT count(1) FROM "draft"
        JOIN "initiative" ON "initiative"."id" = "draft"."initiative_id"
        WHERE "draft"."author_id" = "member"."id"
        AND "initiative"."polling" = "contingent"."polling"
        AND "draft"."created" > now() - "contingent"."time_frame"
      ) + (
        SELECT count(1) FROM "suggestion"
        JOIN "initiative" ON "initiative"."id" = "suggestion"."initiative_id"
        WHERE "suggestion"."author_id" = "member"."id"
        AND "contingent"."polling" = FALSE
        AND "suggestion"."created" > now() - "contingent"."time_frame"
      )
    ELSE NULL END AS "text_entry_count",
    "contingent"."text_entry_limit",
    CASE WHEN "contingent"."initiative_limit" NOTNULL THEN (
      SELECT count(1) FROM "opening_draft" AS "draft"
        JOIN "initiative" ON "initiative"."id" = "draft"."initiative_id"
      WHERE "draft"."author_id" = "member"."id"
      AND "initiative"."polling" = "contingent"."polling"
      AND "draft"."created" > now() - "contingent"."time_frame"
    ) ELSE NULL END AS "initiative_count",
    "contingent"."initiative_limit"
  FROM "member" CROSS JOIN "contingent";

COMMENT ON VIEW "member_contingent" IS 'Actual counts of text entries and initiatives are calculated per member for each limit in the "contingent" table.';

COMMENT ON COLUMN "member_contingent"."text_entry_count" IS 'Only calculated when "text_entry_limit" is not null in the same row';
COMMENT ON COLUMN "member_contingent"."initiative_count" IS 'Only calculated when "initiative_limit" is not null in the same row';

CREATE VIEW "member_contingent_left" AS
  SELECT
    "member_id",
    "polling",
    max("text_entry_limit" - "text_entry_count") AS "text_entries_left",
    max("initiative_limit" - "initiative_count") AS "initiatives_left"
  FROM "member_contingent" GROUP BY "member_id", "polling";

COMMENT ON VIEW "member_contingent_left" IS 'Amount of text entries or initiatives which can be posted now instantly by a member. This view should be used by a frontend to determine, if the contingent for posting is exhausted.';

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

SELECT "copy_current_draft_data" ("id") FROM "initiative";

END;
