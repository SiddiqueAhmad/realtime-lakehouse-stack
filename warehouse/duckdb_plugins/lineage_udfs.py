"""
dbt-duckdb plugin: registers hmac_sha256_hex(key, msg) as a callable SQL
function on every DuckDB connection dbt opens.

WHY A PYTHON UDF, NOT INLINE SQL: DuckDB has sha256() but no built-in keyed
HMAC (checked directly against duckdb_functions() — there is no
hmac_sha256, unlike Trino). A plain sha256(key || msg) is NOT a safe
substitute for HMAC (it's vulnerable to length-extension attacks and isn't
the construction docs/lineage_token_rotation.md documents), so this
implements real HMAC-SHA256 via Python's stdlib `hmac`/`hashlib` instead of
hand-rolling it in SQL.

SECURITY NOTE, and a real improvement over the previous (Trino) design: the
HMAC key is read from RECORD_TOKEN_HMAC_KEY here, in Python, at connection
time — it is never templated into SQL text the way
`warehouse/macros/lineage.sql`'s old Trino version had to (dbt's
`env_var()` resolves at Jinja-compile time and inlines the literal value
into compiled SQL). That inlining was an explicitly documented known
limitation of the Trino version (see docs/lineage_token_rotation.md); this
closes it — the key never appears in compiled SQL, Trino's/DuckDB's query
log, or dbt's target/ artifacts.

UNVERIFIED IN SANDBOX: create_function() itself is exercised directly
against a plain DuckDB connection in this session (see the PR description)
and works as expected; what could NOT be verified here is dbt-duckdb
actually invoking this plugin's configure_connection() through its normal
plugin-loading path end-to-end (needs a live `dbt run`, which needs the
`ducklake` extension this sandbox's network policy blocks — see
warehouse/profiles.yml). First real run is
.github/workflows/e2e-pipeline.yml in CI.
"""

import hashlib
import hmac
import os
from typing import Any, Dict

from dbt.adapters.duckdb.plugins import BasePlugin
from duckdb import DuckDBPyConnection

# Same fallback as the Trino version's _record_token_hmac_key() macro: an
# obviously-fake dev-only key so local/CI runs work without one configured,
# not fit for anything beyond this repo's synthetic fixtures.
_DEV_ONLY_KEY = "dev-only-insecure-key-DO-NOT-USE-IN-PRODUCTION"


def _hmac_sha256_hex(key: str, message: str) -> str:
    return hmac.new(key.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


class Plugin(BasePlugin):
    def initialize(self, plugin_config: Dict[str, Any]):
        # Resolved once per connection, from the real process environment —
        # not from dbt's env_var() Jinja function, precisely so it never
        # touches compiled SQL. See the module docstring.
        self._key = os.environ.get("RECORD_TOKEN_HMAC_KEY", _DEV_ONLY_KEY)

    def configure_connection(self, conn: DuckDBPyConnection):
        conn.create_function(
            "hmac_sha256_hex",
            lambda message: _hmac_sha256_hex(self._key, message),
            ["VARCHAR"],
            "VARCHAR",
        )
