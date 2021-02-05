BEGIN;

--DROP FUNCTION IF EXISTS "closed_initiatives_in_bounding_box" (EBOX, INT4);
DROP INDEX IF EXISTS "suggestion_location_idx";  -- since v4.2.2
DROP INDEX IF EXISTS "draft_location_idx";       -- since v4.2.2
DROP INDEX IF EXISTS "initiative_location_idx";  -- since v4.2.2
DROP INDEX IF EXISTS "area_location_idx";        -- since v4.2.2
DROP INDEX IF EXISTS "unit_location_idx";        -- since v4.2.2
DROP INDEX IF EXISTS "member_location_idx";      -- since v4.2.2

DROP EXTENSION IF EXISTS latlon;  -- since v4.2.2

COMMIT;
