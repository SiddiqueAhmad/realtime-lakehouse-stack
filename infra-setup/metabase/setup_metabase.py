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

# Inventory DB (Postgres) Details
INVENTORY_DB_NAME = "Inventory DB"
INVENTORY_DB_HOST = os.getenv("INVENTORY_DB_HOST", "db")
INVENTORY_DB_PORT = int(os.getenv("INVENTORY_DB_PORT", 5432))
INVENTORY_DB_USER = os.getenv("INVENTORY_DB_USER", "testuser")
INVENTORY_DB_PASS = os.getenv("INVENTORY_DB_PASS", "testpass")
INVENTORY_DB_DBNAME = os.getenv("INVENTORY_DB_DBNAME", "inventory")

# Trino DB Details
TRINO_DB_NAME = "Trino Iceberg"
TRINO_DB_HOST = os.getenv("TRINO_DB_HOST", "../trino")
TRINO_DB_PORT = int(os.getenv("TRINO_DB_PORT", 8080))
TRINO_DB_USER = os.getenv("TRINO_DB_USER", "admin") # Default Trino user
TRINO_DB_CATALOG = os.getenv("TRINO_DB_CATALOG", "iceberg")
TRINO_DB_SCHEMA = os.getenv("TRINO_DB_SCHEMA", "icebergdata")

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

    # --- Add Trino Database ---
    trino_payload = {
        "engine": "starburst",  # Use the starburst driver which is used for Trino
        "name": TRINO_DB_NAME,
        "details": {
            "host": TRINO_DB_HOST,
            "port": TRINO_DB_PORT,
            "user": TRINO_DB_USER,
            "catalog": TRINO_DB_CATALOG,
            "schema": TRINO_DB_SCHEMA, # Add schema for context
            "ssl": False
        },
        "is_on_demand": False,
        "is_full_sync": True,
        "schedules": {}
    }
    add_database(session_id, trino_payload)

    print("🎉 Metabase setup and datasource configuration complete!")
