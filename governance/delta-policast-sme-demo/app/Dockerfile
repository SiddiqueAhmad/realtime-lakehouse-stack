# syntax=docker/dockerfile:1.7
FROM rust:1.98.0-bookworm AS build
# Use the LLVM linker on both native AMD64 and ARM64 builds. The linker is
# confined to the builder image; it is not an application runtime dependency.
RUN apt-get update \
    && apt-get install -y --no-install-recommends clang lld \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ARG CARGO_BUILD_JOBS=1
ENV CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} \
    RUSTFLAGS="-C linker=clang -C link-arg=-fuse-ld=lld -C link-arg=-Wl,--threads=1"
COPY . .
# Compile/link one target at a time and run every test. Do not turn off tests
# to work around OOM. Debug information is disabled in the Cargo profiles.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    set -eu; \
    rustc --version; cargo --version; clang --version; ld.lld --version; \
    if [ -f Cargo.lock ]; then LOCKED=--locked; else LOCKED=; echo 'WARNING: Cargo.lock is not committed yet'; fi; \
    cargo test $LOCKED --all-targets -- --test-threads=1; \
    cargo build $LOCKED --bins; \
    mkdir -p /out; \
    cp target/debug/governed-delta-demo target/debug/seed-fixture target/debug/seed-iceberg-fixture /out/

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/bin/
# Preserve the EXACT dependency resolution used by this successful build.
COPY --from=build /app/Cargo.lock /usr/share/governed-query/Cargo.lock
ENTRYPOINT ["governed-delta-demo"]
