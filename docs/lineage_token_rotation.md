# Lineage token keying and rotation

`record_token` and `source_event_id` (see `warehouse/macros/lineage.sql`) are
HMAC-SHA256 tokens keyed by the `RECORD_TOKEN_HMAC_KEY` environment
variable, computed once at the bronze (reliability engine) layer and
propagated downstream through silver/quality/deid via `select *`.

## Setting the key

```bash
export RECORD_TOKEN_HMAC_KEY="$(openssl rand -hex 32)"   # generate once, store in your secrets manager
cd warehouse && ../.venv/bin/dbt run --profiles-dir .
```

If unset, dbt falls back to an obviously-fake dev key
(`dev-only-insecure-key-DO-NOT-USE-IN-PRODUCTION`) so local/CI runs work
without setup. **Never run this against real PHI-shaped data without
setting a real key** — anyone who knows the fallback string can recompute
every token.

## Why keyed, not just hashed

`patient_id` and the other natural keys here are small sequential integers.
An unkeyed hash (e.g. plain `md5(patient_id)`) is brute-forceable in a
fraction of a second — try every integer, compare hashes. HMAC with a secret
key that never appears in the token closes that off: recovering the natural
key from a token requires either the key or breaking HMAC-SHA256.

## The tokens are templated into compiled SQL — treat that as sensitive

dbt resolves `env_var()` at **compile time** and inlines the literal key
value into the SQL text sent to Trino (and into `warehouse/target/`, which
is gitignored but still exists on disk and in dbt's query logs). That's an
acceptable tradeoff for this repo's synthetic data, but it means the key
itself is exposed to anyone who can read compiled SQL, Trino's query history,
or dbt's logs — not just to whoever reads the token values. A production
deployment handling real ePHI should move the HMAC computation into a
catalog-side function or UDF the key never has to leave, rather than
templating it into every query.

## Rotation

Rotating the key changes every token's value, breaking correlation with
history under the old key — a `record_token` computed today with key v1
will not equal the same patient's token computed tomorrow with key v2. The
token prefix (`r_v1_...`, `evt_v1_...`) exists so a rotation can be staged
rather than being a hard cutover:

1. Bump the version prefix in `generate_record_token`/`generate_source_event_id`
   alongside rotating `RECORD_TOKEN_HMAC_KEY` (or, as in the v1→v2 change
   below, alongside any change to the token *formula*, since that also
   makes old and new tokens for the same underlying row incomparable).
2. Historical rows keep their old-prefix tokens (bronze/silver are not
   recomputed retroactively); only rows processed after the rotation get
   the new prefix.
3. Anything that correlates on `record_token` across the rotation boundary
   (an external audit log, a downstream export) needs to keep both the old
   key and the mapping it's correlating against until every consumer has
   moved past the cutover — this repo doesn't implement that mapping store;
   treat it as required design work before rotating a real deployment's key,
   not an afterthought.

### Changelog

- **v1 → v2**: bumped truncation from 16 hex chars (64 bits) to 32 (128
  bits) — 64 bits of an HMAC output isn't an attack on the keyed HMAC itself,
  but it's a needlessly small margin to leave on the table for a PHI
  reference architecture. Also changed `source_event_id`'s formula to
  include the source table and Debezium's transaction metadata
  (`tx_id`/`tx_total_order`, falling back to the LSN for snapshot events
  that aren't part of a streamed transaction) rather than just
  `natural_key + LSN`, so it captures an event's place in its source
  transaction as part of its identity — see `macros/cdc_reliability.sql`.
  `record_token`'s formula is unchanged (natural key only); it was rev'd to
  v2 alongside `source_event_id` purely because the truncation length
  changed, which likewise makes old and new tokens incomparable.
