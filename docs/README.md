# Documentation index

Private & Confidential. Property of Lifescope Inc. Do not distribute.

Every document under `docs/` is listed here with one line, grouped as overview, architecture, guides, operations, evidence and
plans. Documentation that lives next to the code is listed at the end. The front page of the repository is
[`../README.md`](../README.md); the guide for agents and new maintainers is [`../CLAUDE.md`](../CLAUDE.md).

Companion OS has two supported targets: Companion OS on Ubuntu 26.04.1 LTS (amd64, and arm64 since 2026-10-19) and Companion OS on CachyOS (Plasma edition, x86-64).
Evidence tags used throughout: **[V]** verified, **[I]** implemented and not proven end to end, **[N]** not implemented.

## Start here, by task

| I want to | Read |
|---|---|
| Understand what is supported and what each edition can do | [Supported targets](architecture/supported-targets.md) |
| Build an ISO | [ISO build guide](guides/iso-build-guide.md), then [Building on a Mac](guides/building-on-a-mac.md) if you are on a Mac |
| Install Companion OS | [Installation guide](guides/installation-guide.md), [Quick start](guides/quick-start-guide.md) |
| Make or flash a Companion Stick | [`stick/README.md`](../stick/README.md), [Companion Stick](architecture/companion-stick.md) |
| Boot an image in QEMU and take screenshots | [Testing in QEMU](guides/testing-in-qemu.md) |
| See how other distros install and start, and what to fix first | [First-run teardown](architecture/ftue-teardown.md) |
| Know which tests to run for my change | [Running the tests](guides/running-the-tests.md) |
| Look up an environment variable | [Environment reference](guides/environment-reference.md) |
| Deploy CI-Hub on an appliance | [CI-Hub deploy](guides/ci-hub-deploy.md) |
| Find the records behind a verified claim | [Evidence records](evidence/README.md) |
| Know what has actually been tested | [Test evidence](architecture/test-evidence.md) |
| See what is broken or undecided | [Known issues and decisions](architecture/known-issues-and-decisions.md) |
| Publish an ISO | [Release checklist](guides/release-checklist.md) |
| Add a target, or bring a retired one back | [Supported targets, sections 7 and 8](architecture/supported-targets.md#7-retired-targets-and-the-restore-recipe) |
| Understand how the repository is organised | [Core and backends design](architecture/multi-distro-design.md) |
| Open a pull request that will merge | [`.claude/skills/steward/SKILL.md`](../.claude/skills/steward/SKILL.md) |

## Overview

| Document | What it is |
|---|---|
| [Companion OS on arm64](architecture/arm64.md) | The arm64 architecture of the Ubuntu edition (supported since 2026-10-19): what was built and run on 2026-10-19 (build 19 min, verify 436/0, install 12 min, Hub up), what differs from amd64, how to build it, what is not proven |
| [Supported targets](architecture/supported-targets.md) | The support policy: the two targets, what "supported" means, the capability matrix with evidence tags, per-target caveats, pending evidence, the retirement notice and the restore recipe, and how a target is added. |
| [Core and backends design](architecture/multi-distro-design.md) | How `core/` and `backends/<name>/` fit together, the Ubuntu gresource mechanic, the CachyOS backend, the frozen Arch engine and the findings frozen code cites, the ecosystem manifest, the per-backend contract and the rollout history. The file name is historical. |
| [Known issues and decisions](architecture/known-issues-and-decisions.md) | The open defects and open decisions, each with severity, evidence, an owner column and the decision needed. |

## Architecture

Design records. Each states its own status and evidence.

| Document | What it is |
|---|---|
| [First-run teardown](architecture/ftue-teardown.md) | How stock Ubuntu 26.04.1, Fedora Workstation 44 and Debian 13.7 install and start on arm64, read with the stopwatch and counts of the polish proposal, set next to Companion OS: the tables, a scorecard (ahead on 3, level on 4, behind on 10) and the nine gaps ranked by what the best installers do. A virtual machine, one run each. |
| [Ubuntu ISO layers](architecture/ubuntu-iso-layers.md) | Why the Ubuntu ISO's root filesystem is split into an installer base layer and a live-only layer, what is in each, how to extend the list, and which tests prove it. |
| [Ubuntu 26.04.1 port notes](architecture/ubuntu-2604-port-notes.md) | What changed from 24.04 to 26.04.1 and why, fact by fact, each with its evidence tag and the test that guards it. |
| [One-click install](architecture/one-click-install.md) | The automatic installer: what the user sees, the safety rules, the subiquity state handling, the GRUB entry, the tests and the honest status. |
| [Optional tools in the Ubuntu ISO](architecture/tier-b-tools.md) | Tailscale, cloudflared, GitHub CLI, Ollama and the Companion Launcher: how they are baked in with pinned keys and hashes, and what they cost in size. |
| [Docker in live sessions](architecture/docker-in-live-sessions.md) | How Docker runs on the installed system, in the live ISO and in a Stick live boot: the `docker` group, the data root, the tests. |
| [CachyOS edition](architecture/cachyos-backend.md) | The pinned upstream plus overlay, the three provisioning layers, identity, Secure Boot and Stick limits, verification, the risk register and the 2026-10-18 rolling-release incident. |
| [Headless Wi-Fi setup](architecture/headless-setup.md) | How the hotspot setup works today, the 51-defect audit, the threat model, the redesign, the phased plan and the tested `ci_setup` library. |
| [Companion Stick](architecture/companion-stick.md) | The Stick's architecture, layout, trust model, boot chain, A/B slots and roadmap. |
| [Companion Stick on 128 GB sticks](architecture/companion-stick-128gb.md) | Index and decision record for the first batch of nine 128 GB sticks: Docker, optional tools, models, mass flashing. |
| [Model packs for 128 GB sticks](architecture/model-packs-128gb.md) | The packs `stick-128` and `stick-128-oci`: exact sizes, how they fit, licences. |
| [Model download and cache tooling](architecture/models-tooling.md) | `ci-stick models` and the OS-side adapter: the lock, resumable verified fetch, the cache layout, the Hugging Face view and the hardware-fit gate. |

## Guides

| Document | What it is |
|---|---|
| [ISO build guide](guides/iso-build-guide.md) | Building a Companion OS ISO for either edition, with the build host rules and what the verifier checks. |
| [Installation guide](guides/installation-guide.md) | Installing either edition step by step, first boot, hotspot setup, models, recovery and troubleshooting. |
| [Quick start guide](guides/quick-start-guide.md) | The short path from a built ISO to a running appliance. |
| [GDM branding package](guides/gdm-branding-package.md) | How the `dpkg-divert` package that brands the GNOME login screen is built and why it is update-safe (Ubuntu edition). |
| [Package repository setup](guides/package-repository-setup.md) | The status of an apt package repository for CI-OS packages and what a repository for Ubuntu 26.04 would need. |
| [CI-Hub deploy](guides/ci-hub-deploy.md) | `core/lib/ci-hub.sh` and `pull-dev-manual.sh`: inputs, how to supply secrets, what is created, ports, how to confirm and tear down, the security notes and the tunnel certificate. |
| [Environment reference](guides/environment-reference.md) | The environment variables an operator or maintainer sets, by area: building, verifying, the installer, the model gate, first boot, `ci-stick`, tests. |

## Operations

| Document | What it is |
|---|---|
| [Building on a Mac](guides/building-on-a-mac.md) | The Apple-silicon recipe: the ARM64 `ubuntu:26.04` container, the CachyOS builder under Rosetta, and the Docker Desktop hazards (binfmt registrations, Time Machine snapshots, disk space). |
| [Testing in QEMU](guides/testing-in-qemu.md) | Booting, installing and photographing the images under QEMU on Apple silicon: firmware, CPU models, devices, QMP, timings under software emulation. |
| [Release checklist](guides/release-checklist.md) | The gates before an ISO of either edition is published: clean build, verifier, installed boot, install, checksums and signing, the images that must never be published, and the gates for a Stick bundle. |
| [Running the tests](guides/running-the-tests.md) | Every suite with what it covers, what it needs, whether the gate runs it, and which ones to run for the change you made. |
| [Mass flashing](architecture/mass-flashing.md) | Design and runbook for flashing many Companion Sticks with `ci-stick`. Investigation; no batch tooling exists yet. |
| [Running CI](CI.md) | How to start the gated GitHub workflows. Generated by `ci-local docs`; do not edit by hand. |

## Evidence

| Document | What it is |
|---|---|
| [Test evidence](architecture/test-evidence.md) | What has been run, where, with what result and count, split into verified, implemented-unproven and not implemented, and the table of pending evidence for the Ubuntu 26.04 image. |
| [Evidence records](evidence/README.md) | The small text records behind the verified rows: build records, verifier logs, installed-boot results and the sha256 of each image, with the rules for adding a run. |
| [`ui/`](ui/) | Screenshots. `setup-portal-*.png` are the six states of the setup portal (used by the README). Edition screenshots are under `ui/companion-os/`, indexed in [`ui/companion-os/README.md`](ui/companion-os/README.md). |
| [`ui/companion-os/ubuntu/`](ui/companion-os/ubuntu/CAPTURE.md) | The Ubuntu edition (arm64 image of `4b7597d`, 2026-10-19): 10 frames from the boot menu to Hub's pairing screen, in a virtual machine with hardware acceleration, with `CAPTURE.md` (inputs, times, redactions, what went wrong in the run) and `MANIFEST.json`. |
| [`ui/ftue-teardown/`](ui/ftue-teardown/CAPTURE.md) | Frames of the first-run teardown (2026-10-19): 35 captures of stock Ubuntu 26.04.1, Fedora 44 and Debian 13.7 on arm64 in a virtual machine, three comparison figures, one `MANIFEST.json` per distro, and `CAPTURE.md` (inputs, times, hygiene). The text records are in `docs/evidence/2026-10-19-ftue-teardown/`. |
| [`ui/companion-os/plasma/`](ui/companion-os/plasma/CAPTURE.md) | The Plasma edition capture of ISO #6 (2026-10-18): 29 frames of the live medium, the installer and the installed system, in a virtual machine, with `CAPTURE.md` (command lines, timings, what was fixed and found, hygiene checks) and `MANIFEST.json`. The Ubuntu frames are still to be captured; the documents carry commented-out placeholders for them, and the one table of figure names is in the [Figures section of the test evidence page](architecture/test-evidence.md#figures). |

The text records of the main runs are in `docs/evidence/`, and the records and frames of the Plasma ISO #6 run are in `docs/evidence/2026-10-18-plasma-iso6/` and
`docs/ui/companion-os/plasma/`. The transcripts, frames and capture notes of the earlier runs that are not copied yet are still in the
session scratch directory outside the repository; the documents quote what they showed and say so.

## Plans and specifications

| Document | What it is |
|---|---|
| [Strix Halo ROCm for Companion OS on Ubuntu](plans/strix-halo-rocm-companion-ubuntu.md) | What ROCm line to install on Ubuntu 26.04 for Strix Halo, and the open decision between the archive's ROCm and AMD's repository. |
| [Testing and mass flashing: the plan](architecture/test-and-mass-flash-plan.md) | The test ladder, the IP-KVM bench and the mass-flash rollout, produced by three designers and two red-team reviews. A plan, not an implementation. |
| [Headless setup: the original specification](Create-headless-setup.md) | The prompt that specified the first headless setup system. It is a specification, not a description: the code did not follow all of it (see the headless setup page). |

## Documentation next to the code

| Document | What it is |
|---|---|
| [`../backends/ubuntu/iso/README.md`](../backends/ubuntu/iso/README.md) | The Ubuntu ISO tools: build host, how the build works, layers, flags, branding, script tests, verification, troubleshooting. |
| [`../backends/cachyos/README.md`](../backends/cachyos/README.md) | The CachyOS edition: build, verify, boot test, tests, layout, rolling-release drift, pins, decisions D1 to D9, known limits. |
| [`../backends/cachyos/NOTICE`](../backends/cachyos/NOTICE) | Provenance and licences of the CachyOS edition; what is not shipped. |
| [`../backends/cachyos/installer/README.md`](../backends/cachyos/installer/README.md) | The Calamares overlay, the launcher, and the known issue in the shared setup payload. |
| [`../backends/cachyos/iso/scripts/README.md`](../backends/cachyos/iso/scripts/README.md), [`../backends/cachyos/iso/overlay/README.md`](../backends/cachyos/iso/overlay/README.md), [`../backends/cachyos/iso/overlay/INSTALLED.md`](../backends/cachyos/iso/overlay/INSTALLED.md) | Build scripts, the overlay format, and what the overlay installs. |
| [`../backends/ubuntu/chroot/payload/models/README.md`](../backends/ubuntu/chroot/payload/models/README.md) | The OS side of model tooling: cache environment, Hugging Face view, hardware gate, opt-in prefetch. |
| [`../stick/README.md`](../stick/README.md) | The `ci-stick` CLI: build, usage, models, flashing, the QEMU and Secure Boot harnesses, the staging layout. |
| [`../stick/tests/qemu/README-hotspot.md`](../stick/tests/qemu/README-hotspot.md) | The QEMU hotspot test stack (mac80211_hwsim). |
| [`../core/README.md`](../core/README.md) | What lives in `core/` and why. |
| [`../assets/branding/brand-guidelines.md`](../assets/branding/brand-guidelines.md) | The brand token table and the pointer to CI-Common. |
| [`../.claude/skills/steward/SKILL.md`](../.claude/skills/steward/SKILL.md) | Pull-request conventions: validation, where code lives, what never gets committed, stale branches, security-sensitive areas. |
| [`../CLAUDE.md`](../CLAUDE.md), [`../AGENTS.md`](../AGENTS.md), [`../ANTIGRAVITY.md`](../ANTIGRAVITY.md), [`../.github/copilot-instructions.md`](../.github/copilot-instructions.md) | Agent guides. `CLAUDE.md` is canonical; the others restate the rules. |
| [`../LICENSE.md`](../LICENSE.md), [`../License-FAQ.md`](../License-FAQ.md), [`../NOTICE.md`](../NOTICE.md), [`../THIRD_PARTY.md`](../THIRD_PARTY.md), [`../CREDITS.md`](../CREDITS.md) | Licence and attribution. |

## Conventions for documents in this repository

* Evidence tags **[V]**, **[I]**, **[N]** on every claim about behaviour; a row that waits for a run says what will confirm it.
* The product is "Companion OS", no hyphen. Public file names and titles never carry the CachyOS mark; engineering documents may name it.
* Sentence-case headings, tables for matrices, every command in a fenced block that can be pasted, no em or en dashes in new prose.
* Retired targets are named only in the retirement notice and in the places `core/lib/retired-names.allow` lists, or on a line that
  cites the restore tag `pre-retire-multidistro-2026-10-17`.
* A new document is added to this index, linked from at least one other document, and `git add`ed. **Nothing in the gate enforces any of that**:
  `core/lib/check-untracked-deps.sh` looks at scripts and configuration and explicitly skips Markdown and `docs/`, so a tracked document that
  links to an untracked one passes. Check by hand (`git status --short docs` lists untracked files, and a link scan of the tree finds a link that
  does not resolve). A document that `core/headless/tests/ci_setup` reads (`architecture/headless-setup.md`) is re-checked with
  `bash core/headless/tests/ci_setup/run.sh --quick`.
* A figure that waits for a frame is a commented-out line in the one scheme `docs/ui/companion-os/<edition>/NN-<slug>.png` with the slugs of the table in
  [test-evidence.md](architecture/test-evidence.md#figures); `NN` is written literally. Once the frame exists the line becomes a real image with a relative path
  and alt text. A frame of a virtual machine says so in its caption.
* A record behind a **[V]** is copied into `docs/evidence/` (see its README); a path in a session scratch directory is not a durable source.
