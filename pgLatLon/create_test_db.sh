#!/bin/sh
dropdb latlon_test --if-exists
createdb latlon_test || exit 1
psql -v ON_ERROR_STOP=1 -f create_test_db.schema.sql latlon_test || exit 1
for i in 1 2 3 4 5 6 7 8 9 10
do
psql -v ON_ERROR_STOP=1 -f create_test_db.data.sql latlon_test || exit 1
done
