# Digital Preservation with BeingDB

BeingDB is designed for long-term preservation of knowledge bases through distributed, verifiable replication. Deploy across multiple hosts to ensure your facts survive infrastructure failures, data loss, and organizational changes.

## Why Distributed Preservation?

Traditional databases have single points of failure:
- **Centralized storage** - One database server holds authoritative data
- **Backup complexity** - Replication requires coordination, sync protocols
- **Integrity risks** - Corruption can spread to replicas before detection
- **Geographic limits** - Usually confined to one data center

BeingDB takes a different approach inspired by blockchain architecture:
- **Git as consensus** - All hosts pull from authoritative Git repository
- **Independent compilation** - Each host builds its own Pack store from source
- **Content-addressed verification** - Deterministic compilation ensures identical results
- **Immutable snapshots** - No partial writes, no corruption propagation

## Architecture

```
Primary Repository (GitHub/GitLab)
         ↓
    [Git Clone/Pull]
         ↓
    ┌────┴────┬────────┬────────┐
    ↓         ↓        ↓        ↓
  Host 1    Host 2   Host 3   Archive
    ↓         ↓        ↓        ↓
 [Compile] [Compile] [Compile] [Compile]
    ↓         ↓        ↓        ↓
  Pack      Pack     Pack     Pack
    ↓         ↓        ↓
 [Serve]   [Serve]  [Serve]
```

Each host:
1. Pulls facts from Git (authoritative source)
2. Compiles to Pack store (deterministic, verifiable)
3. Serves queries from local Pack (no network dependencies)

## Setup Guide

### Primary Host (Editable Repository)

The primary host maintains the authoritative Git repository:

```bash
# Initialize Git store
beingdb-clone https://github.com/org/facts.git --git /data/git_store

# Make changes
cd /data/git_store/predicates
vim created.pl  # Edit facts

git add .
git commit -m "Add new artworks"
git push origin main

# Compile to Pack
beingdb-compile --git /data/git_store --pack /data/pack_store

# Serve queries
beingdb-serve --pack /data/pack_store
```

### Replica Hosts (Read-Only)

Replica hosts pull updates and serve queries:

```bash
# Initial setup
beingdb-clone https://github.com/org/facts.git --git /data/git_store

# Pull updates from remote
beingdb-pull --git /data/git_store --remote origin --branch main

# Compile to Pack
beingdb-compile --git /data/git_store --pack /data/pack_store

# Serve queries
beingdb-serve --pack /data/pack_store
```

### Automated Sync

Set up cron jobs for automatic updates:

```bash
# /etc/cron.d/beingdb-sync
# Pull and recompile every hour
0 * * * * beingdb /usr/local/bin/beingdb-pull --git /data/git_store && \
                   /usr/local/bin/beingdb-compile --git /data/git_store --pack /data/pack_store.new && \
                   ln -sfn /data/pack_store.new /data/pack_store.current
```

### Archive Host (No Serving)

For preservation only, without query serving:

```bash
# Pull and compile for archival
beingdb-pull --git /data/archive/git_store
beingdb-compile --git /data/archive/git_store --pack /data/archive/pack_store

# No serve - just preserved snapshots
# Consider keeping dated snapshots:
# /data/archive/2026-01-29/pack_store
# /data/archive/2026-01-30/pack_store
```

## Multi-Region Deployment

Deploy across geographic regions for disaster recovery:

```
Region 1 (US-East)
├── Primary: git + pack + serve
└── Replica: git + pack + serve

Region 2 (EU-West)
├── Replica: git + pack + serve
└── Replica: git + pack + serve

Region 3 (Asia-Pacific)
└── Archive: git + pack (preservation only)
```

**Benefits:**
- Regional failover (any region can serve queries)
- Reduced latency (serve from nearest replica)
- Geographic preservation (survives regional disasters)
- Regulatory compliance (data in multiple jurisdictions)

## Verification

Verify compilation integrity across hosts:

```bash
# On each host after compilation
cd /data/pack_store
find . -type f -exec sha256sum {} \; | sort > /tmp/pack_checksums.txt

# Compare checksums between hosts
diff host1_checksums.txt host2_checksums.txt
# Empty output = identical Pack stores = verified integrity
```

Content-addressed compilation guarantees that identical Git commits produce identical Pack stores. Any difference indicates corruption or compilation issues.

## Load Balancing

Use a load balancer to distribute queries:

```nginx
# nginx.conf
upstream beingdb_cluster {
    server replica1:8080;
    server replica2:8080;
    server replica3:8080;
}

server {
    listen 80;
    location / {
        proxy_pass http://beingdb_cluster;
    }
}
```

All replicas serve identical data, so any host can answer any query.

## Disaster Recovery

### Scenario 1: Host Failure

If any host fails, others continue serving:

```bash
# Traffic automatically routes to healthy hosts
# No data loss - Git and other replicas remain intact
```

### Scenario 2: Primary Repository Loss

If the primary Git repository is lost:

```bash
# Promote any replica's Git store to primary
cd /data/git_store
git remote set-url origin git@github.com:org/facts-new.git
git push -u origin main

# Other hosts update their remotes
git remote set-url origin git@github.com:org/facts-new.git
```

### Scenario 3: Data Corruption

If a Pack store becomes corrupted:

```bash
# Recompile from Git (source of truth)
rm -rf /data/pack_store
beingdb-compile --git /data/git_store --pack /data/pack_store

# Or copy from verified replica
rsync -avz replica1:/data/pack_store/ /data/pack_store/
```

### Scenario 4: Time Travel

Query historical states by checking out old Git commits:

```bash
# Create historical Pack store
cd /data/git_store
git checkout abc123  # Old commit

beingdb-compile --git /data/git_store --pack /data/historical/2025-01-01/pack_store

# Serve historical snapshot
beingdb-serve --pack /data/historical/2025-01-01/pack_store --port 8081
```

## Battle-Tested Technology

BeingDB's Pack backend is the same Irmin Pack storage used by the Tezos blockchain to store billions of dollars in value. This means:

- **Production-hardened** - Years of operation under adversarial conditions
- **Immutability guarantees** - Content-addressed storage prevents silent corruption
- **Performance at scale** - Handles petabyte-scale state trees
- **GC support** - Efficient storage management for long-running systems

Your facts benefit from the same engineering that secures a live blockchain, but with Git's simplicity instead of complex consensus protocols.

## Best Practices

### 1. Multiple Geographic Regions
Deploy in at least 3 regions across different continents to survive regional disasters.

### 2. Automated Sync
Use cron or systemd timers to pull and recompile regularly (hourly or daily depending on update frequency).

### 3. Monitoring
Monitor each host's:
- Git sync status (last successful pull)
- Pack compilation status (last successful compile)
- Query service health (HTTP endpoint checks)
- Disk space (Pack stores grow over time)

### 4. Version Tagging
Use Git tags for important milestones:
```bash
git tag -a v1.0 -m "Complete migration of legacy data"
git push origin v1.0
```

### 5. Backup Git Repository
Mirror the Git repository to multiple hosting providers:
```bash
git remote add backup git@gitlab.com:org/facts.git
git push backup main
```

### 6. Document Failover Procedures
Maintain runbooks for common scenarios:
- Promoting a replica to primary
- Adding new replicas
- Recovering from corruption
- Restoring historical snapshots

## Comparison with Traditional Approaches

| Approach | Single Point of Failure | Verification | Geographic Distribution | Complexity |
|----------|------------------------|--------------|------------------------|------------|
| **Traditional DB** | Yes (primary server) | No built-in verification | Requires complex replication | High |
| **Blockchain** | No | Cryptographic proofs | Yes | Very High |
| **BeingDB** | No (Git + replicas) | Content-addressed | Yes | Low |

BeingDB provides blockchain-style guarantees with Git-level simplicity.

## See Also

- [Deployment Guide](deployment.md) - Production Docker setup
- [Internals](internals.md) - Pack storage format details
- [Getting Started](getting-started.md) - Basic usage tutorial
