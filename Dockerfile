# Multi-stage build for BeingDB server
FROM ocaml/opam:alpine-ocaml-5.4 AS builder

# Install system dependencies
USER root
RUN apk add --no-cache \
    gmp-dev \
    libev-dev \
    openssl-dev \
    libffi-dev \
    zstd-dev \
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
    openssl \
    zstd-libs

# Copy built binaries from builder (`beingdb` provides clone/compile/export/repl)
COPY --from=builder /home/opam/.opam/default/bin/beingdb-serve /home/opam/.opam/default/bin/beingdb /usr/local/bin/

# Create the pack store mount point
RUN mkdir -p /data/pack_store && \
    chmod 755 /data/pack_store

# Create non-root user for running the service
RUN addgroup -g 1000 beingdb && \
    adduser -D -u 1000 -G beingdb beingdb

# Mount the compiled pack store here
VOLUME ["/data/pack_store"]

# Expose default port
EXPOSE 8080

# Environment variables with defaults (SNAPSHOT_PATH is the pack store to serve)
ENV SNAPSHOT_PATH=/data/pack_store \
    PORT=8080 \
    MAX_RESULTS=5000

# Switch to non-root user
USER beingdb

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT}/predicates || exit 1

# Run the server
CMD beingdb serve \
    --pack ${SNAPSHOT_PATH} \
    --port ${PORT} \
    --max-results ${MAX_RESULTS}
