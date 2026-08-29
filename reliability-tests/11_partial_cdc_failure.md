# Scenario 11: Partial CDC failure

**Question:** did we preserve the correct clinical state, even if the
pipeline died mid-stream?

## Setup

1. Make several writes to `ehr` in quick succession — e.g. run scenarios 1,
   3, and 6 back to back — so multiple change events are in flight.
2. While Debezium is still catching up (before it has flushed all events),
   kill the sink:
   ```bash
   docker kill debezium-server-iceberg
   ```
3. Confirm via the container logs / Iceberg table state that only some of
   the events made it through.
4. Restart it:
   ```bash
   docker compose up -d debezium-iceberg
   ```

## Expected

- Debezium resumes from its last committed offset
  (`debezium_offset_storage_table`, per `application.properties`), not from
  scratch — no full resnapshot, no gap, no duplication of events it had
  already committed before the kill.
- Once it catches up and `dbt run --profiles-dir .` is executed, every write
  from step 1 is present and correct — run the relevant scenario's `VERIFY`
  query from `01`/`03`/`06` to confirm.
- No row is silently missing. If a row from step 1 doesn't show up in
  `bronze.*` after Debezium fully catches up, that's a failure of this
  scenario, not an expected side effect of the kill.
