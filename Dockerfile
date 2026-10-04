# syntax=docker/dockerfile:1

# ---- Build -------------------------------------------------------------------
FROM swift:6.4-noble AS build
WORKDIR /build

# Resolve dependencies first so source edits don't invalidate this layer.
COPY Package.swift Package.resolved ./
COPY Kit/Package.swift Kit/Package.swift
RUN mkdir -p Kit/Sources/LumeRecorderKit Kit/Tests/LumeRecorderKitTests \
    && swift package resolve

COPY Kit Kit
COPY Sources Sources
COPY Tests Tests
# `--build-system native`: with Swift 6.4's default swiftbuild backend, a
# --static-swift-stdlib link misses FoundationNetworking's CFURLSessionInterface
# and libcurl dependencies (pulled in via LumeRecorderKit's URLSession client).
ARG SWIFT_BUILD_FLAGS="-c release --static-swift-stdlib --build-system native"
RUN swift build ${SWIFT_BUILD_FLAGS} --product lume-recorder \
    && mkdir -p /staging \
    && cp "$(swift build ${SWIFT_BUILD_FLAGS} --show-bin-path)/lume-recorder" /staging/ \
    && ldd /staging/lume-recorder

# ---- Runtime -----------------------------------------------------------------
FROM ubuntu:24.04

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg avahi-daemon ca-certificates tzdata curl libcurl4 tini \
    && rm -rf /var/lib/apt/lists/* \
    # Standalone avahi: no D-Bus inside the container.
    && sed -i 's/^#\?enable-dbus=.*/enable-dbus=no/' /etc/avahi/avahi-daemon.conf \
    && rm -f /etc/avahi/services/*.service \
    && useradd --system --uid 10001 --user-group --home-dir /data --no-create-home --shell /usr/sbin/nologin lume \
    && mkdir -p /data && chown lume:lume /data

COPY --from=build /staging/lume-recorder /usr/local/bin/lume-recorder
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/lume-recorder

ENV DATA_DIR=/data \
    PORT=8090 \
    HOST=0.0.0.0 \
    MAX_CONCURRENT=4 \
    MIN_FREE_GB=2 \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    LOG_LEVEL=info

VOLUME ["/data"]
EXPOSE 8090

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/api/v1/info" > /dev/null || exit 1

# tini reaps the daemonized avahi and forwards SIGTERM so recordings finalize.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["serve"]
