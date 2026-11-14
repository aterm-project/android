# API/server image. Build and deploy the web frontend separately.
# The build compiles bundled SQLCipher with vendored OpenSSL (needs the perl
# and make shipped in the rust:bookworm image); the runtime needs no OpenSSL.
FROM rust:1.94.1-bookworm AS server-build
WORKDIR /src
COPY server/Cargo.toml server/Cargo.lock ./server/
COPY server/migrations ./server/migrations
COPY server/src ./server/src
COPY server/openapi.yaml ./server/openapi.yaml
WORKDIR /src/server
RUN cargo build --release --locked

FROM debian:bookworm-slim AS runtime
RUN groupadd --system --gid 10001 aterm && useradd --system --uid 10001 --gid aterm --home-dir /nonexistent --shell /usr/sbin/nologin aterm \
    && mkdir -p /data /object-store /app/web /share-gateway /keys \
    && chmod 0700 /data /object-store /share-gateway /keys \
    && chown -R aterm:aterm /data /object-store /app /share-gateway /keys
COPY --from=server-build /src/server/target/release/atermius-server /usr/local/bin/atermius-server
ENV ATERMIUS_DATA_DIR=/data \
    ATERMIUS_DATABASE_URL=sqlite:///data/atermius.db?mode=rwc \
    ATERMIUS_HISTORY_RETENTION_DAYS=90 \
    ATERMIUS_RECORD_RESTORE_RETENTION_DAYS=30 \
    ATERMIUS_BIND=0.0.0.0:8080
VOLUME ["/data", "/object-store"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 CMD ["/usr/local/bin/atermius-server", "healthcheck"]
USER aterm
ENTRYPOINT ["/usr/local/bin/atermius-server"]
CMD ["serve"]
