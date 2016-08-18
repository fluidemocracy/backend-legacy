
CREATE EXTENSION latlon;

CREATE TABLE "test" (
        "id"            SERIAL4         PRIMARY KEY,
        "location"      EPOINT          NOT NULL,
        "area"          ECIRCLE         NOT NULL );

CREATE INDEX "test_location_key" ON "test" USING gist ("location");
CREATE INDEX "test_area_key"     ON "test" USING gist ("area");

