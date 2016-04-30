BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('3.2.1', 3, 2, 1))
  AS "subquery"("string", "major", "minor", "revision");

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
        /* compatibility with PostgreSQL 9.1 */
        DELETE FROM "notification_initiative_sent"
          WHERE "member_id" = "recipient_id_p"
          AND "initiative_id" = "result_row"."initiative_id";
        INSERT INTO "notification_initiative_sent"
          ("member_id", "initiative_id", "last_draft_id", "last_suggestion_id")
          VALUES (
            "recipient_id_p",
            "result_row"."initiative_id",
            "last_draft_id_v",
            "last_suggestion_id_v" );
        /* TODO: use alternative code below, requires PostgreSQL 9.5 or higher
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
        */
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

COMMIT;
