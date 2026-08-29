# The official Debezium Server image doesn't bundle the JDBC sink (it's an
# optional connector, not core) - this adds it, plus the Postgres JDBC
# driver it needs to actually write to warehouse.raw_cdc.*.
#
# UNVERIFIED IN SANDBOX: written against the documented Debezium Server
# plugin-directory convention (drop a connector's jar(s) under
# /debezium/lib) and Maven Central coordinates, but this Dockerfile's build
# could not be run here - no route to Maven Central or Docker Hub/quay.io
# from this sandbox's network egress policy (see docs/lineage_token_rotation.md's
# sibling PRs for the same disclosed constraint on Trino/Iceberg images).
# First real build + run happens in CI (.github/workflows/e2e-pipeline.yml).
ARG DEBEZIUM_VERSION=3.0.8.Final
FROM quay.io/debezium/server:${DEBEZIUM_VERSION}

ARG DEBEZIUM_VERSION=3.0.8.Final
ARG POSTGRES_JDBC_VERSION=42.7.4

USER root
RUN curl -fsSL -o /debezium/lib/debezium-server-jdbc-${DEBEZIUM_VERSION}.jar \
      "https://repo1.maven.org/maven2/io/debezium/debezium-server-jdbc/${DEBEZIUM_VERSION}/debezium-server-jdbc-${DEBEZIUM_VERSION}.jar" \
    && curl -fsSL -o /debezium/lib/postgresql-${POSTGRES_JDBC_VERSION}.jar \
      "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar"
USER 1001
