# Multi-stage build for BeingDB
FROM ocaml/opam:alpine-ocaml-5.1 AS builder

# Install system dependencies
USER root
RUN apk add --no-cache \
    gmp-dev \
    libev-dev \
    openssl-dev \
    libffi-dev \
    perl \
    m4

USER opam
WORKDIR /home/opam/beingdb

# Copy opam files first for dependency caching
COPY --chown=opam:opam beingdb.opam dune-project ./

# Install OCaml dependencies
RUN opam install . --deps-only -y

# Copy source code
COPY --chown=opam:opam . .

# Build BeingDB (tests run separately via docker compose)
RUN eval $(opam env) && dune build --release

# Install to a known location
RUN eval $(opam env) && dune install --prefix=/home/opam/install

# Runtime stage - minimal image
FROM alpine:3.19

# Install runtime dependencies only
RUN apk add --no-cache \
    gmp \
    libev \
    openssl

# Copy compiled binaries from builder
COPY --from=builder /home/opam/install/bin/* /usr/local/bin/

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Create data directories
RUN mkdir -p /data/git-store /data/pack-store /data/facts

WORKDIR /data

# Default command: serve
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 8080
