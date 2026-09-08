# syntax=docker/dockerfile:1.7
FROM rust:1.98.0-bookworm AS build
WORKDIR /app
COPY . .
ARG CARGO_BUILD_JOBS=2
ENV CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    set -eu; \
    if [ -f Cargo.lock ]; then LOCKED=--locked; else LOCKED=; echo 'WARNING: Cargo.lock is not committed yet'; fi; \
    cargo test $LOCKED --all-targets; \
    cargo build $LOCKED --bins; \
    mkdir /out; \
    cp target/debug/governed-delta-demo target/debug/seed-fixture /out/

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/bin/
# Preserve the EXACT dependency resolution used by this successful build.
COPY --from=build /app/Cargo.lock /usr/share/governed-query/Cargo.lock
ENTRYPOINT ["governed-delta-demo"]
