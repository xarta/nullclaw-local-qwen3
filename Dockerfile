# syntax=docker/dockerfile:1
#
# Alpine-based build + runtime.
# The upstream Dockerfile uses gcr.io/distroless/cc-debian13 (glibc) as the
# runtime, but the builder runs on Alpine (musl). The resulting binary is
# dynamically linked against musl, which doesn't exist in the distroless image.
# Fix: use alpine:3.23 as the runtime instead.
#
# root.pem - drop your own CA root cert here if your agents need to reach
# internal HTTPS services signed by a private CA.  Remove the COPY line below
# if not needed.

# -- Stage 1: Build -------------------------------------------------------
FROM alpine:3.23 AS builder
RUN apk add --no-cache zig musl-dev
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/
RUN zig build -Doptimize=ReleaseSmall

# -- Stage 2: Runtime -----------------------------------------------------
FROM alpine:3.23 AS release
# Drop your CA root cert as root.pem to trust internal HTTPS services.
# Remove the next line if you do not need a custom CA.
COPY root.pem /usr/local/share/ca-certificates/local-root.crt
RUN apk add --no-cache curl ca-certificates \
    && update-ca-certificates \
    && mkdir -p /nullclaw-data/.nullclaw /nullclaw-data/workspace \
    && chown -R 65534:65534 /nullclaw-data
COPY --from=builder /app/zig-out/bin/nullclaw /usr/local/bin/nullclaw
ENV NULLCLAW_WORKSPACE=/nullclaw-data/workspace
ENV HOME=/nullclaw-data
ENV NULLCLAW_GATEWAY_PORT=3000
WORKDIR /nullclaw-data
USER 65534:65534
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/nullclaw"]
CMD ["daemon"]
