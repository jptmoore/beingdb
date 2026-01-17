# Multi-stage build for BeingDB server
FROM ocaml/opam:alpine-ocaml-5.1 AS builder

# Install system dependencies
USER root
RUN apk add --no-cache \
    gmp-dev \
    libev-dev \
    openssl-dev \
    libffi-dev \
    git

USER opam
WORKDIR /home/opam/beingdb

# Copy source files
COPY --chown=opam:opam . .

# Install OCaml dependencies and build
RUN opam install . --deps-only -y && \
    eval $(opam env) && \
    dune build --release @install && \
    dune install --prefix=/home/opam/.opam/default

# Runtime image
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache \
    libgcc \
    libstdc++ \
    gmp \
    libev \
    libffi \
    openssl

# Copy built binary from builder
COPY --from=builder /home/opam/.opam/default/bin/beingdb-serve /usr/local/bin/

# Create data directory for snapshots
RUN mkdir -p /data/snapshots && \
    chmod 755 /data/snapshots

# Create non-root user for running the service
RUN addgroup -g 1000 beingdb && \
    adduser -D -u 1000 -G beingdb beingdb

# Volume for snapshot storage
VOLUME ["/data/snapshots"]

# Expose default port
EXPOSE 8080

# Environment variables with defaults
ENV SNAPSHOT_PATH=/data/snapshots/current \
    PORT=8080 \
    MAX_RESULTS=5000

# Switch to non-root user
USER beingdb

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT}/predicates || exit 1

# Run beingdb-serve
CMD beingdb-serve \
    --pack ${SNAPSHOT_PATH} \
    --port ${PORT} \
    --max-results ${MAX_RESULTS}
