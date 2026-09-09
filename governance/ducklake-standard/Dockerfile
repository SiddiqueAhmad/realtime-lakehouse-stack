# syntax=docker/dockerfile:1.7
FROM rust:1.98.0-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends clang lld python3 ca-certificates git && rm -rf /var/lib/apt/lists/*
ENV CARGO_BUILD_JOBS=1 CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 CARGO_INCREMENTAL=0 \
    RUSTFLAGS="-C linker=clang -C link-arg=-fuse-ld=lld -C link-arg=-Wl,--threads=1"
WORKDIR /work
ARG FIXES=1
COPY governance/delta-policast-sme-demo/ governance/delta-policast-sme-demo/
COPY governance/ducklake-standard/ governance/ducklake-standard/
RUN --mount=type=cache,target=/sources set -eu; \
    if [ ! -d /sources/ducklake/.git ]; then git init /sources/ducklake; git -C /sources/ducklake remote add origin https://github.com/datafusion-contrib/datafusion-ducklake.git; fi; \
    git -C /sources/ducklake fetch --depth=1 origin ad1b8c433179192e09bf66e8c84c46d61ba9306e; \
    mkdir /upstream; git -C /sources/ducklake archive ad1b8c433179192e09bf66e8c84c46d61ba9306e | tar -x -C /upstream; \
    if [ ! -d /sources/policast/.git ]; then git init /sources/policast; git -C /sources/policast remote add origin https://github.com/open-lakehouse/policast.git; fi; \
    git -C /sources/policast fetch --depth=1 origin c6891d553fa1105546668c75b9a0d175bc54f70d; \
    mkdir /policast; git -C /sources/policast archive c6891d553fa1105546668c75b9a0d175bc54f70d | tar -x -C /policast; \
    flags=; [ "$FIXES" = 1 ] || flags=--unpatched; \
    python3 governance/ducklake-standard/prepare.py --output /build --upstream /upstream --policast /policast $flags
WORKDIR /build
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/target \
    set -eu; locked=; [ ! -f Cargo.lock ] || locked=--locked; \
    CARGO_TARGET_DIR=/target cargo test $locked --bins; \
    CARGO_TARGET_DIR=/target cargo build $locked --bins; \
    mkdir /out /evidence; cp /target/debug/ducklake-qualification /target/debug/governed-delta-demo /target/debug/seed-ducklake-fixture /out/; \
    cargo metadata --locked --format-version 1 > /evidence/dependencies.json; \
    cp Cargo.lock upstream-changes.patch /evidence/; \
    cp Cargo.toml /evidence/governed-app-Cargo.toml; rustc --version > /evidence/rustc.txt; \
    printf '%s\n' "$FIXES" > /evidence/fixes.txt
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/bin/
COPY --from=build /evidence/ /usr/share/qualification/
ENTRYPOINT ["ducklake-qualification"]
