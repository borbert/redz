# redz

A small **Redis-compatible cache** written in Zig.

redz speaks the Redis RESP protocol so common clients (`redis-cli`, `ioredis`, `redis-py`, etc.) can talk to it. It is **not** Redis: the command set is intentionally incomplete and growing.

## Features

- Persistent TCP connections with command pipelining
- Thread-per-connection server (mutex-protected store)
- Strings, lists, sets, hashes + key TTL helpers
- Optional RDB snapshots and AOF persistence (custom `REDZ` format)
- Password auth (`AUTH` / `--requirepass`)
- Optional TLS (OpenSSL) via `--tls-cert` / `--tls-key`
- CLI flags and environment variable configuration
- Docker image + Compose with a data volume

## Quick start

### Local

Requires [Zig 0.15.2](https://ziglang.org/download/) and OpenSSL development libraries (`libssl` / `libcrypto`).

```bash
zig build
zig build run -- --host 127.0.0.1 --port 6379 --requirepass mypass

# another terminal
redis-cli -p 6379 -a mypass PING
redis-cli -p 6379 -a mypass SET foo bar
redis-cli -p 6379 -a mypass GET foo
```

### TLS (local)

```bash
chmod +x scripts/gen-dev-certs.sh
./scripts/gen-dev-certs.sh ./certs

zig build run -- \
  --host 127.0.0.1 --port 6379 \
  --requirepass mypass \
  --tls-cert ./certs/cert.pem \
  --tls-key ./certs/key.pem

# clients use rediss:// (TLS)
redis-cli --tls --insecure -p 6379 -a mypass PING
```

### Docker Compose

```bash
docker compose up --build -d
redis-cli -p 6379 -a "${REDZ_REQUIREPASS:-changeme}" PING
```

Data is stored in the `redz-data` volume (`/data` in the container). Mount certs at `/certs` when enabling TLS.

## Configuration

CLI flags override environment variables.

| Flag | Env | Default | Description |
|------|-----|---------|-------------|
| `--host` | `REDZ_HOST` | `127.0.0.1` | Bind address (`0.0.0.0` in Docker) |
| `--port` | `REDZ_PORT` | `6379` | Listen port |
| `--requirepass` | `REDZ_REQUIREPASS` | _(unset)_ | Password for `AUTH` (required for public/remote) |
| `--tls-cert` | `REDZ_TLS_CERT` | _(unset)_ | PEM certificate path (enables TLS with `--tls-key`) |
| `--tls-key` | `REDZ_TLS_KEY` | _(unset)_ | PEM private key path |
| `--persistence` | `REDZ_PERSISTENCE` | `none` | `none`, `rdb`, `aof`, or `both` |
| `--data-dir` | `REDZ_DATA_DIR` | `.` | Directory for dump/AOF files |
| `--rdb-filename` | `REDZ_RDB_FILENAME` | `dump.redz` | RDB filename |
| `--aof-filename` | `REDZ_AOF_FILENAME` | `appendonly.redz.aof` | AOF filename |
| `--snapshot-interval` | `REDZ_SNAPSHOT_INTERVAL` | `60` | Seconds between RDB snapshots (`0` disables) |
| `--aof-fsync` | `REDZ_AOF_FSYNC` | `everysec` | `always`, `everysec`, or `no` |

Example for a private remote deploy:

```bash
zig build run -- \
  --host 0.0.0.0 \
  --port 6379 \
  --requirepass "$REDZ_REQUIREPASS" \
  --tls-cert /certs/cert.pem \
  --tls-key /certs/key.pem \
  --persistence both \
  --data-dir /data
```

App connection strings:

- Plain + auth: `redis://:mypass@host:6379`
- TLS + auth: `rediss://:mypass@host:6379`

## Supported commands

| Group | Commands |
|-------|----------|
| Connection | `PING`, `ECHO`, `AUTH` |
| Strings | `SET`, `GET` |
| Keys | `DEL`, `EXISTS`, `EXPIRE`, `TTL`, `PERSIST` |
| Lists | `LPUSH`, `RPUSH`, `LPOP`, `RPOP`, `LRANGE` |
| Sets | `SADD`, `SREM`, `SMEMBERS`, `SISMEMBER` |
| Hashes | `HSET`, `HGET`, `HDEL`, `HGETALL` |
| Persistence | `SAVE`, `LASTSAVE` |

Still missing vs Redis: `INCR`, `SET EX`, pub/sub, replication, cluster, ACL users, … — add as needed.

## Security notes

- When `--requirepass` is set, every command except `AUTH` returns `NOAUTH` until a successful login.
- Password compare uses constant-time equality for equal-length secrets.
- Prefer TLS (`rediss://`) for anything crossing networks; self-signed certs are fine for private VPC use if clients trust them (or use `--insecure` only in dev).
- Do not commit real passwords or private keys. Keep them in env / secret stores / mounted volumes.

## Persistence notes

- RDB uses a custom binary format (`REDZ` magic), not Redis RDB compatibility.
- AOF stores raw RESP command bytes for mutating commands (`AUTH` is not logged).
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
