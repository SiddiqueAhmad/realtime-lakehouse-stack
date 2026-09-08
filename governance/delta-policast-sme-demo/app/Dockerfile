# syntax=docker/dockerfile:1.7
FROM rust:1.98.0-bookworm AS build
WORKDIR /app
COPY . .

# Functional demo: use a debug build for faster iteration. Persist Cargo
# registry/git/target caches across Docker rebuilds. If Cargo.lock has been
# generated and committed, enforce it automatically with --locked.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    if [ -f Cargo.lock ]; then \
        cargo build --locked; \
    else \
        cargo build; \
    fi \
    && cp /app/target/debug/governed-delta-demo /app/governed-delta-demo

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/governed-delta-demo /usr/local/bin/governed-delta-demo
ENTRYPOINT ["governed-delta-demo"]
CMD ["analyst"]
