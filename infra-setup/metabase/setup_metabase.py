import os
import time
import requests

# --- Configuration from Environment Variables ---
METABASE_URL = os.getenv("MB_URL", "http://metabase:3000")
SETUP_TOKEN = os.getenv("MB_SETUP_TOKEN")

# Admin User Details
ADMIN_EMAIL = os.getenv("MB_ADMIN_EMAIL")
ADMIN_PASSWORD = os.getenv("MB_ADMIN_PASSWORD")
ADMIN_FIRST_NAME = os.getenv("MB_ADMIN_FIRST_NAME")
ADMIN_LAST_NAME = os.getenv("MB_ADMIN_LAST_NAME")
SITE_NAME = os.getenv("MB_SITE_NAME")

# Operational EHR DB (Postgres) Details
INVENTORY_DB_NAME = "Healthcare EHR DB"
INVENTORY_DB_HOST = os.getenv("INVENTORY_DB_HOST", "db")
INVENTORY_DB_PORT = int(os.getenv("INVENTORY_DB_PORT", 5432))
INVENTORY_DB_USER = os.getenv("INVENTORY_DB_USER", "testuser")
INVENTORY_DB_PASS = os.getenv("INVENTORY_DB_PASS", "testpass")
INVENTORY_DB_DBNAME = os.getenv("INVENTORY_DB_DBNAME", "ehr")

# NOTE: this used to also register a Trino connection (bronze/silver/gold
# lived behind Trino's Iceberg catalog). Since the DuckDB/DuckLake migration
# (see README's architecture section) there's no long-running query server
# for the warehouse layer to point Metabase at — DuckDB is an embedded,
# single-process engine, and Metabase has no first-party DuckDB driver (a
# community JDBC plugin exists but isn't packaged here). Wiring Metabase up
# to gold/deid is a known gap of this migration, not something silently
# dropped — see governance/phi_classification.yml's KNOWN GAP note for the
# access-control side of the same gap. Until it's closed, querying gold.*
# means running `infra-setup/scripts/dq.py` directly (see README).

def wait_for_metabase():
    """Waits for the Metabase API to be available."""
    print("⏳ Waiting for Metabase API to be responsive...")
    while True:
        try:
            response = requests.get(f"{METABASE_URL}/api/health", timeout=5)
            if response.status_code == 200:
                print("✅ Metabase API is up!")
                return True
        except requests.exceptions.RequestException:
            print("... Metabase not ready yet, sleeping for 2 seconds...")
            time.sleep(2)

def check_if_setup_needed():
    """Checks if the Metabase instance needs initial setup."""
    try:
        response = requests.get(f"{METABASE_URL}/api/session/properties", timeout=5)
        response.raise_for_status()
        properties = response.json()
        # If 'setup-token' is in the response, it means setup is required.
        is_needed = 'setup-token' in properties and properties['setup-token'] is not None
        print(f"🤔 Does Metabase need setup? {'Yes' if is_needed else 'No'}")
        return is_needed
    except requests.exceptions.RequestException as e:
        print(f"Error checking setup status: {e}")
        return False

def perform_initial_setup():
    """Performs the initial setup to create the admin user."""
    print("🚀 Performing initial Metabase setup...")
    payload = {
        "token": SETUP_TOKEN,
        "user": {
            "first_name": ADMIN_FIRST_NAME,
            "last_name": ADMIN_LAST_NAME,
            "email": ADMIN_EMAIL,
            "password": ADMIN_PASSWORD
        },
        "prefs": {
            "allow_tracking": False,
            "site_name": SITE_NAME
        }
    }
    try:
        response = requests.post(f"{METABASE_URL}/api/setup", json=payload, timeout=10)
        response.raise_for_status()
        print("✅ Initial admin user created successfully.")
    except requests.exceptions.RequestException as e:
        print(f"❌ ERROR: Initial setup failed: {e}")
        if e.response:
            print(f"Response body: {e.response.text}")
        exit(1)

def get_session_token():
    """Authenticates and retrieves a session token."""
    print("🔑 Authenticating to get a session token...")
    payload = {
        "username": ADMIN_EMAIL,
        "password": ADMIN_PASSWORD
    }
    try:
        response = requests.post(f"{METABASE_URL}/api/session", json=payload, timeout=10)
        response.raise_for_status()
        token = response.json()["id"]
        print("✅ Session token obtained.")
        return token
    except requests.exceptions.RequestException as e:
        print(f"❌ ERROR: Authentication failed: {e}")
        exit(1)

def add_database(session_token, db_payload):
    """Adds a new database connection to Metabase."""
    db_name = db_payload["name"]
    print(f"🔗 Adding database: {db_name}...")
    headers = {"X-Metabase-Session": session_token}
    try:
        response = requests.post(f"{METABASE_URL}/api/database", json=db_payload, headers=headers, timeout=10)
        if response.status_code == 200:
            print(f"✅ Database '{db_name}' added successfully.")
        elif response.status_code == 400 and "already exists" in response.text:
            print(f"⚠️ Database '{db_name}' already exists. Skipping.")
        else:
            response.raise_for_status()
    except requests.exceptions.RequestException as e:
        print(f"❌ ERROR: Failed to add database '{db_name}': {e}")
        if e.response:
            print(f"Response body: {e.response.text}")
        # We don't exit here to allow the script to try adding other databases

if __name__ == "__main__":
    wait_for_metabase()

    if check_if_setup_needed():
        perform_initial_setup()
        # Give Metabase a moment to finalize setup
        time.sleep(5)

    session_id = get_session_token()

    # --- Add Inventory (Postgres) Database ---
    postgres_payload = {
        "engine": "postgres",
        "name": INVENTORY_DB_NAME,
        "details": {
            "host": INVENTORY_DB_HOST,
            "port": INVENTORY_DB_PORT,
            "dbname": INVENTORY_DB_DBNAME,
            "user": INVENTORY_DB_USER,
            "password": INVENTORY_DB_PASS,
        },
        "is_on_demand": False,
        "is_full_sync": True,
    }
    add_database(session_id, postgres_payload)

    # No second database is registered here anymore — see the module-level
    # NOTE above for why (no DuckDB driver, no long-running warehouse server
    # to connect Metabase to since the DuckDB/DuckLake migration).

    print("🎉 Metabase setup and datasource configuration complete!")
