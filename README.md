# redz

A small **Redis-compatible cache** written in Zig.

redz speaks the Redis RESP protocol so common clients (`redis-cli`, `ioredis`, `redis-py`, etc.) can talk to it. It is **not** Redis: the command set is intentionally incomplete and growing.

## Features

- Persistent TCP connections with command pipelining
- Thread-per-connection server (mutex-protected store)
- Strings, lists, sets, hashes + key TTL helpers
- Optional RDB snapshots and AOF persistence (custom `REDZ` format)
- CLI flags and environment variable configuration
- Docker image + Compose with a data volume

## Quick start

### Local

Requires [Zig 0.15.2](https://ziglang.org/download/).

```bash
zig build
zig build run -- --host 127.0.0.1 --port 6379

# another terminal
redis-cli -p 6379 PING
redis-cli -p 6379 SET foo bar
redis-cli -p 6379 GET foo
```

### Docker Compose

```bash
docker compose up --build -d
redis-cli -p 6379 PING
```

Data is stored in the `redz-data` volume (`/data` in the container).

## Configuration

CLI flags override environment variables.

| Flag | Env | Default | Description |
|------|-----|---------|-------------|
| `--host` | `REDZ_HOST` | `127.0.0.1` | Bind address (`0.0.0.0` in Docker) |
| `--port` | `REDZ_PORT` | `6379` | Listen port |
| `--persistence` | `REDZ_PERSISTENCE` | `none` | `none`, `rdb`, `aof`, or `both` |
| `--data-dir` | `REDZ_DATA_DIR` | `.` | Directory for dump/AOF files |
| `--rdb-filename` | `REDZ_RDB_FILENAME` | `dump.redz` | RDB filename |
| `--aof-filename` | `REDZ_AOF_FILENAME` | `appendonly.redz.aof` | AOF filename |
| `--snapshot-interval` | `REDZ_SNAPSHOT_INTERVAL` | `60` | Seconds between RDB snapshots (`0` disables) |
| `--aof-fsync` | `REDZ_AOF_FSYNC` | `everysec` | `always`, `everysec`, or `no` |

Example with persistence:

```bash
zig build run -- \
  --host 0.0.0.0 \
  --port 6379 \
  --persistence both \
  --data-dir ./data \
  --snapshot-interval 60
```

## Supported commands

| Group | Commands |
|-------|----------|
| Connection | `PING`, `ECHO` |
| Strings | `SET`, `GET` |
| Keys | `DEL`, `EXISTS`, `EXPIRE`, `TTL`, `PERSIST` |
| Lists | `LPUSH`, `RPUSH`, `LPOP`, `RPOP`, `LRANGE` |
| Sets | `SADD`, `SREM`, `SMEMBERS`, `SISMEMBER` |
| Hashes | `HSET`, `HGET`, `HDEL`, `HGETALL` |
| Persistence | `SAVE`, `LASTSAVE` |

Missing Redis features (auth, `INCR`, `SET EX`, pub/sub, replication, cluster, …) are tracked as future work — see the project roadmap discussion in issues.

## Persistence notes

- RDB uses a custom binary format (`REDZ` magic), not Redis RDB compatibility.
- AOF stores raw RESP command bytes for mutating commands.
- Startup order: load RDB (if enabled) → replay AOF (if enabled) → serve traffic.
- Shutdown (`SIGINT`/`SIGTERM`): close/fsync AOF, then write an RDB snapshot when RDB is enabled.

## Development

```bash
zig build test
zig build -Doptimize=ReleaseFast
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
