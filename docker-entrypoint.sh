#!/bin/sh
set -e

# If specific command provided, run it directly
if [ $# -gt 0 ]; then
    exec "$@"
fi

# Default: start server
echo "Starting BeingDB server on port ${BEINGDB_PORT:-8080}..."
exec beingdb-serve --pack /data/pack-store --port "${BEINGDB_PORT:-8080}"
