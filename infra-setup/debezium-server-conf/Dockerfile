# The stock quay.io/debezium/server image does NOT have every sink
# registered at runtime - confirmed the hard way (a real run failed with
# "io.debezium.DebeziumException: No Debezium consumer named 'jdbc' is
# available"), contradicting an earlier assumption based on a web search
# that conflated it with debezium-server-dist (see below). This installs
# the full distribution - debezium-server-dist, published to Maven Central
# as a tar.gz - on top of the base image, using the documented extraction
# pattern real Debezium Server Dockerfiles use:
# `tar xzf dist.tar.gz -C $SERVER_HOME --strip-components 1`.
#
# Why 3.6.0.Final and not 3.0.8.Final: the "No consumer named 'jdbc'"
# failure persisted even after installing debezium-server-dist correctly
# (gzip fixed, extraction verified against a real run's logs). Root-caused
# by fetching debezium-server-dist's own pom.xml at each version tag from
# github.com/debezium/debezium-server and grep'ing it for "jdbc" - the
# debezium-server-jdbc module (a formerly third-party sink, contributed by
# the memiiso/debezium-server-jdbc community project) is NOT one of
# debezium-server-dist's bundled dependencies until 3.6.0.Final; every
# tag from 3.0.8.Final through 3.5.0.Final has no "jdbc" dependency in
# that pom at all, so no extraction pattern could have made it available
# on those versions - the tarball genuinely doesn't contain it.
# 3.6.0.Final (released 2026-07-01, currently the latest stable Final -
# 3.7 is still Alpha) is the first version confirmed, by direct inspection
# of that tag's debezium-server-dist/pom.xml, to declare
# `io.debezium:debezium-server-jdbc` as a compile-scope dependency.
#
# UNVERIFIED IN SANDBOX: this session has no route to Maven Central or
# quay.io (same disclosed constraint as everywhere else in this
# migration), so this Dockerfile's build itself could not be run here.
# Prior iterations, each grounded in the previous run's actual failure,
# not a fresh guess: a guessed Maven coordinate that 404'd; assuming the
# stock image needed no jars at all (wrong - "No Debezium consumer named
# 'jdbc'"); the tar extraction itself failing on a missing gzip binary
# (fixed with `microdnf install -y gzip`); and, after both of those fixes,
# the exact same "No consumer named 'jdbc'" error recurring on a real run
# because 3.0.8.Final's debezium-server-dist simply never bundled a jdbc
# sink (this version bump). First real build + run happens in CI
# (.github/workflows/e2e-pipeline.yml).
ARG DEBEZIUM_VERSION=3.6.0.Final
FROM quay.io/debezium/server:${DEBEZIUM_VERSION}

ARG DEBEZIUM_VERSION=3.6.0.Final

USER root
# Real run (33249165571): the download succeeded, but extraction failed -
# "tar (child): gzip: Cannot exec: No such file or directory". The base
# image is registry.access.redhat.com/ubi8/openjdk-11 (confirmed via
# search of Debezium's own Dockerfile, not assumed) - a UBI image that
# doesn't ship gzip by default; microdnf is its package manager.
RUN microdnf install -y gzip \
    && curl -fsSL -o /tmp/debezium-server-dist.tar.gz \
      "https://repo1.maven.org/maven2/io/debezium/debezium-server-dist/${DEBEZIUM_VERSION}/debezium-server-dist-${DEBEZIUM_VERSION}.tar.gz" \
    && rm -rf /debezium/lib /debezium/*.jar \
    && tar xzf /tmp/debezium-server-dist.tar.gz -C /debezium --strip-components 1 \
    && rm -f /tmp/debezium-server-dist.tar.gz \
    && microdnf clean all
USER 1001
