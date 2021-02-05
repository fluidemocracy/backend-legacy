BEGIN;


CREATE EXTENSION IF NOT EXISTS latlon;


------------------------
-- Geospatial indices --
------------------------

CREATE INDEX IF NOT EXISTS "member_location_idx"
  ON "member"
  USING gist ((GeoJSON_to_ecluster("location")));
CREATE INDEX IF NOT EXISTS "unit_location_idx"
  ON "unit"
  USING gist ((GeoJSON_to_ecluster("location")));
CREATE INDEX IF NOT EXISTS "area_location_idx"
  ON "area"
  USING gist ((GeoJSON_to_ecluster("location")));
CREATE INDEX IF NOT EXISTS "initiative_location_idx"
  ON "initiative"
  USING gist ((GeoJSON_to_ecluster("location")));
CREATE INDEX IF NOT EXISTS "draft_location_idx"
  ON "draft"
  USING gist ((GeoJSON_to_ecluster("location")));
CREATE INDEX IF NOT EXISTS "suggestion_location_idx"
  ON "suggestion"
  USING gist ((GeoJSON_to_ecluster("location")));


------------------------
-- Geospatial lookups --
------------------------

/*
CREATE OR REPLACE FUNCTION "closed_initiatives_in_bounding_box"
  ( "bounding_box_p" EBOX,
    "limit_p"        INT4 )
  RETURNS SETOF "initiative"
  LANGUAGE 'plpgsql' STABLE AS $$
    DECLARE
      "limit_v" INT4;
      "count_v" INT4;
    BEGIN
      "limit_v" := "limit_p" + 1;
      LOOP
        SELECT count(1) INTO "count_v"
          FROM "initiative"
          JOIN "issue" ON "issue"."id" = "initiative"."issue_id"
          WHERE "issue"."closed" NOTNULL
          AND GeoJSON_to_ecluster("initiative"."location") && "bounding_box_p"
          LIMIT "limit_v";
        IF "count_v" < "limit_v" THEN
          RETURN QUERY SELECT "initiative".*
            FROM (
              SELECT
                "initiative"."id" AS "initiative_id",
                "issue"."closed"
              FROM "initiative"
              JOIN "issue" ON "issue"."id" = "initiative"."issue_id"
              WHERE "issue"."closed" NOTNULL
              AND GeoJSON_to_ecluster("initiative"."location") && "bounding_box_p"
            ) AS "subquery"
            JOIN "initiative" ON "initiative"."id" = "subquery"."initiative_id"
            ORDER BY "subquery"."closed" DESC
            LIMIT "limit_p";
          RETURN;
        END IF;
        SELECT count(1) INTO "count_v"
          FROM (
            SELECT "initiative"."id" AS "initiative_id"
            FROM "initiative"
            JOIN "issue" ON "issue"."id" = "initiative"."issue_id"
            WHERE "issue"."closed" NOTNULL
            ORDER BY "closed" DESC
            LIMIT "limit_v"
          ) AS "subquery"
          JOIN "initiative" ON "initiative"."id" = "subquery"."initiative_id"
          WHERE GeoJSON_to_ecluster("initiative"."location") && "bounding_box_p"
          LIMIT "limit_p";
        IF "count_v" >= "limit_p" THEN
          RETURN QUERY SELECT "initiative".*
            FROM (
              SELECT
                "initiative"."id" AS "initiative_id",
                "issue"."closed"
              FROM "initiative"
              JOIN "issue" ON "issue"."id" = "initiative"."issue_id"
              WHERE "issue"."closed" NOTNULL
              ORDER BY "closed" DESC
              LIMIT "limit_v"
            ) AS "subquery"
            JOIN "initiative" ON "initiative"."id" = "subquery"."initiative_id"
            WHERE GeoJSON_to_ecluster("initiative"."location") && "bounding_box_p"
            ORDER BY "subquery"."closed" DESC
            LIMIT "limit_p";
          RETURN;
        END IF;
        "limit_v" := "limit_v" * 2;
      END LOOP;
    END;
  $$;

COMMENT ON FUNCTION "closed_initiatives_in_bounding_box"
  ( EBOX, INT4 )
  IS 'TODO';
*/


COMMIT;
