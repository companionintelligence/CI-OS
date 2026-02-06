# Cubic ISO build (Ubuntu)

Cubic is a GUI tool. The workflow below prepares a reproducible workspace and lets you build a CI-OS ISO interactively, then collect it into `dist/`.

## Prereqs

- Ubuntu host with a desktop session
- Cubic installed (`sudo apt install cubic`)
- Enough disk space for the base ISO, the Cubic project, and the output ISO

## Local build

```bash
./scripts/cubic/launch.sh
```

That script:

- Downloads the Ubuntu base ISO (24.04.2 by default)
- Verifies SHA256 checksums
- Prepares a Cubic workspace under `build/cubic/`
- Writes `build/cubic/INSTRUCTIONS.txt`
- Launches Cubic

Follow the instructions shown in `build/cubic/INSTRUCTIONS.txt` while inside Cubic.

After exporting the ISO from Cubic, collect it into `dist/`:

```bash
./scripts/cubic/collect-iso.sh
```

## GitHub Actions (self-hosted)

A workflow is provided at `.github/workflows/build-iso-cubic.yml`. It must run on a self-hosted runner with a GUI and Cubic installed.

The workflow prepares the workspace and waits for an ISO to appear in:

```
build/cubic/iso/output
```

During the run, open a GUI session on the runner, launch Cubic, and export the ISO to that output directory. The workflow then collects the ISO and uploads it as an artifact.

## Environment overrides

You can override defaults when running the scripts:

- `UBUNTU_ISO_NAME`
- `UBUNTU_ISO_URL`
- `UBUNTU_ISO_SHA256SUMS_URL`
- `CUBIC_WORKDIR`
- `CUBIC_PROJECT_DIR`
- `CUBIC_ISO_BASE_DIR`
- `CUBIC_ISO_OUTPUT_DIR`
- `CUBIC_WAIT_MINUTES`
- `CUBIC_SKIP_VERIFY=1` (skip SHA256 check)
