# Security

Every image this repository builds or pulls is inventoried and vulnerability-scanned, and a
fixable HIGH or CRITICAL advisory fails the run that produced it. The scans run in
[`.github/workflows/security.yml`](.github/workflows/security.yml), the scripts in
[`security/`](security) produce the reports, and `security/gate.sh` decides.

## Layers

| Layer | What runs | Where |
| --- | --- | --- |
| build | the image this repository ships | `make build`, CI `Scan images` |
| inventory | Syft writes a CycloneDX SBOM | `security/scan.sh` |
| vulnerabilities | Trivy, distro-aware, JSON | `security/scan.sh` |
| policy | `security/gate.sh` over the reports | CI `Security gate`, `make gate` |

## What gets scanned

An image this repository builds: CI builds it and scans the image id the build produced, never a
tag, which can move between the build and the scan.

An image this repository only pulls: every base image pinned by digest in the `Dockerfile` is
scanned by that digest, which needs no build. `security/scan-digests.sh` reads the reference off
the `FROM` line, so the pin has one home, and a `FROM` line without a digest fails the run instead
of scanning a tag.

Nothing else here is a container image. The worker VM boots a Debian disk image, which the
scanners do not read.

## Policy

```
block   Trivy reports HIGH or CRITICAL with a fixed version available. Trivy matches OS and
        language packages against the distro's own advisories, so the finding is actionable: a
        base image or package bump clears it.
report  everything else: unfixed findings and UNKNOWN severities.
```

The gate reads the reports in a job of its own and is the only thing that fails a run on a
finding, so a blocked run keeps its evidence. A report the gate cannot read fails it: an empty,
truncated or missing file is not a clean image.

When one run scans multiple images, the gate deduplicates its blocking-finding output by advisory
ID, package name, installed version and fixed version. It prints each unique finding once and lists
every affected image; the gate still evaluates each image independently, so a repeated finding is
not ignored or allowed through. The summary distinguishes unique findings from image-level
occurrences. This reduces noisy repeated reports without losing which app images are affected.

Repository-level GitHub dependency alerts and code scanning are complementary to this check. The
Trivy scan is retained for the actual built image, including OS packages and dependencies installed
during the Docker build that may not be represented by repository manifests. Syft remains the one
SBOM generator in this pipeline.

No exceptions are in force. A temporary one needs its reason and its expiry date in this file, in
the same commit as the exception.

## Runtime trust boundaries

The launcher is [`scripts/sandbox.sh`](scripts/sandbox.sh), the firewall
[`scripts/init-firewall.sh`](scripts/init-firewall.sh), the privilege drop
[`scripts/sandbox-entrypoint.sh`](scripts/sandbox-entrypoint.sh). A run starts as root only long
enough to build the firewall, then drops `NET_ADMIN` and `NET_RAW` from every capability set and
the agent runs as `node`.

**Network.** The default is `NETWORK=bridge` on its own network, never the shared default bridge.
Egress is default deny: `filter` policies go to `DROP` first, then the pre-resolved allowlist and
this run's grants are admitted. Every other Docker subnet is closed, so a `<host>:<port>` grant
cannot reach a sibling container, `HOST_SERVICES` opens only this container's own gateway, and
`PORTS` publishes on `127.0.0.1` only.

`NETWORK=host` skips the firewall (`SANDBOX_SKIP_FIREWALL=1`), so every egress grant is unenforced
and the container reaches what the host reaches, loopback included. `PORTS` is refused there. It
still drops to `node` and still runs without `NET_RAW`. Give it only to work that needs the host
namespace and is trusted as much as the host.

**Credentials.** `$HOME`, the notes vault below its `work` layer, `~/.ssh`, `~/.gnupg` and the
grant directory of another run are never mounted, and a project directory that is `$HOME` or holds
`.ssh` or `.gnupg` is refused. Every other mount is a base-config catalogue entry, gated by its own
options: `auth` needs `GIT_AUTH=true`, an agent directory needs that agent enabled, `grant=` needs
its feature, `ro` stays read-only. Claude's directory is never mounted whole, only its credentials
file and its own project history, and a symlink inside an agent directory is followed only inside a
declared follow root, so a link planted earlier cannot carry an arbitrary host file in. The
operator's `~/.gitconfig` is never mounted because it can name a credential helper; the image gets a
plain config, and a project's `.git/config` still wins. A tool credential is one file, never a
directory, and never a path on that deny list.

**What a compromised container keeps.** The mounts, readable or writable by their mode, and the
credentials mounted with them. Nothing privileged from the host: no daemon socket, no host network,
no extra capability, so an agent inside cannot start containers or read other images. The scanners
below are the only thing here that holds the socket, and they run on the host or in CI.

## Reports

Reports are CI artifacts kept for 90 days and never committed. `scan-manifest.txt` lists every
image expected in the run; each image directory must contain a valid Trivy report, a CycloneDX
SBOM, the scan target and scanner versions. A missing, malformed or unlisted artifact fails the
gate. Reports live in one directory per image, currently `security-out/agent-sandbox` and
`security-out/node-base`.

An SBOM belongs to the image it came from plus the run that produced it: image id and commit for a
build, digest for a pinned base. A rebuild of the same commit into a different image is a
different SBOM.

## Schedule

The weekly run rebuilds the default branch and scans the pinned base images again. A vulnerability
disclosed against an image nobody rebuilt surfaces there, on the repository's own schedule rather
than on the next pull request. GitHub disables a schedule on a repository that has been inactive
for 60 days, so a long quiet spell is worth a manual run.

## Run the same checks locally

`make scan` clears old reports, builds the image and writes fresh reports. `make gate` applies
the policy to them. If a build or scan fails, an earlier run cannot leave reports that make the
next gate look green.

```sh
make scan
make gate
```

Both need Docker with a reachable `/var/run/docker.sock`; the scanners run as containers from
there. The reports land in `security-out/`, which git ignores.

## Notes

- A scanner container reaches the image through the daemon socket and prints its report to
  stdout. The shell redirects that into this job's filesystem. Mounting the output directory into
  the scanner would resolve the path on the daemon host instead, and the report would miss the
  artifact upload.
- Trivy ships a five minute analysis deadline. `security/scan.sh` passes `--timeout 30m`, because
  a scan that gives up leaves the image unscanned.
- Both scanners are pinned by digest in `security/scan.sh`. A scanner that moves under the gate is
  a scanner whose verdict means nothing. A digest settles that the image is the same one on every
  run, not who published it: verifying a signature with Cosign or Notation is the next step there.
- The scanners hold `/var/run/docker.sock`, which is daemon-level authority over the machine that
  runs them. Scanning an exported OCI archive would remove the need for the socket.
- ollama, glab and ant are pinned by `sha256` in the `Dockerfile`, and the build refuses to extract
  an artifact that does not match. The digest comes from the publisher over TLS: it catches a
  truncated or swapped download, not a compromised release, since none of the three is signed.
- The Trivy database goes in a volume, which the CI job names once for both of its scans. Without
  one, every scan fetches the database again, so a local `make scan` fetches it twice where CI
  fetches it once.
