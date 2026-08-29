# Scenario 11: Partial CDC failure

**Question:** did we preserve the correct clinical state, even if the
pipeline died mid-stream?

## Setup

1. Make several writes to `ehr` in quick succession — e.g. run scenarios 1,
   3, and 6 back to back — so multiple change events are in flight.
2. While Debezium is still catching up (before it has flushed all events),
   kill the sink:
   ```bash
   docker kill debezium
   ```
3. Confirm via the container logs / `raw_cdc.*` table state that only some
   of the events made it through.
4. Restart it:
   ```bash
   docker compose up -d debezium
   ```

## Expected

- Debezium resumes from its last committed offset (the local
  `offsets.dat`/`schema-history.dat` files, per `application.properties` —
  note these live in the `debezium-data` Docker volume, not the container's
  writable layer, so a container restart doesn't lose them; a full
  `docker compose down -v` would), not from scratch — no full resnapshot, no
  gap, no duplication of events it had already committed before the kill.
- Once it catches up and `dbt run --profiles-dir .` is executed, every write
  from step 1 is present and correct — run the relevant scenario's `VERIFY`
  query from `01`/`03`/`06` to confirm.
- No row is silently missing. If a row from step 1 doesn't show up in
  `bronze.*` after Debezium fully catches up, that's a failure of this
  scenario, not an expected side effect of the kill.

**Automated as:** the "scenario 11" steps in `.github/workflows/e2e-pipeline.yml`
(near the end of the job) — a deterministic variant of the manual procedure
above: kill Debezium first, write a new row directly to `ehr` while it's
confirmed down (proving Postgres's own replication slot, not Debezium,
is what retains the unconsumed WAL), restart it, and assert the row lands
in `raw_cdc` exactly once and flows through to `bronze`/`quality`
correctly — no gap, no duplicate delivery.
