# Testing

This repo uses shell-based checks for automation scripts.

## Local

```bash
./scripts/test.sh
```

Requires `shellcheck` and `shfmt`.

## CI-compatible

```bash
./scripts/ci.sh
```

Installs dependencies (Ubuntu) and runs the tests.

## What is checked

- `bash -n` syntax checks for all `.sh` files
- `shellcheck` for common shell pitfalls
- `shfmt -d` formatting verification
- ISO smoke checks when an ISO is present in `dist/` or `build/cubic/iso/output` (format and essential files)
