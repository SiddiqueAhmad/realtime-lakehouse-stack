# syntax=docker/dockerfile:1.7
FROM rust:1.98.0-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends clang lld && rm -rf /var/lib/apt/lists/*
ENV CARGO_BUILD_JOBS=1 RUSTFLAGS="-C linker=clang -C link-arg=-fuse-ld=lld -C link-arg=-Wl,--threads=1"
WORKDIR /work
COPY qualification/ qualification/
COPY app/src/query_runtime.rs app/src/query_runtime.rs
COPY app/Cargo.toml app/Cargo.toml
ARG LANE=df53
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/usr/local/cargo/git --mount=type=cache,target=/work/target \
    set -eu; case "$LANE" in df53) manifest=qualification/Cargo.toml;; df54) manifest=qualification/df54/Cargo.toml;; *) exit 2;; esac; \
    mkdir -p /evidence; rustc --version > /evidence/rustc.txt; \
    locked=; test ! -f "$(dirname "$manifest")/Cargo.lock" || locked=--locked; \
    CARGO_TARGET_DIR=/work/target cargo build $locked --manifest-path "$manifest"; \
    CARGO_TARGET_DIR=/work/target cargo metadata --manifest-path "$manifest" --format-version 1 > /evidence/dependencies.json; \
    cp "$(dirname "$manifest")/Cargo.lock" /evidence/Cargo.lock; \
    cp /work/target/debug/ducklake-qualification /evidence/ducklake-qualification; \
    cp app/Cargo.toml /evidence/governed-app-Cargo.toml
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /evidence/ /usr/share/qualification/
ENTRYPOINT ["/usr/share/qualification/ducklake-qualification"]
