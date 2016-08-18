
----------------------------------------
-- forward declarations (shell types) --
----------------------------------------

CREATE TYPE epoint;
CREATE TYPE ebox;
CREATE TYPE ecircle;
CREATE TYPE ecluster;


------------------------------------------------------------
-- dummy input/output functions for dummy index key types --
------------------------------------------------------------

CREATE FUNCTION ekey_point_in_dummy(cstring)
  RETURNS ekey_point
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_notimpl';

CREATE FUNCTION ekey_point_out_dummy(ekey_point)
  RETURNS cstring
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_notimpl';

CREATE FUNCTION ekey_area_in_dummy(cstring)
  RETURNS ekey_area
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_notimpl';

CREATE FUNCTION ekey_area_out_dummy(ekey_area)
  RETURNS cstring
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_notimpl';


--------------------------
-- text input functions --
--------------------------

CREATE FUNCTION epoint_in(cstring)
  RETURNS epoint
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_in';

CREATE FUNCTION ebox_in(cstring)
  RETURNS ebox
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_in';

CREATE FUNCTION ecircle_in(cstring)
  RETURNS ecircle
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_in';

CREATE FUNCTION ecluster_in(cstring)
  RETURNS ecluster
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecluster_in';


---------------------------
-- text output functions --
---------------------------

CREATE FUNCTION epoint_out(epoint)
  RETURNS cstring
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_out';

CREATE FUNCTION ebox_out(ebox)
  RETURNS cstring
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_out';

CREATE FUNCTION ecircle_out(ecircle)
  RETURNS cstring
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_out';

CREATE FUNCTION ecluster_out(ecluster)
  RETURNS cstring
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecluster_out';


--------------------------
-- binary I/O functions --
--------------------------

CREATE FUNCTION epoint_recv(internal)
  RETURNS epoint
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_recv';

CREATE FUNCTION ebox_recv(internal)
  RETURNS ebox
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_recv';

CREATE FUNCTION ecircle_recv(internal)
  RETURNS ecircle
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_recv';

CREATE FUNCTION epoint_send(epoint)
  RETURNS bytea
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_send';

CREATE FUNCTION ebox_send(ebox)
  RETURNS bytea
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_send';

CREATE FUNCTION ecircle_send(ecircle)
  RETURNS bytea
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_send';


-----------------------------------------------
-- type definitions of dummy index key types --
-----------------------------------------------

CREATE TYPE ekey_point (
  internallength = 8,
  input = ekey_point_in_dummy,
  output = ekey_point_out_dummy,
  alignment = char );

CREATE TYPE ekey_area (
  internallength = 9,
  input = ekey_area_in_dummy,
  output = ekey_area_out_dummy,
  alignment = char );


------------------------------------------
-- definitions of geographic data types --
------------------------------------------

CREATE TYPE epoint (
  internallength = 16,
  input = epoint_in,
  output = epoint_out,
  receive = epoint_recv,
  send = epoint_send,
  alignment = double );

CREATE TYPE ebox (
  internallength = 32,
  input = ebox_in,
  output = ebox_out,
  receive = ebox_recv,
  send = ebox_send,
  alignment = double );

CREATE TYPE ecircle (
  internallength = 24,
  input = ecircle_in,
  output = ecircle_out,
  receive = ecircle_recv,
  send = ecircle_send,
  alignment = double );

CREATE TYPE ecluster (
  internallength = VARIABLE,
  input = ecluster_in,
  output = ecluster_out,
  alignment = double,
  storage = external );


--------------------
-- B-tree support --
--------------------

-- begin of B-tree support for epoint

CREATE FUNCTION epoint_btree_lt(epoint, epoint)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_epoint_lt';

CREATE FUNCTION epoint_btree_le(epoint, epoint)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_epoint_le';

CREATE FUNCTION epoint_btree_eq(epoint, epoint)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_epoint_eq';

CREATE FUNCTION epoint_btree_ne(epoint, epoint)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_epoint_ne';

CREATE FUNCTION epoint_btree_ge(epoint, epoint)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_epoint_ge';

CREATE FUNCTION epoint_btree_gt(epoint, epoint)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_epoint_gt';

CREATE OPERATOR <<< (
  leftarg = epoint,
  rightarg = epoint,
  procedure = epoint_btree_lt,
  commutator = >>>,
  negator = >>>=,
  restrict = scalarltsel,
  join = scalarltjoinsel
);

CREATE OPERATOR <<<= (
  leftarg = epoint,
  rightarg = epoint,
  procedure = epoint_btree_le,
  commutator = >>>=,
  negator = >>>,
  restrict = scalarltsel,
  join = scalarltjoinsel
);

CREATE OPERATOR = (
  leftarg = epoint,
  rightarg = epoint,
  procedure = epoint_btree_eq,
  commutator = =,
  negator = <>,
  restrict = eqsel,
  join = eqjoinsel,
  merges
);

CREATE OPERATOR <> (
  leftarg = epoint,
  rightarg = epoint,
  procedure = epoint_btree_eq,
  commutator = <>,
  negator = =,
  restrict = neqsel,
  join = neqjoinsel
);

CREATE OPERATOR >>>= (
  leftarg = epoint,
  rightarg = epoint,
  procedure = epoint_btree_ge,
  commutator = <<<=,
  negator = <<<,
  restrict = scalargtsel,
  join = scalargtjoinsel
);

CREATE OPERATOR >>> (
  leftarg = epoint,
  rightarg = epoint,
  procedure = epoint_btree_gt,
  commutator = <<<,
  negator = <<<=,
  restrict = scalargtsel,
  join = scalargtjoinsel
);

CREATE FUNCTION epoint_btree_cmp(epoint, epoint)
  RETURNS int4
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_epoint_cmp';

CREATE OPERATOR CLASS epoint_btree_ops
  DEFAULT FOR TYPE epoint USING btree AS
  OPERATOR 1 <<< ,
  OPERATOR 2 <<<= ,
  OPERATOR 3 = ,
  OPERATOR 4 >>>= ,
  OPERATOR 5 >>> ,
  FUNCTION 1 epoint_btree_cmp(epoint, epoint);

-- end of B-tree support for epoint

-- begin of B-tree support for ebox

CREATE FUNCTION ebox_btree_lt(ebox, ebox)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ebox_lt';

CREATE FUNCTION ebox_btree_le(ebox, ebox)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ebox_le';

CREATE FUNCTION ebox_btree_eq(ebox, ebox)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ebox_eq';

CREATE FUNCTION ebox_btree_ne(ebox, ebox)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ebox_ne';

CREATE FUNCTION ebox_btree_ge(ebox, ebox)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ebox_ge';

CREATE FUNCTION ebox_btree_gt(ebox, ebox)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ebox_gt';

CREATE OPERATOR <<< (
  leftarg = ebox,
  rightarg = ebox,
  procedure = ebox_btree_lt,
  commutator = >>>,
  negator = >>>=,
  restrict = scalarltsel,
  join = scalarltjoinsel
);

CREATE OPERATOR <<<= (
  leftarg = ebox,
  rightarg = ebox,
  procedure = ebox_btree_le,
  commutator = >>>=,
  negator = >>>,
  restrict = scalarltsel,
  join = scalarltjoinsel
);

CREATE OPERATOR = (
  leftarg = ebox,
  rightarg = ebox,
  procedure = ebox_btree_eq,
  commutator = =,
  negator = <>,
  restrict = eqsel,
  join = eqjoinsel,
  merges
);

CREATE OPERATOR <> (
  leftarg = ebox,
  rightarg = ebox,
  procedure = ebox_btree_eq,
  commutator = <>,
  negator = =,
  restrict = neqsel,
  join = neqjoinsel
);

CREATE OPERATOR >>>= (
  leftarg = ebox,
  rightarg = ebox,
  procedure = ebox_btree_ge,
  commutator = <<<=,
  negator = <<<,
  restrict = scalargtsel,
  join = scalargtjoinsel
);

CREATE OPERATOR >>> (
  leftarg = ebox,
  rightarg = ebox,
  procedure = ebox_btree_gt,
  commutator = <<<,
  negator = <<<=,
  restrict = scalargtsel,
  join = scalargtjoinsel
);

CREATE FUNCTION ebox_btree_cmp(ebox, ebox)
  RETURNS int4
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ebox_cmp';

CREATE OPERATOR CLASS ebox_btree_ops
  DEFAULT FOR TYPE ebox USING btree AS
  OPERATOR 1 <<< ,
  OPERATOR 2 <<<= ,
  OPERATOR 3 = ,
  OPERATOR 4 >>>= ,
  OPERATOR 5 >>> ,
  FUNCTION 1 ebox_btree_cmp(ebox, ebox);

-- end of B-tree support for ebox

-- begin of B-tree support for ecircle

CREATE FUNCTION ecircle_btree_lt(ecircle, ecircle)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ecircle_lt';

CREATE FUNCTION ecircle_btree_le(ecircle, ecircle)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ecircle_le';

CREATE FUNCTION ecircle_btree_eq(ecircle, ecircle)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ecircle_eq';

CREATE FUNCTION ecircle_btree_ne(ecircle, ecircle)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ecircle_ne';

CREATE FUNCTION ecircle_btree_ge(ecircle, ecircle)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ecircle_ge';

CREATE FUNCTION ecircle_btree_gt(ecircle, ecircle)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ecircle_gt';

CREATE OPERATOR <<< (
  leftarg = ecircle,
  rightarg = ecircle,
  procedure = ecircle_btree_lt,
  commutator = >>>,
  negator = >>>=,
  restrict = scalarltsel,
  join = scalarltjoinsel
);

CREATE OPERATOR <<<= (
  leftarg = ecircle,
  rightarg = ecircle,
  procedure = ecircle_btree_le,
  commutator = >>>=,
  negator = >>>,
  restrict = scalarltsel,
  join = scalarltjoinsel
);

CREATE OPERATOR = (
  leftarg = ecircle,
  rightarg = ecircle,
  procedure = ecircle_btree_eq,
  commutator = =,
  negator = <>,
  restrict = eqsel,
  join = eqjoinsel,
  merges
);

CREATE OPERATOR <> (
  leftarg = ecircle,
  rightarg = ecircle,
  procedure = ecircle_btree_eq,
  commutator = <>,
  negator = =,
  restrict = neqsel,
  join = neqjoinsel
);

CREATE OPERATOR >>>= (
  leftarg = ecircle,
  rightarg = ecircle,
  procedure = ecircle_btree_ge,
  commutator = <<<=,
  negator = <<<,
  restrict = scalargtsel,
  join = scalargtjoinsel
);

CREATE OPERATOR >>> (
  leftarg = ecircle,
  rightarg = ecircle,
  procedure = ecircle_btree_gt,
  commutator = <<<,
  negator = <<<=,
  restrict = scalargtsel,
  join = scalargtjoinsel
);

CREATE FUNCTION ecircle_btree_cmp(ecircle, ecircle)
  RETURNS int4
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_btree_ecircle_cmp';

CREATE OPERATOR CLASS ecircle_btree_ops
  DEFAULT FOR TYPE ecircle USING btree AS
  OPERATOR 1 <<< ,
  OPERATOR 2 <<<= ,
  OPERATOR 3 = ,
  OPERATOR 4 >>>= ,
  OPERATOR 5 >>> ,
  FUNCTION 1 ecircle_btree_cmp(ecircle, ecircle);

-- end of B-tree support for ecircle


----------------
-- type casts --
----------------

CREATE FUNCTION cast_epoint_to_ebox(epoint)
  RETURNS ebox
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_to_ebox';

CREATE CAST (epoint AS ebox) WITH FUNCTION cast_epoint_to_ebox(epoint);

CREATE FUNCTION cast_epoint_to_ecircle(epoint)
  RETURNS ecircle
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_to_ecircle';

CREATE CAST (epoint AS ecircle) WITH FUNCTION cast_epoint_to_ecircle(epoint);

CREATE FUNCTION cast_epoint_to_ecluster(epoint)
  RETURNS ecluster
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_to_ecluster';

CREATE CAST (epoint AS ecluster) WITH FUNCTION cast_epoint_to_ecluster(epoint);

CREATE FUNCTION cast_ebox_to_ecluster(ebox)
  RETURNS ecluster
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_to_ecluster';

CREATE CAST (ebox AS ecluster) WITH FUNCTION cast_ebox_to_ecluster(ebox);


---------------------------
-- constructor functions --
---------------------------

CREATE FUNCTION epoint(float8, float8)
  RETURNS epoint
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_create_epoint';

CREATE FUNCTION epoint_latlon(float8, float8)
  RETURNS epoint
  LANGUAGE SQL IMMUTABLE STRICT AS $$
    SELECT epoint($1, $2)
  $$;

CREATE FUNCTION epoint_lonlat(float8, float8)
  RETURNS epoint
  LANGUAGE SQL IMMUTABLE STRICT AS $$
    SELECT epoint($2, $1)
  $$;

CREATE FUNCTION empty_ebox()
  RETURNS ebox
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_create_empty_ebox';

CREATE FUNCTION ebox(float8, float8, float8, float8)
  RETURNS ebox
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_create_ebox';

CREATE FUNCTION ebox(epoint, epoint)
  RETURNS ebox
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_create_ebox_from_epoints';

CREATE FUNCTION ecircle(float8, float8, float8)
  RETURNS ecircle
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_create_ecircle';

CREATE FUNCTION ecircle(epoint, float8)
  RETURNS ecircle
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_create_ecircle_from_epoint';

CREATE FUNCTION ecluster_concat(ecluster[])
  RETURNS ecluster
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT array_to_string($1, ' ')::ecluster
  $$;

CREATE FUNCTION ecluster_concat(ecluster, ecluster)
  RETURNS ecluster
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ($1::text || ' ' || $2::text)::ecluster
  $$;

CREATE FUNCTION ecluster_create_multipoint(epoint[])
  RETURNS ecluster
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT
      array_to_string(array_agg('point (' || unnest || ')'), ' ')::ecluster
    FROM unnest($1)
  $$;

CREATE FUNCTION ecluster_create_path(epoint[])
  RETURNS ecluster
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE WHEN "str" = '' THEN 'empty'::ecluster ELSE
      ('path (' || array_to_string($1, ' ') || ')')::ecluster
    END
    FROM array_to_string($1, ' ') AS "str"
  $$;

CREATE FUNCTION ecluster_create_outline(epoint[])
  RETURNS ecluster
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE WHEN "str" = '' THEN 'empty'::ecluster ELSE
      ('outline (' || array_to_string($1, ' ') || ')')::ecluster
    END
    FROM array_to_string($1, ' ') AS "str"
  $$;

CREATE FUNCTION ecluster_create_polygon(epoint[])
  RETURNS ecluster
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE WHEN "str" = '' THEN 'empty'::ecluster ELSE
      ('polygon (' || array_to_string($1, ' ') || ')')::ecluster
    END
    FROM array_to_string($1, ' ') AS "str"
  $$;


----------------------
-- getter functions --
----------------------

CREATE FUNCTION latitude(epoint)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_lat';

CREATE FUNCTION longitude(epoint)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_lon';

CREATE FUNCTION min_latitude(ebox)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_lat_min';

CREATE FUNCTION max_latitude(ebox)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_lat_max';

CREATE FUNCTION min_longitude(ebox)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_lon_min';

CREATE FUNCTION max_longitude(ebox)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_lon_max';

CREATE FUNCTION center(ecircle)
  RETURNS epoint
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_center';

CREATE FUNCTION radius(ecircle)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_radius';

CREATE FUNCTION ecluster_extract_points(ecluster)
  RETURNS SETOF epoint
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT "match"[2]::epoint
    FROM regexp_matches($1::text, e'(^| )point \\(([^)]+)\\)', 'g') AS "match"
  $$;

CREATE FUNCTION ecluster_extract_paths(ecluster)
  RETURNS SETOF epoint[]
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT (
      SELECT array_agg("m2"[1]::epoint)
      FROM regexp_matches("m1"[2], e'[^ ]+ [^ ]+', 'g') AS "m2"
    )
    FROM regexp_matches($1::text, e'(^| )path \\(([^)]+)\\)', 'g') AS "m1"
  $$;

CREATE FUNCTION ecluster_extract_outlines(ecluster)
  RETURNS SETOF epoint[]
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT (
      SELECT array_agg("m2"[1]::epoint)
      FROM regexp_matches("m1"[2], e'[^ ]+ [^ ]+', 'g') AS "m2"
    )
    FROM regexp_matches($1::text, e'(^| )outline \\(([^)]+)\\)', 'g') AS "m1"
  $$;

CREATE FUNCTION ecluster_extract_polygons(ecluster)
  RETURNS SETOF epoint[]
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT (
      SELECT array_agg("m2"[1]::epoint)
      FROM regexp_matches("m1"[2], e'[^ ]+ [^ ]+', 'g') AS "m2"
    )
    FROM regexp_matches($1::text, e'(^| )polygon \\(([^)]+)\\)', 'g') AS "m1"
  $$;


---------------
-- operators --
---------------

CREATE FUNCTION epoint_ebox_overlap_proc(epoint, ebox)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_ebox_overlap';

CREATE FUNCTION epoint_ecircle_overlap_proc(epoint, ecircle)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_ecircle_overlap';

CREATE FUNCTION epoint_ecluster_overlap_proc(epoint, ecluster)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_ecluster_overlap';

CREATE FUNCTION ebox_overlap_proc(ebox, ebox)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ebox_overlap';

CREATE FUNCTION ecircle_overlap_proc(ecircle, ecircle)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_overlap';

CREATE FUNCTION ecircle_ecluster_overlap_proc(ecircle, ecluster)
  RETURNS boolean
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_ecluster_overlap';

CREATE FUNCTION epoint_distance_proc(epoint, epoint)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_distance';

CREATE FUNCTION epoint_ecircle_distance_proc(epoint, ecircle)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_ecircle_distance';

CREATE FUNCTION epoint_ecluster_distance_proc(epoint, ecluster)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_epoint_ecluster_distance';

CREATE FUNCTION ecircle_distance_proc(ecircle, ecircle)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_distance';

CREATE FUNCTION ecircle_ecluster_distance_proc(ecircle, ecluster)
  RETURNS float8
  LANGUAGE C IMMUTABLE STRICT
  AS '$libdir/latlon-v0001', 'pgl_ecircle_ecluster_distance';

CREATE OPERATOR && (
  leftarg = epoint,
  rightarg = ebox,
  procedure = epoint_ebox_overlap_proc,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE FUNCTION epoint_ebox_overlap_commutator(ebox, epoint)
  RETURNS boolean
  LANGUAGE sql IMMUTABLE AS 'SELECT $2 && $1';

CREATE OPERATOR && (
  leftarg = ebox,
  rightarg = epoint,
  procedure = epoint_ebox_overlap_commutator,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE OPERATOR && (
  leftarg = epoint,
  rightarg = ecircle,
  procedure = epoint_ecircle_overlap_proc,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE FUNCTION epoint_ecircle_overlap_commutator(ecircle, epoint)
  RETURNS boolean
  LANGUAGE sql IMMUTABLE AS 'SELECT $2 && $1';

CREATE OPERATOR && (
  leftarg = ecircle,
  rightarg = epoint,
  procedure = epoint_ecircle_overlap_commutator,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE OPERATOR && (
  leftarg = epoint,
  rightarg = ecluster,
  procedure = epoint_ecluster_overlap_proc,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE FUNCTION epoint_ecluster_overlap_commutator(ecluster, epoint)
  RETURNS boolean
  LANGUAGE sql IMMUTABLE AS 'SELECT $2 && $1';

CREATE OPERATOR && (
  leftarg = ecluster,
  rightarg = epoint,
  procedure = epoint_ecluster_overlap_commutator,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE OPERATOR && (
  leftarg = ebox,
  rightarg = ebox,
  procedure = ebox_overlap_proc,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE OPERATOR && (
  leftarg = ecircle,
  rightarg = ecircle,
  procedure = ecircle_overlap_proc,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE OPERATOR && (
  leftarg = ecircle,
  rightarg = ecluster,
  procedure = ecircle_ecluster_overlap_proc,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE FUNCTION ecircle_ecluster_overlap_commutator(ecluster, ecircle)
  RETURNS boolean
  LANGUAGE sql IMMUTABLE AS 'SELECT $2 && $1';

CREATE OPERATOR && (
  leftarg = ecluster,
  rightarg = ecircle,
  procedure = ecircle_ecluster_overlap_commutator,
  commutator = &&,
  restrict = areasel,
  join = areajoinsel
);

CREATE OPERATOR <-> (
  leftarg = epoint,
  rightarg = epoint,
  procedure = epoint_distance_proc,
  commutator = <->
);

CREATE OPERATOR <-> (
  leftarg = epoint,
  rightarg = ecircle,
  procedure = epoint_ecircle_distance_proc,
  commutator = <->
);

CREATE FUNCTION epoint_ecircle_distance_commutator(ecircle, epoint)
  RETURNS float8
  LANGUAGE sql IMMUTABLE AS 'SELECT $2 <-> $1';

CREATE OPERATOR <-> (
  leftarg = ecircle,
  rightarg = epoint,
  procedure = epoint_ecircle_distance_commutator,
  commutator = <->
);

CREATE OPERATOR <-> (
  leftarg = epoint,
  rightarg = ecluster,
  procedure = epoint_ecluster_distance_proc,
  commutator = <->
);

CREATE FUNCTION epoint_ecluster_distance_commutator(ecluster, epoint)
  RETURNS float8
  LANGUAGE sql IMMUTABLE AS 'SELECT $2 <-> $1';

CREATE OPERATOR <-> (
  leftarg = ecluster,
  rightarg = epoint,
  procedure = epoint_ecluster_distance_commutator,
  commutator = <->
);

CREATE OPERATOR <-> (
  leftarg = ecircle,
  rightarg = ecircle,
  procedure = ecircle_distance_proc,
  commutator = <->
);

CREATE OPERATOR <-> (
  leftarg = ecircle,
  rightarg = ecluster,
  procedure = ecircle_ecluster_distance_proc,
  commutator = <->
);

CREATE FUNCTION ecircle_ecluster_distance_commutator(ecluster, ecircle)
  RETURNS float8
  LANGUAGE sql IMMUTABLE AS 'SELECT $2 <-> $1';

CREATE OPERATOR <-> (
  leftarg = ecluster,
  rightarg = ecircle,
  procedure = ecircle_ecluster_distance_commutator,
  commutator = <->
);


----------------
-- GiST index --
----------------

CREATE FUNCTION pgl_gist_consistent(internal, internal, smallint, oid, internal)
  RETURNS boolean
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_consistent';

CREATE FUNCTION pgl_gist_union(internal, internal)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_union';

CREATE FUNCTION pgl_gist_compress_epoint(internal)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_compress_epoint';

CREATE FUNCTION pgl_gist_compress_ecircle(internal)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_compress_ecircle';

CREATE FUNCTION pgl_gist_compress_ecluster(internal)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_compress_ecluster';

CREATE FUNCTION pgl_gist_decompress(internal)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_decompress';

CREATE FUNCTION pgl_gist_penalty(internal, internal, internal)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_penalty';

CREATE FUNCTION pgl_gist_picksplit(internal, internal)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_picksplit';

CREATE FUNCTION pgl_gist_same(internal, internal, internal)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_same';

CREATE FUNCTION pgl_gist_distance(internal, internal, smallint, oid)
  RETURNS internal
  LANGUAGE C STRICT
  AS '$libdir/latlon-v0001', 'pgl_gist_distance';

CREATE OPERATOR CLASS epoint_ops
  DEFAULT FOR TYPE epoint USING gist AS
  OPERATOR 11 = ,
  OPERATOR 22 && (epoint, ebox),
  OPERATOR 23 && (epoint, ecircle),
  OPERATOR 24 && (epoint, ecluster),
  OPERATOR 31 <-> (epoint, epoint) FOR ORDER BY float_ops,
  OPERATOR 33 <-> (epoint, ecircle) FOR ORDER BY float_ops,
  OPERATOR 34 <-> (epoint, ecluster) FOR ORDER BY float_ops,
  FUNCTION 1 pgl_gist_consistent(internal, internal, smallint, oid, internal),
  FUNCTION 2 pgl_gist_union(internal, internal),
  FUNCTION 3 pgl_gist_compress_epoint(internal),
  FUNCTION 4 pgl_gist_decompress(internal),
  FUNCTION 5 pgl_gist_penalty(internal, internal, internal),
  FUNCTION 6 pgl_gist_picksplit(internal, internal),
  FUNCTION 7 pgl_gist_same(internal, internal, internal),
  FUNCTION 8 pgl_gist_distance(internal, internal, smallint, oid),
  STORAGE ekey_point;

CREATE OPERATOR CLASS ecircle_ops
  DEFAULT FOR TYPE ecircle USING gist AS
  OPERATOR 13 = ,
  OPERATOR 21 && (ecircle, epoint),
  OPERATOR 23 && (ecircle, ecircle),
  OPERATOR 24 && (ecircle, ecluster),
  OPERATOR 31 <-> (ecircle, epoint) FOR ORDER BY float_ops,
  OPERATOR 33 <-> (ecircle, ecircle) FOR ORDER BY float_ops,
  OPERATOR 34 <-> (ecircle, ecluster) FOR ORDER BY float_ops,
  FUNCTION 1 pgl_gist_consistent(internal, internal, smallint, oid, internal),
  FUNCTION 2 pgl_gist_union(internal, internal),
  FUNCTION 3 pgl_gist_compress_ecircle(internal),
  FUNCTION 4 pgl_gist_decompress(internal),
  FUNCTION 5 pgl_gist_penalty(internal, internal, internal),
  FUNCTION 6 pgl_gist_picksplit(internal, internal),
  FUNCTION 7 pgl_gist_same(internal, internal, internal),
  FUNCTION 8 pgl_gist_distance(internal, internal, smallint, oid),
  STORAGE ekey_area;

CREATE OPERATOR CLASS ecluster_ops
  DEFAULT FOR TYPE ecluster USING gist AS
  OPERATOR 21 && (ecluster, epoint),
  FUNCTION 1 pgl_gist_consistent(internal, internal, smallint, oid, internal),
  FUNCTION 2 pgl_gist_union(internal, internal),
  FUNCTION 3 pgl_gist_compress_ecluster(internal),
  FUNCTION 4 pgl_gist_decompress(internal),
  FUNCTION 5 pgl_gist_penalty(internal, internal, internal),
  FUNCTION 6 pgl_gist_picksplit(internal, internal),
  FUNCTION 7 pgl_gist_same(internal, internal, internal),
  FUNCTION 8 pgl_gist_distance(internal, internal, smallint, oid),
  STORAGE ekey_area;


---------------------
-- alias functions --
---------------------

CREATE FUNCTION distance(epoint, epoint)
  RETURNS float8
  LANGUAGE sql IMMUTABLE AS 'SELECT $1 <-> $2';

CREATE FUNCTION distance(ecluster, epoint)
  RETURNS float8
  LANGUAGE sql IMMUTABLE AS 'SELECT $1 <-> $2';

CREATE FUNCTION distance_within(epoint, epoint, float8)
  RETURNS boolean
  LANGUAGE sql IMMUTABLE AS 'SELECT $1 && ecircle($2, $3)';

CREATE FUNCTION distance_within(ecluster, epoint, float8)
  RETURNS boolean
  LANGUAGE sql IMMUTABLE AS 'SELECT $1 && ecircle($2, $3)';


--------------------------------
-- other data storage formats --
--------------------------------

CREATE FUNCTION coords_to_epoint(float8, float8, text = 'epoint_lonlat')
  RETURNS epoint
  LANGUAGE plpgsql IMMUTABLE STRICT AS $$
    DECLARE
      "result" epoint;
    BEGIN
      IF $3 = 'epoint_lonlat' THEN
        -- avoid dynamic command execution for better performance
        RETURN epoint($2, $1);
      END IF;
      IF $3 = 'epoint' OR $3 = 'epoint_latlon' THEN
        -- avoid dynamic command execution for better performance
        RETURN epoint($1, $2);
      END IF;
      EXECUTE 'SELECT ' || $3 || '($1, $2)' INTO STRICT "result" USING $1, $2;
      RETURN "result";
    END;
  $$;

CREATE FUNCTION GeoJSON_to_epoint(jsonb, text = 'epoint_lonlat')
  RETURNS epoint
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE
    WHEN $1->>'type' = 'Point' THEN
      coords_to_epoint(
        ($1->'coordinates'->>1)::float8,
        ($1->'coordinates'->>0)::float8,
        $2
      )
    WHEN $1->>'type' = 'Feature' THEN
      GeoJSON_to_epoint($1->'geometry', $2)
    ELSE
      NULL
    END
  $$;

CREATE FUNCTION GeoJSON_to_ecluster(jsonb, text = 'epoint_lonlat')
  RETURNS ecluster
  LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE $1->>'type'
    WHEN 'Point' THEN
      coords_to_epoint(
        ($1->'coordinates'->>1)::float8,
        ($1->'coordinates'->>0)::float8,
        $2
      )::ecluster
    WHEN 'MultiPoint' THEN
      ( SELECT ecluster_create_multipoint(array_agg(
          coords_to_epoint(
            ("coord"->>1)::float8,
            ("coord"->>0)::float8,
            $2
          )
        ))
        FROM jsonb_array_elements($1->'coordinates') AS "coord"
      )
    WHEN 'LineString' THEN
      ( SELECT ecluster_create_path(array_agg(
          coords_to_epoint(
            ("coord"->>1)::float8,
            ("coord"->>0)::float8,
            $2
          )
        ))
        FROM jsonb_array_elements($1->'coordinates') AS "coord"
      )
    WHEN 'MultiLineString' THEN
      ( SELECT ecluster_concat(array_agg(
          ( SELECT ecluster_create_path(array_agg(
              coords_to_epoint(
                ("coord"->>1)::float8,
                ("coord"->>0)::float8,
                $2
              )
            ))
            FROM jsonb_array_elements("coord_array") AS "coord"
          )
        ))
        FROM jsonb_array_elements($1->'coordinates') AS "coord_array"
      )
    WHEN 'Polygon' THEN
      ( SELECT ecluster_concat(array_agg(
          ( SELECT ecluster_create_polygon(array_agg(
              coords_to_epoint(
                ("coord"->>1)::float8,
                ("coord"->>0)::float8,
                $2
              )
            ))
            FROM jsonb_array_elements("coord_array") AS "coord"
          )
        ))
        FROM jsonb_array_elements($1->'coordinates') AS "coord_array"
      )
    WHEN 'MultiPolygon' THEN
      ( SELECT ecluster_concat(array_agg(
          ( SELECT ecluster_concat(array_agg(
              ( SELECT ecluster_create_polygon(array_agg(
                  coords_to_epoint(
                    ("coord"->>1)::float8,
                    ("coord"->>0)::float8,
                    $2
                  )
                ))
                FROM jsonb_array_elements("coord_array") AS "coord"
              )
            ))
            FROM jsonb_array_elements("coord_array_array") AS "coord_array"
          )
        ))
        FROM jsonb_array_elements($1->'coordinates') AS "coord_array_array"
      )
    WHEN 'Feature' THEN
      GeoJSON_to_ecluster($1->'geometry', $2)
    WHEN 'FeatureCollection' THEN
      ( SELECT ecluster_concat(array_agg(
          GeoJSON_to_ecluster("feature", $2)
        ))
        FROM jsonb_array_elements($1->'features') AS "feature"
      )
    ELSE
      NULL
    END
  $$;

