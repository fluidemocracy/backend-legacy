
INSERT INTO "test" ("location", "area") SELECT
  epoint((asin(2*random()-1) / pi()) * 180, (2*random()-1) * 180),
  ecircle((asin(2*random()-1) / pi()) * 180, (2*random()-1) * 180, -ln(1-random()) * 1000)
  FROM generate_series(1, 10000);

