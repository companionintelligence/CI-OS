# Security policy

This policy covers Companion OS, the appliance operating system built from this repository (the Ubuntu edition and the Plasma
edition), and `ci-stick`, the Companion Stick command line tool. It says how to report a vulnerability privately, what to put in a
report, which versions get fixes and what is in scope.

## How to report a vulnerability

Report it privately. Do not open a public issue, pull request or discussion about it.

Use GitHub's private vulnerability reporting for this repository: on the **Security** tab of
[companionintelligence/CI-OS](https://github.com/companionintelligence/CI-OS/security), choose **Report a vulnerability** and fill in
the form. Only you and the maintainers of the repository can read the report. The form is at
<https://github.com/companionintelligence/CI-OS/security/advisories/new>.

## What to put in a report

- What is affected: the component (an image, the setup portal, a build or release script, `ci-stick`) and its version. For an image,
  its file name and sha256; for a build from source, the commit; for `ci-stick`, what `ci-stick --version` prints.
- How to reproduce it, step by step, on a machine or a virtual machine that you own.
- What an attacker gains, and what they need first (a place on the setup hotspot, a user account, physical access).
- Whether you know of it being used.

The sha256 of an image and the version of `ci-stick`:

```bash
shasum -a 256 companion-os-*.iso
ci-stick --version
```

**Never put a credential in a report.** No password, token, private key, device key, tunnel token or session cookie, yours or anyone
else's, and none in a screenshot or a log either. If the problem is a secret that is exposed, say where it is (the file and line, or
the URL) and what kind of secret it is, never its value. A credential that arrives in a report anyway is treated as exposed.

## Supported versions

No release of Companion OS has been published yet **[N]**. From the first release on, these get security fixes:

| Component | Supported |
|---|---|
| Companion OS, Ubuntu edition (Ubuntu 26.04.1 LTS base), amd64 and arm64 | the current release |
| Companion OS, Plasma edition (x86-64) | an image built within the expiry window of [gate 12 of the release checklist](docs/guides/release-checklist.md#12-retired-baselines-and-stale-builds); the edition is a rolling release, so an older image is replaced by a new build, not patched |
| `ci-stick` | the current release |
| An image built on Ubuntu 24.04, or on a base that was retired on 2026-10-17 | not supported |

## Scope

In scope:

- the build and release scripts (`backends/ubuntu/iso/`, `backends/cachyos/iso/`) and the workflows in `.github/workflows/`;
- the first boot and the setup portal: the first-boot units and provisioning, and `core/headless/` (the setup hotspot, its portal and
  its backend);
- the release pipeline: checksums, signatures, publishing and the published files;
- `ci-stick` (`stick/`), its device-safety rules included.

Out of scope:

- vulnerabilities in the packages of the upstream distributions and in vendors' own binaries: report those to the upstream project.
  They are in scope when the problem is our pin or our configuration (a pinned version we did not update, a setting we changed);
- attacks that need physical access to an unlocked machine;
- denial of service by a user who already has root on the machine.

## What happens after a report

The times below are proposals, **owner to confirm** before anyone relies on them.

| Step | Proposed time (owner to confirm) |
|---|---|
| The report is acknowledged | within 5 working days |
| You get a first assessment: confirmed or not, severity, affected versions | within 15 working days |
| A fix or a mitigation is released | depends on the severity; the plan comes with the assessment |
| The advisory is published | when the fix is released, or after 90 days, whichever is first, unless another date is agreed with you |
| Credit | in the advisory, if you want it |

Keep the report private until the advisory is published.

© Companion Intelligence, Lifescope Inc
