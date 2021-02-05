BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('4.2.2', 4, 2, 2))
  AS "subquery"("string", "major", "minor", "revision");

--DROP FUNCTION "closed_initiatives_in_bounding_box" (EBOX, INT4);
DROP INDEX "suggestion_location_idx";
DROP INDEX "draft_location_idx";
DROP INDEX "initiative_location_idx";
DROP INDEX "area_location_idx";
DROP INDEX "unit_location_idx";
DROP INDEX "member_location_idx";

DROP EXTENSION latlon;

COMMIT;
