# BeingDB Deployment Guide

Deploy BeingDB in production using Docker with snapshot-based updates.

## Key Concepts

BeingDB uses **immutable snapshots** for zero-downtime deployments:

1. **Facts live in Git** - Version control for your knowledge base
2. **Compile to snapshots** - Transform facts into optimized pack format
3. **Deploy with symlinks** - Point container at snapshot via `current` symlink
4. **Update atomically** - Compile new snapshot, update symlink, restart (minimal downtime)

## Quick Start

### Prerequisites

- Docker and Docker Compose
- BeingDB installed locally (for compilation)

### 1. Setup Directory Structure

```bash
mkdir -p data/snapshots data/git_store

# Clone your facts repository
git clone https://github.com/your-org/your-facts.git data/git_store
```

### 2. Compile Initial Snapshot

```bash
# Compile facts to pack snapshot
beingdb-compile \
  --git ./data/git_store \
  --pack ./data/snapshots/pack_store_$(date +%Y%m%d_%H%M%S)

# Create 'current' symlink pointing to latest snapshot
cd data/snapshots
ln -s pack_store_20260117_100000 current
cd ../..
```

**Result:**
```
data/snapshots/
├── current -> pack_store_20260117_100000/  (symlink)
└── pack_store_20260117_100000/             (snapshot directory)
```

### 3. Start Server

```bash
docker compose up -d

# Verify
curl http://localhost:8080/predicates
```

## Update Workflow

When facts change, compile a new snapshot and update atomically:

```bash
#!/bin/bash
# update.sh

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NEW_SNAPSHOT="pack_store_${TIMESTAMP}"

# 1. Pull latest facts
cd data/git_store && git pull && cd ../..

# 2. Compile new snapshot
beingdb-compile \
  --git ./data/git_store \
  --pack ./data/snapshots/${NEW_SNAPSHOT}

# 3. Update symlink atomically
ln -sfn ${NEW_SNAPSHOT} data/snapshots/current

# 4. Restart container (few seconds downtime)
docker compose restart beingdb

# 5. Verify
sleep 5
curl -f http://localhost:8080/predicates && echo "✓ Update successful!"

# Optional: Clean up old snapshots (keep last 3)
ls -t data/snapshots/pack_store_* | tail -n +4 | xargs -r rm -rf
```

**Make executable:**
```bash
chmod +x update.sh
./update.sh
```

**Note:** Server defaults to 1000 max results. Configure via `MAX_RESULTS` environment variable.

## Configuration

### Environment Variables

Edit `docker-compose.yml`:

```yaml
environment:
  SNAPSHOT_PATH: /data/snapshots/current  # Symlink to active snapshot
  PORT: 8080                               # HTTP port
  MAX_RESULTS: 5000                        # Max results per response
```

### Resource Limits

Add to `docker-compose.yml`:

```yaml
services:
  beingdb:
    # ... existing config ...
    deploy:
      resources:
        limits:
          memory: 512M    # Adjust based on dataset size
```

## Production Setup

### With Nginx Reverse Proxy

```bash
# Start with nginx for rate limiting and SSL
docker compose --profile production up -d
```

The included `nginx.conf` provides:
- Rate limiting (10 requests/second)
- Proper timeouts for long queries
- Health check optimization

### HTTPS with Caddy (Alternative)

```dockerfile
# Caddyfile
yourdomain.com {
    reverse_proxy beingdb:8080
    rate_limit {
        zone dynamic {
            key {remote_host}
            events 10
            window 1s
        }
    }
}
```

## Monitoring

### Health Check

```bash
# Manual check
curl http://localhost:8080/predicates

# Docker health status
docker inspect beingdb-serve --format='{{.State.Health.Status}}'
```

### Resource Usage

```bash
# Real-time monitoring
docker stats beingdb-serve

# Memory usage
docker exec beingdb-serve ps aux
```

### Logs

```bash
docker compose logs -f beingdb
```

## Backup and Rollback

### Backup Current Snapshot

```bash
# Tar backup
tar czf backup_$(date +%Y%m%d).tar.gz data/snapshots/current

# Or copy to remote storage
rsync -av data/snapshots/current/ backup-server:/backups/beingdb/
```

### Rollback to Previous Snapshot

```bash
# List available snapshots
ls -lh data/snapshots/

# Update symlink to older snapshot
ln -sfn pack_store_20260116_153000 data/snapshots/current

# Restart
docker compose restart beingdb
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker compose logs beingdb

# Verify snapshot exists
ls -la data/snapshots/current

# Check permissions
chmod -R 755 data/snapshots
```

### Out of Memory

```bash
# Check memory usage
docker stats beingdb-serve

# Increase limit in docker-compose.yml or reduce MAX_RESULTS
```

### Slow Queries

BeingDB has built-in protections:
- 5 second query timeout
- 10,000 intermediate result limit
- Automatic query optimization

If queries still timeout, the query may be too broad. Check logs for patterns.

## Best Practices

1. **Version control** - Keep facts in Git with meaningful commit messages
2. **Test snapshots** - Compile and test locally before production deployment
3. **Keep backups** - Retain at least 3 recent snapshots for rollback
4. **Monitor resources** - Watch memory usage, especially after updates
5. **Pin dependencies** - Irmin versions are pinned to 3.11.0 for pack format compatibility
6. **Use reverse proxy** - Add nginx/Caddy for rate limiting and HTTPS
7. **Automate updates** - Use CI/CD to compile and deploy on Git push

## Directory Structure Reference

```
beingdb/
├── Dockerfile                    # Server image definition
├── docker-compose.yml            # Deployment configuration
├── nginx.conf                    # Reverse proxy config (optional)
├── update.sh                     # Update script
└── data/
    ├── git_store/               # Facts repository (Git)
    │   └── predicates/
    │       ├── artist.pl
    │       ├── work.pl
    │       └── ...
    └── snapshots/               # Compiled snapshots
        ├── current -> pack_store_20260117_143000/  (active symlink)
        ├── pack_store_20260117_143000/             (latest)
        ├── pack_store_20260117_100000/             (previous)
        └── pack_store_20260116_153000/             (old, can delete)
```

## Further Reading

- [Installation Guide](installation.md)
- [Query Language](query-language.md)
- [API Reference](api.md)
