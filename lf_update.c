#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <libpq-fe.h>

#define exec_sql_error(message) do { \
    fprintf(stderr, message ": %s\n%s", command, PQresultErrorMessage(res)); \
    goto exec_sql_error_clear; \
  } while (0)

int exec_sql(PGconn *db, PGresult **resptr, int *errptr, int onerow, char *command) {
  int count = 0;
  PGresult *res = PQexec(db, command);
  if (!res) {
    fprintf(stderr, "Error in pqlib while sending the following SQL command: %s\n", command);
    goto exec_sql_error_exit;
  }
  if (
    PQresultStatus(res) != PGRES_COMMAND_OK &&
    PQresultStatus(res) != PGRES_TUPLES_OK
  ) exec_sql_error("Error while executing the following SQL command");
  if (resptr) {
    if (PQresultStatus(res) != PGRES_TUPLES_OK) exec_sql_error("The following SQL command returned no result");
    count = PQntuples(res);
    if (count < 0) exec_sql_error("The following SQL command returned too many rows");
    if (onerow) {
      if      (count < 1) exec_sql_error("The following SQL command returned less than one row");
      else if (count > 1) exec_sql_error("The following SQL command returned more than one row");
    }
    *resptr = res;
  } else {
    PQclear(res);
  }
  return count;
  exec_sql_error_clear:
  PQclear(res);
  exec_sql_error_exit:
  if (resptr) *resptr = NULL;
  if (errptr) *errptr = 1;
  return -1;
}

int main(int argc, char **argv) {

  // variable declarations:
  int err = 0;               /* set to 1 if any error occured */
  int admission_failed = 0;  /* set to 1 if error occurred during admission */
  int i, count;
  char *conninfo;
  PGconn *db;
  PGresult *res;

  // parse command line:
  if (argc == 0) return 1;
  if (argc == 1 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
    FILE *out;
    out = argc == 1 ? stderr : stdout;
    fprintf(out, "\n");
    fprintf(out, "Usage: %s <conninfo>\n", argv[0]);
    fprintf(out, "\n");
    fprintf(out, "<conninfo> is specified by PostgreSQL's libpq,\n");
    fprintf(out, "see http://www.postgresql.org/docs/9.6/static/libpq-connect.html\n");
    fprintf(out, "\n");
    fprintf(out, "Example: %s dbname=liquid_feedback\n", argv[0]);
    fprintf(out, "\n");
    return argc == 1 ? 1 : 0;
  }
  {
    size_t len = 0, seglen;
    for (i=1; i<argc; i++) {
      seglen = strlen(argv[i]) + 1;
      if (seglen >= SIZE_MAX/2 || len >= SIZE_MAX/2) {
        fprintf(stderr, "Error: Command line arguments too long\n");
        return 1;
      }
      len += seglen;
    }
    if (!len) len = 1;  // not needed but suppresses compiler warning
    conninfo = malloc(len * sizeof(char));
    if (!conninfo) {
      fprintf(stderr, "Error: Could not allocate memory for conninfo string\n");
      return 1;
    }
    conninfo[0] = 0;
    for (i=1; i<argc; i++) {
      if (i>1) strcat(conninfo, " ");
      strcat(conninfo, argv[i]);
    }
  }

  // connect to database:
  db = PQconnectdb(conninfo);
  if (!db) {
    fprintf(stderr, "Error: Could not create database handle\n");
    return 1;
  }
  if (PQstatus(db) != CONNECTION_OK) {
    fprintf(stderr, "Could not open connection:\n%s", PQerrorMessage(db));
    return 1;
  }

  // delete expired sessions:
  exec_sql(db, NULL, &err, 0, "DELETE FROM \"expired_session\"");

  // delete expired tokens and authorization codes:
  exec_sql(db, NULL, &err, 0, "DELETE FROM \"expired_token\"");
 
  // delete unused snapshots:
  exec_sql(db, NULL, &err, 0, "DELETE FROM \"unused_snapshot\"");
 
  // check member activity:
  exec_sql(db, NULL, &err, 0, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SELECT \"check_activity\"()");

  // calculate member counts:
  exec_sql(db, NULL, &err, 0, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; SELECT \"calculate_member_counts\"()");

  // issue admission:
  count = exec_sql(db, &res, &err, 0, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SELECT \"id\" FROM \"area_with_unaccepted_issues\"");
  if (!res) admission_failed = 1;
  else {
    char *area_id, *escaped_area_id, *cmd;
    PGresult *res2;
    for (i=0; i<count; i++) {
      area_id = PQgetvalue(res, i, 0);
      escaped_area_id = PQescapeLiteral(db, area_id, strlen(area_id));
      if (!escaped_area_id) {
        fprintf(stderr, "Could not escape literal in memory.\n");
        err = admission_failed = 1;
        continue;
      }
      if (asprintf(&cmd, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; SELECT \"take_snapshot\"(NULL, %s)", escaped_area_id) < 0) {
        fprintf(stderr, "Could not prepare query string in memory.\n");
        err = admission_failed = 1;
        PQfreemem(escaped_area_id);
        continue;
      }
      exec_sql(db, &res2, &err, 1, cmd);
      free(cmd);
      if (!res2) admission_failed = 1;
      else {
        char *snapshot_id, *escaped_snapshot_id;
        int j, count2;
        snapshot_id = PQgetvalue(res2, 0, 0);
        escaped_snapshot_id = PQescapeLiteral(db, snapshot_id, strlen(snapshot_id));
        PQclear(res2);
        if (!escaped_snapshot_id) {
          fprintf(stderr, "Could not escape literal in memory.\n");
          err = admission_failed = 1;
          goto area_admission_cleanup;
        }
        if (asprintf(&cmd, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SELECT \"issue_id\" FROM \"snapshot_issue\" WHERE \"snapshot_id\" = %s", escaped_snapshot_id) < 0) {
          fprintf(stderr, "Could not prepare query string in memory.\n");
          err = admission_failed = 1;
          PQfreemem(escaped_snapshot_id);
          goto area_admission_cleanup;
        }
        PQfreemem(escaped_snapshot_id);
        count2 = exec_sql(db, &res2, &err, 0, cmd);
        free(cmd);
        if (!res2) admission_failed = 1;
        else {
          char *issue_id, *escaped_issue_id;
          for (j=0; j<count2; j++) {
            issue_id = PQgetvalue(res2, j, 0);
            escaped_issue_id = PQescapeLiteral(db, issue_id, strlen(issue_id));
            if (!escaped_issue_id) {
              fprintf(stderr, "Could not escape literal in memory.\n");
              err = admission_failed = 1;
              continue;
            }
            if (asprintf(&cmd, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SELECT \"finish_snapshot\"(%s)", escaped_issue_id) < 0) {
              fprintf(stderr, "Could not prepare query string in memory.\n");
              err = admission_failed = 1;
              PQfreemem(escaped_issue_id);
              continue;
            }
            PQfreemem(escaped_issue_id);
            if (exec_sql(db, NULL, &err, 0, cmd) < 0) admission_failed = 1;
            free(cmd);
          }
          PQclear(res2);
        }
        if (!admission_failed) {
          if (asprintf(&cmd, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SELECT \"issue_admission\"(%s)", escaped_area_id) < 0) {
            fprintf(stderr, "Could not prepare query string in memory.\n");
            err = admission_failed = 1;
            goto area_admission_cleanup;
          }
        }
        while (1) {
          exec_sql(db, &res2, &err, 1, cmd);
          if (!res2) {
            admission_failed = 1;
            break;
          }
          if (PQgetvalue(res2, 0, 0)[0] != 't') {
            PQclear(res2);
            break;
          }
          PQclear(res2);
        }
      }
      area_admission_cleanup:
      PQfreemem(escaped_area_id);
    }
    PQclear(res);
  }

  // update open issues:
  count = exec_sql(
    db, &res, &err, 0,
    admission_failed ?
    "SELECT \"id\" FROM \"open_issue\" WHERE \"state\" != 'admission'::\"issue_state\"" :
    "SELECT \"id\" FROM \"open_issue\""
  );
  for (i=0; i<count; i++) {
    char *issue_id, *escaped_issue_id;
    PGresult *res2, *old_res2;
    int j;
    issue_id = PQgetvalue(res, i, 0);
    escaped_issue_id = PQescapeLiteral(db, issue_id, strlen(issue_id));
    if (!escaped_issue_id) {
      fprintf(stderr, "Could not escape literal in memory.\n");
      err = 1;
      continue;
    }
    old_res2 = NULL;
    for (j=0; ; j++) {
      if (j >= 20) {  // safety to avoid endless loops
        fprintf(stderr, "Function \"check_issue\"(...) returned non-null value too often.\n");
        err = 1;
        if (j > 0) PQclear(old_res2);
        break;
      }
      if (j == 0) {
        char *cmd;
        if (asprintf(&cmd, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; SELECT \"check_issue\"(%s, NULL)", escaped_issue_id) < 0) {
          fprintf(stderr, "Could not prepare query string in memory.\n");
          err = 1;
          break;
        }
        exec_sql(db, &res2, &err, 1, cmd);
        free(cmd);
      } else {
        char *persist, *escaped_persist, *cmd;
        persist = PQgetvalue(old_res2, 0, 0);
        escaped_persist = PQescapeLiteral(db, persist, strlen(persist));
        if (!escaped_persist) {
          fprintf(stderr, "Could not escape literal in memory.\n");
          err = 1;
          PQclear(old_res2);
          break;
        }
        if (asprintf(&cmd, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; SELECT \"check_issue\"(%s, %s::\"check_issue_persistence\")", escaped_issue_id, escaped_persist) < 0) {
          PQfreemem(escaped_persist);
          fprintf(stderr, "Could not prepare query string in memory.\n");
          err = 1;
          PQclear(old_res2);
          break;
        }
        PQfreemem(escaped_persist);
        exec_sql(db, &res2, &err, 1, cmd);
        free(cmd);
        PQclear(old_res2);
      }
      if (!res2) break;
      if (PQgetisnull(res2, 0, 0)) {
        PQclear(res2);
        break;
      }
      old_res2 = res2;
    }
    PQfreemem(escaped_issue_id);
  }
  if (res) PQclear(res);

  // delete unused snapshots:
  exec_sql(db, NULL, &err, 0, "DELETE FROM \"unused_snapshot\"");

   // cleanup and exit:
  PQfinish(db);
  return err;

}
