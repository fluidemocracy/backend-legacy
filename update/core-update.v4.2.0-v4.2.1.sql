CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.2.1-incomplete-update', 4, 2, -1))
  AS "subquery"("string", "major", "minor", "revision");

BEGIN;

ALTER TABLE "unit" ADD COLUMN "attr" JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof("attr") = 'object');
COMMENT ON COLUMN "unit"."attr" IS 'Opaque data structure to store any extended attributes used by frontend or middleware';

ALTER TABLE "unit" ADD COLUMN "member_weight" INT4;
COMMENT ON COLUMN "unit"."member_weight" IS 'Sum of active members'' voting weight';

ALTER TABLE "snapshot_population" ADD COLUMN "weight" INT4 NOT NULL DEFAULT 1;
ALTER TABLE "snapshot_population" ALTER COLUMN "weight" DROP DEFAULT;
 
ALTER TABLE "privilege" ADD COLUMN "weight" INT4 NOT NULL DEFAULT 1 CHECK ("weight" >= 0);
COMMENT ON COLUMN "privilege"."weight"           IS 'Voting weight of member in unit';

CREATE TABLE "issue_privilege" (
        PRIMARY KEY ("issue_id", "member_id"),
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "initiative_right"      BOOLEAN,
        "voting_right"          BOOLEAN,
        "polling_right"         BOOLEAN,
        "weight"                INT4            CHECK ("weight" >= 0) );
CREATE INDEX "issue_privilege_idx" ON "issue_privilege" ("member_id");
COMMENT ON TABLE "issue_privilege" IS 'Override of "privilege" table for rights of members in certain issues';
 
ALTER TABLE "direct_interest_snapshot" ADD COLUMN "ownweight" INT4 NOT NULL DEFAULT 1;
ALTER TABLE "direct_interest_snapshot" ALTER COLUMN "ownweight" DROP DEFAULT;
COMMENT ON COLUMN "direct_interest_snapshot"."ownweight" IS 'Own voting weight of member, disregading delegations';
COMMENT ON COLUMN "direct_interest_snapshot"."weight"    IS 'Voting weight of member according to own weight and "delegating_interest_snapshot"';
 
ALTER TABLE "delegating_interest_snapshot" ADD COLUMN "ownweight" INT4 NOT NULL DEFAULT 1;
ALTER TABLE "delegating_interest_snapshot" ALTER COLUMN "ownweight" DROP DEFAULT;
COMMENT ON COLUMN "delegating_interest_snapshot"."ownweight" IS 'Own voting weight of member, disregading delegations';
COMMENT ON COLUMN "delegating_interest_snapshot"."weight"    IS 'Intermediate voting weight considering incoming delegations';

ALTER TABLE "direct_voter" ADD COLUMN "ownweight" INT4 DEFAULT 1;
ALTER TABLE "direct_voter" ALTER COLUMN "ownweight" DROP DEFAULT;
COMMENT ON COLUMN "direct_voter"."ownweight" IS 'Own voting weight of member, disregarding delegations';
COMMENT ON COLUMN "direct_voter"."weight"    IS 'Voting weight of member according to own weight and "delegating_interest_snapshot"';

ALTER TABLE "delegating_voter" ADD COLUMN "ownweight" INT4 NOT NULL DEFAULT 1;
ALTER TABLE "delegating_voter" ALTER COLUMN "ownweight" DROP DEFAULT;
COMMENT ON COLUMN "delegating_voter"."ownweight" IS 'Own voting weight of member, disregarding delegations';
COMMENT ON COLUMN "delegating_voter"."weight"    IS 'Intermediate voting weight considering incoming delegations';

ALTER TABLE "posting" ADD FOREIGN KEY ("issue_id", "initiative_id") REFERENCES "initiative" ("issue_id", "id");

DROP VIEW "issue_delegation";
CREATE VIEW "issue_delegation" AS
  SELECT DISTINCT ON ("issue"."id", "delegation"."truster_id")
    "issue"."id" AS "issue_id",
    "delegation"."id",
    "delegation"."truster_id",
    "delegation"."trustee_id",
    COALESCE("issue_privilege"."weight", "privilege"."weight") AS "weight",
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
  LEFT JOIN "privilege"
    ON "area"."unit_id" = "privilege"."unit_id"
    AND "delegation"."truster_id" = "privilege"."member_id"
  LEFT JOIN "issue_privilege"
    ON "issue"."id" = "issue_privilege"."issue_id"
    AND "delegation"."truster_id" = "issue_privilege"."member_id"
  WHERE "member"."active"
  AND COALESCE("issue_privilege"."voting_right", "privilege"."voting_right")
  ORDER BY
    "issue"."id",
    "delegation"."truster_id",
    "delegation"."scope" DESC;
COMMENT ON VIEW "issue_delegation" IS 'Issue delegations where trusters are active and have voting right';

CREATE OR REPLACE VIEW "unit_member" AS
  SELECT
    "privilege"."unit_id" AS "unit_id",
    "member"."id"         AS "member_id",
    "privilege"."weight"
  FROM "privilege" JOIN "member" ON "member"."id" = "privilege"."member_id"
  WHERE "privilege"."voting_right" AND "member"."active";

CREATE OR REPLACE VIEW "unit_member_count" AS
  SELECT
    "unit"."id" AS "unit_id",
    count("unit_member"."member_id") AS "member_count",
    sum("unit_member"."weight") AS "member_weight"
  FROM "unit" LEFT JOIN "unit_member"
  ON "unit"."id" = "unit_member"."unit_id"
  GROUP BY "unit"."id";

CREATE OR REPLACE VIEW "event_for_notification" AS
  SELECT
    "member"."id" AS "recipient_id",
    "event".*
  FROM "member" CROSS JOIN "event"
  JOIN "issue" ON "issue"."id" = "event"."issue_id"
  JOIN "area" ON "area"."id" = "issue"."area_id"
  LEFT JOIN "privilege" ON
    "privilege"."member_id" = "member"."id" AND
    "privilege"."unit_id" = "area"."unit_id"
  LEFT JOIN "issue_privilege" ON
    "issue_privilege"."member_id" = "member"."id" AND
    "issue_privilege"."issue_id" = "event"."issue_id"
  LEFT JOIN "subscription" ON
    "subscription"."member_id" = "member"."id" AND
    "subscription"."unit_id" = "area"."unit_id"
  LEFT JOIN "ignored_area" ON
    "ignored_area"."member_id" = "member"."id" AND
    "ignored_area"."area_id" = "issue"."area_id"
  LEFT JOIN "interest" ON
    "interest"."member_id" = "member"."id" AND
    "interest"."issue_id" = "event"."issue_id"
  LEFT JOIN "supporter" ON
    "supporter"."member_id" = "member"."id" AND
    "supporter"."initiative_id" = "event"."initiative_id"
  WHERE (
    COALESCE("issue_privilege"."voting_right", "privilege"."voting_right") OR
    "subscription"."member_id" NOTNULL
  ) AND ("ignored_area"."member_id" ISNULL OR "interest"."member_id" NOTNULL)
  AND (
    "event"."event" = 'issue_state_changed'::"event_type" OR
    ( "event"."event" = 'initiative_revoked'::"event_type" AND
      "supporter"."member_id" NOTNULL ) );

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
              "privilege"."unit_id" = "area"."unit_id"
            LEFT JOIN "issue_privilege" ON
              "issue_privilege"."member_id" = "recipient_id_p" AND
              "issue_privilege"."issue_id" = "initiative"."issue_id"
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
              COALESCE(
                "issue_privilege"."voting_right", "privilege"."voting_right"
              ) OR "subscription"."member_id" NOTNULL )
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
          SELECT NULL FROM "member"
          LEFT JOIN "privilege"
          ON "privilege"."member_id" = "member"."id"
          AND "privilege"."unit_id" = "unit_id_v"
          LEFT JOIN "issue_privilege"
          ON "issue_privilege"."member_id" = "member"."id"
          AND "issue_privilege"."issue_id" = "issue_id_p"
          WHERE "id" = "output_row"."member_id"
          AND "member"."active"
          AND COALESCE(
            "issue_privilege"."voting_right", "privilege"."voting_right")
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

CREATE OR REPLACE FUNCTION "calculate_member_counts"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      PERFORM "require_transaction_isolation"();
      DELETE FROM "member_count";
      INSERT INTO "member_count" ("total_count")
        SELECT "total_count" FROM "member_count_view";
      UPDATE "unit" SET
        "member_count" = "view"."member_count",
        "member_weight" = "view"."member_weight"
        FROM "unit_member_count" AS "view"
        WHERE "view"."unit_id" = "unit"."id";
      RETURN;
    END;
  $$;
COMMENT ON FUNCTION "calculate_member_counts"() IS 'Updates "member_count" table and "member_count" and "member_weight" columns of table "area" by materializing data from views "member_count_view" and "unit_member_count"';
 
CREATE OR REPLACE FUNCTION "weight_of_added_delegations_for_snapshot"
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
              "ownweight",
              "scope",
              "delegate_member_ids"
            ) VALUES (
              "snapshot_id_p",
              "issue_id_p",
              "issue_delegation_row"."truster_id",
              "issue_delegation_row"."weight",
              "issue_delegation_row"."scope",
              "delegate_member_ids_v"
            );
          "sub_weight_v" := "issue_delegation_row"."weight" +
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

CREATE OR REPLACE FUNCTION "take_snapshot"
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
      SELECT "unit_id" INTO "unit_id_v" FROM "area" WHERE "id" = "area_id_v";
      INSERT INTO "snapshot" ("area_id", "issue_id")
        VALUES ("area_id_v", "issue_id_p")
        RETURNING "id" INTO "snapshot_id_v";
      INSERT INTO "snapshot_population" ("snapshot_id", "member_id", "weight")
        SELECT
          "snapshot_id_v",
          "member"."id",
          COALESCE("issue_privilege"."weight", "privilege"."weight")
        FROM "member"
        LEFT JOIN "privilege"
        ON "privilege"."unit_id" = "unit_id_v"
        AND "privilege"."member_id" = "member"."id"
        LEFT JOIN "issue_privilege"
        ON "issue_privilege"."issue_id" = "issue_id_p"
        AND "issue_privilege"."member_id" = "member"."id"
        WHERE "member"."active" AND COALESCE(
          "issue_privilege"."voting_right", "privilege"."voting_right");
      UPDATE "snapshot" SET
        "population" = (
          SELECT sum("weight") FROM "snapshot_population"
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
          ("snapshot_id", "issue_id", "member_id", "ownweight")
          SELECT
            "snapshot_id_v" AS "snapshot_id",
            "issue_id_v"    AS "issue_id",
            "member"."id"   AS "member_id",
            COALESCE(
              "issue_privilege"."weight", "privilege"."weight"
            ) AS "ownweight"
          FROM "issue"
          JOIN "area" ON "issue"."area_id" = "area"."id"
          JOIN "interest" ON "issue"."id" = "interest"."issue_id"
          JOIN "member" ON "interest"."member_id" = "member"."id"
          LEFT JOIN "privilege"
            ON "privilege"."unit_id" = "area"."unit_id"
            AND "privilege"."member_id" = "member"."id"
          LEFT JOIN "issue_privilege"
            ON "issue_privilege"."issue_id" = "issue_id_v"
            AND "issue_privilege"."member_id" = "member"."id"
          WHERE "issue"."id" = "issue_id_v"
          AND "member"."active" AND COALESCE(
            "issue_privilege"."voting_right", "privilege"."voting_right");
        FOR "member_id_v" IN
          SELECT "member_id" FROM "direct_interest_snapshot"
          WHERE "snapshot_id" = "snapshot_id_v"
          AND "issue_id" = "issue_id_v"
        LOOP
          UPDATE "direct_interest_snapshot" SET
            "weight" = "ownweight" +
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

CREATE OR REPLACE FUNCTION "weight_of_added_vote_delegations"
  ( "issue_id_p"            "issue"."id"%TYPE,
    "member_id_p"           "member"."id"%TYPE,
    "delegate_member_ids_p" "delegating_voter"."delegate_member_ids"%TYPE )
  RETURNS "direct_voter"."weight"%TYPE
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_delegation_row"  "issue_delegation"%ROWTYPE;
      "delegate_member_ids_v" "delegating_voter"."delegate_member_ids"%TYPE;
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
          SELECT NULL FROM "direct_voter"
          WHERE "member_id" = "issue_delegation_row"."truster_id"
          AND "issue_id" = "issue_id_p"
        ) AND NOT EXISTS (
          SELECT NULL FROM "delegating_voter"
          WHERE "member_id" = "issue_delegation_row"."truster_id"
          AND "issue_id" = "issue_id_p"
        ) THEN
          "delegate_member_ids_v" :=
            "member_id_p" || "delegate_member_ids_p";
          INSERT INTO "delegating_voter" (
              "issue_id",
              "member_id",
              "ownweight",
              "scope",
              "delegate_member_ids"
            ) VALUES (
              "issue_id_p",
              "issue_delegation_row"."truster_id",
              "issue_delegation_row"."weight",
              "issue_delegation_row"."scope",
              "delegate_member_ids_v"
            );
          "sub_weight_v" := "issue_delegation_row"."weight" +
            "weight_of_added_vote_delegations"(
              "issue_id_p",
              "issue_delegation_row"."truster_id",
              "delegate_member_ids_v"
            );
          UPDATE "delegating_voter"
            SET "weight" = "sub_weight_v"
            WHERE "issue_id" = "issue_id_p"
            AND "member_id" = "issue_delegation_row"."truster_id";
          "weight_v" := "weight_v" + "sub_weight_v";
        END IF;
      END LOOP;
      RETURN "weight_v";
    END;
  $$;

CREATE OR REPLACE FUNCTION "add_vote_delegations"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "member_id_v" "member"."id"%TYPE;
    BEGIN
      PERFORM "require_transaction_isolation"();
      FOR "member_id_v" IN
        SELECT "member_id" FROM "direct_voter"
        WHERE "issue_id" = "issue_id_p"
      LOOP
        UPDATE "direct_voter" SET
          "weight" = "ownweight" + "weight_of_added_vote_delegations"(
            "issue_id_p",
            "member_id_v",
            '{}'
          )
          WHERE "member_id" = "member_id_v"
          AND "issue_id" = "issue_id_p";
      END LOOP;
      RETURN;
    END;
  $$;

CREATE OR REPLACE FUNCTION "close_voting"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "area_id_v"   "area"."id"%TYPE;
      "unit_id_v"   "unit"."id"%TYPE;
      "member_id_v" "member"."id"%TYPE;
    BEGIN
      PERFORM "require_transaction_isolation"();
      SELECT "area_id" INTO "area_id_v" FROM "issue" WHERE "id" = "issue_id_p";
      SELECT "unit_id" INTO "unit_id_v" FROM "area"  WHERE "id" = "area_id_v";
      -- override protection triggers:
      INSERT INTO "temporary_transaction_data" ("key", "value")
        VALUES ('override_protection_triggers', TRUE::TEXT);
      -- delete timestamp of voting comment:
      UPDATE "direct_voter" SET "comment_changed" = NULL
        WHERE "issue_id" = "issue_id_p";
      -- delete delegating votes (in cases of manual reset of issue state):
      DELETE FROM "delegating_voter"
        WHERE "issue_id" = "issue_id_p";
      -- delete votes from non-privileged voters:
      DELETE FROM "direct_voter"
        USING (
          SELECT "direct_voter"."member_id"
          FROM "direct_voter"
          JOIN "member" ON "direct_voter"."member_id" = "member"."id"
          LEFT JOIN "privilege"
          ON "privilege"."unit_id" = "unit_id_v"
          AND "privilege"."member_id" = "direct_voter"."member_id"
          LEFT JOIN "issue_privilege"
          ON "issue_privilege"."issue_id" = "issue_id_p"
          AND "issue_privilege"."member_id" = "direct_voter"."member_id"
          WHERE "direct_voter"."issue_id" = "issue_id_p" AND (
            "member"."active" = FALSE OR
            COALESCE(
              "issue_privilege"."voting_right",
              "privilege"."voting_right",
              FALSE
            ) = FALSE
          )
        ) AS "subquery"
        WHERE "direct_voter"."issue_id" = "issue_id_p"
        AND "direct_voter"."member_id" = "subquery"."member_id";
      -- consider voting weight and delegations:
      UPDATE "direct_voter" SET "ownweight" = "privilege"."weight"
        FROM "privilege"
        WHERE "issue_id" = "issue_id_p"
        AND "privilege"."unit_id" = "unit_id_v"
        AND "privilege"."member_id" = "direct_voter"."member_id";
      UPDATE "direct_voter" SET "ownweight" = "issue_privilege"."weight"
        FROM "issue_privilege"
        WHERE "direct_voter"."issue_id" = "issue_id_p"
        AND "issue_privilege"."issue_id" = "issue_id_p"
        AND "issue_privilege"."member_id" = "direct_voter"."member_id";
      PERFORM "add_vote_delegations"("issue_id_p");
      -- mark first preferences:
      UPDATE "vote" SET "first_preference" = "subquery"."first_preference"
        FROM (
          SELECT
            "vote"."initiative_id",
            "vote"."member_id",
            CASE WHEN "vote"."grade" > 0 THEN
              CASE WHEN "vote"."grade" = max("agg"."grade") THEN TRUE ELSE FALSE END
            ELSE NULL
            END AS "first_preference"
          FROM "vote"
          JOIN "initiative"  -- NOTE: due to missing index on issue_id
          ON "vote"."issue_id" = "initiative"."issue_id"
          JOIN "vote" AS "agg"
          ON "initiative"."id" = "agg"."initiative_id"
          AND "vote"."member_id" = "agg"."member_id"
          GROUP BY "vote"."initiative_id", "vote"."member_id", "vote"."grade"
        ) AS "subquery"
        WHERE "vote"."issue_id" = "issue_id_p"
        AND "vote"."initiative_id" = "subquery"."initiative_id"
        AND "vote"."member_id" = "subquery"."member_id";
      -- finish overriding protection triggers (avoids garbage):
      DELETE FROM "temporary_transaction_data"
        WHERE "key" = 'override_protection_triggers';
      -- materialize battle_view:
      -- NOTE: "closed" column of issue must be set at this point
      DELETE FROM "battle" WHERE "issue_id" = "issue_id_p";
      INSERT INTO "battle" (
        "issue_id",
        "winning_initiative_id", "losing_initiative_id",
        "count"
      ) SELECT
        "issue_id",
        "winning_initiative_id", "losing_initiative_id",
        "count"
        FROM "battle_view" WHERE "issue_id" = "issue_id_p";
      -- set voter count:
      UPDATE "issue" SET
        "voter_count" = (
          SELECT coalesce(sum("weight"), 0)
          FROM "direct_voter" WHERE "issue_id" = "issue_id_p"
        )
        WHERE "id" = "issue_id_p";
      -- copy "positive_votes" and "negative_votes" from "battle" table:
      -- NOTE: "first_preference_votes" is set to a default of 0 at this step
      UPDATE "initiative" SET
        "first_preference_votes" = 0,
        "positive_votes" = "battle_win"."count",
        "negative_votes" = "battle_lose"."count"
        FROM "battle" AS "battle_win", "battle" AS "battle_lose"
        WHERE
          "battle_win"."issue_id" = "issue_id_p" AND
          "battle_win"."winning_initiative_id" = "initiative"."id" AND
          "battle_win"."losing_initiative_id" ISNULL AND
          "battle_lose"."issue_id" = "issue_id_p" AND
          "battle_lose"."losing_initiative_id" = "initiative"."id" AND
          "battle_lose"."winning_initiative_id" ISNULL;
      -- calculate "first_preference_votes":
      -- NOTE: will only set values not equal to zero
      UPDATE "initiative" SET "first_preference_votes" = "subquery"."sum"
        FROM (
          SELECT "vote"."initiative_id", sum("direct_voter"."weight")
          FROM "vote" JOIN "direct_voter"
          ON "vote"."issue_id" = "direct_voter"."issue_id"
          AND "vote"."member_id" = "direct_voter"."member_id"
          WHERE "vote"."first_preference"
          GROUP BY "vote"."initiative_id"
        ) AS "subquery"
        WHERE "initiative"."issue_id" = "issue_id_p"
        AND "initiative"."admitted"
        AND "initiative"."id" = "subquery"."initiative_id";
    END;
  $$;

COMMIT;
