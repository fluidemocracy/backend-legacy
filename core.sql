
CREATE LANGUAGE plpgsql;  -- Triggers are implemented in PL/pgSQL

-- NOTE: In PostgreSQL every UNIQUE constraint implies creation of an index

BEGIN;



-------------------------
-- Tables and indicies --
-------------------------


CREATE TABLE "member" (
        "id"                    SERIAL4         PRIMARY KEY,
        "login"                 TEXT            NOT NULL UNIQUE,
        "password"              TEXT,
        "active"                BOOLEAN         NOT NULL DEFAULT TRUE,
        "admin"                 BOOLEAN         NOT NULL DEFAULT FALSE,
        "name"                  TEXT,
        "ident_number"          TEXT            UNIQUE );
CREATE INDEX "member_active_idx" ON "member" ("active");

COMMENT ON TABLE "member" IS 'Users of the system, e.g. members of an organization';

COMMENT ON COLUMN "member"."login"        IS 'Login name';
COMMENT ON COLUMN "member"."password"     IS 'Password (preferably as crypto-hash, depending on the frontend or access layer)';
COMMENT ON COLUMN "member"."active"       IS 'Inactive members can not login and their supports/votes are not counted by the system.';
COMMENT ON COLUMN "member"."ident_number" IS 'Additional information about the members idenficication number within the organization';


CREATE TABLE "contact" (
        PRIMARY KEY ("member_id", "other_member_id"),
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "other_member_id"       INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "public"                BOOLEAN         NOT NULL DEFAULT FALSE );

COMMENT ON TABLE "contact" IS 'Contact lists';

COMMENT ON COLUMN "contact"."member_id"       IS 'Member having the contact list';
COMMENT ON COLUMN "contact"."other_member_id" IS 'Member referenced in the contact list';
COMMENT ON COLUMN "contact"."public"          IS 'TRUE = display contact publically';


CREATE TABLE "session" (
        "ident"                 TEXT            PRIMARY KEY,
        "additional_secret"     TEXT,
        "expiry"                TIMESTAMPTZ     NOT NULL DEFAULT now() + '24 hours',
        "member_id"             INT8            REFERENCES "member" ("id") ON DELETE SET NULL,
        "lang"                  TEXT );
CREATE INDEX "session_expiry_idx" ON "session" ("expiry");

COMMENT ON TABLE "session" IS 'Sessions, i.e. for a web-frontend';

COMMENT ON COLUMN "session"."ident"             IS 'Secret session identifier (i.e. random string)';
COMMENT ON COLUMN "session"."additional_secret" IS 'Additional field to store a secret, which can be used against CSRF attacks';
COMMENT ON COLUMN "session"."member_id"         IS 'Reference to member, who is logged in';
COMMENT ON COLUMN "session"."lang"              IS 'Language code of the selected language';


CREATE TABLE "policy" (
        "id"                    SERIAL4         PRIMARY KEY,
        "active"                BOOLEAN         NOT NULL DEFAULT TRUE,
        "name"                  TEXT            NOT NULL UNIQUE,
        "description"           TEXT            NOT NULL DEFAULT '',
        "admission_time"        INTERVAL        NOT NULL,
        "discussion_time"       INTERVAL        NOT NULL,
        "voting_time"           INTERVAL        NOT NULL,
        "issue_quorum_num"      INT4            NOT NULL,
        "issue_quorum_den"      INT4            NOT NULL,
        "initiative_quorum_num" INT4            NOT NULL,
        "initiative_quorum_den" INT4            NOT NULL );
CREATE INDEX "policy_active_idx" ON "policy" ("active");

COMMENT ON TABLE "policy" IS 'Policies for a particular proceeding type (timelimits, quorum)';

COMMENT ON COLUMN "policy"."active"                IS 'TRUE = policy can be used for new issues';
COMMENT ON COLUMN "policy"."admission_time"        IS 'Maximum time an issue stays open without being "accepted"';
COMMENT ON COLUMN "policy"."discussion_time"       IS 'Regular time until an issue is "frozen" after being "accepted"';
COMMENT ON COLUMN "policy"."voting_time"           IS 'Time after an issue is "frozen" but not "closed"';
COMMENT ON COLUMN "policy"."issue_quorum_num"      IS 'Numerator of quorum to be reached by one initiative of an issue to be "accepted"';
COMMENT ON COLUMN "policy"."issue_quorum_den"      IS 'Denominator of quorum to be reached by one initiative of an issue to be "accepted"';
COMMENT ON COLUMN "policy"."initiative_quorum_num" IS 'Numerator of quorum to be reached by an initiative to be "admitted" for voting';
COMMENT ON COLUMN "policy"."initiative_quorum_den" IS 'Denominator of quorum to be reached by an initiative to be "admitted" for voting';


CREATE TABLE "area" (
        "id"                    SERIAL4         PRIMARY KEY,
        "active"                BOOLEAN         NOT NULL DEFAULT TRUE,
        "name"                  TEXT            NOT NULL,
        "description"           TEXT            NOT NULL DEFAULT '' );
CREATE INDEX "area_active_idx" ON "area" ("active");

COMMENT ON TABLE "area" IS 'Subject areas';

COMMENT ON COLUMN "area"."active" IS 'TRUE means new issues can be created in this area';


CREATE TABLE "issue" (
        "id"                    SERIAL4         PRIMARY KEY,
        "area_id"               INT4            NOT NULL REFERENCES "area" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "policy_id"             INT4            NOT NULL REFERENCES "policy" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "created"               TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "accepted"              TIMESTAMPTZ,
        "frozen"                TIMESTAMPTZ,
        "closed"                TIMESTAMPTZ,
        "ranks_available"       BOOLEAN         NOT NULL DEFAULT FALSE,
        "snapshot"              TIMESTAMPTZ,
        "population"            INT4,
        "vote_now"              INT4,
        "vote_later"            INT4,
        CONSTRAINT "valid_state" CHECK (
          ("accepted" ISNULL  AND "frozen" ISNULL  AND "closed" ISNULL  AND "ranks_available" = FALSE) OR
          ("accepted" ISNULL  AND "frozen" ISNULL  AND "closed" NOTNULL AND "ranks_available" = FALSE) OR
          ("accepted" NOTNULL AND "frozen" ISNULL  AND "closed" ISNULL  AND "ranks_available" = FALSE) OR
          ("accepted" NOTNULL AND "frozen" NOTNULL AND "closed" ISNULL  AND "ranks_available" = FALSE) OR
          ("accepted" NOTNULL AND "frozen" NOTNULL AND "closed" NOTNULL AND "ranks_available" = FALSE) OR
          ("accepted" NOTNULL AND "frozen" NOTNULL AND "closed" NOTNULL AND "ranks_available" = TRUE) ),
        CONSTRAINT "state_change_order" CHECK ("created" <= "accepted" AND "accepted" <= "frozen" AND "frozen" <= "closed"),
        CONSTRAINT "last_snapshot_on_freeze" CHECK ("snapshot" = "frozen"),  -- NOTE: snapshot can be set, while frozen is NULL yet
        CONSTRAINT "freeze_requires_snapshot" CHECK ("frozen" ISNULL OR "snapshot" NOTNULL) );
CREATE INDEX "issue_area_id_idx" ON "issue" ("area_id");
CREATE INDEX "issue_policy_id_idx" ON "issue" ("policy_id");
CREATE INDEX "issue_created_idx_open" ON "issue" ("created") WHERE "closed" ISNULL;

COMMENT ON TABLE "issue" IS 'Groups of initiatives';

COMMENT ON COLUMN "issue"."accepted"        IS 'Point in time, when one initiative of issue reached the "issue_quorum"';
COMMENT ON COLUMN "issue"."frozen"          IS 'Point in time, when "discussion_time" has elapsed, or members voted for voting.';
COMMENT ON COLUMN "issue"."closed"          IS 'Point in time, when "admission_time" or "voting_time" is over, and issue is no longer active';
COMMENT ON COLUMN "issue"."ranks_available" IS 'TRUE = ranks have been calculated';
COMMENT ON COLUMN "issue"."snapshot"        IS 'Point in time, when snapshot tables have been updated and "population", "vote_now", "vote_later" and *_count values were precalculated';
COMMENT ON COLUMN "issue"."population"      IS 'Calculated from table "direct_population_snapshot"';
COMMENT ON COLUMN "issue"."vote_now"        IS 'Calculated from table "direct_interest_snapshot"';
COMMENT ON COLUMN "issue"."vote_later"      IS 'Calculated from table "direct_interest_snapshot"';


CREATE TABLE "initiative" (
        UNIQUE ("issue_id", "id"),  -- index needed for foreign-key on table "vote"
        "issue_id"              INT4            NOT NULL REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "id"                    SERIAL4         PRIMARY KEY,
        "name"                  TEXT            NOT NULL,
        "created"               TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "revoked"               TIMESTAMPTZ,
        "admitted"              BOOLEAN,
        "supporter_count"                    INT4,
        "informed_supporter_count"           INT4,
        "satisfied_supporter_count"          INT4,
        "satisfied_informed_supporter_count" INT4,
        "positive_votes"        INT4,
        "negative_votes"        INT4,
        "rank"                  INT4,
        CONSTRAINT "revoked_initiatives_cant_be_admitted"
          CHECK ("revoked" ISNULL OR "admitted" ISNULL),
        CONSTRAINT "non_admitted_initiatives_cant_contain_voting_results"
          CHECK ("admitted" = TRUE OR ("positive_votes" ISNULL AND "negative_votes" ISNULL AND "rank" ISNULL)) );

COMMENT ON TABLE "initiative" IS 'Group of members publishing drafts for resolutions to be passed';

COMMENT ON COLUMN "initiative"."revoked"        IS 'Point in time, when one initiator decided to revoke the initiative';
COMMENT ON COLUMN "initiative"."admitted"       IS 'True, if initiative reaches the "initiative_quorum" when freezing the issue';
COMMENT ON COLUMN "initiative"."supporter_count"                    IS 'Calculated from table "direct_supporter_snapshot"';
COMMENT ON COLUMN "initiative"."informed_supporter_count"           IS 'Calculated from table "direct_supporter_snapshot"';
COMMENT ON COLUMN "initiative"."satisfied_supporter_count"          IS 'Calculated from table "direct_supporter_snapshot"';
COMMENT ON COLUMN "initiative"."satisfied_informed_supporter_count" IS 'Calculated from table "direct_supporter_snapshot"';
COMMENT ON COLUMN "initiative"."positive_votes" IS 'Calculated from table "direct_voter"';
COMMENT ON COLUMN "initiative"."negative_votes" IS 'Calculated from table "direct_voter"';
COMMENT ON COLUMN "initiative"."rank"           IS 'Rank of approved initiatives (winner is 1), calculated from table "direct_voter"';


CREATE TABLE "draft" (
        UNIQUE ("initiative_id", "id"),  -- index needed for foreign-key on table "supporter"
        "initiative_id"         INT4            NOT NULL REFERENCES "initiative" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "id"                    SERIAL8         PRIMARY KEY,
        "created"               TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "author_id"             INT4            NOT NULL REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "content"               TEXT            NOT NULL );

COMMENT ON TABLE "draft" IS 'Drafts of initiatives to solve issues';


CREATE TABLE "suggestion" (
        UNIQUE ("initiative_id", "id"),  -- index needed for foreign-key on table "opinion"
        "initiative_id"         INT4            NOT NULL REFERENCES "initiative" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "id"                    SERIAL8         PRIMARY KEY,
        "created"               TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "author_id"             INT4            NOT NULL REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "name"                  TEXT            NOT NULL,
        "description"           TEXT            NOT NULL DEFAULT '',
        "minus2_unfulfilled_count" INT4,
        "minus2_fulfilled_count"   INT4,
        "minus1_unfulfilled_count" INT4,
        "minus1_fulfilled_count"   INT4,
        "plus1_unfulfilled_count"  INT4,
        "plus1_fulfilled_count"    INT4,
        "plus2_unfulfilled_count"  INT4,
        "plus2_fulfilled_count"    INT4 );

COMMENT ON TABLE "suggestion" IS 'Suggestions to initiators, to change the current draft';

COMMENT ON COLUMN "suggestion"."minus2_unfulfilled_count" IS 'Calculated from table "direct_supporter_snapshot", not requiring informed supporters';
COMMENT ON COLUMN "suggestion"."minus2_fulfilled_count"   IS 'Calculated from table "direct_supporter_snapshot", not requiring informed supporters';
COMMENT ON COLUMN "suggestion"."minus1_unfulfilled_count" IS 'Calculated from table "direct_supporter_snapshot", not requiring informed supporters';
COMMENT ON COLUMN "suggestion"."minus1_fulfilled_count"   IS 'Calculated from table "direct_supporter_snapshot", not requiring informed supporters';
COMMENT ON COLUMN "suggestion"."plus1_unfulfilled_count"  IS 'Calculated from table "direct_supporter_snapshot", not requiring informed supporters';
COMMENT ON COLUMN "suggestion"."plus1_fulfilled_count"    IS 'Calculated from table "direct_supporter_snapshot", not requiring informed supporters';
COMMENT ON COLUMN "suggestion"."plus2_unfulfilled_count"  IS 'Calculated from table "direct_supporter_snapshot", not requiring informed supporters';
COMMENT ON COLUMN "suggestion"."plus2_fulfilled_count"    IS 'Calculated from table "direct_supporter_snapshot", not requiring informed supporters';


CREATE TABLE "membership" (
        PRIMARY KEY ("area_id", "member_id"),
        "area_id"               INT4            REFERENCES "area" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "autoreject"            BOOLEAN         NOT NULL DEFAULT FALSE );
CREATE INDEX "membership_member_id_idx" ON "membership" ("member_id");

COMMENT ON TABLE "membership" IS 'Interest of members in topic areas';

COMMENT ON COLUMN "membership"."autoreject" IS 'TRUE = member votes against all initiatives in case of not explicitly taking part in the voting procedure; If there exists an "interest" entry, the interest entry has precedence';


CREATE TABLE "interest" (
        PRIMARY KEY ("issue_id", "member_id"),
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "autoreject"            BOOLEAN         NOT NULL,
        "voting_requested"      BOOLEAN );
CREATE INDEX "interest_member_id_idx" ON "interest" ("member_id");

COMMENT ON TABLE "interest" IS 'Interest of members in a particular issue';

COMMENT ON COLUMN "interest"."autoreject"       IS 'TRUE = member votes against all initiatives in case of not explicitly taking part in the voting procedure';
COMMENT ON COLUMN "interest"."voting_requested" IS 'TRUE = member wants to vote now, FALSE = member wants to vote later, NULL = policy rules should apply';


CREATE TABLE "initiator" (
        PRIMARY KEY ("initiative_id", "member_id"),
        "initiative_id"         INT4            REFERENCES "initiative" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "accepted"              BOOLEAN         NOT NULL DEFAULT TRUE );
CREATE INDEX "initiator_member_id_idx" ON "initiator" ("member_id");

COMMENT ON TABLE "initiator" IS 'Members who are allowed to post new drafts';

COMMENT ON COLUMN "initiator"."accepted" IS 'If "accepted" = FALSE, then the member was invited to be a co-initiator, but has not answered yet.';


CREATE TABLE "supporter" (
        "issue_id"              INT4            NOT NULL,
        PRIMARY KEY ("initiative_id", "member_id"),
        "initiative_id"         INT4,
        "member_id"             INT4,
        "draft_id"              INT8            NOT NULL,
        FOREIGN KEY ("issue_id", "member_id") REFERENCES "interest" ("issue_id", "member_id") ON DELETE RESTRICT ON UPDATE CASCADE,
        FOREIGN KEY ("initiative_id", "draft_id") REFERENCES "draft" ("initiative_id", "id") ON DELETE CASCADE ON UPDATE CASCADE );
CREATE INDEX "supporter_member_id_idx" ON "supporter" ("member_id");

COMMENT ON TABLE "supporter" IS 'Members who support an initiative (conditionally)';

COMMENT ON COLUMN "supporter"."draft_id" IS 'Latest seen draft';


CREATE TABLE "opinion" (
        "initiative_id"         INT4            NOT NULL,
        PRIMARY KEY ("suggestion_id", "member_id"),
        "suggestion_id"         INT8,
        "member_id"             INT4,
        "degree"                INT2            NOT NULL CHECK ("degree" >= -2 AND "degree" <= 2 AND "degree" != 0),
        "fulfilled"             BOOLEAN         NOT NULL DEFAULT FALSE,
        FOREIGN KEY ("initiative_id", "suggestion_id") REFERENCES "suggestion" ("initiative_id", "id") ON DELETE RESTRICT ON UPDATE CASCADE,
        FOREIGN KEY ("initiative_id", "member_id") REFERENCES "supporter" ("initiative_id", "member_id") ON DELETE CASCADE ON UPDATE CASCADE );
CREATE INDEX "opinion_member_id_idx" ON "opinion" ("member_id");

COMMENT ON TABLE "opinion" IS 'Opinion on suggestions (criticism related to initiatives)';

COMMENT ON COLUMN "opinion"."degree" IS '2 = fulfillment required for support; 1 = fulfillment desired; -1 = fulfillment unwanted; -2 = fulfillment cancels support';


CREATE TABLE "delegation" (
        "id"                    SERIAL8         PRIMARY KEY,
        "truster_id"            INT4            NOT NULL REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "trustee_id"            INT4            NOT NULL REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "area_id"               INT4            REFERENCES "area" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        CONSTRAINT "cant_delegate_to_yourself" CHECK ("truster_id" != "trustee_id"),
        CONSTRAINT "area_id_or_issue_id_can_be_set_but_not_both" CHECK ("area_id" ISNULL OR "issue_id" ISNULL),
        UNIQUE ("area_id", "truster_id", "trustee_id"),
        UNIQUE ("issue_id", "truster_id", "trustee_id") );
CREATE UNIQUE INDEX "delegation_default_truster_id_trustee_id_unique_idx"
  ON "delegation" ("truster_id", "trustee_id")
  WHERE "area_id" ISNULL AND "issue_id" ISNULL;
CREATE INDEX "delegation_truster_id_idx" ON "delegation" ("truster_id");
CREATE INDEX "delegation_trustee_id_idx" ON "delegation" ("trustee_id");

COMMENT ON TABLE "delegation" IS 'Delegation of vote-weight to other members';

COMMENT ON COLUMN "delegation"."area_id"  IS 'Reference to area, if delegation is area-wide, otherwise NULL';
COMMENT ON COLUMN "delegation"."issue_id" IS 'Reference to issue, if delegation is issue-wide, otherwise NULL';


CREATE TYPE "snapshot_event" AS ENUM ('periodic', 'end_of_admission', 'end_of_discussion');

COMMENT ON TYPE "snapshot_event" IS 'Reason for snapshots: ''periodic'' = due to periodic recalculation, ''end_of_admission'' = saved state at end of admission period, ''end_of_discussion'' = saved state at end of discussion period';


CREATE TABLE "direct_population_snapshot" (
        PRIMARY KEY ("issue_id", "event", "member_id"),
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "event"                 "snapshot_event",
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "weight"                INT4,
        "interest_exists"       BOOLEAN         NOT NULL );
CREATE INDEX "direct_population_snapshot_member_id_idx" ON "direct_population_snapshot" ("member_id");

COMMENT ON TABLE "direct_population_snapshot" IS 'Snapshot of active members having either a "membership" in the "area" or an "interest" in the "issue"';

COMMENT ON COLUMN "direct_population_snapshot"."event"           IS 'Reason for snapshot, see "snapshot_event" type for details';
COMMENT ON COLUMN "direct_population_snapshot"."weight"          IS 'Weight of member (1 or higher) according to "delegating_population_snapshot"';
COMMENT ON COLUMN "direct_population_snapshot"."interest_exists" IS 'TRUE if entry is due to interest in issue, FALSE if entry is only due to membership in area';


CREATE TABLE "delegating_population_snapshot" (
        PRIMARY KEY ("issue_id", "event", "member_id"),
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "event"                "snapshot_event",
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "delegate_member_ids"   INT4[]          NOT NULL );
CREATE INDEX "delegating_population_snapshot_member_id_idx" ON "delegating_population_snapshot" ("member_id");

COMMENT ON TABLE "direct_population_snapshot" IS 'Delegations increasing the weight of entries in the "direct_population_snapshot" table';

COMMENT ON COLUMN "delegating_population_snapshot"."event"               IS 'Reason for snapshot, see "snapshot_event" type for details';
COMMENT ON COLUMN "delegating_population_snapshot"."member_id"           IS 'Delegating member';
COMMENT ON COLUMN "delegating_population_snapshot"."delegate_member_ids" IS 'Chain of members who act as delegates; last entry referes to "member_id" column of table "direct_population_snapshot"';


CREATE TABLE "direct_interest_snapshot" (
        PRIMARY KEY ("issue_id", "event", "member_id"),
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "event"                 "snapshot_event",
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "weight"                INT4,
        "voting_requested"      BOOLEAN );
CREATE INDEX "direct_interest_snapshot_member_id_idx" ON "direct_interest_snapshot" ("member_id");

COMMENT ON TABLE "direct_interest_snapshot" IS 'Snapshot of active members having an "interest" in the "issue"';

COMMENT ON COLUMN "direct_interest_snapshot"."event"            IS 'Reason for snapshot, see "snapshot_event" type for details';
COMMENT ON COLUMN "direct_interest_snapshot"."weight"           IS 'Weight of member (1 or higher) according to "delegating_interest_snapshot"';
COMMENT ON COLUMN "direct_interest_snapshot"."voting_requested" IS 'Copied from column "voting_requested" of table "interest"';


CREATE TABLE "delegating_interest_snapshot" (
        PRIMARY KEY ("issue_id", "event", "member_id"),
        "issue_id"         INT4                 REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "event"                "snapshot_event",
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "delegate_member_ids"   INT4[]          NOT NULL );
CREATE INDEX "delegating_interest_snapshot_member_id_idx" ON "delegating_interest_snapshot" ("member_id");

COMMENT ON TABLE "delegating_interest_snapshot" IS 'Delegations increasing the weight of entries in the "direct_interest_snapshot" table';

COMMENT ON COLUMN "delegating_interest_snapshot"."event"               IS 'Reason for snapshot, see "snapshot_event" type for details';
COMMENT ON COLUMN "delegating_interest_snapshot"."member_id"           IS 'Delegating member';
COMMENT ON COLUMN "delegating_interest_snapshot"."delegate_member_ids" IS 'Chain of members who act as delegates; last entry referes to "member_id" column of table "direct_interest_snapshot"';


CREATE TABLE "direct_supporter_snapshot" (
        "issue_id"              INT4            NOT NULL,
        PRIMARY KEY ("initiative_id", "event", "member_id"),
        "initiative_id"         INT4,
        "event"                 "snapshot_event",
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "informed"              BOOLEAN         NOT NULL,
        "satisfied"             BOOLEAN         NOT NULL,
        FOREIGN KEY ("issue_id", "initiative_id") REFERENCES "initiative" ("issue_id", "id") ON DELETE CASCADE ON UPDATE CASCADE,
        FOREIGN KEY ("issue_id", "event", "member_id") REFERENCES "direct_interest_snapshot" ("issue_id", "event", "member_id") ON DELETE CASCADE ON UPDATE CASCADE );
CREATE INDEX "direct_supporter_snapshot_member_id_idx" ON "direct_supporter_snapshot" ("member_id");

COMMENT ON TABLE "direct_supporter_snapshot" IS 'Snapshot of supporters of initiatives (weight is stored in "direct_interest_snapshot)';

COMMENT ON COLUMN "direct_supporter_snapshot"."event"     IS 'Reason for snapshot, see "snapshot_event" type for details';
COMMENT ON COLUMN "direct_supporter_snapshot"."informed"  IS 'Supporter has seen the latest draft of the initiative';
COMMENT ON COLUMN "direct_supporter_snapshot"."satisfied" IS 'Supporter has no "critical_opinion"s';


CREATE TABLE "direct_voter" (
        PRIMARY KEY ("issue_id", "member_id"),
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "weight"                INT4,
        "autoreject"            BOOLEAN         NOT NULL DEFAULT FALSE );
CREATE INDEX "direct_voter_member_id_idx" ON "direct_voter" ("member_id");

COMMENT ON TABLE "direct_voter" IS 'Members having directly voted for/against initiatives of an issue';

COMMENT ON COLUMN "direct_voter"."weight"     IS 'Weight of member (1 or higher) according to "delegating_voter" table';
COMMENT ON COLUMN "direct_voter"."autoreject" IS 'Votes were inserted due to "autoreject" feature';


CREATE TABLE "delegating_voter" (
        PRIMARY KEY ("issue_id", "member_id"),
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "delegate_member_ids"   INT4[]          NOT NULL );
CREATE INDEX "delegating_voter_member_id_idx" ON "direct_voter" ("member_id");

COMMENT ON TABLE "delegating_voter" IS 'Delegations increasing the weight of entries in the "direct_voter" table';

COMMENT ON COLUMN "delegating_voter"."member_id"           IS 'Delegating member';
COMMENT ON COLUMN "delegating_voter"."delegate_member_ids" IS 'Chain of members who act as delegates; last entry referes to "member_id" column of table "direct_voter"';


CREATE TABLE "vote" (
        "issue_id"              INT4            NOT NULL,
        PRIMARY KEY ("initiative_id", "member_id"),
        "initiative_id"         INT4,
        "member_id"             INT4,
        "grade"                 INT4,
        FOREIGN KEY ("issue_id", "initiative_id") REFERENCES "initiative" ("issue_id", "id") ON DELETE CASCADE ON UPDATE CASCADE,
        FOREIGN KEY ("issue_id", "member_id") REFERENCES "direct_voter" ("issue_id", "member_id") ON DELETE CASCADE ON UPDATE CASCADE );
CREATE INDEX "vote_member_id_idx" ON "vote" ("member_id");

COMMENT ON TABLE "vote" IS 'Manual and delegated votes without abstentions';

COMMENT ON COLUMN "vote"."grade" IS 'Values smaller than zero mean reject, values greater than zero mean acceptance, zero or missing row means abstention. Preferences are expressed by different positive or negative numbers.';



----------------------------
-- Additional constraints --
----------------------------


CREATE FUNCTION "issue_requires_first_initiative_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT NULL FROM "initiative" WHERE "issue_id" = NEW."id"
      ) THEN
        --RAISE 'Cannot create issue without an initial initiative.' USING
        --  ERRCODE = 'integrity_constraint_violation',
        --  HINT    = 'Create issue, initiative, and draft within the same transaction.';
        RAISE EXCEPTION 'Cannot create issue without an initial initiative.';
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE CONSTRAINT TRIGGER "issue_requires_first_initiative"
  AFTER INSERT OR UPDATE ON "issue" DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE PROCEDURE
  "issue_requires_first_initiative_trigger"();

COMMENT ON FUNCTION "issue_requires_first_initiative_trigger"() IS 'Implementation of trigger "issue_requires_first_initiative" on table "issue"';
COMMENT ON TRIGGER "issue_requires_first_initiative" ON "issue" IS 'Ensure that new issues have at least one initiative';


CREATE FUNCTION "last_initiative_deletes_issue_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "reference_lost" BOOLEAN;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        "reference_lost" := TRUE;
      ELSE
        "reference_lost" := NEW."issue_id" != OLD."issue_id";
      END IF;
      IF
        "reference_lost" AND NOT EXISTS (
          SELECT NULL FROM "initiative" WHERE "issue_id" = OLD."issue_id"
        )
      THEN
        DELETE FROM "issue" WHERE "id" = OLD."issue_id";
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE CONSTRAINT TRIGGER "last_initiative_deletes_issue"
  AFTER UPDATE OR DELETE ON "initiative" DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE PROCEDURE
  "last_initiative_deletes_issue_trigger"();

COMMENT ON FUNCTION "last_initiative_deletes_issue_trigger"()      IS 'Implementation of trigger "last_initiative_deletes_issue" on table "initiative"';
COMMENT ON TRIGGER "last_initiative_deletes_issue" ON "initiative" IS 'Removing the last initiative of an issue deletes the issue';


CREATE FUNCTION "initiative_requires_first_draft_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT NULL FROM "draft" WHERE "initiative_id" = NEW."id"
      ) THEN
        --RAISE 'Cannot create initiative without an initial draft.' USING
        --  ERRCODE = 'integrity_constraint_violation',
        --  HINT    = 'Create issue, initiative and draft within the same transaction.';
        RAISE EXCEPTION 'Cannot create initiative without an initial draft.';
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE CONSTRAINT TRIGGER "initiative_requires_first_draft"
  AFTER INSERT OR UPDATE ON "initiative" DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE PROCEDURE
  "initiative_requires_first_draft_trigger"();

COMMENT ON FUNCTION "initiative_requires_first_draft_trigger"()      IS 'Implementation of trigger "initiative_requires_first_draft" on table "initiative"';
COMMENT ON TRIGGER "initiative_requires_first_draft" ON "initiative" IS 'Ensure that new initiatives have at least one draft';


CREATE FUNCTION "last_draft_deletes_initiative_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "reference_lost" BOOLEAN;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        "reference_lost" := TRUE;
      ELSE
        "reference_lost" := NEW."initiative_id" != OLD."initiative_id";
      END IF;
      IF
        "reference_lost" AND NOT EXISTS (
          SELECT NULL FROM "draft" WHERE "initiative_id" = OLD."initiative_id"
        )
      THEN
        DELETE FROM "initiative" WHERE "id" = OLD."initiative_id";
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE CONSTRAINT TRIGGER "last_draft_deletes_initiative"
  AFTER UPDATE OR DELETE ON "draft" DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE PROCEDURE
  "last_draft_deletes_initiative_trigger"();

COMMENT ON FUNCTION "last_draft_deletes_initiative_trigger"() IS 'Implementation of trigger "last_draft_deletes_initiative" on table "draft"';
COMMENT ON TRIGGER "last_draft_deletes_initiative" ON "draft" IS 'Removing the last draft of an initiative deletes the initiative';


CREATE FUNCTION "suggestion_requires_first_opinion_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT NULL FROM "opinion" WHERE "suggestion_id" = NEW."id"
      ) THEN
        RAISE EXCEPTION 'Cannot create a suggestion without an opinion.';
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE CONSTRAINT TRIGGER "suggestion_requires_first_opinion"
  AFTER INSERT OR UPDATE ON "suggestion" DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE PROCEDURE
  "suggestion_requires_first_opinion_trigger"();

COMMENT ON FUNCTION "suggestion_requires_first_opinion_trigger"()      IS 'Implementation of trigger "suggestion_requires_first_opinion" on table "suggestion"';
COMMENT ON TRIGGER "suggestion_requires_first_opinion" ON "suggestion" IS 'Ensure that new suggestions have at least one opinion';


CREATE FUNCTION "last_opinion_deletes_suggestion_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "reference_lost" BOOLEAN;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        "reference_lost" := TRUE;
      ELSE
        "reference_lost" := NEW."suggestion_id" != OLD."suggestion_id";
      END IF;
      IF
        "reference_lost" AND NOT EXISTS (
          SELECT NULL FROM "opinion" WHERE "suggestion_id" = OLD."suggestion_id"
        )
      THEN
        DELETE FROM "suggestion" WHERE "id" = OLD."suggestion_id";
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE CONSTRAINT TRIGGER "last_opinion_deletes_suggestion"
  AFTER UPDATE OR DELETE ON "opinion" DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE PROCEDURE
  "last_opinion_deletes_suggestion_trigger"();

COMMENT ON FUNCTION "last_opinion_deletes_suggestion_trigger"()   IS 'Implementation of trigger "last_opinion_deletes_suggestion" on table "opinion"';
COMMENT ON TRIGGER "last_opinion_deletes_suggestion" ON "opinion" IS 'Removing the last opinion of a suggestion deletes the suggestion';



--------------------------------------------------------------------
-- Auto-retrieval of fields only needed for referential integrity --
--------------------------------------------------------------------

CREATE FUNCTION "autofill_issue_id_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NEW."issue_id" ISNULL THEN
        SELECT "issue_id" INTO NEW."issue_id"
          FROM "initiative" WHERE "id" = NEW."initiative_id";
      END IF;
      RETURN NEW;
    END;
  $$;

CREATE TRIGGER "autofill_issue_id" BEFORE INSERT ON "supporter"
  FOR EACH ROW EXECUTE PROCEDURE "autofill_issue_id_trigger"();

CREATE TRIGGER "autofill_issue_id" BEFORE INSERT ON "vote"
  FOR EACH ROW EXECUTE PROCEDURE "autofill_issue_id_trigger"();

COMMENT ON FUNCTION "autofill_issue_id_trigger"()     IS 'Implementation of triggers "autofill_issue_id" on tables "supporter" and "vote"';
COMMENT ON TRIGGER "autofill_issue_id" ON "supporter" IS 'Set "issue_id" field automatically, if NULL';
COMMENT ON TRIGGER "autofill_issue_id" ON "vote"      IS 'Set "issue_id" field automatically, if NULL';


CREATE FUNCTION "autofill_initiative_id_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NEW."initiative_id" ISNULL THEN
        SELECT "initiative_id" INTO NEW."initiative_id"
          FROM "suggestion" WHERE "id" = NEW."suggestion_id";
      END IF;
      RETURN NEW;
    END;
  $$;

CREATE TRIGGER "autofill_initiative_id" BEFORE INSERT ON "opinion"
  FOR EACH ROW EXECUTE PROCEDURE "autofill_initiative_id_trigger"();

COMMENT ON FUNCTION "autofill_initiative_id_trigger"()   IS 'Implementation of trigger "autofill_initiative_id" on table "opinion"';
COMMENT ON TRIGGER "autofill_initiative_id" ON "opinion" IS 'Set "initiative_id" field automatically, if NULL';



-----------------------------------------------------------------------
-- Automatic copy of autoreject settings from membership to interest --
-----------------------------------------------------------------------

CREATE FUNCTION "copy_autoreject_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NEW."autoreject" ISNULL THEN
        SELECT "membership"."autoreject" INTO NEW."autoreject"
          FROM "issue" JOIN "membership"
          ON "issue"."area_id" = "membership"."area_id"
          WHERE "issue"."id" = NEW."issue_id"
          AND "membership"."member_id" = NEW."member_id";
      END IF;
      IF NEW."autoreject" ISNULL THEN 
        NEW."autoreject" := FALSE;
      END IF;
      RETURN NEW;
    END;
  $$;

CREATE TRIGGER "copy_autoreject" BEFORE INSERT OR UPDATE ON "interest"
  FOR EACH ROW EXECUTE PROCEDURE "copy_autoreject_trigger"();

COMMENT ON FUNCTION "copy_autoreject_trigger"()    IS 'Implementation of trigger "copy_autoreject" on table "interest"';
COMMENT ON TRIGGER "copy_autoreject" ON "interest" IS 'If "autoreject" is NULL, then copy it from the area setting, or set to FALSE, if no membership existent';



----------------------------------------
-- Automatic creation of dependencies --
----------------------------------------

CREATE FUNCTION "autocreate_interest_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT NULL FROM "initiative" JOIN "interest"
        ON "initiative"."issue_id" = "interest"."issue_id"
        WHERE "initiative"."id" = NEW."initiative_id"
        AND "interest"."member_id" = NEW."member_id"
      ) THEN
        BEGIN
          INSERT INTO "interest" ("issue_id", "member_id")
            SELECT "issue_id", NEW."member_id"
            FROM "initiative" WHERE "id" = NEW."initiative_id";
        EXCEPTION WHEN unique_violation THEN END;
      END IF;
      RETURN NEW;
    END;
  $$;

CREATE TRIGGER "autocreate_interest" BEFORE INSERT ON "supporter"
  FOR EACH ROW EXECUTE PROCEDURE "autocreate_interest_trigger"();

COMMENT ON FUNCTION "autocreate_interest_trigger"()     IS 'Implementation of trigger "autocreate_interest" on table "supporter"';
COMMENT ON TRIGGER "autocreate_interest" ON "supporter" IS 'Supporting an initiative implies interest in the issue, thus automatically creates an entry in the "interest" table';


CREATE FUNCTION "autocreate_supporter_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT NULL FROM "suggestion" JOIN "supporter"
        ON "suggestion"."initiative_id" = "supporter"."initiative_id"
        WHERE "suggestion"."id" = NEW."suggestion_id"
        AND "supporter"."member_id" = NEW."member_id"
      ) THEN
        BEGIN
          INSERT INTO "supporter" ("initiative_id", "member_id")
            SELECT "initiative_id", NEW."member_id"
            FROM "suggestion" WHERE "id" = NEW."suggestion_id";
        EXCEPTION WHEN unique_violation THEN END;
      END IF;
      RETURN NEW;
    END;
  $$;

CREATE TRIGGER "autocreate_supporter" BEFORE INSERT ON "opinion"
  FOR EACH ROW EXECUTE PROCEDURE "autocreate_supporter_trigger"();

COMMENT ON FUNCTION "autocreate_supporter_trigger"()   IS 'Implementation of trigger "autocreate_supporter" on table "opinion"';
COMMENT ON TRIGGER "autocreate_supporter" ON "opinion" IS 'Opinions can only be added for supported initiatives. This trigger automatrically creates an entry in the "supporter" table, if not existent yet.';



------------------------------------------
-- Views and helper functions for views --
------------------------------------------

CREATE VIEW "issue_delegation_with_overridden_and_inactive" AS
  SELECT "delegation".*, "issue"."id" AS "resulting_issue_id"
  FROM "delegation"
  JOIN "issue" ON
    ("delegation"."area_id" ISNULL AND "delegation"."issue_id" ISNULL) OR
    "delegation"."area_id" = "issue"."area_id" OR
    "delegation"."issue_id" = "issue"."id";

COMMENT ON VIEW "issue_delegation_with_overridden_and_inactive" IS 'Helper view for "issue_delegation"';


CREATE VIEW "issue_delegation" AS
  SELECT
    "entry"."id"                 AS "id",
    "entry"."truster_id"         AS "truster_id",
    "entry"."trustee_id"         AS "trustee_id",
    "entry"."resulting_issue_id" AS "issue_id"
  FROM "issue_delegation_with_overridden_and_inactive" AS "entry"
  JOIN "member" AS "truster" ON "entry"."truster_id" = "truster"."id"
  JOIN "member" AS "trustee" ON "entry"."trustee_id" = "trustee"."id"
  LEFT JOIN "issue_delegation_with_overridden_and_inactive" AS "override"
    ON "entry"."truster_id" = "override"."truster_id"
    AND "entry"."id" != "override"."id"
    AND (
      ("entry"."area_id" ISNULL AND "entry"."issue_id" ISNULL) OR
      "override"."issue_id" NOTNULL
    )
  WHERE "truster"."active" AND "trustee"."active"
  AND "override"."truster_id" ISNULL;

COMMENT ON VIEW "issue_delegation" IS 'Resulting delegations for issues, without those involving inactive members';


CREATE VIEW "current_draft" AS
  SELECT "draft".* FROM (
    SELECT
      "initiative"."id" AS "initiative_id",
      max("draft"."id") AS "draft_id"
    FROM "initiative" JOIN "draft"
    ON "initiative"."id" = "draft"."initiative_id"
    GROUP BY "initiative"."id"
  ) AS "subquery"
  JOIN "draft" ON "subquery"."draft_id" = "draft"."id";

COMMENT ON VIEW "current_draft" IS 'All latest drafts for each initiative';


CREATE VIEW "critical_opinion" AS
  SELECT * FROM "opinion"
  WHERE ("degree" = 2 AND "fulfilled" = FALSE)
  OR ("degree" = -2 AND "fulfilled" = TRUE);

COMMENT ON VIEW "critical_opinion" IS 'Opinions currently causing dissatisfaction';


CREATE VIEW "battle_participant" AS
  SELECT "issue_id", "id" AS "initiative_id" FROM "initiative"
  WHERE "admitted"
  AND "positive_votes" > "negative_votes";

COMMENT ON VIEW "battle_participant" IS 'Helper view for "battle" view';


CREATE VIEW "battle" AS
  SELECT
    "issue"."id" AS "issue_id",
    "winning_initiative"."initiative_id" AS "winning_initiative_id",
    "losing_initiative"."initiative_id" AS "losing_initiative_id",
    sum(
      CASE WHEN
        coalesce("better_vote"."grade", 0) >
        coalesce("worse_vote"."grade", 0)
      THEN "direct_voter"."weight" ELSE 0 END
    ) AS "count"
  FROM "issue"
  LEFT JOIN "direct_voter"
  ON "issue"."id" = "direct_voter"."issue_id"
  JOIN "battle_participant" AS "winning_initiative"
  ON "issue"."id" = "winning_initiative"."issue_id"
  JOIN "battle_participant" AS "losing_initiative"
  ON "issue"."id" = "losing_initiative"."issue_id"
  LEFT JOIN "vote" AS "better_vote"
  ON "direct_voter"."member_id" = "better_vote"."member_id"
  AND "winning_initiative"."initiative_id" = "better_vote"."initiative_id"
  LEFT JOIN "vote" AS "worse_vote"
  ON "direct_voter"."member_id" = "worse_vote"."member_id"
  AND "losing_initiative"."initiative_id" = "worse_vote"."initiative_id"
  WHERE
    "winning_initiative"."initiative_id" !=
    "losing_initiative"."initiative_id"
  GROUP BY
    "issue"."id",
    "winning_initiative"."initiative_id",
    "losing_initiative"."initiative_id";

COMMENT ON VIEW "battle" IS 'Number of members preferring one initiative over another';


CREATE VIEW "expired_session" AS
  SELECT * FROM "session" WHERE now() > "expiry";

CREATE RULE "delete" AS ON DELETE TO "expired_session" DO INSTEAD
  DELETE FROM "session" WHERE "ident" = OLD."ident";

COMMENT ON VIEW "expired_session" IS 'View containing all expired sessions where DELETE is possible';
COMMENT ON RULE "delete" ON "expired_session" IS 'Rule allowing DELETE on rows in "expired_session" view, i.e. DELETE FROM "expired_session"';


CREATE VIEW "open_issue" AS
  SELECT * FROM "issue" WHERE "closed" ISNULL;

COMMENT ON VIEW "open_issue" IS 'All open issues';


CREATE VIEW "issue_with_ranks_missing" AS
  SELECT * FROM "issue"
  WHERE "frozen" NOTNULL
  AND "closed" NOTNULL
  AND "ranks_available" = FALSE;

COMMENT ON VIEW "issue_with_ranks_missing" IS 'Issues where voting was finished, but no ranks have been calculated yet';



------------------------------
-- Comparison by vote count --
------------------------------

CREATE FUNCTION "vote_ratio"
  ( "positive_votes_p" "initiative"."positive_votes"%TYPE,
    "negative_votes_p" "initiative"."negative_votes"%TYPE )
  RETURNS FLOAT8
  LANGUAGE 'plpgsql' STABLE AS $$
    DECLARE
      "total_v" INT4;
    BEGIN
      "total_v" := "positive_votes_p" + "negative_votes_p";
      IF "total_v" > 0 THEN
        RETURN "positive_votes_p"::FLOAT8 / "total_v"::FLOAT8;
      ELSE
        RETURN 0.5;
      END IF;
    END;
  $$;

COMMENT ON FUNCTION "vote_ratio"
  ( "initiative"."positive_votes"%TYPE,
    "initiative"."negative_votes"%TYPE )
  IS 'Ratio of positive votes to sum of positive and negative votes; 0.5, if there are neither positive nor negative votes';



------------------------------------------------
-- Locking for snapshots and voting procedure --
------------------------------------------------

CREATE FUNCTION "global_lock"() RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      -- NOTE: PostgreSQL allows reading, while tables are locked in
      -- exclusive move. Transactions should be kept short anyway!
      LOCK TABLE "member"     IN EXCLUSIVE MODE;
      LOCK TABLE "policy"     IN EXCLUSIVE MODE;
      LOCK TABLE "area"       IN EXCLUSIVE MODE;
      LOCK TABLE "issue"      IN EXCLUSIVE MODE;
      LOCK TABLE "initiative" IN EXCLUSIVE MODE;
      LOCK TABLE "draft"      IN EXCLUSIVE MODE;
      LOCK TABLE "suggestion" IN EXCLUSIVE MODE;
      LOCK TABLE "membership" IN EXCLUSIVE MODE;
      LOCK TABLE "interest"   IN EXCLUSIVE MODE;
      LOCK TABLE "initiator"  IN EXCLUSIVE MODE;
      LOCK TABLE "supporter"  IN EXCLUSIVE MODE;
      LOCK TABLE "opinion"    IN EXCLUSIVE MODE;
      LOCK TABLE "delegation" IN EXCLUSIVE MODE;
      LOCK TABLE "direct_population_snapshot"     IN EXCLUSIVE MODE;
      LOCK TABLE "delegating_population_snapshot" IN EXCLUSIVE MODE;
      LOCK TABLE "direct_interest_snapshot"       IN EXCLUSIVE MODE;
      LOCK TABLE "delegating_interest_snapshot"   IN EXCLUSIVE MODE;
      LOCK TABLE "direct_supporter_snapshot"      IN EXCLUSIVE MODE;
      LOCK TABLE "direct_voter"     IN EXCLUSIVE MODE;
      LOCK TABLE "delegating_voter" IN EXCLUSIVE MODE;
      LOCK TABLE "vote"             IN EXCLUSIVE MODE;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "global_lock"() IS 'Locks all tables related to support/voting until end of transaction; read access is still possible though';



------------------------------
-- Calculation of snapshots --
------------------------------

CREATE FUNCTION "weight_of_added_delegations_for_population_snapshot"
  ( "issue_id_p"            "issue"."id"%TYPE,
    "member_id_p"           "member"."id"%TYPE,
    "delegate_member_ids_p" "delegating_population_snapshot"."delegate_member_ids"%TYPE )
  RETURNS "direct_population_snapshot"."weight"%TYPE
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_delegation_row"  "issue_delegation"%ROWTYPE;
      "delegate_member_ids_v" "delegating_population_snapshot"."delegate_member_ids"%TYPE;
      "weight_v"              INT4;
    BEGIN
      "weight_v" := 0;
      FOR "issue_delegation_row" IN
        SELECT * FROM "issue_delegation"
        WHERE "trustee_id" = "member_id_p"
        AND "issue_id" = "issue_id_p"
      LOOP
        IF NOT EXISTS (
          SELECT NULL FROM "direct_population_snapshot"
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
          AND "member_id" = "issue_delegation_row"."truster_id"
        ) AND NOT EXISTS (
          SELECT NULL FROM "delegating_population_snapshot"
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
          AND "member_id" = "issue_delegation_row"."truster_id"
        ) THEN
          "delegate_member_ids_v" :=
            "member_id_p" || "delegate_member_ids_p";
          INSERT INTO "delegating_population_snapshot"
            ("issue_id", "event", "member_id", "delegate_member_ids")
            VALUES (
              "issue_id_p",
              'periodic',
              "issue_delegation_row"."truster_id",
              "delegate_member_ids_v"
            );
          "weight_v" := "weight_v" + 1 +
            "weight_of_added_delegations_for_population_snapshot"(
              "issue_id_p",
              "issue_delegation_row"."truster_id",
              "delegate_member_ids_v"
            );
        END IF;
      END LOOP;
      RETURN "weight_v";
    END;
  $$;

COMMENT ON FUNCTION "weight_of_added_delegations_for_population_snapshot"
  ( "issue"."id"%TYPE,
    "member"."id"%TYPE,
    "delegating_population_snapshot"."delegate_member_ids"%TYPE )
  IS 'Helper function for "create_population_snapshot" function';


CREATE FUNCTION "create_population_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "member_id_v" "member"."id"%TYPE;
    BEGIN
      DELETE FROM "direct_population_snapshot"
        WHERE "issue_id" = "issue_id_p"
        AND "event" = 'periodic';
      DELETE FROM "delegating_population_snapshot"
        WHERE "issue_id" = "issue_id_p"
        AND "event" = 'periodic';
      INSERT INTO "direct_population_snapshot"
        ("issue_id", "event", "member_id", "interest_exists")
        SELECT DISTINCT ON ("issue_id", "member_id")
          "issue_id_p" AS "issue_id",
          'periodic'   AS "event",
          "subquery"."member_id",
          "subquery"."interest_exists"
        FROM (
          SELECT
            "member"."id" AS "member_id",
            FALSE         AS "interest_exists"
          FROM "issue"
          JOIN "area" ON "issue"."area_id" = "area"."id"
          JOIN "membership" ON "area"."id" = "membership"."area_id"
          JOIN "member" ON "membership"."member_id" = "member"."id"
          WHERE "issue"."id" = "issue_id_p"
          AND "member"."active"
          UNION
          SELECT
            "member"."id" AS "member_id",
            TRUE          AS "interest_exists"
          FROM "interest" JOIN "member"
          ON "interest"."member_id" = "member"."id"
          WHERE "interest"."issue_id" = "issue_id_p"
          AND "member"."active"
        ) AS "subquery"
        ORDER BY
          "issue_id_p",
          "subquery"."member_id",
          "subquery"."interest_exists" DESC;
      FOR "member_id_v" IN
        SELECT "member_id" FROM "direct_population_snapshot"
        WHERE "issue_id" = "issue_id_p"
        AND "event" = 'periodic'
      LOOP
        UPDATE "direct_population_snapshot" SET
          "weight" = 1 +
            "weight_of_added_delegations_for_population_snapshot"(
              "issue_id_p",
              "member_id_v",
              '{}'
            )
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
          AND "member_id" = "member_id_v";
      END LOOP;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "create_population_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE )
  IS 'This function creates a new ''periodic'' population snapshot for the given issue. It does neither lock any tables, nor updates precalculated values in other tables.';


CREATE FUNCTION "weight_of_added_delegations_for_interest_snapshot"
  ( "issue_id_p"            "issue"."id"%TYPE,
    "member_id_p"           "member"."id"%TYPE,
    "delegate_member_ids_p" "delegating_interest_snapshot"."delegate_member_ids"%TYPE )
  RETURNS "direct_interest_snapshot"."weight"%TYPE
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_delegation_row"  "issue_delegation"%ROWTYPE;
      "delegate_member_ids_v" "delegating_interest_snapshot"."delegate_member_ids"%TYPE;
      "weight_v"              INT4;
    BEGIN
      "weight_v" := 0;
      FOR "issue_delegation_row" IN
        SELECT * FROM "issue_delegation"
        WHERE "trustee_id" = "member_id_p"
        AND "issue_id" = "issue_id_p"
      LOOP
        IF NOT EXISTS (
          SELECT NULL FROM "direct_interest_snapshot"
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
          AND "member_id" = "issue_delegation_row"."truster_id"
        ) AND NOT EXISTS (
          SELECT NULL FROM "delegating_interest_snapshot"
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
          AND "member_id" = "issue_delegation_row"."truster_id"
        ) THEN
          "delegate_member_ids_v" :=
            "member_id_p" || "delegate_member_ids_p";
          INSERT INTO "delegating_interest_snapshot"
            ("issue_id", "event", "member_id", "delegate_member_ids")
            VALUES (
              "issue_id_p",
              'periodic',
              "issue_delegation_row"."truster_id",
              "delegate_member_ids_v"
            );
          "weight_v" := "weight_v" + 1 +
            "weight_of_added_delegations_for_interest_snapshot"(
              "issue_id_p",
              "issue_delegation_row"."truster_id",
              "delegate_member_ids_v"
            );
        END IF;
      END LOOP;
      RETURN "weight_v";
    END;
  $$;

COMMENT ON FUNCTION "weight_of_added_delegations_for_interest_snapshot"
  ( "issue"."id"%TYPE,
    "member"."id"%TYPE,
    "delegating_interest_snapshot"."delegate_member_ids"%TYPE )
  IS 'Helper function for "create_interest_snapshot" function';


CREATE FUNCTION "create_interest_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "member_id_v" "member"."id"%TYPE;
    BEGIN
      DELETE FROM "direct_interest_snapshot"
        WHERE "issue_id" = "issue_id_p"
        AND "event" = 'periodic';
      DELETE FROM "delegating_interest_snapshot"
        WHERE "issue_id" = "issue_id_p"
        AND "event" = 'periodic';
      DELETE FROM "direct_supporter_snapshot"
        WHERE "issue_id" = "issue_id_p"
        AND "event" = 'periodic';
      INSERT INTO "direct_interest_snapshot"
        ("issue_id", "event", "member_id", "voting_requested")
        SELECT
          "issue_id_p"  AS "issue_id",
          'periodic'    AS "event",
          "member"."id" AS "member_id",
          "interest"."voting_requested"
        FROM "interest" JOIN "member"
        ON "interest"."member_id" = "member"."id"
        WHERE "interest"."issue_id" = "issue_id_p"
        AND "member"."active";
      FOR "member_id_v" IN
        SELECT "member_id" FROM "direct_interest_snapshot"
        WHERE "issue_id" = "issue_id_p"
        AND "event" = 'periodic'
      LOOP
        UPDATE "direct_interest_snapshot" SET
          "weight" = 1 +
            "weight_of_added_delegations_for_interest_snapshot"(
              "issue_id_p",
              "member_id_v",
              '{}'
            )
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
          AND "member_id" = "member_id_v";
      END LOOP;
      INSERT INTO "direct_supporter_snapshot"
        ( "issue_id", "initiative_id", "event", "member_id",
          "informed", "satisfied" )
        SELECT
          "issue_id_p"      AS "issue_id",
          "initiative"."id" AS "initiative_id",
          'periodic'        AS "event",
          "member"."id"     AS "member_id",
          "supporter"."draft_id" = "current_draft"."id" AS "informed",
          NOT EXISTS (
            SELECT NULL FROM "critical_opinion"
            WHERE "initiative_id" = "initiative"."id"
            AND "member_id" = "member"."id"
          ) AS "satisfied"
        FROM "supporter"
        JOIN "member"
        ON "supporter"."member_id" = "member"."id"
        JOIN "initiative"
        ON "supporter"."initiative_id" = "initiative"."id"
        JOIN "current_draft"
        ON "initiative"."id" = "current_draft"."initiative_id"
        JOIN "direct_interest_snapshot"
        ON "member"."id" = "direct_interest_snapshot"."member_id"
        AND "initiative"."issue_id" = "direct_interest_snapshot"."issue_id"
        WHERE "member"."active"
        AND "initiative"."issue_id" = "issue_id_p";
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "create_interest_snapshot"
  ( "issue"."id"%TYPE )
  IS 'This function creates a new ''periodic'' interest/supporter snapshot for the given issue. It does neither lock any tables, nor updates precalculated values in other tables.';


CREATE FUNCTION "create_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "initiative_id_v"    "initiative"."id"%TYPE;
      "suggestion_id_v"    "suggestion"."id"%TYPE;
    BEGIN
      PERFORM "global_lock"();
      PERFORM "create_population_snapshot"("issue_id_p");
      PERFORM "create_interest_snapshot"("issue_id_p");
      UPDATE "issue" SET
        "snapshot"   = now(),
        "population" = (
          SELECT coalesce(sum("weight"), 0)
          FROM "direct_population_snapshot"
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
        ),
        "vote_now"   = (
          SELECT coalesce(sum("weight"), 0)
          FROM "direct_interest_snapshot"
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
          AND "voting_requested" = TRUE
        ),
        "vote_later" = (
          SELECT coalesce(sum("weight"), 0)
          FROM "direct_interest_snapshot"
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
          AND "voting_requested" = FALSE
        )
        WHERE "id" = "issue_id_p";
      FOR "initiative_id_v" IN
        SELECT "id" FROM "initiative" WHERE "issue_id" = "issue_id_p"
      LOOP
        UPDATE "initiative" SET
          "supporter_count" = (
            SELECT coalesce(sum("di"."weight"), 0)
            FROM "direct_interest_snapshot" AS "di"
            JOIN "direct_supporter_snapshot" AS "ds"
            ON "di"."member_id" = "ds"."member_id"
            WHERE "di"."issue_id" = "issue_id_p"
            AND "di"."event" = 'periodic'
            AND "ds"."initiative_id" = "initiative_id_v"
            AND "ds"."event" = 'periodic'
          ),
          "informed_supporter_count" = (
            SELECT coalesce(sum("di"."weight"), 0)
            FROM "direct_interest_snapshot" AS "di"
            JOIN "direct_supporter_snapshot" AS "ds"
            ON "di"."member_id" = "ds"."member_id"
            WHERE "di"."issue_id" = "issue_id_p"
            AND "di"."event" = 'periodic'
            AND "ds"."initiative_id" = "initiative_id_v"
            AND "ds"."event" = 'periodic'
            AND "ds"."informed"
          ),
          "satisfied_supporter_count" = (
            SELECT coalesce(sum("di"."weight"), 0)
            FROM "direct_interest_snapshot" AS "di"
            JOIN "direct_supporter_snapshot" AS "ds"
            ON "di"."member_id" = "ds"."member_id"
            WHERE "di"."issue_id" = "issue_id_p"
            AND "di"."event" = 'periodic'
            AND "ds"."initiative_id" = "initiative_id_v"
            AND "ds"."event" = 'periodic'
            AND "ds"."satisfied"
          ),
          "satisfied_informed_supporter_count" = (
            SELECT coalesce(sum("di"."weight"), 0)
            FROM "direct_interest_snapshot" AS "di"
            JOIN "direct_supporter_snapshot" AS "ds"
            ON "di"."member_id" = "ds"."member_id"
            WHERE "di"."issue_id" = "issue_id_p"
            AND "di"."event" = 'periodic'
            AND "ds"."initiative_id" = "initiative_id_v"
            AND "ds"."event" = 'periodic'
            AND "ds"."informed"
            AND "ds"."satisfied"
          )
          WHERE "id" = "initiative_id_v";
        FOR "suggestion_id_v" IN
          SELECT "id" FROM "suggestion"
          WHERE "initiative_id" = "initiative_id_v"
        LOOP
          UPDATE "suggestion" SET
            "minus2_unfulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "snapshot"
              ON "opinion"."member_id" = "snapshot"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion_id_v"
              AND "snapshot"."issue_id" = "issue_id_p"
              AND "opinion"."degree" = -2
              AND "opinion"."fulfilled" = FALSE
            ),
            "minus2_fulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "snapshot"
              ON "opinion"."member_id" = "snapshot"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion_id_v"
              AND "snapshot"."issue_id" = "issue_id_p"
              AND "opinion"."degree" = -2
              AND "opinion"."fulfilled" = TRUE
            ),
            "minus1_unfulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "snapshot"
              ON "opinion"."member_id" = "snapshot"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion_id_v"
              AND "snapshot"."issue_id" = "issue_id_p"
              AND "opinion"."degree" = -1
              AND "opinion"."fulfilled" = FALSE
            ),
            "minus1_fulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "snapshot"
              ON "opinion"."member_id" = "snapshot"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion_id_v"
              AND "snapshot"."issue_id" = "issue_id_p"
              AND "opinion"."degree" = -1
              AND "opinion"."fulfilled" = TRUE
            ),
            "plus1_unfulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "snapshot"
              ON "opinion"."member_id" = "snapshot"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion_id_v"
              AND "snapshot"."issue_id" = "issue_id_p"
              AND "opinion"."degree" = 1
              AND "opinion"."fulfilled" = FALSE
            ),
            "plus1_fulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "snapshot"
              ON "opinion"."member_id" = "snapshot"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion_id_v"
              AND "snapshot"."issue_id" = "issue_id_p"
              AND "opinion"."degree" = 1
              AND "opinion"."fulfilled" = TRUE
            ),
            "plus2_unfulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "snapshot"
              ON "opinion"."member_id" = "snapshot"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion_id_v"
              AND "snapshot"."issue_id" = "issue_id_p"
              AND "opinion"."degree" = 2
              AND "opinion"."fulfilled" = FALSE
            ),
            "plus2_fulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "opinion" JOIN "direct_interest_snapshot" AS "snapshot"
              ON "opinion"."member_id" = "snapshot"."member_id"
              WHERE "opinion"."suggestion_id" = "suggestion_id_v"
              AND "snapshot"."issue_id" = "issue_id_p"
              AND "opinion"."degree" = 2
              AND "opinion"."fulfilled" = TRUE
            )
            WHERE "suggestion"."id" = "suggestion_id_v";
        END LOOP;
      END LOOP;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "create_snapshot"
  ( "issue"."id"%TYPE )
  IS 'This function creates a complete new ''periodic'' snapshot of population, interest and support for the given issue. All involved tables are locked, and after completion precalculated values in the source tables are updated.';


CREATE FUNCTION "set_snapshot_event"
  ( "issue_id_p" "issue"."id"%TYPE,
    "event_p" "snapshot_event" )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      UPDATE "direct_population_snapshot"
        SET "event" = 'end_of_discussion'
        WHERE "issue_id" = "issue_id_p" AND "event" = 'periodic';
      UPDATE "delegating_population_snapshot"
        SET "event" = 'end_of_discussion'
        WHERE "issue_id" = "issue_id_p" AND "event" = 'periodic';
      UPDATE "direct_interest_snapshot"
        SET "event" = 'end_of_discussion'
        WHERE "issue_id" = "issue_id_p" AND "event" = 'periodic';
      UPDATE "delegating_interest_snapshot"
        SET "event" = 'end_of_discussion'
        WHERE "issue_id" = "issue_id_p" AND "event" = 'periodic';
      UPDATE "direct_supporter_snapshot"
        SET "event" = 'end_of_discussion'
        WHERE "issue_id" = "issue_id_p" AND "event" = 'periodic';
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "set_snapshot_event"
  ( "issue"."id"%TYPE,
    "snapshot_event" )
  IS 'Change "event" attribute of the previous ''periodic'' snapshot';



---------------------
-- Freezing issues --
---------------------

CREATE FUNCTION "freeze_after_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row"      "issue"%ROWTYPE;
      "policy_row"     "policy"%ROWTYPE;
      "initiative_row" "initiative"%ROWTYPE;
    BEGIN
      SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p";
      SELECT * INTO "policy_row"
        FROM "policy" WHERE "id" = "issue_row"."policy_id";
      PERFORM "set_snapshot_event"("issue_id_p", 'end_of_discussion');
      UPDATE "issue" SET "frozen" = now() WHERE "id" = "issue_id_p";
      FOR "initiative_row" IN
        SELECT * FROM "initiative" WHERE "issue_id" = "issue_id_p"
      LOOP
        IF
          "initiative_row"."satisfied_supporter_count" > 0 AND
          "initiative_row"."satisfied_supporter_count" *
          "policy_row"."initiative_quorum_den" >=
          "issue_row"."population" * "policy_row"."initiative_quorum_num"
        THEN
          UPDATE "initiative" SET "admitted" = TRUE
            WHERE "id" = "initiative_row"."id";
        ELSE
          UPDATE "initiative" SET "admitted" = FALSE
            WHERE "id" = "initiative_row"."id";
        END IF;
      END LOOP;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "freeze_after_snapshot"
  ( "issue"."id"%TYPE )
  IS 'This function freezes an issue, but must only be called when "create_snapshot" was called in the same transaction';


CREATE FUNCTION "manual_freeze"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row" "issue"%ROWTYPE;
    BEGIN
      PERFORM "create_snapshot"("issue_id_p");
      PERFORM "freeze_after_snapshot"("issue_id_p");
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "freeze_after_snapshot"
  ( "issue"."id"%TYPE )
  IS 'Freeze an issue manually';



-----------------------
-- Counting of votes --
-----------------------


CREATE FUNCTION "weight_of_added_delegations"
  ( "issue_id_p"            "issue"."id"%TYPE,
    "member_id_p"           "member"."id"%TYPE,
    "delegate_member_ids_p" "delegating_voter"."delegate_member_ids"%TYPE )
  RETURNS "direct_voter"."weight"%TYPE
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_delegation_row"  "issue_delegation"%ROWTYPE;
      "delegate_member_ids_v" "delegating_voter"."delegate_member_ids"%TYPE;
      "weight_v"              INT4;
    BEGIN
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
          INSERT INTO "delegating_voter"
            ("member_id", "issue_id", "delegate_member_ids")
            VALUES (
              "issue_delegation_row"."truster_id",
              "issue_id_p",
              "delegate_member_ids_v"
            );
          "weight_v" := "weight_v" + 1 + "weight_of_added_delegations"(
            "issue_id_p",
            "issue_delegation_row"."truster_id",
            "delegate_member_ids_v"
          );
        END IF;
      END LOOP;
      RETURN "weight_v";
    END;
  $$;

COMMENT ON FUNCTION "weight_of_added_delegations"
  ( "issue"."id"%TYPE,
    "member"."id"%TYPE,
    "delegating_voter"."delegate_member_ids"%TYPE )
  IS 'Helper function for "add_vote_delegations" function';


CREATE FUNCTION "add_vote_delegations"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "member_id_v" "member"."id"%TYPE;
    BEGIN
      FOR "member_id_v" IN
        SELECT "member_id" FROM "direct_voter"
        WHERE "issue_id" = "issue_id_p"
      LOOP
        UPDATE "direct_voter" SET
          "weight" = "weight" + "weight_of_added_delegations"(
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

COMMENT ON FUNCTION "add_vote_delegations"
  ( "issue_id_p" "issue"."id"%TYPE )
  IS 'Helper function for "close_voting" function';


CREATE FUNCTION "close_voting"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row"   "issue"%ROWTYPE;
      "member_id_v" "member"."id"%TYPE;
    BEGIN
      PERFORM "global_lock"();
      SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p";
      DELETE FROM "delegating_voter"
        WHERE "issue_id" = "issue_id_p";
      DELETE FROM "direct_voter"
        WHERE "issue_id" = "issue_id_p"
        AND "autoreject" = TRUE;
      DELETE FROM "direct_voter" USING "member"
        WHERE "direct_voter"."member_id" = "member"."id"
        AND "direct_voter"."issue_id" = "issue_id_p"
        AND "member"."active" = FALSE;
      UPDATE "direct_voter" SET "weight" = 1
        WHERE "issue_id" = "issue_id_p";
      PERFORM "add_vote_delegations"("issue_id_p");
      FOR "member_id_v" IN
        SELECT "interest"."member_id"
          FROM "interest"
          LEFT JOIN "direct_voter"
            ON "interest"."member_id" = "direct_voter"."member_id"
            AND "interest"."issue_id" = "direct_voter"."issue_id"
          LEFT JOIN "delegating_voter"
            ON "interest"."member_id" = "delegating_voter"."member_id"
            AND "interest"."issue_id" = "delegating_voter"."issue_id"
          WHERE "interest"."issue_id" = "issue_id_p"
          AND "interest"."autoreject" = TRUE
          AND "direct_voter"."member_id" ISNULL
          AND "delegating_voter"."member_id" ISNULL
        UNION SELECT "membership"."member_id"
          FROM "membership"
          LEFT JOIN "interest"
            ON "membership"."member_id" = "interest"."member_id"
            AND "interest"."issue_id" = "issue_id_p"
          LEFT JOIN "direct_voter"
            ON "membership"."member_id" = "direct_voter"."member_id"
            AND "direct_voter"."issue_id" = "issue_id_p"
          LEFT JOIN "delegating_voter"
            ON "membership"."member_id" = "delegating_voter"."member_id"
            AND "delegating_voter"."issue_id" = "issue_id_p"
          WHERE "membership"."area_id" = "issue_row"."area_id"
          AND "membership"."autoreject" = TRUE
          AND "interest"."autoreject" ISNULL
          AND "direct_voter"."member_id" ISNULL
          AND "delegating_voter"."member_id" ISNULL
      LOOP
        INSERT INTO "direct_voter" ("member_id", "issue_id", "autoreject")
          VALUES ("member_id_v", "issue_id_p", TRUE);
        INSERT INTO "vote" (
          "member_id",
          "issue_id",
          "initiative_id",
          "grade"
          ) SELECT
            "member_id_v" AS "member_id",
            "issue_id_p"  AS "issue_id",
            "id"          AS "initiative_id",
            -1            AS "grade"
          FROM "initiative" WHERE "issue_id" = "issue_id_p";
      END LOOP;
      PERFORM "add_vote_delegations"("issue_id_p");
      UPDATE "initiative" SET
        "positive_votes" = "subquery"."positive_votes",
        "negative_votes" = "subquery"."negative_votes"
        FROM (
          SELECT
            "initiative_id",
            sum(
              CASE WHEN "grade" > 0 THEN "direct_voter"."weight" ELSE 0 END
            ) AS "positive_votes",
            sum (
              CASE WHEN "grade" < 0 THEN "direct_voter"."weight" ELSE 0 END
            ) AS "negative_votes"
          FROM "vote" JOIN "direct_voter"
          ON "vote"."member_id" = "direct_voter"."member_id"
          AND "vote"."issue_id" = "direct_voter"."issue_id"
          WHERE "vote"."issue_id" = "issue_id_p"
          GROUP BY "initiative_id"
        ) AS "subquery"
        WHERE "initiative"."admitted"
        AND "initiative"."id" = "subquery"."initiative_id";
      UPDATE "issue" SET "closed" = now() WHERE "id" = "issue_id_p";
    END;
  $$;

COMMENT ON FUNCTION "close_voting"
  ( "issue"."id"%TYPE )
  IS 'Closes the voting on an issue, and calculates positive and negative votes for each initiative; The ranking is not calculated yet, to keep the (locking) transaction short.';


CREATE FUNCTION "init_array"("dim_p" INTEGER)
  RETURNS INT4[]
  LANGUAGE 'plpgsql' IMMUTABLE AS $$
    DECLARE
      "i"          INTEGER;
      "ary_text_v" TEXT;
    BEGIN
      IF "dim_p" >= 1 THEN
        "ary_text_v" := '{NULL';
        "i" := "dim_p";
        LOOP
          "i" := "i" - 1;
          EXIT WHEN "i" = 0;
          "ary_text_v" := "ary_text_v" || ',NULL';
        END LOOP;
        "ary_text_v" := "ary_text_v" || '}';
        RETURN "ary_text_v"::INT4[][];
      ELSE
        RAISE EXCEPTION 'Dimension needs to be at least 1.';
      END IF;
    END;
  $$;

COMMENT ON FUNCTION "init_array"(INTEGER) IS 'Needed for PostgreSQL < 8.4, due to missing "array_fill" function';


CREATE FUNCTION "init_square_matrix"("dim_p" INTEGER)
  RETURNS INT4[][]
  LANGUAGE 'plpgsql' IMMUTABLE AS $$
    DECLARE
      "i"          INTEGER;
      "row_text_v" TEXT;
      "ary_text_v" TEXT;
    BEGIN
      IF "dim_p" >= 1 THEN
        "row_text_v" := '{NULL';
        "i" := "dim_p";
        LOOP
          "i" := "i" - 1;
          EXIT WHEN "i" = 0;
          "row_text_v" := "row_text_v" || ',NULL';
        END LOOP;
        "row_text_v" := "row_text_v" || '}';
        "ary_text_v" := '{' || "row_text_v";
        "i" := "dim_p";
        LOOP
          "i" := "i" - 1;
          EXIT WHEN "i" = 0;
          "ary_text_v" := "ary_text_v" || ',' || "row_text_v";
        END LOOP;
        "ary_text_v" := "ary_text_v" || '}';
        RETURN "ary_text_v"::INT4[][];
      ELSE
        RAISE EXCEPTION 'Dimension needs to be at least 1.';
      END IF;
    END;
  $$;

COMMENT ON FUNCTION "init_square_matrix"(INTEGER) IS 'Needed for PostgreSQL < 8.4, due to missing "array_fill" function';


CREATE FUNCTION "calculate_ranks"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "dimension_v"     INTEGER;
      "matrix"          INT4[][];
      "i"               INTEGER;
      "j"               INTEGER;
      "k"               INTEGER;
      "battle_row"      "battle"%ROWTYPE;
      "rank_ary"        INT4[];
      "rank_v"          INT4;
      "done_v"          INTEGER;
      "winners_ary"     INTEGER[];
      "initiative_id_v" "initiative"."id"%TYPE;
    BEGIN
      PERFORM NULL FROM "issue" WHERE "id" = "issue_id_p" FOR UPDATE;
      -- Prepare matrix for Schulze-Method:
      SELECT count(1) INTO "dimension_v"
        FROM "battle_participant" WHERE "issue_id" = "issue_id_p";
      IF "dimension_v" = 1 THEN
        UPDATE "initiative" SET
          "rank" = 1
          FROM "battle_participant"
          WHERE "initiative"."issue_id" = "issue_id_p"
          AND "initiative"."id" = "battle_participant"."initiative_id";
      ELSIF "dimension_v" > 1 THEN
        "matrix" := "init_square_matrix"("dimension_v");  -- TODO: replace by "array_fill" function (PostgreSQL 8.4)
        "i" := 1;
        "j" := 2;
        -- Fill matrix with data from "battle" view
        FOR "battle_row" IN
          SELECT * FROM "battle" WHERE "issue_id" = "issue_id_p"
          ORDER BY "winning_initiative_id", "losing_initiative_id"
        LOOP
          "matrix"["i"]["j"] := "battle_row"."count";
          IF "j" = "dimension_v" THEN
            "i" := "i" + 1;
            "j" := 1;
          ELSE
            "j" := "j" + 1;
            IF "j" = "i" THEN
              "j" := "j" + 1;
            END IF;
          END IF;
        END LOOP;
        IF "i" != "dimension_v" OR "j" != "dimension_v" + 1 THEN
          RAISE EXCEPTION 'Wrong battle count (should not happen)';
        END IF;
        -- Delete losers from matrix:
        "i" := 1;
        LOOP
          "j" := "i" + 1;
          LOOP
            IF "i" != "j" THEN
              IF "matrix"["i"]["j"] < "matrix"["j"]["i"] THEN
                "matrix"["i"]["j"] := 0;
              ELSIF matrix[j][i] < matrix[i][j] THEN
                "matrix"["j"]["i"] := 0;
              ELSE
                "matrix"["i"]["j"] := 0;
                "matrix"["j"]["i"] := 0;
              END IF;
            END IF;
            EXIT WHEN "j" = "dimension_v";
            "j" := "j" + 1;
          END LOOP;
          EXIT WHEN "i" = "dimension_v" - 1;
          "i" := "i" + 1;
        END LOOP;
        -- Find best paths:
        "i" := 1;
        LOOP
          "j" := 1;
          LOOP
            IF "i" != "j" THEN
              "k" := 1;
              LOOP
                IF "i" != "k" AND "j" != "k" THEN
                  IF "matrix"["j"]["i"] < "matrix"["i"]["k"] THEN
                    IF "matrix"["j"]["i"] > "matrix"["j"]["k"] THEN
                      "matrix"["j"]["k"] := "matrix"["j"]["i"];
                    END IF;
                  ELSE
                    IF "matrix"["i"]["k"] > "matrix"["j"]["k"] THEN
                      "matrix"["j"]["k"] := "matrix"["i"]["k"];
                    END IF;
                  END IF;
                END IF;
                EXIT WHEN "k" = "dimension_v";
                "k" := "k" + 1;
              END LOOP;
            END IF;
            EXIT WHEN "j" = "dimension_v";
            "j" := "j" + 1;
          END LOOP;
          EXIT WHEN "i" = "dimension_v";
          "i" := "i" + 1;
        END LOOP;
        -- Determine order of winners:
        "rank_ary" := "init_array"("dimension_v");  -- TODO: replace by "array_fill" function (PostgreSQL 8.4)
        "rank_v" := 1;
        "done_v" := 0;
        LOOP
          "winners_ary" := '{}';
          "i" := 1;
          LOOP
            IF "rank_ary"["i"] ISNULL THEN
              "j" := 1;
              LOOP
                IF
                  "i" != "j" AND
                  "rank_ary"["j"] ISNULL AND
                  "matrix"["j"]["i"] > "matrix"["i"]["j"]
                THEN
                  -- someone else is better
                  EXIT;
                END IF;
                IF "j" = "dimension_v" THEN
                  -- noone is better
                  "winners_ary" := "winners_ary" || "i";
                  EXIT;
                END IF;
                "j" := "j" + 1;
              END LOOP;
            END IF;
            EXIT WHEN "i" = "dimension_v";
            "i" := "i" + 1;
          END LOOP;
          "i" := 1;
          LOOP
            "rank_ary"["winners_ary"["i"]] := "rank_v";
            "done_v" := "done_v" + 1;
            EXIT WHEN "i" = array_upper("winners_ary", 1);
            "i" := "i" + 1;
          END LOOP;
          EXIT WHEN "done_v" = "dimension_v";
          "rank_v" := "rank_v" + 1;
        END LOOP;
        -- write preliminary ranks:
        "i" := 1;
        FOR "initiative_id_v" IN
          SELECT "initiative"."id"
          FROM "initiative" JOIN "battle_participant"
          ON "initiative"."id" = "battle_participant"."initiative_id"
          WHERE "initiative"."issue_id" = "issue_id_p"
          ORDER BY "initiative"."id"
        LOOP
          UPDATE "initiative" SET "rank" = "rank_ary"["i"]
            WHERE "id" = "initiative_id_v";
          "i" := "i" + 1;
        END LOOP;
        IF "i" != "dimension_v" + 1 THEN
          RAISE EXCEPTION 'Wrong winner count (should not happen)';
        END IF;
        -- straighten ranks (start counting with 1, no equal ranks):
        "rank_v" := 1;
        FOR "initiative_id_v" IN
          SELECT "id" FROM "initiative"
          WHERE "issue_id" = "issue_id_p" AND "rank" NOTNULL
          ORDER BY
            "rank",
            "vote_ratio"("positive_votes", "negative_votes") DESC,
            "id"
        LOOP
          UPDATE "initiative" SET "rank" = "rank_v"
            WHERE "id" = "initiative_id_v";
          "rank_v" := "rank_v" + 1;
        END LOOP;
      END IF;
      -- mark issue as finished
      UPDATE "issue" SET "ranks_available" = TRUE
        WHERE "id" = "issue_id_p";
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "calculate_ranks"
  ( "issue"."id"%TYPE )
  IS 'Determine ranking (Votes have to be counted first)';



-----------------------------
-- Automatic state changes --
-----------------------------


CREATE FUNCTION "check_issue"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row"         "issue"%ROWTYPE;
      "policy_row"        "policy"%ROWTYPE;
      "voting_requested_v" BOOLEAN;
    BEGIN
      PERFORM "global_lock"();
      SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p";
      IF "issue_row"."closed" ISNULL THEN
        SELECT * INTO "policy_row" FROM "policy"
          WHERE "id" = "issue_row"."policy_id";
        IF "issue_row"."frozen" ISNULL THEN
          PERFORM "create_snapshot"("issue_id_p");
          SELECT * INTO "issue_row" FROM "issue" WHERE "id" = "issue_id_p";
        END IF;
        IF "issue_row"."accepted" ISNULL THEN
          IF EXISTS (
            SELECT NULL FROM "initiative"
            WHERE "issue_id" = "issue_id_p"
            AND "supporter_count" > 0
            AND "supporter_count" * "policy_row"."issue_quorum_den"
            >= "issue_row"."population" * "policy_row"."issue_quorum_num"
          ) THEN
            "issue_row"."accepted" = now();  -- NOTE: "issue_row" used later
            UPDATE "issue" SET "accepted" = "issue_row"."accepted"
              WHERE "id" = "issue_row"."id";
          ELSIF
            now() > "issue_row"."created" + "policy_row"."admission_time"
          THEN
            PERFORM "set_snapshot_event"("issue_id_p", 'end_of_admission');
            UPDATE "issue" SET "closed" = now()
              WHERE "id" = "issue_row"."id";
          END IF;
        END IF;
        IF
          "issue_row"."accepted" NOTNULL AND
          "issue_row"."frozen" ISNULL
        THEN
          SELECT
            CASE
              WHEN "vote_now" * 2 > "issue_row"."population" THEN
                TRUE
              WHEN "vote_later" * 2 > "issue_row"."population" THEN
                FALSE
              ELSE NULL
            END
            INTO "voting_requested_v"
            FROM "issue" WHERE "id" = "issue_id_p";
          IF
            "voting_requested_v" OR (
              "voting_requested_v" ISNULL AND now() >
              "issue_row"."accepted" + "policy_row"."discussion_time"
            )
          THEN
            PERFORM "freeze_after_snapshot"("issue_id_p");
          END IF;
        END IF;
        IF
          "issue_row"."frozen" NOTNULL AND
          now() > "issue_row"."frozen" + "policy_row"."voting_time"
        THEN
          PERFORM "close_voting"("issue_id_p");
        END IF;
      END IF;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "check_issue"
  ( "issue"."id"%TYPE )
  IS 'Precalculate supporter counts etc. for a given issue, and check, if status change is required; At end of voting the ranking is not calculated by this function, but must be calculated in a seperate transaction using the "calculate_ranks" function.';


CREATE FUNCTION "check_everything"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_id_v" "issue"."id"%TYPE;
    BEGIN
      DELETE FROM "expired_session";
      FOR "issue_id_v" IN
        SELECT "id" FROM "open_issue"
      LOOP
        PERFORM "check_issue"("issue_id_v");
      END LOOP;
      FOR "issue_id_v" IN
        SELECT "id" FROM "issue_with_ranks_missing"
      LOOP
        PERFORM "calculate_ranks"("issue_id_v");
      END LOOP;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "check_everything"() IS 'Perform "check_issue" for every open issue, and if possible, automatically calculate ranks. Use this function only for development and debugging purposes, as long transactions with exclusive locking may result.';



COMMIT;