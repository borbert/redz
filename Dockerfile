# syntax=docker/dockerfile:1

FROM alpine:3.21 AS build
RUN apk add --no-cache curl xz
ARG ZIG_VERSION=0.15.2
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
 && ln -s "/opt/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN zig build -Doptimize=ReleaseFast

FROM alpine:3.21
RUN apk add --no-cache ca-certificates \
 && adduser -D -H -u 10001 redz \
 && mkdir -p /data \
 && chown redz:redz /data
COPY --from=build /src/zig-out/bin/redz /usr/local/bin/redz
USER redz
WORKDIR /data
EXPOSE 6379
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/redz"]
CMD ["--host", "0.0.0.0", "--port", "6379", "--persistence", "both", "--data-dir", "/data"]
