# Contributing to redz

Thanks for helping improve redz.

## Development

Requirements:

- Zig `0.15.2` (see `build.zig.zon`)

Useful commands:

```bash
zig build
zig build test
zig build run -- --host 127.0.0.1 --port 6379
```

## Pull requests

1. Keep changes focused.
2. Add or update tests for behavior changes.
3. Run `zig build test` before opening a PR.
4. Update the supported-commands table in `README.md` when adding commands.

## Issue reports

Please include:

- Zig version
- How you ran redz (CLI flags / Docker)
- Minimal reproduction (commands + expected vs actual)

## Scope

redz is intentionally a Redis-*compatible* subset for caching. Prefer small, useful command additions over full Redis parity.
