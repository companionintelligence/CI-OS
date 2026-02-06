# AGENTS.md

## Project summary
CI OS builds a custom Ubuntu-based distribution branded Companion Intelligence. Core flows include:
- Preparing a Cubic project workspace and staging bundle
- Building a customized ISO via Cubic
- Collecting build outputs into `dist/`

## Key paths
- Cubic scripts: `scripts/cubic/`
- Customization scripts: `configs/scripts/`
- Branding assets: `setup/os-changes/`, `assets/`
- Docs: `docs/`

## Commands (local)
- Tests: `./scripts/test.sh`
- ISO smoke check: `./scripts/test-iso.sh`
- CI checks (installs deps): `./scripts/ci.sh`
- Cubic build: `./scripts/cubic/launch.sh`

## Testing expectations
- All shell scripts should pass:
  - `bash -n` syntax check
  - `shellcheck`
  - `shfmt -d`

## Definition of done
- Shell checks pass locally and in CI
- Any new scripts are executable and added under `scripts/` or `configs/scripts/`
- Docs updated when workflows change
