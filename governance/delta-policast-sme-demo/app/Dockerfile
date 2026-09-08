FROM rust:1.98.0-bookworm AS build
WORKDIR /app
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/governed-delta-demo /usr/local/bin/governed-delta-demo
ENTRYPOINT ["governed-delta-demo"]
CMD ["analyst"]
