
/*-------------*
 *  C prelude  *
 *-------------*/

#include "postgres.h"
#include "fmgr.h"
#include "libpq/pqformat.h"
#include "access/gist.h"
#include "access/stratnum.h"
#include "utils/array.h"
#include <math.h>

#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

#if INT_MAX < 2147483647
#error Expected int type to be at least 32 bit wide
#endif


/*---------------------------------*
 *  distance calculation on earth  *
 *  (using WGS-84 spheroid)        *
 *---------------------------------*/

/*  WGS-84 spheroid with following parameters:
    semi-major axis  a = 6378137
    semi-minor axis  b = a * (1 - 1/298.257223563)
    estimated diameter = 2 * (2*a+b)/3
*/
#define PGL_SPHEROID_A 6378137.0            /* semi major axis */
#define PGL_SPHEROID_F (1.0/298.257223563)  /* flattening */
#define PGL_SPHEROID_B (PGL_SPHEROID_A * (1.0-PGL_SPHEROID_F))
#define PGL_EPS2       ( ( PGL_SPHEROID_A * PGL_SPHEROID_A - \
                           PGL_SPHEROID_B * PGL_SPHEROID_B ) / \
                         ( PGL_SPHEROID_A * PGL_SPHEROID_A ) )
#define PGL_SUBEPS2    (1.0-PGL_EPS2)
#define PGL_DIAMETER   ((4.0*PGL_SPHEROID_A + 2.0*PGL_SPHEROID_B) / 3.0)
#define PGL_SCALE      (PGL_SPHEROID_A / PGL_DIAMETER)  /* semi-major ref. */
#define PGL_FADELIMIT  (PGL_DIAMETER * M_PI / 6.0)      /* 1/6 circumference */
#define PGL_MAXDIST    (PGL_DIAMETER * M_PI / 2.0)      /* maximum distance */

/* calculate distance between two points on earth (given in degrees) */
static inline double pgl_distance(
  double lat1, double lon1, double lat2, double lon2
) {
  float8 lat1cos, lat1sin, lat2cos, lat2sin, lon2cos, lon2sin;
  float8 nphi1, nphi2, x1, z1, x2, y2, z2, g, s, t;
  /* normalize delta longitude (lon2 > 0 && lon1 = 0) */
  /* lon1 = 0 (not used anymore) */
  lon2 = fabs(lon2-lon1);
  /* convert to radians (first divide, then multiply) */
  lat1 = (lat1 / 180.0) * M_PI;
  lat2 = (lat2 / 180.0) * M_PI;
  lon2 = (lon2 / 180.0) * M_PI;
  /* make lat2 >= lat1 to ensure reversal-symmetry despite floating point
     operations (lon2 >= lon1 is already ensured in a previous step) */
  if (lat2 < lat1) { float8 swap = lat1; lat1 = lat2; lat2 = swap; }
  /* calculate 3d coordinates on scaled ellipsoid which has an average diameter
     of 1.0 */
  lat1cos = cos(lat1); lat1sin = sin(lat1);
  lat2cos = cos(lat2); lat2sin = sin(lat2);
  lon2cos = cos(lon2); lon2sin = sin(lon2);
  nphi1 = PGL_SCALE / sqrt(1 - PGL_EPS2 * lat1sin * lat1sin);
  nphi2 = PGL_SCALE / sqrt(1 - PGL_EPS2 * lat2sin * lat2sin);
  x1 = nphi1 * lat1cos;
  z1 = nphi1 * PGL_SUBEPS2 * lat1sin;
  x2 = nphi2 * lat2cos * lon2cos;
  y2 = nphi2 * lat2cos * lon2sin;
  z2 = nphi2 * PGL_SUBEPS2 * lat2sin;
  /* calculate tunnel distance through scaled (diameter 1.0) ellipsoid */
  g = sqrt((x2-x1)*(x2-x1) + y2*y2 + (z2-z1)*(z2-z1));
  /* convert tunnel distance through scaled ellipsoid to approximated surface
     distance on original ellipsoid */
  if (g > 1.0) g = 1.0;
  s = PGL_DIAMETER * asin(g);
  /* return result only if small enough to be precise (less than 1/3 of
     maximum possible distance) */
  if (s <= PGL_FADELIMIT) return s;
  /* determine antipodal point of second point (i.e. mirror second point) */
  lat2 = -lat2; lon2 = lon2 - M_PI;
  lat2cos = cos(lat2); lat2sin = sin(lat2);
  lon2cos = cos(lon2); lon2sin = sin(lon2);
  /* calculate 3d coordinates of antipodal point on scaled ellipsoid */
  nphi2 = PGL_SCALE / sqrt(1 - PGL_EPS2 * lat2sin * lat2sin);
  x2 = nphi2 * lat2cos * lon2cos;
  y2 = nphi2 * lat2cos * lon2sin;
  z2 = nphi2 * PGL_SUBEPS2 * lat2sin;
  /* calculate tunnel distance to antipodal point through scaled ellipsoid */
  g = sqrt((x2-x1)*(x2-x1) + y2*y2 + (z2-z1)*(z2-z1));
  /* convert tunnel distance to antipodal point through scaled ellipsoid to
     approximated surface distance to antipodal point on original ellipsoid */
  if (g > 1.0) g = 1.0;
  t = PGL_DIAMETER * asin(g);
  /* surface distance between original points can now be approximated by
     substracting antipodal distance from maximum possible distance;
     return result only if small enough (less than 1/3 of maximum possible
     distance) */
  if (t <= PGL_FADELIMIT) return PGL_MAXDIST-t;
  /* otherwise crossfade direct and antipodal result to ensure monotonicity */
  return (
    (s * (t-PGL_FADELIMIT) + (PGL_MAXDIST-t) * (s-PGL_FADELIMIT)) /
    (s + t - 2*PGL_FADELIMIT)
  );
}

/* finite distance that can not be reached on earth */
#define PGL_ULTRA_DISTANCE (3 * PGL_MAXDIST)


/*--------------------------------*
 *  simple geographic data types  *
 *--------------------------------*/

/* point on earth given by latitude and longitude in degrees */
/* (type "epoint" in SQL) */
typedef struct {
  double lat;  /* between  -90 and  90 (both inclusive) */
  double lon;  /* between -180 and 180 (both inclusive) */
} pgl_point;

/* box delimited by two parallels and two meridians (all in degrees) */
/* (type "ebox" in SQL) */
typedef struct {
  double lat_min;  /* between  -90 and  90 (both inclusive) */
  double lat_max;  /* between  -90 and  90 (both inclusive) */
  double lon_min;  /* between -180 and 180 (both inclusive) */
  double lon_max;  /* between -180 and 180 (both inclusive) */
  /* if lat_min > lat_max, then box is empty */
  /* if lon_min > lon_max, then 180th meridian is crossed */
} pgl_box;

/* circle on earth surface (for radial searches with fixed radius) */
/* (type "ecircle" in SQL) */
typedef struct {
  pgl_point center;
  double radius; /* positive (including +0 but excluding -0), or -INFINITY */
  /* A negative radius (i.e. -INFINITY) denotes nothing (i.e. no point),
     zero radius (0) denotes a single point,
     a finite radius (0 < radius < INFINITY) denotes a filled circle, and
     a radius of INFINITY is valid and means complete coverage of earth. */
} pgl_circle;


/*----------------------------------*
 *  geographic "cluster" data type  *
 *----------------------------------*/

/* A cluster is a collection of points, paths, outlines, and polygons. If two
   polygons in a cluster overlap, the area covered by both polygons does not
   belong to the cluster. This way, a cluster can be used to describe complex
   shapes like polygons with holes. Outlines are non-filled polygons. Paths are
   open by default (i.e. the last point in the list is not connected with the
   first point in the list). Note that each outline or polygon in a cluster
   must cover a longitude range of less than 180 degrees to avoid ambiguities.
   Areas which are larger may be split into multiple polygons. */

/* maximum number of points in a cluster */
/* (limited to avoid integer overflows, e.g. when allocating memory) */
#define PGL_CLUSTER_MAXPOINTS 16777216

/* types of cluster entries */
#define PGL_ENTRY_POINT   1  /* a point */
#define PGL_ENTRY_PATH    2  /* a path from first point to last point */
#define PGL_ENTRY_OUTLINE 3  /* a non-filled polygon with given vertices */
#define PGL_ENTRY_POLYGON 4  /* a filled polygon with given vertices */

/* Entries of a cluster are described by two different structs: pgl_newentry
   and pgl_entry. The first is used only during construction of a cluster, the
   second is used in all other cases (e.g. when reading clusters from the
   database, performing operations, etc). */

/* entry for new geographic cluster during construction of that cluster */
typedef struct {
  int32_t entrytype;
  int32_t npoints;
  pgl_point *points;  /* pointer to an array of points (pgl_point) */
} pgl_newentry;

/* entry of geographic cluster */
typedef struct {
  int32_t entrytype;  /* type of entry: point, path, outline, polygon */
  int32_t npoints;    /* number of stored points (set to 1 for point entry) */
  int32_t offset;     /* offset of pgl_point array from cluster base address */
  /* use macro PGL_ENTRY_POINTS to obtain a pointer to the array of points */
} pgl_entry;

/* geographic cluster which is a collection of points, (open) paths, polygons,
   and outlines (non-filled polygons) */
typedef struct {
  char header[VARHDRSZ];  /* PostgreSQL header for variable size data types */
  int32_t nentries;       /* number of stored points */
  pgl_circle bounding;    /* bounding circle */
  /* Note: bounding circle ensures alignment of pgl_cluster for points */
  pgl_entry entries[FLEXIBLE_ARRAY_MEMBER];  /* var-length data */
} pgl_cluster;

/* macro to determine memory alignment of points */
/* (needed to store pgl_point array after entries in pgl_cluster) */
typedef struct { char dummy; pgl_point aligned; } pgl_point_alignment;
#define PGL_POINT_ALIGNMENT offsetof(pgl_point_alignment, aligned)

/* macro to extract a pointer to the array of points of a cluster entry */
#define PGL_ENTRY_POINTS(cluster, idx) \
  ((pgl_point *)(((intptr_t)cluster)+(cluster)->entries[idx].offset))

/* convert pgl_newentry array to pgl_cluster */
static pgl_cluster *pgl_new_cluster(int nentries, pgl_newentry *entries) {
  int i;              /* index of current entry */
  int npoints = 0;    /* number of points in whole cluster */
  int entry_npoints;  /* number of points in current entry */
  int points_offset = PGL_POINT_ALIGNMENT * (
    ( offsetof(pgl_cluster, entries) +
      nentries * sizeof(pgl_entry) +
      PGL_POINT_ALIGNMENT - 1
    ) / PGL_POINT_ALIGNMENT
  );  /* offset of pgl_point array from base address (considering alignment) */
  pgl_cluster *cluster;  /* new cluster to be returned */
  /* determine total number of points */
  for (i=0; i<nentries; i++) npoints += entries[i].npoints;
  /* allocate memory for cluster (including entries and points) */
  cluster = palloc(points_offset + npoints * sizeof(pgl_point));
  /* re-count total number of points to determine offset for each entry */
  npoints = 0;
  /* copy entries and points */
  for (i=0; i<nentries; i++) {
    /* determine number of points in entry */
    entry_npoints = entries[i].npoints;
    /* copy entry */
    cluster->entries[i].entrytype = entries[i].entrytype;
    cluster->entries[i].npoints = entry_npoints;
    /* calculate offset (in bytes) of pgl_point array */
    cluster->entries[i].offset = points_offset + npoints * sizeof(pgl_point);
    /* copy points */
    memcpy(
      PGL_ENTRY_POINTS(cluster, i),
      entries[i].points,
      entry_npoints * sizeof(pgl_point)
    );
    /* update total number of points processed */
    npoints += entry_npoints;
  }
  /* set number of entries in cluster */
  cluster->nentries = nentries;
  /* set PostgreSQL header for variable sized data */
  SET_VARSIZE(cluster, points_offset + npoints * sizeof(pgl_point));
  /* return newly created cluster */
  return cluster;
}


/*----------------------------------------*
 *  C functions on geographic data types  *
 *----------------------------------------*/

/* round latitude or longitude to 12 digits after decimal point */
static inline double pgl_round(double val) {
  return round(val * 1e12) / 1e12;
}

/* compare two points */
/* (equality when same point on earth is described, otherwise an arbitrary
   linear order) */
static int pgl_point_cmp(pgl_point *point1, pgl_point *point2) {
  double lon1, lon2;  /* modified longitudes for special cases */
  /* use latitude as first ordering criterion */
  if (point1->lat < point2->lat) return -1;
  if (point1->lat > point2->lat) return 1;
  /* determine modified longitudes (considering special case of poles and
     180th meridian which can be described as W180 or E180) */
  if (point1->lat == -90 || point1->lat == 90) lon1 = 0;
  else if (point1->lon == 180) lon1 = -180;
  else lon1 = point1->lon;
  if (point2->lat == -90 || point2->lat == 90) lon2 = 0;
  else if (point2->lon == 180) lon2 = -180;
  else lon2 = point2->lon;
  /* use (modified) longitude as secondary ordering criterion */
  if (lon1 < lon2) return -1;
  if (lon1 > lon2) return 1;
  /* no difference found, points are equal */
  return 0;
}

/* compare two boxes */
/* (equality when same box on earth is described, otherwise an arbitrary linear
   order) */
static int pgl_box_cmp(pgl_box *box1, pgl_box *box2) {
  /* two empty boxes are equal, and an empty box is always considered "less
     than" a non-empty box */
  if (box1->lat_min> box1->lat_max && box2->lat_min<=box2->lat_max) return -1;
  if (box1->lat_min> box1->lat_max && box2->lat_min> box2->lat_max) return 0;
  if (box1->lat_min<=box1->lat_max && box2->lat_min> box2->lat_max) return 1;
  /* use southern border as first ordering criterion */
  if (box1->lat_min < box2->lat_min) return -1;
  if (box1->lat_min > box2->lat_min) return 1;
  /* use northern border as second ordering criterion */
  if (box1->lat_max < box2->lat_max) return -1;
  if (box1->lat_max > box2->lat_max) return 1;
  /* use western border as third ordering criterion */
  if (box1->lon_min < box2->lon_min) return -1;
  if (box1->lon_min > box2->lon_min) return 1;
  /* use eastern border as fourth ordering criterion */
  if (box1->lon_max < box2->lon_max) return -1;
  if (box1->lon_max > box2->lon_max) return 1;
  /* no difference found, boxes are equal */
  return 0;
}

/* compare two circles */
/* (equality when same circle on earth is described, otherwise an arbitrary
   linear order) */
static int pgl_circle_cmp(pgl_circle *circle1, pgl_circle *circle2) {
  /* two circles with same infinite radius (positive or negative infinity) are
     considered equal independently of center point */
  if (
    !isfinite(circle1->radius) && !isfinite(circle2->radius) &&
    circle1->radius == circle2->radius
  ) return 0;
  /* use radius as first ordering criterion */
  if (circle1->radius < circle2->radius) return -1;
  if (circle1->radius > circle2->radius) return 1;
  /* use center point as secondary ordering criterion */
  return pgl_point_cmp(&(circle1->center), &(circle2->center));
}

/* set box to empty box*/
static void pgl_box_set_empty(pgl_box *box) {
  box->lat_min = INFINITY;
  box->lat_max = -INFINITY;
  box->lon_min = 0;
  box->lon_max = 0;
}

/* check if point is inside a box */
static bool pgl_point_in_box(pgl_point *point, pgl_box *box) {
  return (
    point->lat >= box->lat_min && point->lat <= box->lat_max && (
      (box->lon_min > box->lon_max) ? (
        /* box crosses 180th meridian */
        point->lon >= box->lon_min || point->lon <= box->lon_max
      ) : (
        /* box does not cross the 180th meridian */
        point->lon >= box->lon_min && point->lon <= box->lon_max
      )
    )
  );
}

/* check if two boxes overlap */
static bool pgl_boxes_overlap(pgl_box *box1, pgl_box *box2) {
  return (
    box2->lat_max >= box2->lat_min &&  /* ensure box2 is not empty */
    ( box2->lat_min >= box1->lat_min || box2->lat_max >= box1->lat_min ) &&
    ( box2->lat_min <= box1->lat_max || box2->lat_max <= box1->lat_max ) && (
      (
        /* check if one and only one box crosses the 180th meridian */
        ((box1->lon_min > box1->lon_max) ? 1 : 0) ^
        ((box2->lon_min > box2->lon_max) ? 1 : 0)
      ) ? (
        /* exactly one box crosses the 180th meridian */
        box2->lon_min >= box1->lon_min || box2->lon_max >= box1->lon_min ||
        box2->lon_min <= box1->lon_max || box2->lon_max <= box1->lon_max
      ) : (
        /* no box or both boxes cross the 180th meridian */
        (
          (box2->lon_min >= box1->lon_min || box2->lon_max >= box1->lon_min) &&
          (box2->lon_min <= box1->lon_max || box2->lon_max <= box1->lon_max)
        ) ||
        /* handle W180 == E180 */
        ( box1->lon_min == -180 && box2->lon_max == 180 ) ||
        ( box2->lon_min == -180 && box1->lon_max == 180 )
      )
    )
  );
}

/* check unambiguousness of east/west orientation of cluster entries and set
   bounding circle of cluster */
static bool pgl_finalize_cluster(pgl_cluster *cluster) {
  int i, j;                 /* i: index of entry, j: index of point in entry */
  int npoints;              /* number of points in entry */
  int total_npoints = 0;    /* total number of points in cluster */
  pgl_point *points;        /* points in entry */
  int lon_dir;              /* first point of entry west (-1) or east (+1) */
  double lon_break = 0;     /* antipodal longitude of first point in entry */
  double lon_min, lon_max;  /* covered longitude range of entry */
  double value;             /* temporary variable */
  /* reset bounding circle center to empty circle at 0/0 coordinates */
  cluster->bounding.center.lat = 0;
  cluster->bounding.center.lon = 0;
  cluster->bounding.radius = -INFINITY;
  /* if cluster is not empty */
  if (cluster->nentries != 0) {
    /* iterate over all cluster entries and ensure they each cover a longitude
       range less than 180 degrees */
    for (i=0; i<cluster->nentries; i++) {
      /* get properties of entry */
      npoints = cluster->entries[i].npoints;
      points = PGL_ENTRY_POINTS(cluster, i);
      /* get longitude of first point of entry */
      value = points[0].lon;
      /* initialize lon_min and lon_max with longitude of first point */
      lon_min = value;
      lon_max = value;
      /* determine east/west orientation of first point and calculate antipodal
         longitude (Note: rounding required here) */
      if      (value < 0) { lon_dir = -1; lon_break = pgl_round(value + 180); }
      else if (value > 0) { lon_dir =  1; lon_break = pgl_round(value - 180); }
      else lon_dir = 0;
      /* iterate over all other points in entry */
      for (j=1; j<npoints; j++) {
        /* consider longitude wrap-around */
        value = points[j].lon;
        if      (lon_dir<0 && value>lon_break) value = pgl_round(value - 360);
        else if (lon_dir>0 && value<lon_break) value = pgl_round(value + 360);
        /* update lon_min and lon_max */
        if      (value < lon_min) lon_min = value;
        else if (value > lon_max) lon_max = value;
        /* return false if 180 degrees or more are covered */
        if (lon_max - lon_min >= 180) return false;
      }
    }
    /* iterate over all points of all entries and calculate arbitrary center
       point for bounding circle (best if center point minimizes the radius,
       but some error is allowed here) */
    for (i=0; i<cluster->nentries; i++) {
      /* get properties of entry */
      npoints = cluster->entries[i].npoints;
      points = PGL_ENTRY_POINTS(cluster, i);
      /* check if first entry */
      if (i==0) {
        /* get longitude of first point of first entry in whole cluster */
        value = points[0].lon;
        /* initialize lon_min and lon_max with longitude of first point of
           first entry in whole cluster (used to determine if whole cluster
           covers a longitude range of 180 degrees or more) */
        lon_min = value;
        lon_max = value;
        /* determine east/west orientation of first point and calculate
           antipodal longitude (Note: rounding not necessary here) */
        if      (value < 0) { lon_dir = -1; lon_break = value + 180; }
        else if (value > 0) { lon_dir =  1; lon_break = value - 180; }
        else lon_dir = 0;
      }
      /* iterate over all points in entry */
      for (j=0; j<npoints; j++) {
        /* longitude wrap-around (Note: rounding not necessary here) */
        value = points[j].lon;
        if      (lon_dir < 0 && value > lon_break) value -= 360;
        else if (lon_dir > 0 && value < lon_break) value += 360;
        if      (value < lon_min) lon_min = value;
        else if (value > lon_max) lon_max = value;
        /* set bounding circle to cover whole earth if more than 180 degrees
           are covered */
        if (lon_max - lon_min >= 180) {
          cluster->bounding.center.lat = 0;
          cluster->bounding.center.lon = 0;
          cluster->bounding.radius = INFINITY;
          return true;
        }
        /* add point to bounding circle center (for average calculation) */
        cluster->bounding.center.lat += points[j].lat;
        cluster->bounding.center.lon += value;
      }
      /* count total number of points */
      total_npoints += npoints;
    }
    /* determine average latitude and longitude of cluster */
    cluster->bounding.center.lat /= total_npoints;
    cluster->bounding.center.lon /= total_npoints;
    /* normalize longitude of center of cluster bounding circle */
    if (cluster->bounding.center.lon < -180) {
      cluster->bounding.center.lon += 360;
    }
    else if (cluster->bounding.center.lon > 180) {
      cluster->bounding.center.lon -= 360;
    }
    /* round bounding circle center (useful if it is used by other functions) */
    cluster->bounding.center.lat = pgl_round(cluster->bounding.center.lat);
    cluster->bounding.center.lon = pgl_round(cluster->bounding.center.lon);
    /* calculate radius of bounding circle */
    for (i=0; i<cluster->nentries; i++) {
      npoints = cluster->entries[i].npoints;
      points = PGL_ENTRY_POINTS(cluster, i);
      for (j=0; j<npoints; j++) {
        value = pgl_distance(
          cluster->bounding.center.lat, cluster->bounding.center.lon,
          points[j].lat, points[j].lon
        );
        if (value > cluster->bounding.radius) cluster->bounding.radius = value;
      }
    }
  }
  /* return true (east/west orientation is unambiguous) */
  return true;
}

/* check if point is inside cluster */
static bool pgl_point_in_cluster(pgl_point *point, pgl_cluster *cluster) {
  int i, j, k;  /* i: entry, j: point in entry, k: next point in entry */
  int entrytype;         /* type of entry */
  int npoints;           /* number of points in entry */
  pgl_point *points;     /* array of points in entry */
  int lon_dir = 0;       /* first vertex west (-1) or east (+1) */
  double lon_break = 0;  /* antipodal longitude of first vertex */
  double lat0 = point->lat;  /* latitude of point */
  double lon0;           /* (adjusted) longitude of point */
  double lat1, lon1;     /* latitude and (adjusted) longitude of vertex */
  double lat2, lon2;     /* latitude and (adjusted) longitude of next vertex */
  double lon;            /* longitude of intersection */
  int counter = 0;       /* counter for intersections east of point */
  /* points outside bounding circle are always assumed to be non-overlapping */
  /* (necessary for consistent table and index scans) */
  if (
    pgl_distance(
      point->lat, point->lon,
      cluster->bounding.center.lat, cluster->bounding.center.lon
    ) > cluster->bounding.radius
  ) return false;
  /* iterate over all entries */
  for (i=0; i<cluster->nentries; i++) {
    /* get properties of entry */
    entrytype = cluster->entries[i].entrytype;
    npoints = cluster->entries[i].npoints;
    points = PGL_ENTRY_POINTS(cluster, i);
    /* determine east/west orientation of first point of entry and calculate
       antipodal longitude */
    lon_break = points[0].lon;
    if      (lon_break < 0) { lon_dir = -1; lon_break += 180; }
    else if (lon_break > 0) { lon_dir =  1; lon_break -= 180; }
    else lon_dir = 0;
    /* get longitude of point */
    lon0 = point->lon;
    /* consider longitude wrap-around for point */
    if      (lon_dir < 0 && lon0 > lon_break) lon0 = pgl_round(lon0 - 360);
    else if (lon_dir > 0 && lon0 < lon_break) lon0 = pgl_round(lon0 + 360);
    /* iterate over all edges and vertices */
    for (j=0; j<npoints; j++) {
      /* return true if point is on vertex of polygon */
      if (pgl_point_cmp(point, &(points[j])) == 0) return true;
      /* calculate index of next vertex */
      k = (j+1) % npoints;
      /* skip last edge unless entry is (closed) outline or polygon */
      if (
        k == 0 &&
        entrytype != PGL_ENTRY_OUTLINE &&
        entrytype != PGL_ENTRY_POLYGON
      ) continue;
      /* get latitude and longitude values of edge */
      lat1 = points[j].lat;
      lat2 = points[k].lat;
      lon1 = points[j].lon;
      lon2 = points[k].lon;
      /* consider longitude wrap-around for edge */
      if      (lon_dir < 0 && lon1 > lon_break) lon1 = pgl_round(lon1 - 360);
      else if (lon_dir > 0 && lon1 < lon_break) lon1 = pgl_round(lon1 + 360);
      if      (lon_dir < 0 && lon2 > lon_break) lon2 = pgl_round(lon2 - 360);
      else if (lon_dir > 0 && lon2 < lon_break) lon2 = pgl_round(lon2 + 360);
      /* return true if point is on horizontal (west to east) edge of polygon */
      if (
        lat0 == lat1 && lat0 == lat2 &&
        ( (lon0 >= lon1 && lon0 <= lon2) || (lon0 >= lon2 && lon0 <= lon1) )
      ) return true;
      /* check if edge crosses east/west line of point */
      if ((lat1 < lat0 && lat2 >= lat0) || (lat2 < lat0 && lat1 >= lat0)) {
        /* calculate longitude of intersection */
        lon = (lon1 * (lat2-lat0) + lon2 * (lat0-lat1)) / (lat2-lat1);
        /* return true if intersection goes (approximately) through point */
        if (pgl_round(lon) == lon0) return true;
        /* count intersection if east of point and entry is polygon*/
        if (entrytype == PGL_ENTRY_POLYGON && lon > lon0) counter++;
      }
    }
  }
  /* return true if number of intersections is odd */
  return counter & 1;
}

/* calculate (approximate) distance between point and cluster */
static double pgl_point_cluster_distance(pgl_point *point, pgl_cluster *cluster) {
  int i, j, k;  /* i: entry, j: point in entry, k: next point in entry */
  int entrytype;         /* type of entry */
  int npoints;           /* number of points in entry */
  pgl_point *points;     /* array of points in entry */
  int lon_dir = 0;       /* first vertex west (-1) or east (+1) */
  double lon_break = 0;  /* antipodal longitude of first vertex */
  double lon_min = 0;    /* minimum (adjusted) longitude of entry vertices */
  double lon_max = 0;    /* maximum (adjusted) longitude of entry vertices */
  double lat0 = point->lat;  /* latitude of point */
  double lon0;           /* (adjusted) longitude of point */
  double lat1, lon1;     /* latitude and (adjusted) longitude of vertex */
  double lat2, lon2;     /* latitude and (adjusted) longitude of next vertex */
  double s;              /* scalar for vector calculations */
  double dist;           /* distance calculated in one step */
  double min_dist = INFINITY;   /* minimum distance */
  /* distance is zero if point is contained in cluster */
  if (pgl_point_in_cluster(point, cluster)) return 0;
  /* iterate over all entries */
  for (i=0; i<cluster->nentries; i++) {
    /* get properties of entry */
    entrytype = cluster->entries[i].entrytype;
    npoints = cluster->entries[i].npoints;
    points = PGL_ENTRY_POINTS(cluster, i);
    /* determine east/west orientation of first point of entry and calculate
       antipodal longitude */
    lon_break = points[0].lon;
    if      (lon_break < 0) { lon_dir = -1; lon_break += 180; }
    else if (lon_break > 0) { lon_dir =  1; lon_break -= 180; }
    else lon_dir = 0;
    /* determine covered longitude range */
    for (j=0; j<npoints; j++) {
      /* get longitude of vertex */
      lon1 = points[j].lon;
      /* adjust longitude to fix potential wrap-around */
      if      (lon_dir < 0 && lon1 > lon_break) lon1 -= 360;
      else if (lon_dir > 0 && lon1 < lon_break) lon1 += 360;
      /* update minimum and maximum longitude of polygon */
      if (j == 0 || lon1 < lon_min) lon_min = lon1;
      if (j == 0 || lon1 > lon_max) lon_max = lon1;
    }
    /* adjust longitude wrap-around according to full longitude range */
    lon_break = (lon_max + lon_min) / 2;
    if      (lon_break < 0) { lon_dir = -1; lon_break += 180; }
    else if (lon_break > 0) { lon_dir =  1; lon_break -= 180; }
    /* get longitude of point */
    lon0 = point->lon;
    /* consider longitude wrap-around for point */
    if      (lon_dir < 0 && lon0 > lon_break) lon0 -= 360;
    else if (lon_dir > 0 && lon0 < lon_break) lon0 += 360;
    /* iterate over all edges and vertices */
    for (j=0; j<npoints; j++) {
      /* get latitude and longitude values of current point */
      lat1 = points[j].lat;
      lon1 = points[j].lon;
      /* consider longitude wrap-around for current point */
      if      (lon_dir < 0 && lon1 > lon_break) lon1 -= 360;
      else if (lon_dir > 0 && lon1 < lon_break) lon1 += 360;
      /* calculate distance to vertex */
      dist = pgl_distance(lat0, lon0, lat1, lon1);
      /* store calculated distance if smallest */
      if (dist < min_dist) min_dist = dist;
      /* calculate index of next vertex */
      k = (j+1) % npoints;
      /* skip last edge unless entry is (closed) outline or polygon */
      if (
        k == 0 &&
        entrytype != PGL_ENTRY_OUTLINE &&
        entrytype != PGL_ENTRY_POLYGON
      ) continue;
      /* get latitude and longitude values of next point */
      lat2 = points[k].lat;
      lon2 = points[k].lon;
      /* consider longitude wrap-around for next point */
      if      (lon_dir < 0 && lon2 > lon_break) lon2 -= 360;
      else if (lon_dir > 0 && lon2 < lon_break) lon2 += 360;
      /* go to next vertex and edge if edge is degenerated */
      if (lat1 == lat2 && lon1 == lon2) continue;
      /* otherwise test if point can be projected onto edge of polygon */
      s = (
        ((lat0-lat1) * (lat2-lat1) + (lon0-lon1) * (lon2-lon1)) /
        ((lat2-lat1) * (lat2-lat1) + (lon2-lon1) * (lon2-lon1))
      );
      /* go to next vertex and edge if point cannot be projected */
      if (!(s > 0 && s < 1)) continue;
      /* calculate distance from original point to projected point */
      dist = pgl_distance(
        lat0, lon0,
        lat1 + s * (lat2-lat1),
        lon1 + s * (lon2-lon1)
      );
      /* store calculated distance if smallest */
      if (dist < min_dist) min_dist = dist;
    }
  }
  /* return minimum distance */
  return min_dist;
}

/* estimator function for distance between box and point */
/* allowed to return smaller values than actually correct */
static double pgl_estimate_point_box_distance(pgl_point *point, pgl_box *box) {
  double dlon;  /* longitude range of box (delta longitude) */
  double h;     /* half of distance along meridian */
  double d;     /* distance between both southern or both northern points */
  double cur_dist;  /* calculated distance */
  double min_dist;  /* minimum distance calculated */
  /* return infinity if bounding box is empty */
  if (box->lat_min > box->lat_max) return INFINITY;
  /* return zero if point is inside bounding box */
  if (pgl_point_in_box(point, box)) return 0;
  /* calculate delta longitude */
  dlon = box->lon_max - box->lon_min;
  if (dlon < 0) dlon += 360;  /* 180th meridian crossed */
  /* if delta longitude is greater than 180 degrees, perform safe fall-back */
  if (dlon > 180) return 0;
  /* calculate half of distance along meridian */
  h = pgl_distance(box->lat_min, 0, box->lat_max, 0) / 2;
  /* calculate full distance between southern points */
  d = pgl_distance(box->lat_min, 0, box->lat_min, dlon);
  /* calculate maximum of full distance and half distance */
  if (h > d) d = h;
  /* calculate distance from point to first southern vertex and substract
     maximum error */
  min_dist = pgl_distance(
    point->lat, point->lon, box->lat_min, box->lon_min
  ) - d;
  /* return zero if estimated distance is smaller than zero */
  if (min_dist <= 0) return 0;
  /* repeat procedure with second southern vertex */
  cur_dist = pgl_distance(
    point->lat, point->lon, box->lat_min, box->lon_max
  ) - d;
  if (cur_dist <= 0) return 0;
  if (cur_dist < min_dist) min_dist = cur_dist;
  /* calculate full distance between northern points */
  d = pgl_distance(box->lat_max, 0, box->lat_max, dlon);
  /* calculate maximum of full distance and half distance */
  if (h > d) d = h;
  /* repeat procedure with northern vertices */
  cur_dist = pgl_distance(
    point->lat, point->lon, box->lat_max, box->lon_max
  ) - d;
  if (cur_dist <= 0) return 0;
  if (cur_dist < min_dist) min_dist = cur_dist;
  cur_dist = pgl_distance(
    point->lat, point->lon, box->lat_max, box->lon_min
  ) - d;
  if (cur_dist <= 0) return 0;
  if (cur_dist < min_dist) min_dist = cur_dist;
  /* return smallest value (unless already returned zero) */
  return min_dist;
}


/*----------------------------*
 *  fractal geographic index  *
 *----------------------------*/

/* number of bytes used for geographic (center) position in keys */
#define PGL_KEY_LATLON_BYTELEN 7

/* maximum reference value for logarithmic size of geographic objects */
#define PGL_AREAKEY_REFOBJSIZE (PGL_DIAMETER/3.0)  /* can be tweaked */

/* safety margin to avoid floating point errors in distance estimation */
#define PGL_FPE_SAFETY (1.0+1e-14)  /* slightly greater than 1.0 */

/* pointer to index key (either pgl_pointkey or pgl_areakey) */
typedef unsigned char *pgl_keyptr;

/* index key for points (objects with zero area) on the spheroid */
/* bit  0..55: interspersed bits of latitude and longitude,
   bit 56..57: always zero,
   bit 58..63: node depth in hypothetic (full) tree from 0 to 56 (incl.) */
typedef unsigned char pgl_pointkey[PGL_KEY_LATLON_BYTELEN+1];

/* index key for geographic objects on spheroid with area greater than zero */
/* bit  0..55: interspersed bits of latitude and longitude of center point,
   bit     56: always set to 1,
   bit 57..63: node depth in hypothetic (full) tree from 0 to (2*56)+1 (incl.),
   bit 64..71: logarithmic object size from 0 to 56+1 = 57 (incl.), but set to
               PGL_KEY_OBJSIZE_EMPTY (with interspersed bits = 0 and node depth
               = 113) for empty objects, and set to PGL_KEY_OBJSIZE_UNIVERSAL
               (with interspersed bits = 0 and node depth = 0) for keys which
               cover both empty and non-empty objects */

typedef unsigned char pgl_areakey[PGL_KEY_LATLON_BYTELEN+2];

/* helper macros for reading/writing index keys */
#define PGL_KEY_NODEDEPTH_OFFSET  PGL_KEY_LATLON_BYTELEN
#define PGL_KEY_OBJSIZE_OFFSET    (PGL_KEY_NODEDEPTH_OFFSET+1)
#define PGL_POINTKEY_MAXDEPTH     (PGL_KEY_LATLON_BYTELEN*8)
#define PGL_AREAKEY_MAXDEPTH      (2*PGL_POINTKEY_MAXDEPTH+1)
#define PGL_AREAKEY_MAXOBJSIZE    (PGL_POINTKEY_MAXDEPTH+1)
#define PGL_AREAKEY_TYPEMASK      0x80
#define PGL_KEY_LATLONBIT(key, n) ((key)[(n)/8] & (0x80 >> ((n)%8)))
#define PGL_KEY_LATLONBIT_DIFF(key1, key2, n) \
                                  ( PGL_KEY_LATLONBIT(key1, n) ^ \
                                    PGL_KEY_LATLONBIT(key2, n) )
#define PGL_KEY_IS_AREAKEY(key)   ((key)[PGL_KEY_NODEDEPTH_OFFSET] & \
                                    PGL_AREAKEY_TYPEMASK)
#define PGL_KEY_NODEDEPTH(key)    ((key)[PGL_KEY_NODEDEPTH_OFFSET] & \
                                    (PGL_AREAKEY_TYPEMASK-1))
#define PGL_KEY_OBJSIZE(key)      ((key)[PGL_KEY_OBJSIZE_OFFSET])
#define PGL_KEY_OBJSIZE_EMPTY     126
#define PGL_KEY_OBJSIZE_UNIVERSAL 127
#define PGL_KEY_IS_EMPTY(key)     ( PGL_KEY_IS_AREAKEY(key) && \
                                    (key)[PGL_KEY_OBJSIZE_OFFSET] == \
                                    PGL_KEY_OBJSIZE_EMPTY )
#define PGL_KEY_IS_UNIVERSAL(key) ( PGL_KEY_IS_AREAKEY(key) && \
                                    (key)[PGL_KEY_OBJSIZE_OFFSET] == \
                                    PGL_KEY_OBJSIZE_UNIVERSAL )

/* set area key to match empty objects only */
static void pgl_key_set_empty(pgl_keyptr key) {
  memset(key, 0, sizeof(pgl_areakey));
  /* Note: setting node depth to maximum is required for picksplit function */
  key[PGL_KEY_NODEDEPTH_OFFSET] = PGL_AREAKEY_TYPEMASK | PGL_AREAKEY_MAXDEPTH;
  key[PGL_KEY_OBJSIZE_OFFSET] = PGL_KEY_OBJSIZE_EMPTY;
}

/* set area key to match any object (including empty objects) */
static void pgl_key_set_universal(pgl_keyptr key) {
  memset(key, 0, sizeof(pgl_areakey));
  key[PGL_KEY_NODEDEPTH_OFFSET] = PGL_AREAKEY_TYPEMASK;
  key[PGL_KEY_OBJSIZE_OFFSET] = PGL_KEY_OBJSIZE_UNIVERSAL;
}

/* convert a point on earth into a max-depth key to be used in index */
static void pgl_point_to_key(pgl_point *point, pgl_keyptr key) {
  double lat = point->lat;
  double lon = point->lon;
  int i;
  /* clear latitude and longitude bits */
  memset(key, 0, PGL_KEY_LATLON_BYTELEN);
  /* set node depth to maximum and type bit to zero */
  key[PGL_KEY_NODEDEPTH_OFFSET] = PGL_POINTKEY_MAXDEPTH;
  /* iterate over all latitude/longitude bit pairs */
  for (i=0; i<PGL_POINTKEY_MAXDEPTH/2; i++) {
    /* determine latitude bit */
    if (lat >= 0) {
      key[i/4] |= 0x80 >> (2*(i%4));
      lat *= 2; lat -= 90;
    } else {
      lat *= 2; lat += 90;
    }
    /* determine longitude bit */
    if (lon >= 0) {
      key[i/4] |= 0x80 >> (2*(i%4)+1);
      lon *= 2; lon -= 180;
    } else {
      lon *= 2; lon += 180;
    }
  }
}

/* convert a circle on earth into a max-depth key to be used in an index */
static void pgl_circle_to_key(pgl_circle *circle, pgl_keyptr key) {
  /* handle special case of empty circle */
  if (circle->radius < 0) {
    pgl_key_set_empty(key);
    return;
  }
  /* perform same action as for point keys */
  pgl_point_to_key(&(circle->center), key);
  /* but overwrite type and node depth to fit area index key */
  key[PGL_KEY_NODEDEPTH_OFFSET] = PGL_AREAKEY_TYPEMASK | PGL_AREAKEY_MAXDEPTH;
  /* check if radius is greater than (or equal to) reference size */
  /* (treat equal values as greater values for numerical safety) */
  if (circle->radius >= PGL_AREAKEY_REFOBJSIZE) {
    /* if yes, set logarithmic size to zero */
    key[PGL_KEY_OBJSIZE_OFFSET] = 0;
  } else {
    /* otherwise, determine logarithmic size iteratively */
    /* (one step is equivalent to a factor of sqrt(2)) */
    double reference = PGL_AREAKEY_REFOBJSIZE / M_SQRT2;
    int objsize = 1;
    while (objsize < PGL_AREAKEY_MAXOBJSIZE) {
      /* stop when radius is greater than (or equal to) adjusted reference */
      /* (treat equal values as greater values for numerical safety) */
      if (circle->radius >= reference) break;
      reference /= M_SQRT2;
      objsize++;
    }
    /* set logarithmic size to determined value */
    key[PGL_KEY_OBJSIZE_OFFSET] = objsize;
  }
}

/* check if one key is subkey of another key or vice versa */
static bool pgl_keys_overlap(pgl_keyptr key1, pgl_keyptr key2) {
  int i;  /* key bit offset (includes both lat/lon and log. obj. size bits) */
  /* determine smallest depth */
  int depth1 = PGL_KEY_NODEDEPTH(key1);
  int depth2 = PGL_KEY_NODEDEPTH(key2);
  int depth = (depth1 < depth2) ? depth1 : depth2;
  /* check if keys are area keys (assuming that both keys have same type) */
  if (PGL_KEY_IS_AREAKEY(key1)) {
    int j = 0;  /* bit offset for logarithmic object size bits */
    int k = 0;  /* bit offset for latitude and longitude */
    /* fetch logarithmic object size information */
    int objsize1 = PGL_KEY_OBJSIZE(key1);
    int objsize2 = PGL_KEY_OBJSIZE(key2);
    /* handle special cases for empty objects (universal and empty keys) */
    if (
      objsize1 == PGL_KEY_OBJSIZE_UNIVERSAL ||
      objsize2 == PGL_KEY_OBJSIZE_UNIVERSAL
    ) return true;
    if (
      objsize1 == PGL_KEY_OBJSIZE_EMPTY ||
      objsize2 == PGL_KEY_OBJSIZE_EMPTY
    ) return objsize1 == objsize2;
    /* iterate through key bits */
    for (i=0; i<depth; i++) {
      /* every second bit is a bit describing the object size */
      if (i%2 == 0) {
        /* check if object size bit is different in both keys (objsize1 and
           objsize2 describe the minimum index when object size bit is set) */
        if (
          (objsize1 <= j && objsize2 > j) ||
          (objsize2 <= j && objsize1 > j)
        ) {
          /* bit differs, therefore keys are in separate branches */
          return false;
        }
        /* increase bit counter for object size bits */
        j++;
      }
      /* all other bits describe latitude and longitude */
      else {
        /* check if bit differs in both keys */
        if (PGL_KEY_LATLONBIT_DIFF(key1, key2, k)) {
          /* bit differs, therefore keys are in separate branches */
          return false;
        }
        /* increase bit counter for latitude/longitude bits */
        k++;
      }
    }
  }
  /* if not, keys are point keys */
  else {
    /* iterate through key bits */
    for (i=0; i<depth; i++) {
      /* check if bit differs in both keys */
      if (PGL_KEY_LATLONBIT_DIFF(key1, key2, i)) {
        /* bit differs, therefore keys are in separate branches */
        return false;
      }
    }
  }
  /* return true because keys are in the same branch */
  return true;
}

/* combine two keys into new key which covers both original keys */
/* (result stored in first argument) */
static void pgl_unite_keys(pgl_keyptr dst, pgl_keyptr src) {
  int i;  /* key bit offset (includes both lat/lon and log. obj. size bits) */
  /* determine smallest depth */
  int depth1 = PGL_KEY_NODEDEPTH(dst);
  int depth2 = PGL_KEY_NODEDEPTH(src);
  int depth = (depth1 < depth2) ? depth1 : depth2;
  /* check if keys are area keys (assuming that both keys have same type) */
  if (PGL_KEY_IS_AREAKEY(dst)) {
    pgl_areakey dstbuf = { 0, };  /* destination buffer (cleared) */
    int j = 0;  /* bit offset for logarithmic object size bits */
    int k = 0;  /* bit offset for latitude and longitude */
    /* fetch logarithmic object size information */
    int objsize1 = PGL_KEY_OBJSIZE(dst);
    int objsize2 = PGL_KEY_OBJSIZE(src);
    /* handle special cases for empty objects (universal and empty keys) */
    if (
      objsize1 > PGL_AREAKEY_MAXOBJSIZE ||
      objsize2 > PGL_AREAKEY_MAXOBJSIZE
    ) {
      if (
        objsize1 == PGL_KEY_OBJSIZE_EMPTY &&
        objsize2 == PGL_KEY_OBJSIZE_EMPTY
      ) pgl_key_set_empty(dst);
      else pgl_key_set_universal(dst);
      return;
    }
    /* iterate through key bits */
    for (i=0; i<depth; i++) {
      /* every second bit is a bit describing the object size */
      if (i%2 == 0) {
        /* increase bit counter for object size bits first */
        /* (handy when setting objsize variable) */
        j++;
        /* check if object size bit is set in neither key */
        if (objsize1 >= j && objsize2 >= j) {
          /* set objsize in destination buffer to indicate that size bit is
             unset in destination buffer at the current bit position */
          dstbuf[PGL_KEY_OBJSIZE_OFFSET] = j;
        }
        /* break if object size bit is set in one key only */
        else if (objsize1 >= j || objsize2 >= j) break;
      }
      /* all other bits describe latitude and longitude */
      else {
        /* break if bit differs in both keys */
        if (PGL_KEY_LATLONBIT(dst, k)) {
          if (!PGL_KEY_LATLONBIT(src, k)) break;
          /* but set bit in destination buffer if bit is set in both keys */
          dstbuf[k/8] |= 0x80 >> (k%8);
        } else if (PGL_KEY_LATLONBIT(src, k)) break;
        /* increase bit counter for latitude/longitude bits */
        k++;
      }
    }
    /* set common node depth and type bit (type bit = 1) */
    dstbuf[PGL_KEY_NODEDEPTH_OFFSET] = PGL_AREAKEY_TYPEMASK | i;
    /* copy contents of destination buffer to first key */
    memcpy(dst, dstbuf, sizeof(pgl_areakey));
  }
  /* if not, keys are point keys */
  else {
    pgl_pointkey dstbuf = { 0, };  /* destination buffer (cleared) */
    /* iterate through key bits */
    for (i=0; i<depth; i++) {
      /* break if bit differs in both keys */
      if (PGL_KEY_LATLONBIT(dst, i)) {
        if (!PGL_KEY_LATLONBIT(src, i)) break;
        /* but set bit in destination buffer if bit is set in both keys */
        dstbuf[i/8] |= 0x80 >> (i%8);
      } else if (PGL_KEY_LATLONBIT(src, i)) break;
    }
    /* set common node depth (type bit = 0) */
    dstbuf[PGL_KEY_NODEDEPTH_OFFSET] = i;
    /* copy contents of destination buffer to first key */
    memcpy(dst, dstbuf, sizeof(pgl_pointkey));
  }
}

/* determine center(!) boundaries and radius estimation of index key */
static double pgl_key_to_box(pgl_keyptr key, pgl_box *box) {
  int i;
  /* determine node depth */
  int depth = PGL_KEY_NODEDEPTH(key);
  /* center point of possible result */
  double lat = 0;
  double lon = 0;
  /* maximum distance of real center point from key center */
  double dlat = 90;
  double dlon = 180;
  /* maximum radius of contained objects */
  double radius = 0;  /* always return zero for point index keys */
  /* check if key is area key */
  if (PGL_KEY_IS_AREAKEY(key)) {
    /* get logarithmic object size */
    int objsize = PGL_KEY_OBJSIZE(key);
    /* handle special cases for empty objects (universal and empty keys) */
    if (objsize == PGL_KEY_OBJSIZE_EMPTY) {
      pgl_box_set_empty(box);
      return 0;
    } else if (objsize == PGL_KEY_OBJSIZE_UNIVERSAL) {
      box->lat_min = -90;
      box->lat_max =  90;
      box->lon_min = -180;
      box->lon_max =  180;
      return 0;  /* any value >= 0 would do */
    }
    /* calculate maximum possible radius of objects covered by the given key */
    if (objsize == 0) radius = INFINITY;
    else {
      radius = PGL_AREAKEY_REFOBJSIZE;
      while (--objsize) radius /= M_SQRT2;
    }
    /* iterate over latitude and longitude bits in key */
    /* (every second bit is a latitude or longitude bit) */
    for (i=0; i<depth/2; i++) {
      /* check if latitude bit */
      if (i%2 == 0) {
        /* cut latitude dimension in half */
        dlat /= 2;
        /* increase center latitude if bit is 1, otherwise decrease */
        if (PGL_KEY_LATLONBIT(key, i)) lat += dlat;
        else lat -= dlat;
      }
      /* otherwise longitude bit */
      else {
        /* cut longitude dimension in half */
        dlon /= 2;
        /* increase center longitude if bit is 1, otherwise decrease */
        if (PGL_KEY_LATLONBIT(key, i)) lon += dlon;
        else lon -= dlon;
      }
    }
  }
  /* if not, keys are point keys */
  else {
    /* iterate over all bits in key */
    for (i=0; i<depth; i++) {
      /* check if latitude bit */
      if (i%2 == 0) {
        /* cut latitude dimension in half */
        dlat /= 2;
        /* increase center latitude if bit is 1, otherwise decrease */
        if (PGL_KEY_LATLONBIT(key, i)) lat += dlat;
        else lat -= dlat;
      }
      /* otherwise longitude bit */
      else {
        /* cut longitude dimension in half */
        dlon /= 2;
        /* increase center longitude if bit is 1, otherwise decrease */
        if (PGL_KEY_LATLONBIT(key, i)) lon += dlon;
        else lon -= dlon;
      }
    }
  }
  /* calculate boundaries from center point and remaining dlat and dlon */
  /* (return values through pointer to box) */
  box->lat_min = lat - dlat;
  box->lat_max = lat + dlat;
  box->lon_min = lon - dlon;
  box->lon_max = lon + dlon;
  /* return radius (as a function return value) */
  return radius;
}

/* estimator function for distance between point and index key */
/* allowed to return smaller values than actually correct */
static double pgl_estimate_key_distance(pgl_keyptr key, pgl_point *point) {
  pgl_box box;  /* center(!) bounding box of area index key */
  /* calculate center(!) bounding box and maximum radius of objects covered
     by area index key (radius is zero for point index keys) */
  double distance = pgl_key_to_box(key, &box);
  /* calculate estimated distance between bounding box of center point of
     indexed object and point passed as second argument, then substract maximum
     radius of objects covered by index key */
  /* (use PGL_FPE_SAFETY factor to cope with minor floating point errors) */
  distance = (
    pgl_estimate_point_box_distance(point, &box) / PGL_FPE_SAFETY -
    distance * PGL_FPE_SAFETY
  );
  /* truncate negative results to zero */
  if (distance <= 0) distance = 0;
  /* return result */
  return distance;
}


/*---------------------------------*
 *  helper functions for text I/O  *
 *---------------------------------*/

#define PGL_NUMBUFLEN 64  /* buffer size for number to string conversion */

/* convert floating point number to string (round-trip safe) */
static void pgl_print_float(char *buf, double flt) {
  /* check if number is integral */
  if (trunc(flt) == flt) {
    /* for integral floats use maximum precision */
    snprintf(buf, PGL_NUMBUFLEN, "%.17g", flt);
  } else {
    /* otherwise check if 15, 16, or 17 digits needed (round-trip safety) */
    snprintf(buf, PGL_NUMBUFLEN, "%.15g", flt);
    if (strtod(buf, NULL) != flt) snprintf(buf, PGL_NUMBUFLEN, "%.16g", flt);
    if (strtod(buf, NULL) != flt) snprintf(buf, PGL_NUMBUFLEN, "%.17g", flt);
  }
}

/* convert latitude floating point number (in degrees) to string */
static void pgl_print_lat(char *buf, double lat) {
  if (signbit(lat)) {
    /* treat negative latitudes (including -0) as south */
    snprintf(buf, PGL_NUMBUFLEN, "S%015.12f", -lat);
  } else {
    /* treat positive latitudes (including +0) as north */
    snprintf(buf, PGL_NUMBUFLEN, "N%015.12f", lat);
  }
}

/* convert longitude floating point number (in degrees) to string */
static void pgl_print_lon(char *buf, double lon) {
  if (signbit(lon)) {
    /* treat negative longitudes (including -0) as west */
    snprintf(buf, PGL_NUMBUFLEN, "W%016.12f", -lon);
  } else {
    /* treat positive longitudes (including +0) as east */
    snprintf(buf, PGL_NUMBUFLEN, "E%016.12f", lon);
  }
}

/* bit masks used as return value of pgl_scan() function */
#define PGL_SCAN_NONE 0      /* no value has been parsed */
#define PGL_SCAN_LAT (1<<0)  /* latitude has been parsed */
#define PGL_SCAN_LON (1<<1)  /* longitude has been parsed */
#define PGL_SCAN_LATLON (PGL_SCAN_LAT | PGL_SCAN_LON)  /* bitwise OR of both */

/* parse a coordinate (can be latitude or longitude) */
static int pgl_scan(char **str, double *lat, double *lon) {
  double val;
  int len;
  if (
    sscanf(*str, " N %lf %n", &val, &len) ||
    sscanf(*str, " n %lf %n", &val, &len)
  ) {
    *str += len; *lat = val; return PGL_SCAN_LAT;
  }
  if (
    sscanf(*str, " S %lf %n", &val, &len) ||
    sscanf(*str, " s %lf %n", &val, &len)
  ) {
    *str += len; *lat = -val; return PGL_SCAN_LAT;
  }
  if (
    sscanf(*str, " E %lf %n", &val, &len) ||
    sscanf(*str, " e %lf %n", &val, &len)
  ) {
    *str += len; *lon = val; return PGL_SCAN_LON;
  }
  if (
    sscanf(*str, " W %lf %n", &val, &len) ||
    sscanf(*str, " w %lf %n", &val, &len)
  ) {
    *str += len; *lon = -val; return PGL_SCAN_LON;
  }
  return PGL_SCAN_NONE;
}


/*-----------------*
 *  SQL functions  *
 *-----------------*/

/* Note: These function names use "epoint", "ebox", etc. notation here instead
   of "point", "box", etc. in order to distinguish them from any previously
   defined functions. */

/* function needed for dummy types and/or not implemented features */
PG_FUNCTION_INFO_V1(pgl_notimpl);
Datum pgl_notimpl(PG_FUNCTION_ARGS) {
  ereport(ERROR, (errmsg("not implemented by pgLatLon")));
}

/* set point to latitude and longitude (including checks) */
static void pgl_epoint_set_latlon(pgl_point *point, double lat, double lon) {
  /* reject infinite or NaN values */
  if (!isfinite(lat) || !isfinite(lon)) {
    ereport(ERROR, (
      errcode(ERRCODE_DATA_EXCEPTION),
      errmsg("epoint requires finite coordinates")
    ));
  }
  /* check latitude bounds */
  if (lat < -90) {
    ereport(WARNING, (errmsg("latitude exceeds south pole")));
    lat = -90;
  } else if (lat > 90) {
    ereport(WARNING, (errmsg("latitude exceeds north pole")));
    lat = 90;
  }
  /* check longitude bounds */
  if (lon < -180) {
    ereport(NOTICE, (errmsg("longitude west of 180th meridian normalized")));
    lon += 360 - trunc(lon / 360) * 360;
  } else if (lon > 180) {
    ereport(NOTICE, (errmsg("longitude east of 180th meridian normalized")));
    lon -= 360 + trunc(lon / 360) * 360;
  }
  /* store rounded latitude/longitude values for round-trip safety */
  point->lat = pgl_round(lat);
  point->lon = pgl_round(lon);
}

/* create point ("epoint" in SQL) from latitude and longitude */
PG_FUNCTION_INFO_V1(pgl_create_epoint);
Datum pgl_create_epoint(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)palloc(sizeof(pgl_point));
  pgl_epoint_set_latlon(point, PG_GETARG_FLOAT8(0), PG_GETARG_FLOAT8(1));
  PG_RETURN_POINTER(point);
}

/* parse point ("epoint" in SQL) */
/* format: '[NS]<float> [EW]<float>' */
PG_FUNCTION_INFO_V1(pgl_epoint_in);
Datum pgl_epoint_in(PG_FUNCTION_ARGS) {
  char *str = PG_GETARG_CSTRING(0);  /* input string */
  char *strptr = str;  /* current position within string */
  int done = 0;        /* bit mask storing if latitude or longitude was read */
  double lat, lon;     /* parsed values as double precision floats */
  pgl_point *point;    /* return value (to be palloc'ed) */
  /* parse two floats (each latitude or longitude) separated by white-space */
  done |= pgl_scan(&strptr, &lat, &lon);
  if (strptr != str && isspace(strptr[-1])) {
    done |= pgl_scan(&strptr, &lat, &lon);
  }
  /* require end of string, and latitude and longitude parsed successfully */
  if (strptr[0] || done != PGL_SCAN_LATLON) {
    ereport(ERROR, (
      errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
      errmsg("invalid input syntax for type epoint: \"%s\"", str)
    ));
  }
  /* allocate memory for result */
  point = (pgl_point *)palloc(sizeof(pgl_point));
  /* set latitude and longitude (and perform checks) */
  pgl_epoint_set_latlon(point, lat, lon);
  /* return result */
  PG_RETURN_POINTER(point);
}

/* create box ("ebox" in SQL) that is empty */
PG_FUNCTION_INFO_V1(pgl_create_empty_ebox);
Datum pgl_create_empty_ebox(PG_FUNCTION_ARGS) {
  pgl_box *box = (pgl_box *)palloc(sizeof(pgl_box));
  pgl_box_set_empty(box);
  PG_RETURN_POINTER(box);
}

/* set box to given boundaries (including checks) */
static void pgl_ebox_set_boundaries(
  pgl_box *box,
  double lat_min, double lat_max, double lon_min, double lon_max
) {
  /* if minimum latitude is greater than maximum latitude, return empty box */
  if (lat_min > lat_max) {
    pgl_box_set_empty(box);
    return;
  }
  /* otherwise reject infinite or NaN values */
  if (
    !isfinite(lat_min) || !isfinite(lat_max) ||
    !isfinite(lon_min) || !isfinite(lon_max)
  ) {
    ereport(ERROR, (
      errcode(ERRCODE_DATA_EXCEPTION),
      errmsg("ebox requires finite coordinates")
    ));
  }
  /* check latitude bounds */
  if (lat_max < -90) {
    ereport(WARNING, (errmsg("northern latitude exceeds south pole")));
    lat_max = -90;
  } else if (lat_max > 90) {
    ereport(WARNING, (errmsg("northern latitude exceeds north pole")));
    lat_max = 90;
  }
  if (lat_min < -90) {
    ereport(WARNING, (errmsg("southern latitude exceeds south pole")));
    lat_min = -90;
  } else if (lat_min > 90) {
    ereport(WARNING, (errmsg("southern latitude exceeds north pole")));
    lat_min = 90;
  }
  /* check if all longitudes are included */
  if (lon_max - lon_min >= 360) {
    if (lon_max - lon_min > 360) ereport(WARNING, (
      errmsg("longitude coverage greater than 360 degrees")
    ));
    lon_min = -180;
    lon_max = 180;
  } else {
    /* normalize longitude bounds */
    if      (lon_min < -180) lon_min += 360 - trunc(lon_min / 360) * 360;
    else if (lon_min >  180) lon_min -= 360 + trunc(lon_min / 360) * 360;
    if      (lon_max < -180) lon_max += 360 - trunc(lon_max / 360) * 360;
    else if (lon_max >  180) lon_max -= 360 + trunc(lon_max / 360) * 360;
  }
  /* store rounded latitude/longitude values for round-trip safety */
  box->lat_min = pgl_round(lat_min);
  box->lat_max = pgl_round(lat_max);
  box->lon_min = pgl_round(lon_min);
  box->lon_max = pgl_round(lon_max);
  /* ensure that rounding does not change orientation */
  if (lon_min > lon_max && box->lon_min == box->lon_max) {
    box->lon_min = -180;
    box->lon_max = 180;
  }
}

/* create box ("ebox" in SQL) from min/max latitude and min/max longitude */
PG_FUNCTION_INFO_V1(pgl_create_ebox);
Datum pgl_create_ebox(PG_FUNCTION_ARGS) {
  pgl_box *box = (pgl_box *)palloc(sizeof(pgl_box));
  pgl_ebox_set_boundaries(
    box,
    PG_GETARG_FLOAT8(0), PG_GETARG_FLOAT8(1),
    PG_GETARG_FLOAT8(2), PG_GETARG_FLOAT8(3)
  );
  PG_RETURN_POINTER(box);
}

/* create box ("ebox" in SQL) from two points ("epoint"s) */
/* (can not be used to cover a longitude range of more than 120 degrees) */
PG_FUNCTION_INFO_V1(pgl_create_ebox_from_epoints);
Datum pgl_create_ebox_from_epoints(PG_FUNCTION_ARGS) {
  pgl_point *point1 = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_point *point2 = (pgl_point *)PG_GETARG_POINTER(1);
  pgl_box *box = (pgl_box *)palloc(sizeof(pgl_box));
  double lat_min, lat_max, lon_min, lon_max;
  double dlon;  /* longitude range (delta longitude) */
  /* order latitude and longitude boundaries */
  if (point2->lat < point1->lat) {
    lat_min = point2->lat;
    lat_max = point1->lat;
  } else {
    lat_min = point1->lat;
    lat_max = point2->lat;
  }
  if (point2->lon < point1->lon) {
    lon_min = point2->lon;
    lon_max = point1->lon;
  } else {
    lon_min = point1->lon;
    lon_max = point2->lon;
  }
  /* calculate longitude range (round to avoid floating point errors) */
  dlon = pgl_round(lon_max - lon_min);
  /* determine east-west direction */
  if (dlon >= 240) {
    /* assume that 180th meridian is crossed and swap min/max longitude */
    double swap = lon_min; lon_min = lon_max; lon_max = swap;
  } else if (dlon > 120) {
    /* unclear orientation since delta longitude > 120 */
    ereport(ERROR, (
      errcode(ERRCODE_DATA_EXCEPTION),
      errmsg("can not determine east/west orientation for ebox")
    ));
  }
  /* use boundaries to setup box (and perform checks) */
  pgl_ebox_set_boundaries(box, lat_min, lat_max, lon_min, lon_max);
  /* return result */
  PG_RETURN_POINTER(box);
}

/* parse box ("ebox" in SQL) */
/* format: '[NS]<float> [EW]<float> [NS]<float> [EW]<float>'
       or: '[NS]<float> [NS]<float> [EW]<float> [EW]<float>' */
PG_FUNCTION_INFO_V1(pgl_ebox_in);
Datum pgl_ebox_in(PG_FUNCTION_ARGS) {
  char *str = PG_GETARG_CSTRING(0);  /* input string */
  char *str_lower;     /* lower case version of input string */
  char *strptr;        /* current position within string */
  int valid;           /* number of valid chars */
  int done;            /* specifies if latitude or longitude was read */
  double val;          /* temporary variable */
  int lat_count = 0;   /* count of latitude values parsed */
  int lon_count = 0;   /* count of longitufde values parsed */
  double lat_min, lat_max, lon_min, lon_max;  /* see pgl_box struct */
  pgl_box *box;        /* return value (to be palloc'ed) */
  /* lowercase input */
  str_lower = psprintf("%s", str);
  for (strptr=str_lower; *strptr; strptr++) {
    if (*strptr >= 'A' && *strptr <= 'Z') *strptr += 'a' - 'A';
  }
  /* reset reading position to start of (lowercase) string */
  strptr = str_lower;
  /* check if empty box */
  valid = 0;
  sscanf(strptr, " empty %n", &valid);
  if (valid && strptr[valid] == 0) {
    /* allocate and return empty box */
    box = (pgl_box *)palloc(sizeof(pgl_box));
    pgl_box_set_empty(box);
    PG_RETURN_POINTER(box);
  }
  /* demand four blocks separated by whitespace */
  valid = 0;
  sscanf(strptr, " %*s %*s %*s %*s %n", &valid);
  /* if four blocks separated by whitespace exist, parse those blocks */
  if (strptr[valid] == 0) while (strptr[0]) {
    /* parse either latitude or longitude (whichever found in input string) */
    done = pgl_scan(&strptr, &val, &val);
    /* store latitude or longitude in lat_min, lat_max, lon_min, or lon_max */
    if (done == PGL_SCAN_LAT) {
      if (!lat_count) lat_min = val; else lat_max = val;
      lat_count++;
    } else if (done == PGL_SCAN_LON) {
      if (!lon_count) lon_min = val; else lon_max = val;
      lon_count++;
    } else {
      break;
    }
  }
  /* require end of string, and two latitude and two longitude values */
  if (strptr[0] || lat_count != 2 || lon_count != 2) {
    ereport(ERROR, (
      errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
      errmsg("invalid input syntax for type ebox: \"%s\"", str)
    ));
  }
  /* free lower case string */
  pfree(str_lower);
  /* order boundaries (maximum greater than minimum) */
  if (lat_min > lat_max) { val = lat_min; lat_min = lat_max; lat_max = val; }
  if (lon_min > lon_max) { val = lon_min; lon_min = lon_max; lon_max = val; }
  /* allocate memory for result */
  box = (pgl_box *)palloc(sizeof(pgl_box));
  /* set boundaries (and perform checks) */
  pgl_ebox_set_boundaries(box, lat_min, lat_max, lon_min, lon_max);
  /* return result */
  PG_RETURN_POINTER(box);
}

/* set circle to given latitude, longitude, and radius (including checks) */
static void pgl_ecircle_set_latlon_radius(
  pgl_circle *circle, double lat, double lon, double radius
) {
  /* set center point (including checks) */
  pgl_epoint_set_latlon(&(circle->center), lat, lon);
  /* handle non-positive radius */
  if (isnan(radius)) {
    ereport(ERROR, (
      errcode(ERRCODE_DATA_EXCEPTION),
      errmsg("invalid radius for ecircle")
    ));
  }
  if (radius == 0) radius = 0;  /* avoids -0 */
  else if (radius < 0) {
    if (isfinite(radius)) {
      ereport(NOTICE, (errmsg("negative radius converted to minus infinity")));
    }
    radius = -INFINITY;
  }
  /* store radius (round-trip safety is ensured by pgl_print_float) */
  circle->radius = radius;
}

/* create circle ("ecircle" in SQL) from latitude, longitude, and radius */
PG_FUNCTION_INFO_V1(pgl_create_ecircle);
Datum pgl_create_ecircle(PG_FUNCTION_ARGS) {
  pgl_circle *circle = (pgl_circle *)palloc(sizeof(pgl_circle));
  pgl_ecircle_set_latlon_radius(
    circle, PG_GETARG_FLOAT8(0), PG_GETARG_FLOAT8(1), PG_GETARG_FLOAT8(2)
  );
  PG_RETURN_POINTER(circle);
}

/* create circle ("ecircle" in SQL) from point ("epoint"), and radius */
PG_FUNCTION_INFO_V1(pgl_create_ecircle_from_epoint);
Datum pgl_create_ecircle_from_epoint(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  double radius = PG_GETARG_FLOAT8(1);
  pgl_circle *circle = (pgl_circle *)palloc(sizeof(pgl_circle));
  /* set latitude, longitude, radius (and perform checks) */
  pgl_ecircle_set_latlon_radius(circle, point->lat, point->lon, radius);
  /* return result */
  PG_RETURN_POINTER(circle);
}

/* parse circle ("ecircle" in SQL) */
/* format: '[NS]<float> [EW]<float> <float>' */
PG_FUNCTION_INFO_V1(pgl_ecircle_in);
Datum pgl_ecircle_in(PG_FUNCTION_ARGS) {
  char *str = PG_GETARG_CSTRING(0);  /* input string */
  char *strptr = str;       /* current position within string */
  double lat, lon, radius;  /* parsed values as double precision flaots */
  int valid = 0;            /* number of valid chars */
  int done = 0;             /* stores if latitude and/or longitude was read */
  pgl_circle *circle;       /* return value (to be palloc'ed) */
  /* demand three blocks separated by whitespace */
  sscanf(strptr, " %*s %*s %*s %n", &valid);
  /* if three blocks separated by whitespace exist, parse those blocks */
  if (strptr[valid] == 0) {
    /* parse latitude and longitude */
    done |= pgl_scan(&strptr, &lat, &lon);
    done |= pgl_scan(&strptr, &lat, &lon);
    /* parse radius (while incrementing strptr by number of bytes parsed) */
    valid = 0;
    if (sscanf(strptr, " %lf %n", &radius, &valid) == 1) strptr += valid;
  }
  /* require end of string and both latitude and longitude being parsed */
  if (strptr[0] || done != PGL_SCAN_LATLON) {
    ereport(ERROR, (
      errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
      errmsg("invalid input syntax for type ecircle: \"%s\"", str)
    ));
  }
  /* allocate memory for result */
  circle = (pgl_circle *)palloc(sizeof(pgl_circle));
  /* set latitude, longitude, radius (and perform checks) */
  pgl_ecircle_set_latlon_radius(circle, lat, lon, radius);
  /* return result */
  PG_RETURN_POINTER(circle);
}

/* parse cluster ("ecluster" in SQL) */
PG_FUNCTION_INFO_V1(pgl_ecluster_in);
Datum pgl_ecluster_in(PG_FUNCTION_ARGS) {
  int i;
  char *str = PG_GETARG_CSTRING(0);  /* input string */
  char *str_lower;         /* lower case version of input string */
  char *strptr;            /* pointer to current reading position of input */
  int npoints_total = 0;   /* total number of points in cluster */
  int nentries = 0;        /* total number of entries */
  pgl_newentry *entries;   /* array of pgl_newentry to create pgl_cluster */
  int entries_buflen = 4;  /* maximum number of elements in entries array */
  int valid;               /* number of valid chars processed */
  double lat, lon;         /* latitude and longitude of parsed point */
  int entrytype;           /* current entry type */
  int npoints;             /* number of points in current entry */
  pgl_point *points;       /* array of pgl_point for pgl_newentry */
  int points_buflen;       /* maximum number of elements in points array */
  int done;                /* return value of pgl_scan function */
  pgl_cluster *cluster;    /* created cluster */
  /* lowercase input */
  str_lower = psprintf("%s", str);
  for (strptr=str_lower; *strptr; strptr++) {
    if (*strptr >= 'A' && *strptr <= 'Z') *strptr += 'a' - 'A';
  }
  /* reset reading position to start of (lowercase) string */
  strptr = str_lower;
  /* allocate initial buffer for entries */
  entries = palloc(entries_buflen * sizeof(pgl_newentry));
  /* parse until end of string */
  while (strptr[0]) {
    /* require previous white-space or closing parenthesis before next token */
    if (strptr != str_lower && !isspace(strptr[-1]) && strptr[-1] != ')') {
      goto pgl_ecluster_in_error;
    }
    /* ignore token "empty" */
    valid = 0; sscanf(strptr, " empty %n", &valid);
    if (valid) { strptr += valid; continue; }
    /* test for "point" token */
    valid = 0; sscanf(strptr, " point ( %n", &valid);
    if (valid) {
      strptr += valid;
      entrytype = PGL_ENTRY_POINT;
      goto pgl_ecluster_in_type_ok;
    }
    /* test for "path" token */
    valid = 0; sscanf(strptr, " path ( %n", &valid);
    if (valid) {
      strptr += valid;
      entrytype = PGL_ENTRY_PATH;
      goto pgl_ecluster_in_type_ok;
    }
    /* test for "outline" token */
    valid = 0; sscanf(strptr, " outline ( %n", &valid);
    if (valid) {
      strptr += valid;
      entrytype = PGL_ENTRY_OUTLINE;
      goto pgl_ecluster_in_type_ok;
    }
    /* test for "polygon" token */
    valid = 0; sscanf(strptr, " polygon ( %n", &valid);
    if (valid) {
      strptr += valid;
      entrytype = PGL_ENTRY_POLYGON;
      goto pgl_ecluster_in_type_ok;
    }
    /* error if no valid token found */
    goto pgl_ecluster_in_error;
    pgl_ecluster_in_type_ok:
    /* check if pgl_newentry array needs to grow */
    if (nentries == entries_buflen) {
      pgl_newentry *newbuf;
      entries_buflen *= 2;
      newbuf = palloc(entries_buflen * sizeof(pgl_newentry));
      memcpy(newbuf, entries, nentries * sizeof(pgl_newentry));
      pfree(entries);
      entries = newbuf;
    }
    /* reset number of points for current entry */
    npoints = 0;
    /* allocate array for points */
    points_buflen = 4;
    points = palloc(points_buflen * sizeof(pgl_point));
    /* parse until closing parenthesis */
    while (strptr[0] != ')') {
      /* error on unexpected end of string */
      if (strptr[0] == 0) goto pgl_ecluster_in_error;
      /* mark neither latitude nor longitude as read */
      done = PGL_SCAN_NONE;
      /* require white-space before second, third, etc. point */
      if (npoints != 0 && !isspace(strptr[-1])) goto pgl_ecluster_in_error;
      /* scan latitude (or longitude) */
      done |= pgl_scan(&strptr, &lat, &lon);
      /* require white-space before second coordinate */
      if (strptr != str && !isspace(strptr[-1])) goto pgl_ecluster_in_error;
      /* scan longitude (or latitude) */
      done |= pgl_scan(&strptr, &lat, &lon);
      /* error unless both latitude and longitude were parsed */
      if (done != PGL_SCAN_LATLON) goto pgl_ecluster_in_error;
      /* throw error if number of points is too high */
      if (npoints_total == PGL_CLUSTER_MAXPOINTS) {
        ereport(ERROR, (
          errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
          errmsg(
            "too many points for ecluster entry (maximum %i)",
            PGL_CLUSTER_MAXPOINTS
          )
        ));
      }
      /* check if pgl_point array needs to grow */
      if (npoints == points_buflen) {
        pgl_point *newbuf;
        points_buflen *= 2;
        newbuf = palloc(points_buflen * sizeof(pgl_point));
        memcpy(newbuf, points, npoints * sizeof(pgl_point));
        pfree(points);
        points = newbuf;
      }
      /* append point to pgl_point array (includes checks) */
      pgl_epoint_set_latlon(&(points[npoints++]), lat, lon);
      /* increase total number of points */
      npoints_total++;
    }
    /* error if entry has no points */
    if (!npoints) goto pgl_ecluster_in_error;
    /* entries with one point are automatically of type "point" */
    if (npoints == 1) entrytype = PGL_ENTRY_POINT;
    /* if entries have more than one point */
    else {
      /* throw error if entry type is "point" */
      if (entrytype == PGL_ENTRY_POINT) {
        ereport(ERROR, (
          errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
          errmsg("invalid input syntax for type ecluster (point entry with more than one point)")
        ));
      }
      /* coerce outlines and polygons with more than 2 points to be a path */
      if (npoints == 2) entrytype = PGL_ENTRY_PATH;
    }
    /* append entry to pgl_newentry array */
    entries[nentries].entrytype = entrytype;
    entries[nentries].npoints = npoints;
    entries[nentries].points = points;
    nentries++;
    /* consume closing parenthesis */
    strptr++;
    /* consume white-space */
    while (isspace(strptr[0])) strptr++;
  }
  /* free lower case string */
  pfree(str_lower);
  /* create cluster from pgl_newentry array */
  cluster = pgl_new_cluster(nentries, entries);
  /* free pgl_newentry array */
  for (i=0; i<nentries; i++) pfree(entries[i].points);
  pfree(entries);
  /* set bounding circle of cluster and check east/west orientation */
  if (!pgl_finalize_cluster(cluster)) {
    ereport(ERROR, (
      errcode(ERRCODE_DATA_EXCEPTION),
      errmsg("can not determine east/west orientation for ecluster"),
      errhint("Ensure that each entry has a longitude span of less than 180 degrees.")
    ));
  }
  /* return cluster */
  PG_RETURN_POINTER(cluster);
  /* code to throw error */
  pgl_ecluster_in_error:
  ereport(ERROR, (
    errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
    errmsg("invalid input syntax for type ecluster: \"%s\"", str)
  ));
}

/* convert point ("epoint") to string representation */
PG_FUNCTION_INFO_V1(pgl_epoint_out);
Datum pgl_epoint_out(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  char latstr[PGL_NUMBUFLEN];
  char lonstr[PGL_NUMBUFLEN];
  pgl_print_lat(latstr, point->lat);
  pgl_print_lon(lonstr, point->lon);
  PG_RETURN_CSTRING(psprintf("%s %s", latstr, lonstr));
}

/* convert box ("ebox") to string representation */
PG_FUNCTION_INFO_V1(pgl_ebox_out);
Datum pgl_ebox_out(PG_FUNCTION_ARGS) {
  pgl_box *box = (pgl_box *)PG_GETARG_POINTER(0);
  double lon_min = box->lon_min;
  double lon_max = box->lon_max;
  char lat_min_str[PGL_NUMBUFLEN];
  char lat_max_str[PGL_NUMBUFLEN];
  char lon_min_str[PGL_NUMBUFLEN];
  char lon_max_str[PGL_NUMBUFLEN];
  /* return string "empty" if box is set to be empty */
  if (box->lat_min > box->lat_max) PG_RETURN_CSTRING("empty");
  /* use boundaries exceeding W180 or E180 if 180th meridian is enclosed */
  /* (required since pgl_box_in orders the longitude boundaries) */
  if (lon_min > lon_max) {
    if (lon_min + lon_max >= 0) lon_min -= 360;
    else lon_max += 360;
  }
  /* format and return result */
  pgl_print_lat(lat_min_str, box->lat_min);
  pgl_print_lat(lat_max_str, box->lat_max);
  pgl_print_lon(lon_min_str, lon_min);
  pgl_print_lon(lon_max_str, lon_max);
  PG_RETURN_CSTRING(psprintf(
    "%s %s %s %s",
    lat_min_str, lon_min_str, lat_max_str, lon_max_str
  ));
}

/* convert circle ("ecircle") to string representation */
PG_FUNCTION_INFO_V1(pgl_ecircle_out);
Datum pgl_ecircle_out(PG_FUNCTION_ARGS) {
  pgl_circle *circle = (pgl_circle *)PG_GETARG_POINTER(0);
  char latstr[PGL_NUMBUFLEN];
  char lonstr[PGL_NUMBUFLEN];
  char radstr[PGL_NUMBUFLEN];
  pgl_print_lat(latstr, circle->center.lat);
  pgl_print_lon(lonstr, circle->center.lon);
  pgl_print_float(radstr, circle->radius);
  PG_RETURN_CSTRING(psprintf("%s %s %s", latstr, lonstr, radstr));
}

/* convert cluster ("ecluster") to string representation */
PG_FUNCTION_INFO_V1(pgl_ecluster_out);
Datum pgl_ecluster_out(PG_FUNCTION_ARGS) {
  pgl_cluster *cluster = (pgl_cluster *)PG_DETOAST_DATUM(PG_GETARG_DATUM(0));
  char latstr[PGL_NUMBUFLEN];  /* string buffer for latitude */
  char lonstr[PGL_NUMBUFLEN];  /* string buffer for longitude */
  char ***strings;     /* array of array of strings */
  char *string;        /* string of current token */
  char *res, *resptr;  /* result and pointer to current write position */
  size_t reslen = 1;   /* length of result (init with 1 for terminator) */
  int npoints;         /* number of points of current entry */
  int i, j;            /* i: entry, j: point in entry */
  /* handle empty clusters */
  if (cluster->nentries == 0) {
    /* free detoasted cluster (if copy) */
    PG_FREE_IF_COPY(cluster, 0);
    /* return static result */
    PG_RETURN_CSTRING("empty");
  }
  /* allocate array of array of strings */
  strings = palloc(cluster->nentries * sizeof(char **));
  /* iterate over all entries in cluster */
  for (i=0; i<cluster->nentries; i++) {
    /* get number of points in entry */
    npoints = cluster->entries[i].npoints;
    /* allocate array of strings (one string for each point plus two extra) */
    strings[i] = palloc((2 + npoints) * sizeof(char *));
    /* determine opening string */
    switch (cluster->entries[i].entrytype) {
      case PGL_ENTRY_POINT:   string = (i==0)?"point ("  :" point (";   break;
      case PGL_ENTRY_PATH:    string = (i==0)?"path ("   :" path (";    break;
      case PGL_ENTRY_OUTLINE: string = (i==0)?"outline (":" outline ("; break;
      case PGL_ENTRY_POLYGON: string = (i==0)?"polygon (":" polygon ("; break;
      default:                string = (i==0)?"unknown"  :" unknown";
    }
    /* use opening string as first string in array */
    strings[i][0] = string;
    /* update result length (for allocating result string later) */
    reslen += strlen(string);
    /* iterate over all points */
    for (j=0; j<npoints; j++) {
      /* create string representation of point */
      pgl_print_lat(latstr, PGL_ENTRY_POINTS(cluster, i)[j].lat);
      pgl_print_lon(lonstr, PGL_ENTRY_POINTS(cluster, i)[j].lon);
      string = psprintf((j == 0) ? "%s %s" : " %s %s", latstr, lonstr);
      /* copy string pointer to string array */
      strings[i][j+1] = string;
      /* update result length (for allocating result string later) */
      reslen += strlen(string);
    }
    /* use closing parenthesis as last string in array */
    strings[i][npoints+1] = ")";
    /* update result length (for allocating result string later) */
    reslen++;
  }
  /* allocate result string */
  res = palloc(reslen);
  /* set write pointer to begin of result string */
  resptr = res;
  /* copy strings into result string */
  for (i=0; i<cluster->nentries; i++) {
    npoints = cluster->entries[i].npoints;
    for (j=0; j<npoints+2; j++) {
      string = strings[i][j];
      strcpy(resptr, string);
      resptr += strlen(string);
      /* free strings allocated by psprintf */
      if (j != 0 && j != npoints+1) pfree(string);
    }
    /* free array of strings */
    pfree(strings[i]);
  }
  /* free array of array of strings */
  pfree(strings);
  /* free detoasted cluster (if copy) */
  PG_FREE_IF_COPY(cluster, 0);
  /* return result */
  PG_RETURN_CSTRING(res);
}

/* binary input function for point ("epoint") */
PG_FUNCTION_INFO_V1(pgl_epoint_recv);
Datum pgl_epoint_recv(PG_FUNCTION_ARGS) {
  StringInfo buf = (StringInfo)PG_GETARG_POINTER(0);
  pgl_point *point = (pgl_point *)palloc(sizeof(pgl_point));
  point->lat = pq_getmsgfloat8(buf);
  point->lon = pq_getmsgfloat8(buf);
  PG_RETURN_POINTER(point);
}

/* binary input function for box ("ebox") */
PG_FUNCTION_INFO_V1(pgl_ebox_recv);
Datum pgl_ebox_recv(PG_FUNCTION_ARGS) {
  StringInfo buf = (StringInfo)PG_GETARG_POINTER(0);
  pgl_box *box = (pgl_box *)palloc(sizeof(pgl_box));
  box->lat_min = pq_getmsgfloat8(buf);
  box->lat_max = pq_getmsgfloat8(buf);
  box->lon_min = pq_getmsgfloat8(buf);
  box->lon_max = pq_getmsgfloat8(buf);
  PG_RETURN_POINTER(box);
}

/* binary input function for circle ("ecircle") */
PG_FUNCTION_INFO_V1(pgl_ecircle_recv);
Datum pgl_ecircle_recv(PG_FUNCTION_ARGS) {
  StringInfo buf = (StringInfo)PG_GETARG_POINTER(0);
  pgl_circle *circle = (pgl_circle *)palloc(sizeof(pgl_circle));
  circle->center.lat = pq_getmsgfloat8(buf);
  circle->center.lon = pq_getmsgfloat8(buf);
  circle->radius = pq_getmsgfloat8(buf);
  PG_RETURN_POINTER(circle);
}

/* TODO: binary receive function for cluster */

/* binary output function for point ("epoint") */
PG_FUNCTION_INFO_V1(pgl_epoint_send);
Datum pgl_epoint_send(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  StringInfoData buf;
  pq_begintypsend(&buf);
  pq_sendfloat8(&buf, point->lat);
  pq_sendfloat8(&buf, point->lon);
  PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/* binary output function for box ("ebox") */
PG_FUNCTION_INFO_V1(pgl_ebox_send);
Datum pgl_ebox_send(PG_FUNCTION_ARGS) {
  pgl_box *box = (pgl_box *)PG_GETARG_POINTER(0);
  StringInfoData buf;
  pq_begintypsend(&buf);
  pq_sendfloat8(&buf, box->lat_min);
  pq_sendfloat8(&buf, box->lat_max);
  pq_sendfloat8(&buf, box->lon_min);
  pq_sendfloat8(&buf, box->lon_max);
  PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/* binary output function for circle ("ecircle") */
PG_FUNCTION_INFO_V1(pgl_ecircle_send);
Datum pgl_ecircle_send(PG_FUNCTION_ARGS) {
  pgl_circle *circle = (pgl_circle *)PG_GETARG_POINTER(0);
  StringInfoData buf;
  pq_begintypsend(&buf);
  pq_sendfloat8(&buf, circle->center.lat);
  pq_sendfloat8(&buf, circle->center.lon);
  pq_sendfloat8(&buf, circle->radius);
  PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/* TODO: binary send functions for cluster */

/* cast point ("epoint") to box ("ebox") */
PG_FUNCTION_INFO_V1(pgl_epoint_to_ebox);
Datum pgl_epoint_to_ebox(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_box *box = palloc(sizeof(pgl_box));
  box->lat_min = point->lat;
  box->lat_max = point->lat;
  box->lon_min = point->lon;
  box->lon_max = point->lon;
  PG_RETURN_POINTER(box);
}

/* cast point ("epoint") to circle ("ecircle") */
PG_FUNCTION_INFO_V1(pgl_epoint_to_ecircle);
Datum pgl_epoint_to_ecircle(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_circle *circle = palloc(sizeof(pgl_box));
  circle->center = *point;
  circle->radius = 0;
  PG_RETURN_POINTER(circle);
}

/* cast point ("epoint") to cluster ("ecluster") */
PG_FUNCTION_INFO_V1(pgl_epoint_to_ecluster);
Datum pgl_epoint_to_ecluster(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_newentry entry;
  entry.entrytype = PGL_ENTRY_POINT;
  entry.npoints = 1;
  entry.points = point;
  PG_RETURN_POINTER(pgl_new_cluster(1, &entry));
}

/* cast box ("ebox") to cluster ("ecluster") */
#define pgl_ebox_to_ecluster_macro(i, a, b) \
  entries[i].entrytype = PGL_ENTRY_POLYGON; \
  entries[i].npoints = 4; \
  entries[i].points = points[i]; \
  points[i][0].lat = box->lat_min; \
  points[i][0].lon = (a); \
  points[i][1].lat = box->lat_min; \
  points[i][1].lon = (b); \
  points[i][2].lat = box->lat_max; \
  points[i][2].lon = (b); \
  points[i][3].lat = box->lat_max; \
  points[i][3].lon = (a);
PG_FUNCTION_INFO_V1(pgl_ebox_to_ecluster);
Datum pgl_ebox_to_ecluster(PG_FUNCTION_ARGS) {
  pgl_box *box = (pgl_box *)PG_GETARG_POINTER(0);
  double lon, dlon;
  int nentries;
  pgl_newentry entries[3];
  pgl_point points[3][4];
  if (box->lat_min > box->lat_max) {
    nentries = 0;
  } else if (box->lon_min > box->lon_max) {
    if (box->lon_min < 0) {
      lon = pgl_round((box->lon_min + 180) / 2.0);
      nentries = 3;
      pgl_ebox_to_ecluster_macro(0, box->lon_min, lon);
      pgl_ebox_to_ecluster_macro(1, lon, 180);
      pgl_ebox_to_ecluster_macro(2, -180, box->lon_max);
    } else if (box->lon_max > 0) {
      lon = pgl_round((box->lon_max - 180) / 2.0);
      nentries = 3;
      pgl_ebox_to_ecluster_macro(0, box->lon_min, 180);
      pgl_ebox_to_ecluster_macro(1, -180, lon);
      pgl_ebox_to_ecluster_macro(2, lon, box->lon_max);
    } else {
      nentries = 2;
      pgl_ebox_to_ecluster_macro(0, box->lon_min, 180);
      pgl_ebox_to_ecluster_macro(1, -180, box->lon_max);
    }
  } else {
    dlon = pgl_round(box->lon_max - box->lon_min);
    if (dlon < 180) {
      nentries = 1;
      pgl_ebox_to_ecluster_macro(0, box->lon_min, box->lon_max);
    } else {
      lon = pgl_round((box->lon_min + box->lon_max) / 2.0);
      if (
        pgl_round(lon - box->lon_min) < 180 &&
        pgl_round(box->lon_max - lon) < 180
      ) {
        nentries = 2;
        pgl_ebox_to_ecluster_macro(0, box->lon_min, lon);
        pgl_ebox_to_ecluster_macro(1, lon, box->lon_max);
      } else {
        nentries = 3;
        pgl_ebox_to_ecluster_macro(0, box->lon_min, -60);
        pgl_ebox_to_ecluster_macro(1, -60, 60);
        pgl_ebox_to_ecluster_macro(2, 60, box->lon_max);
      }
    }
  }
  PG_RETURN_POINTER(pgl_new_cluster(nentries, entries));
}

/* extract latitude from point ("epoint") */
PG_FUNCTION_INFO_V1(pgl_epoint_lat);
Datum pgl_epoint_lat(PG_FUNCTION_ARGS) {
  PG_RETURN_FLOAT8(((pgl_point *)PG_GETARG_POINTER(0))->lat);
}

/* extract longitude from point ("epoint") */
PG_FUNCTION_INFO_V1(pgl_epoint_lon);
Datum pgl_epoint_lon(PG_FUNCTION_ARGS) {
  PG_RETURN_FLOAT8(((pgl_point *)PG_GETARG_POINTER(0))->lon);
}

/* extract minimum latitude from box ("ebox") */
PG_FUNCTION_INFO_V1(pgl_ebox_lat_min);
Datum pgl_ebox_lat_min(PG_FUNCTION_ARGS) {
  PG_RETURN_FLOAT8(((pgl_box *)PG_GETARG_POINTER(0))->lat_min);
}

/* extract maximum latitude from box ("ebox") */
PG_FUNCTION_INFO_V1(pgl_ebox_lat_max);
Datum pgl_ebox_lat_max(PG_FUNCTION_ARGS) {
  PG_RETURN_FLOAT8(((pgl_box *)PG_GETARG_POINTER(0))->lat_max);
}

/* extract minimum longitude from box ("ebox") */
PG_FUNCTION_INFO_V1(pgl_ebox_lon_min);
Datum pgl_ebox_lon_min(PG_FUNCTION_ARGS) {
  PG_RETURN_FLOAT8(((pgl_box *)PG_GETARG_POINTER(0))->lon_min);
}

/* extract maximum longitude from box ("ebox") */
PG_FUNCTION_INFO_V1(pgl_ebox_lon_max);
Datum pgl_ebox_lon_max(PG_FUNCTION_ARGS) {
  PG_RETURN_FLOAT8(((pgl_box *)PG_GETARG_POINTER(0))->lon_max);
}

/* extract center point from circle ("ecircle") */
PG_FUNCTION_INFO_V1(pgl_ecircle_center);
Datum pgl_ecircle_center(PG_FUNCTION_ARGS) {
  PG_RETURN_POINTER(&(((pgl_circle *)PG_GETARG_POINTER(0))->center));
}

/* extract radius from circle ("ecircle") */
PG_FUNCTION_INFO_V1(pgl_ecircle_radius);
Datum pgl_ecircle_radius(PG_FUNCTION_ARGS) {
  PG_RETURN_FLOAT8(((pgl_circle *)PG_GETARG_POINTER(0))->radius);
}

/* check if point is inside box (overlap operator "&&") in SQL */
PG_FUNCTION_INFO_V1(pgl_epoint_ebox_overlap);
Datum pgl_epoint_ebox_overlap(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_box *box = (pgl_box *)PG_GETARG_POINTER(1);
  PG_RETURN_BOOL(pgl_point_in_box(point, box));
}

/* check if point is inside circle (overlap operator "&&") in SQL */
PG_FUNCTION_INFO_V1(pgl_epoint_ecircle_overlap);
Datum pgl_epoint_ecircle_overlap(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_circle *circle = (pgl_circle *)PG_GETARG_POINTER(1);
  PG_RETURN_BOOL(
    pgl_distance(
      point->lat, point->lon,
      circle->center.lat, circle->center.lon
    ) <= circle->radius
  );
}

/* check if point is inside cluster (overlap operator "&&") in SQL */
PG_FUNCTION_INFO_V1(pgl_epoint_ecluster_overlap);
Datum pgl_epoint_ecluster_overlap(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_cluster *cluster = (pgl_cluster *)PG_DETOAST_DATUM(PG_GETARG_DATUM(1));
  bool retval = pgl_point_in_cluster(point, cluster);
  PG_FREE_IF_COPY(cluster, 1);
  PG_RETURN_BOOL(retval);
}

/* check if two boxes overlap (overlap operator "&&") in SQL */
PG_FUNCTION_INFO_V1(pgl_ebox_overlap);
Datum pgl_ebox_overlap(PG_FUNCTION_ARGS) {
  pgl_box *box1 = (pgl_box *)PG_GETARG_POINTER(0);
  pgl_box *box2 = (pgl_box *)PG_GETARG_POINTER(1);
  PG_RETURN_BOOL(pgl_boxes_overlap(box1, box2));
}

/* check if two circles overlap (overlap operator "&&") in SQL */
PG_FUNCTION_INFO_V1(pgl_ecircle_overlap);
Datum pgl_ecircle_overlap(PG_FUNCTION_ARGS) {
  pgl_circle *circle1 = (pgl_circle *)PG_GETARG_POINTER(0);
  pgl_circle *circle2 = (pgl_circle *)PG_GETARG_POINTER(1);
  PG_RETURN_BOOL(
    pgl_distance(
      circle1->center.lat, circle1->center.lon,
      circle2->center.lat, circle2->center.lon
    ) <= circle1->radius + circle2->radius
  );
}

/* check if circle and cluster overlap (overlap operator "&&") in SQL */
PG_FUNCTION_INFO_V1(pgl_ecircle_ecluster_overlap);
Datum pgl_ecircle_ecluster_overlap(PG_FUNCTION_ARGS) {
  pgl_circle *circle = (pgl_circle *)PG_GETARG_POINTER(0);
  pgl_cluster *cluster = (pgl_cluster *)PG_DETOAST_DATUM(PG_GETARG_DATUM(1));
  bool retval = (
    pgl_point_cluster_distance(&(circle->center), cluster) <= circle->radius
  );
  PG_FREE_IF_COPY(cluster, 1);
  PG_RETURN_BOOL(retval);
}

/* calculate distance between two points ("<->" operator) in SQL */
PG_FUNCTION_INFO_V1(pgl_epoint_distance);
Datum pgl_epoint_distance(PG_FUNCTION_ARGS) {
  pgl_point *point1 = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_point *point2 = (pgl_point *)PG_GETARG_POINTER(1);
  PG_RETURN_FLOAT8(pgl_distance(
    point1->lat, point1->lon, point2->lat, point2->lon
  ));
}

/* calculate point to circle distance ("<->" operator) in SQL */
PG_FUNCTION_INFO_V1(pgl_epoint_ecircle_distance);
Datum pgl_epoint_ecircle_distance(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_circle *circle = (pgl_circle *)PG_GETARG_POINTER(1);
  double distance = pgl_distance(
    point->lat, point->lon, circle->center.lat, circle->center.lon
  ) - circle->radius;
  PG_RETURN_FLOAT8((distance <= 0) ? 0 : distance);
}

/* calculate point to cluster distance ("<->" operator) in SQL */
PG_FUNCTION_INFO_V1(pgl_epoint_ecluster_distance);
Datum pgl_epoint_ecluster_distance(PG_FUNCTION_ARGS) {
  pgl_point *point = (pgl_point *)PG_GETARG_POINTER(0);
  pgl_cluster *cluster = (pgl_cluster *)PG_DETOAST_DATUM(PG_GETARG_DATUM(1));
  double distance = pgl_point_cluster_distance(point, cluster);
  PG_FREE_IF_COPY(cluster, 1);
  PG_RETURN_FLOAT8(distance);
}

/* calculate distance between two circles ("<->" operator) in SQL */
PG_FUNCTION_INFO_V1(pgl_ecircle_distance);
Datum pgl_ecircle_distance(PG_FUNCTION_ARGS) {
  pgl_circle *circle1 = (pgl_circle *)PG_GETARG_POINTER(0);
  pgl_circle *circle2 = (pgl_circle *)PG_GETARG_POINTER(1);
  double distance = pgl_distance(
    circle1->center.lat, circle1->center.lon,
    circle2->center.lat, circle2->center.lon
  ) - (circle1->radius + circle2->radius);
  PG_RETURN_FLOAT8((distance <= 0) ? 0 : distance);
}

/* calculate circle to cluster distance ("<->" operator) in SQL */
PG_FUNCTION_INFO_V1(pgl_ecircle_ecluster_distance);
Datum pgl_ecircle_ecluster_distance(PG_FUNCTION_ARGS) {
  pgl_circle *circle = (pgl_circle *)PG_GETARG_POINTER(0);
  pgl_cluster *cluster = (pgl_cluster *)PG_DETOAST_DATUM(PG_GETARG_DATUM(1));
  double distance = (
    pgl_point_cluster_distance(&(circle->center), cluster) - circle->radius
  );
  PG_FREE_IF_COPY(cluster, 1);
  PG_RETURN_FLOAT8((distance <= 0) ? 0 : distance);
}


/*-----------------------------------------------------------*
 *  B-tree comparison operators and index support functions  *
 *-----------------------------------------------------------*/

/* macro for a B-tree operator (without detoasting) */
#define PGL_BTREE_OPER(func, type, cmpfunc, oper) \
  PG_FUNCTION_INFO_V1(func); \
  Datum func(PG_FUNCTION_ARGS) { \
    type *a = (type *)PG_GETARG_POINTER(0); \
    type *b = (type *)PG_GETARG_POINTER(1); \
    PG_RETURN_BOOL(cmpfunc(a, b) oper 0); \
  }

/* macro for a B-tree comparison function (without detoasting) */
#define PGL_BTREE_CMP(func, type, cmpfunc) \
  PG_FUNCTION_INFO_V1(func); \
  Datum func(PG_FUNCTION_ARGS) { \
    type *a = (type *)PG_GETARG_POINTER(0); \
    type *b = (type *)PG_GETARG_POINTER(1); \
    PG_RETURN_INT32(cmpfunc(a, b)); \
  }

/* macro for a B-tree operator (with detoasting) */
#define PGL_BTREE_OPER_DETOAST(func, type, cmpfunc, oper) \
  PG_FUNCTION_INFO_V1(func); \
  Datum func(PG_FUNCTION_ARGS) { \
    bool res; \
    type *a = (type *)PG_DETOAST_DATUM(PG_GETARG_DATUM(0)); \
    type *b = (type *)PG_DETOAST_DATUM(PG_GETARG_DATUM(1)); \
    res = cmpfunc(a, b) oper 0; \
    PG_FREE_IF_COPY(a, 0); \
    PG_FREE_IF_COPY(b, 1); \
    PG_RETURN_BOOL(res); \
  }

/* macro for a B-tree comparison function (with detoasting) */
#define PGL_BTREE_CMP_DETOAST(func, type, cmpfunc) \
  PG_FUNCTION_INFO_V1(func); \
  Datum func(PG_FUNCTION_ARGS) { \
    int32_t res; \
    type *a = (type *)PG_DETOAST_DATUM(PG_GETARG_DATUM(0)); \
    type *b = (type *)PG_DETOAST_DATUM(PG_GETARG_DATUM(1)); \
    res = cmpfunc(a, b); \
    PG_FREE_IF_COPY(a, 0); \
    PG_FREE_IF_COPY(b, 1); \
    PG_RETURN_INT32(res); \
  }

/* B-tree operators and comparison function for point */
PGL_BTREE_OPER(pgl_btree_epoint_lt, pgl_point, pgl_point_cmp, <)
PGL_BTREE_OPER(pgl_btree_epoint_le, pgl_point, pgl_point_cmp, <=)
PGL_BTREE_OPER(pgl_btree_epoint_eq, pgl_point, pgl_point_cmp, ==)
PGL_BTREE_OPER(pgl_btree_epoint_ne, pgl_point, pgl_point_cmp, !=)
PGL_BTREE_OPER(pgl_btree_epoint_ge, pgl_point, pgl_point_cmp, >=)
PGL_BTREE_OPER(pgl_btree_epoint_gt, pgl_point, pgl_point_cmp, >)
PGL_BTREE_CMP(pgl_btree_epoint_cmp, pgl_point, pgl_point_cmp)

/* B-tree operators and comparison function for box */
PGL_BTREE_OPER(pgl_btree_ebox_lt, pgl_box, pgl_box_cmp, <)
PGL_BTREE_OPER(pgl_btree_ebox_le, pgl_box, pgl_box_cmp, <=)
PGL_BTREE_OPER(pgl_btree_ebox_eq, pgl_box, pgl_box_cmp, ==)
PGL_BTREE_OPER(pgl_btree_ebox_ne, pgl_box, pgl_box_cmp, !=)
PGL_BTREE_OPER(pgl_btree_ebox_ge, pgl_box, pgl_box_cmp, >=)
PGL_BTREE_OPER(pgl_btree_ebox_gt, pgl_box, pgl_box_cmp, >)
PGL_BTREE_CMP(pgl_btree_ebox_cmp, pgl_box, pgl_box_cmp)

/* B-tree operators and comparison function for circle */
PGL_BTREE_OPER(pgl_btree_ecircle_lt, pgl_circle, pgl_circle_cmp, <)
PGL_BTREE_OPER(pgl_btree_ecircle_le, pgl_circle, pgl_circle_cmp, <=)
PGL_BTREE_OPER(pgl_btree_ecircle_eq, pgl_circle, pgl_circle_cmp, ==)
PGL_BTREE_OPER(pgl_btree_ecircle_ne, pgl_circle, pgl_circle_cmp, !=)
PGL_BTREE_OPER(pgl_btree_ecircle_ge, pgl_circle, pgl_circle_cmp, >=)
PGL_BTREE_OPER(pgl_btree_ecircle_gt, pgl_circle, pgl_circle_cmp, >)
PGL_BTREE_CMP(pgl_btree_ecircle_cmp, pgl_circle, pgl_circle_cmp)


/*--------------------------------*
 *  GiST index support functions  *
 *--------------------------------*/

/* GiST "consistent" support function */
PG_FUNCTION_INFO_V1(pgl_gist_consistent);
Datum pgl_gist_consistent(PG_FUNCTION_ARGS) {
  GISTENTRY *entry = (GISTENTRY *) PG_GETARG_POINTER(0);
  pgl_keyptr key = (pgl_keyptr)DatumGetPointer(entry->key);
  StrategyNumber strategy = (StrategyNumber)PG_GETARG_UINT16(2);
  bool *recheck = (bool *)PG_GETARG_POINTER(4);
  /* demand recheck because index and query methods are lossy */
  *recheck = true;
  /* strategy number 11: equality of two points */
  if (strategy == 11) {
    /* query datum is another point */
    pgl_point *query = (pgl_point *)PG_GETARG_POINTER(1);
    /* convert other point to key */
    pgl_pointkey querykey;
    pgl_point_to_key(query, querykey);
    /* return true if both keys overlap */
    PG_RETURN_BOOL(pgl_keys_overlap(key, querykey));
  }
  /* strategy number 13: equality of two circles */
  if (strategy == 13) {
    /* query datum is another circle */
    pgl_circle *query = (pgl_circle *)PG_GETARG_POINTER(1);
    /* convert other circle to key */
    pgl_areakey querykey;
    pgl_circle_to_key(query, querykey);
    /* return true if both keys overlap */
    PG_RETURN_BOOL(pgl_keys_overlap(key, querykey));
  }
  /* for all remaining strategies, keys on empty objects produce no match */
  /* (check necessary because query radius may be infinite) */
  if (PGL_KEY_IS_EMPTY(key)) PG_RETURN_BOOL(false);
  /* strategy number 21: overlapping with point */
  if (strategy == 21) {
    /* query datum is a point */
    pgl_point *query = (pgl_point *)PG_GETARG_POINTER(1);
    /* return true if estimated distance (allowed to be smaller than real
       distance) between index key and point is zero */
    PG_RETURN_BOOL(pgl_estimate_key_distance(key, query) == 0);
  }
  /* strategy number 22: (point) overlapping with box */
  if (strategy == 22) {
    /* query datum is a box */
    pgl_box *query = (pgl_box *)PG_GETARG_POINTER(1);
    /* determine bounding box of indexed key */
    pgl_box keybox;
    pgl_key_to_box(key, &keybox);
    /* return true if query box overlaps with bounding box of indexed key */
    PG_RETURN_BOOL(pgl_boxes_overlap(query, &keybox));
  }
  /* strategy number 23: overlapping with circle */
  if (strategy == 23) {
    /* query datum is a circle */
    pgl_circle *query = (pgl_circle *)PG_GETARG_POINTER(1);
    /* return true if estimated distance (allowed to be smaller than real
       distance) between index key and circle center is smaller than radius */
    PG_RETURN_BOOL(
      pgl_estimate_key_distance(key, &(query->center)) <= query->radius
    );
  }
  /* strategy number 24: overlapping with cluster */
  if (strategy == 24) {
    bool retval;  /* return value */
    /* query datum is a cluster */
    pgl_cluster *query = (pgl_cluster *)PG_DETOAST_DATUM(PG_GETARG_DATUM(1));
    /* return true if estimated distance (allowed to be smaller than real
       distance) between index key and circle center is smaller than radius */
    retval = (
      pgl_estimate_key_distance(key, &(query->bounding.center)) <=
      query->bounding.radius
    );
    PG_FREE_IF_COPY(query, 1);  /* free detoasted cluster (if copy) */
    PG_RETURN_BOOL(retval);
  }
  /* throw error for any unknown strategy number */
  elog(ERROR, "unrecognized strategy number: %d", strategy);
}

/* GiST "union" support function */
PG_FUNCTION_INFO_V1(pgl_gist_union);
Datum pgl_gist_union(PG_FUNCTION_ARGS) {
  GistEntryVector *entryvec = (GistEntryVector *)PG_GETARG_POINTER(0);
  pgl_keyptr out;  /* return value (to be palloc'ed) */
  int i;
  /* determine key size */
  size_t keysize = PGL_KEY_IS_AREAKEY(
    (pgl_keyptr)DatumGetPointer(entryvec->vector[0].key)
  ) ? sizeof (pgl_areakey) : sizeof(pgl_pointkey);
  /* begin with first key as result */
  out = palloc(keysize);
  memcpy(out, (pgl_keyptr)DatumGetPointer(entryvec->vector[0].key), keysize);
  /* unite current result with second, third, etc. key */
  for (i=1; i<entryvec->n; i++) {
    pgl_unite_keys(out, (pgl_keyptr)DatumGetPointer(entryvec->vector[i].key));
  }
  /* return result */
  PG_RETURN_POINTER(out);
}

/* GiST "compress" support function for indicis on points */
PG_FUNCTION_INFO_V1(pgl_gist_compress_epoint);
Datum pgl_gist_compress_epoint(PG_FUNCTION_ARGS) {
  GISTENTRY *entry = (GISTENTRY *) PG_GETARG_POINTER(0);
  GISTENTRY *retval;  /* return value (to be palloc'ed unless set to entry) */
  /* only transform new leaves */
  if (entry->leafkey) {
    /* get point to be transformed */
    pgl_point *point = (pgl_point *)DatumGetPointer(entry->key);
    /* allocate memory for key */
    pgl_keyptr key = palloc(sizeof(pgl_pointkey));
    /* transform point to key */
    pgl_point_to_key(point, key);
    /* create new GISTENTRY structure as return value */
    retval = palloc(sizeof(GISTENTRY));
    gistentryinit(
      *retval, PointerGetDatum(key),
      entry->rel, entry->page, entry->offset, FALSE
    );
  } else {
    /* inner nodes have already been transformed */
    retval = entry;
  }
  /* return pointer to old or new GISTENTRY structure */
  PG_RETURN_POINTER(retval);
}

/* GiST "compress" support function for indicis on circles */
PG_FUNCTION_INFO_V1(pgl_gist_compress_ecircle);
Datum pgl_gist_compress_ecircle(PG_FUNCTION_ARGS) {
  GISTENTRY *entry = (GISTENTRY *) PG_GETARG_POINTER(0);
  GISTENTRY *retval;  /* return value (to be palloc'ed unless set to entry) */
  /* only transform new leaves */
  if (entry->leafkey) {
    /* get circle to be transformed */
    pgl_circle *circle = (pgl_circle *)DatumGetPointer(entry->key);
    /* allocate memory for key */
    pgl_keyptr key = palloc(sizeof(pgl_areakey));
    /* transform circle to key */
    pgl_circle_to_key(circle, key);
    /* create new GISTENTRY structure as return value */
    retval = palloc(sizeof(GISTENTRY));
    gistentryinit(
      *retval, PointerGetDatum(key),
      entry->rel, entry->page, entry->offset, FALSE
    );
  } else {
    /* inner nodes have already been transformed */
    retval = entry;
  }
  /* return pointer to old or new GISTENTRY structure */
  PG_RETURN_POINTER(retval);
}

/* GiST "compress" support function for indices on clusters */
PG_FUNCTION_INFO_V1(pgl_gist_compress_ecluster);
Datum pgl_gist_compress_ecluster(PG_FUNCTION_ARGS) {
  GISTENTRY *entry = (GISTENTRY *) PG_GETARG_POINTER(0);
  GISTENTRY *retval;  /* return value (to be palloc'ed unless set to entry) */
  /* only transform new leaves */
  if (entry->leafkey) {
    /* get cluster to be transformed (detoasting necessary!) */
    pgl_cluster *cluster = (pgl_cluster *)PG_DETOAST_DATUM(entry->key);
    /* allocate memory for key */
    pgl_keyptr key = palloc(sizeof(pgl_areakey));
    /* transform cluster to key */
    pgl_circle_to_key(&(cluster->bounding), key);
    /* create new GISTENTRY structure as return value */
    retval = palloc(sizeof(GISTENTRY));
    gistentryinit(
      *retval, PointerGetDatum(key),
      entry->rel, entry->page, entry->offset, FALSE
    );
    /* free detoasted datum */
    if ((void *)cluster != (void *)DatumGetPointer(entry->key)) pfree(cluster);
  } else {
    /* inner nodes have already been transformed */
    retval = entry;
  }
  /* return pointer to old or new GISTENTRY structure */
  PG_RETURN_POINTER(retval);
}

/* GiST "decompress" support function for indices */
PG_FUNCTION_INFO_V1(pgl_gist_decompress);
Datum pgl_gist_decompress(PG_FUNCTION_ARGS) {
  /* return passed pointer without transformation */
  PG_RETURN_POINTER(PG_GETARG_POINTER(0));
}

/* GiST "penalty" support function */
PG_FUNCTION_INFO_V1(pgl_gist_penalty);
Datum pgl_gist_penalty(PG_FUNCTION_ARGS) {
  GISTENTRY *origentry = (GISTENTRY *)PG_GETARG_POINTER(0);
  GISTENTRY *newentry = (GISTENTRY *)PG_GETARG_POINTER(1);
  float *penalty = (float *)PG_GETARG_POINTER(2);
  /* get original key and key to insert */
  pgl_keyptr orig = (pgl_keyptr)DatumGetPointer(origentry->key);
  pgl_keyptr new = (pgl_keyptr)DatumGetPointer(newentry->key);
  /* copy original key */
  union { pgl_pointkey pointkey; pgl_areakey areakey; } union_key;
  if (PGL_KEY_IS_AREAKEY(orig)) {
    memcpy(union_key.areakey, orig, sizeof(union_key.areakey));
  } else {
    memcpy(union_key.pointkey, orig, sizeof(union_key.pointkey));
  }
  /* calculate union of both keys */
  pgl_unite_keys((pgl_keyptr)&union_key, new);
  /* penalty equal to reduction of key length (logarithm of added area) */
  /* (return value by setting referenced value and returning pointer) */
  *penalty = (
    PGL_KEY_NODEDEPTH(orig) - PGL_KEY_NODEDEPTH((pgl_keyptr)&union_key)
  );
  PG_RETURN_POINTER(penalty);
}

/* GiST "picksplit" support function */
PG_FUNCTION_INFO_V1(pgl_gist_picksplit);
Datum pgl_gist_picksplit(PG_FUNCTION_ARGS) {
  GistEntryVector *entryvec = (GistEntryVector *)PG_GETARG_POINTER(0);
  GIST_SPLITVEC *v = (GIST_SPLITVEC *)PG_GETARG_POINTER(1);
  OffsetNumber i;  /* between FirstOffsetNumber and entryvec->n (inclusive) */
  union {
    pgl_pointkey pointkey;
    pgl_areakey areakey;
  } union_all;  /* union of all keys (to be calculated from scratch)
                   (later cut in half) */
  int is_areakey = PGL_KEY_IS_AREAKEY(
    (pgl_keyptr)DatumGetPointer(entryvec->vector[FirstOffsetNumber].key)
  );
  int keysize = is_areakey ? sizeof(pgl_areakey) : sizeof(pgl_pointkey);
  pgl_keyptr unionL = palloc(keysize);  /* union of keys that go left */
  pgl_keyptr unionR = palloc(keysize);  /* union of keys that go right */
  pgl_keyptr key;  /* current key to be processed */
  /* allocate memory for array of left and right keys, set counts to zero */
  v->spl_left = (OffsetNumber *)palloc(entryvec->n * sizeof(OffsetNumber));
  v->spl_nleft = 0;
  v->spl_right = (OffsetNumber *)palloc(entryvec->n * sizeof(OffsetNumber));
  v->spl_nright = 0;
  /* calculate union of all keys from scratch */
  memcpy(
    (pgl_keyptr)&union_all,
    (pgl_keyptr)DatumGetPointer(entryvec->vector[FirstOffsetNumber].key),
    keysize
  );
  for (i=FirstOffsetNumber+1; i<entryvec->n; i=OffsetNumberNext(i)) {
    pgl_unite_keys(
      (pgl_keyptr)&union_all,
      (pgl_keyptr)DatumGetPointer(entryvec->vector[i].key)
    );
  }
  /* check if trivial split is necessary due to exhausted key length */
  /* (Note: keys for empty objects must have node depth set to maximum) */
  if (PGL_KEY_NODEDEPTH((pgl_keyptr)&union_all) == (
    is_areakey ? PGL_AREAKEY_MAXDEPTH : PGL_POINTKEY_MAXDEPTH
  )) {
    /* half of all keys go left */
    for (
      i=FirstOffsetNumber;
      i<FirstOffsetNumber+(entryvec->n - FirstOffsetNumber)/2;
      i=OffsetNumberNext(i)
    ) {
      /* pointer to current key */
      key = (pgl_keyptr)DatumGetPointer(entryvec->vector[i].key);
      /* update unionL */
      /* check if key is first key that goes left */
      if (!v->spl_nleft) {
        /* first key that goes left is just copied to unionL */
        memcpy(unionL, key, keysize);
      } else {
        /* unite current value and next key */
        pgl_unite_keys(unionL, key);
      }
      /* append offset number to list of keys that go left */
      v->spl_left[v->spl_nleft++] = i;
    }
    /* other half goes right */
    for (
      i=FirstOffsetNumber+(entryvec->n - FirstOffsetNumber)/2;
      i<entryvec->n;
      i=OffsetNumberNext(i)
    ) {
      /* pointer to current key */
      key = (pgl_keyptr)DatumGetPointer(entryvec->vector[i].key);
      /* update unionR */
      /* check if key is first key that goes right */
      if (!v->spl_nright) {
        /* first key that goes right is just copied to unionR */
        memcpy(unionR, key, keysize);
      } else {
        /* unite current value and next key */
        pgl_unite_keys(unionR, key);
      }
      /* append offset number to list of keys that go right */
      v->spl_right[v->spl_nright++] = i;
    }
  }
  /* otherwise, a non-trivial split is possible */
  else {
    /* cut covered area in half */
    /* (union_all then refers to area of keys that go left) */
    /* check if union of all keys covers empty and non-empty objects */
    if (PGL_KEY_IS_UNIVERSAL((pgl_keyptr)&union_all)) {
      /* if yes, split into empty and non-empty objects */
      pgl_key_set_empty((pgl_keyptr)&union_all);
    } else {
      /* otherwise split by next bit */
      ((pgl_keyptr)&union_all)[PGL_KEY_NODEDEPTH_OFFSET]++;
      /* NOTE: type bit conserved */
    }
    /* determine for each key if it goes left or right */
    for (i=FirstOffsetNumber; i<entryvec->n; i=OffsetNumberNext(i)) {
      /* pointer to current key */
      key = (pgl_keyptr)DatumGetPointer(entryvec->vector[i].key);
      /* keys within one half of the area go left */
      if (pgl_keys_overlap((pgl_keyptr)&union_all, key)) {
        /* update unionL */
        /* check if key is first key that goes left */
        if (!v->spl_nleft) {
          /* first key that goes left is just copied to unionL */
          memcpy(unionL, key, keysize);
        } else {
          /* unite current value of unionL and processed key */
          pgl_unite_keys(unionL, key);
        }
        /* append offset number to list of keys that go left */
        v->spl_left[v->spl_nleft++] = i;
      }
      /* the other keys go right */
      else {
        /* update unionR */
        /* check if key is first key that goes right */
        if (!v->spl_nright) {
          /* first key that goes right is just copied to unionR */
          memcpy(unionR, key, keysize);
        } else {
          /* unite current value of unionR and processed key */
          pgl_unite_keys(unionR, key);
        }
        /* append offset number to list of keys that go right */
        v->spl_right[v->spl_nright++] = i;
      }
    }
  }
  /* store unions in return value */
  v->spl_ldatum = PointerGetDatum(unionL);
  v->spl_rdatum = PointerGetDatum(unionR);
  /* return all results */
  PG_RETURN_POINTER(v);
}

/* GiST "same"/"equal" support function */
PG_FUNCTION_INFO_V1(pgl_gist_same);
Datum pgl_gist_same(PG_FUNCTION_ARGS) {
  pgl_keyptr key1 = (pgl_keyptr)PG_GETARG_POINTER(0);
  pgl_keyptr key2 = (pgl_keyptr)PG_GETARG_POINTER(1);
  bool *boolptr = (bool *)PG_GETARG_POINTER(2);
  /* two keys are equal if they are binary equal */
  /* (return result by setting referenced boolean and returning pointer) */
  *boolptr = !memcmp(
    key1,
    key2,
    PGL_KEY_IS_AREAKEY(key1) ? sizeof(pgl_areakey) : sizeof(pgl_pointkey)
  );
  PG_RETURN_POINTER(boolptr);
}

/* GiST "distance" support function */
PG_FUNCTION_INFO_V1(pgl_gist_distance);
Datum pgl_gist_distance(PG_FUNCTION_ARGS) {
  GISTENTRY *entry = (GISTENTRY *)PG_GETARG_POINTER(0);
  pgl_keyptr key = (pgl_keyptr)DatumGetPointer(entry->key);
  StrategyNumber strategy = (StrategyNumber)PG_GETARG_UINT16(2);
  bool *recheck = (bool *)PG_GETARG_POINTER(4);
  double distance;  /* return value */
  /* demand recheck because distance is just an estimation */
  /* (real distance may be bigger) */
  *recheck = true;
  /* strategy number 31: distance to point */
  if (strategy == 31) {
    /* query datum is a point */
    pgl_point *query = (pgl_point *)PG_GETARG_POINTER(1);
    /* use pgl_estimate_pointkey_distance() function to compute result */
    distance = pgl_estimate_key_distance(key, query);
    /* avoid infinity (reserved!) */
    if (!isfinite(distance)) distance = PGL_ULTRA_DISTANCE;
    /* return result */
    PG_RETURN_FLOAT8(distance);
  }
  /* strategy number 33: distance to circle */
  if (strategy == 33) {
    /* query datum is a circle */
    pgl_circle *query = (pgl_circle *)PG_GETARG_POINTER(1);
    /* estimate distance to circle center and substract circle radius */
    distance = (
      pgl_estimate_key_distance(key, &(query->center)) - query->radius
    );
    /* convert non-positive values to zero and avoid infinity (reserved!) */
    if (distance <= 0) distance = 0;
    else if (!isfinite(distance)) distance = PGL_ULTRA_DISTANCE;
    /* return result */
    PG_RETURN_FLOAT8(distance);
  }
  /* strategy number 34: distance to cluster */
  if (strategy == 34) {
    /* query datum is a cluster */
    pgl_cluster *query = (pgl_cluster *)PG_DETOAST_DATUM(PG_GETARG_DATUM(1));
    /* estimate distance to bounding center and substract bounding radius */
    distance = (
      pgl_estimate_key_distance(key, &(query->bounding.center)) -
      query->bounding.radius
    );
    /* convert non-positive values to zero and avoid infinity (reserved!) */
    if (distance <= 0) distance = 0;
    else if (!isfinite(distance)) distance = PGL_ULTRA_DISTANCE;
    /* free detoasted cluster (if copy) */
    PG_FREE_IF_COPY(query, 1);
    /* return result */
    PG_RETURN_FLOAT8(distance);
  }
  /* throw error for any unknown strategy number */
  elog(ERROR, "unrecognized strategy number: %d", strategy);
}

