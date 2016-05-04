BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('3.2.2', 3, 2, 2))
  AS "subquery"("string", "major", "minor", "revision");

CREATE OR REPLACE FUNCTION "featured_initiative"
  ( "recipient_id_p" "member"."id"%TYPE,
    "area_id_p"      "area"."id"%TYPE )
  RETURNS SETOF "initiative"."id"%TYPE
  LANGUAGE 'plpgsql' STABLE AS $$
    DECLARE
      "counter_v"         "member"."notification_counter"%TYPE;
      "sample_size_v"     "member"."notification_sample_size"%TYPE;
      "initiative_id_ary" INT4[];  --"initiative"."id"%TYPE[]
      "match_v"           BOOLEAN;
      "member_id_v"       "member"."id"%TYPE;
      "seed_v"            TEXT;
      "initiative_id_v"   "initiative"."id"%TYPE;
    BEGIN
      SELECT "notification_counter", "notification_sample_size"
        INTO "counter_v", "sample_size_v"
        FROM "member" WHERE "id" = "recipient_id_p";
      IF COALESCE("sample_size_v" <= 0, TRUE) THEN
        RETURN;
      END IF;
      "initiative_id_ary" := '{}';
      LOOP
        "match_v" := FALSE;
        FOR "member_id_v", "seed_v" IN
          SELECT * FROM (
            SELECT DISTINCT
              "supporter"."member_id",
              md5(
                "recipient_id_p" || '-' ||
                "counter_v"      || '-' ||
                "area_id_p"      || '-' ||
                "supporter"."member_id"
              ) AS "seed"
            FROM "supporter"
            JOIN "initiative" ON "initiative"."id" = "supporter"."initiative_id"
            JOIN "issue" ON "issue"."id" = "initiative"."issue_id"
            WHERE "supporter"."member_id" != "recipient_id_p"
            AND "issue"."area_id" = "area_id_p"
            AND "issue"."state" IN ('admission', 'discussion', 'verification')
          ) AS "subquery"
          ORDER BY "seed"
        LOOP
          SELECT "initiative"."id" INTO "initiative_id_v"
            FROM "initiative"
            JOIN "issue" ON "issue"."id" = "initiative"."issue_id"
            JOIN "area" ON "area"."id" = "issue"."area_id"
            JOIN "supporter" ON "supporter"."initiative_id" = "initiative"."id"
            LEFT JOIN "supporter" AS "self_support" ON
              "self_support"."initiative_id" = "initiative"."id" AND
              "self_support"."member_id" = "recipient_id_p"
            LEFT JOIN "privilege" ON
              "privilege"."member_id" = "recipient_id_p" AND
              "privilege"."unit_id" = "area"."unit_id" AND
              "privilege"."voting_right" = TRUE
            LEFT JOIN "subscription" ON
              "subscription"."member_id" = "recipient_id_p" AND
              "subscription"."unit_id" = "area"."unit_id"
            LEFT JOIN "ignored_initiative" ON
              "ignored_initiative"."member_id" = "recipient_id_p" AND
              "ignored_initiative"."initiative_id" = "initiative"."id"
            WHERE "supporter"."member_id" = "member_id_v"
            AND "issue"."area_id" = "area_id_p"
            AND "issue"."state" IN ('admission', 'discussion', 'verification')
            AND "initiative"."revoked" ISNULL
            AND "self_support"."member_id" ISNULL
            AND NOT "initiative_id_ary" @> ARRAY["initiative"."id"]
            AND (
              "privilege"."member_id" NOTNULL OR
              "subscription"."member_id" NOTNULL )
            AND "ignored_initiative"."member_id" ISNULL
            AND NOT EXISTS (
              SELECT NULL FROM "draft"
              JOIN "ignored_member" ON
                "ignored_member"."member_id" = "recipient_id_p" AND
                "ignored_member"."other_member_id" = "draft"."author_id"
              WHERE "draft"."initiative_id" = "initiative"."id"
            )
            ORDER BY md5("seed_v" || '-' || "initiative"."id")
            LIMIT 1;
          IF FOUND THEN
            "match_v" := TRUE;
            RETURN NEXT "initiative_id_v";
            IF array_length("initiative_id_ary", 1) + 1 >= "sample_size_v" THEN
              RETURN;
            END IF;
            "initiative_id_ary" := "initiative_id_ary" || "initiative_id_v";
          END IF;
        END LOOP;
        EXIT WHEN NOT "match_v";
      END LOOP;
      RETURN;
    END;
  $$;

COMMIT;
