# syntax=docker/dockerfile:1

# -- Stage 1: Build ---------------------------------------------------------
FROM --platform=$BUILDPLATFORM alpine:3.23 AS builder

ARG ZIG_VERSION=0.16.0
ARG VERSION=dev

RUN apk add --no-cache curl musl-dev xz
RUN set -eu; \
    case "$(uname -m)" in \
      x86_64) zig_pkg="zig-x86_64-linux-${ZIG_VERSION}.tar.xz" ;; \
      aarch64|arm64) zig_pkg="zig-aarch64-linux-${ZIG_VERSION}.tar.xz" ;; \
      *) echo "Unsupported build arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fL "https://ziglang.org/download/${ZIG_VERSION}/${zig_pkg}" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    rm -f /tmp/zig.tar.xz

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/

ARG TARGETARCH
RUN --mount=type=cache,target=/root/.cache/zig \
    --mount=type=cache,target=/app/.zig-cache \
    set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64) arch="amd64" ;; \
        aarch64|arm64) arch="arm64" ;; \
        *) echo "Unsupported host arch: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64) zig_target="x86_64-linux-musl" ;; \
      arm64) zig_target="aarch64-linux-musl" ;; \
      *) echo "Unsupported TARGETARCH: ${arch}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSmall -Dversion="${VERSION}"

# -- Stage 2: Runtime -------------------------------------------------------
FROM alpine:3.23 AS release-base

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nullwatch

RUN apk add --no-cache ca-certificates tzdata
RUN mkdir -p /nullwatch-data/data && chown -R 65534:65534 /nullwatch-data

COPY --from=builder /app/zig-out/bin/nullwatch /usr/local/bin/nullwatch

ENV NULLWATCH_HOME=/nullwatch-data
WORKDIR /nullwatch-data
EXPOSE 7710
ENTRYPOINT ["nullwatch"]
CMD ["serve", "--host", "0.0.0.0", "--port", "7710", "--data-dir", "/nullwatch-data/data"]

FROM release-base AS release-root
USER 0:0

FROM release-base AS release
USER 65534:65534
