# Running CI for this repo

Automatic workflow triggers in this repository are **gated**: pushing does not
start a GitHub-hosted run any more. Checks run on local hardware, and the
workflows that remain are started deliberately.

Why: GitHub Actions was costing the org $563/month, almost all of it hosted
compute for checks that run just as well on hardware we already own.

Starting a gated workflow needs the [`gh` CLI](https://cli.github.com) and push
access. `--ref` matters - the workflow file is read from that branch, so a
workflow that only exists on your feature branch must be dispatched against it.

Full cross-repo runbook: `CI-Local-CICD/RUNBOOK.md` (regenerate with
`ci-local docs`). This file is generated - do not hand-edit.

---

Default branch: `main`

### Test locally

_No local checks detected._

### Run a check workflow on GitHub

**Build Companion OS ISO** — `build-companion-os-iso.yml`

```bash
gh workflow run build-companion-os-iso.yml --repo companionintelligence/CI-OS --ref main -f version=1.0 -f arch=both -f publish=none -f sign=false -f runner_amd64=ubuntu-24.04 -f runner_arm64=ubuntu-24.04-arm
```

Required inputs: `version` (Companion OS version, as in the image names (1.0, 1.1, 1.0-rc1))

**PR checks** — `pr-checks.yml`

```bash
gh workflow run pr-checks.yml --repo companionintelligence/CI-OS --ref main
```

**Companion Stick real-ISO smoke test** — `stick-real-iso.yml`

```bash
gh workflow run stick-real-iso.yml --repo companionintelligence/CI-OS --ref main -f ubuntu_release_dir=26.04 -f ci_os_run_id=<value> -f ci_os_artifact=companion-os-amd64
```

Required inputs: `ubuntu_release_dir` (releases.ubuntu.com directory holding the desktop ISO + SHA256SUMS)

**Style canon lint** — `style-canon-lint.yml`

```bash
gh workflow run style-canon-lint.yml --repo companionintelligence/CI-OS --ref main
```
