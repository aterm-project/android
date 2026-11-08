# Build the standalone browser frontend.
# sodium 4.1.1+1 requires Dart 3.13; pin the official Flutter 3.47.5 archive
# and verify its published digest instead of relying on a drifting image tag.
FROM debian:bookworm-slim AS web-build
ENV PATH="/opt/flutter/bin:${PATH}"
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl git libglu1-mesa unzip xz-utils zip; \
    rm -rf /var/lib/apt/lists/*; \
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 \
      https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.5-stable.tar.xz \
      --output /tmp/flutter.tar.xz; \
    echo '2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb  /tmp/flutter.tar.xz' | sha256sum --check -; \
    mkdir -p /opt; \
    tar -xJf /tmp/flutter.tar.xz -C /opt; \
    rm /tmp/flutter.tar.xz
RUN git config --global --add safe.directory /opt/flutter
WORKDIR /src/apps/client
RUN flutter --version && dart --version
# Keep every local path dependency from apps/client/pubspec.yaml available in
# the image build context. Flutter resolves these relative to /src/apps/client.
COPY packages/drift /src/packages/drift
COPY packages/sqlite3 /src/packages/sqlite3
COPY packages/xterm /src/packages/xterm
COPY apps/client/pubspec.yaml apps/client/pubspec.lock ./
COPY apps/client/lib ./lib
COPY apps/client/web ./web
RUN flutter --version && flutter pub get --enforce-lockfile
RUN flutter build web --release --no-web-resources-cdn

FROM nginx:stable-alpine@sha256:583b7f2fce1cdb8da5ad5c39ebd3c33b98b87d493190e548bdee1fa8c619c311
COPY --from=web-build /src/apps/client/build/web/ /usr/share/nginx/html/
COPY deploy/nginx.conf /etc/nginx/nginx.conf
RUN chown -R nginx:nginx /var/cache/nginx /usr/share/nginx/html
USER nginx
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD wget -q -O /dev/null http://127.0.0.1:8080/index.html || exit 1
CMD ["nginx", "-g", "daemon off;"]
