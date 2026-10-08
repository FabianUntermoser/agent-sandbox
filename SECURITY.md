# Security

Every image this repository builds or pulls is inventoried and vulnerability-scanned, and a
fixable high-severity advisory fails the run that produced it. The scans run in
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

No exceptions are in force. A temporary one needs its reason and its expiry date in this file, in
the same commit as the exception.

## Reports

Reports are CI artifacts kept for 90 days and never committed: `trivy.json`, `syft.cdx.json`,
`scan-target.txt`, `scanner-versions.txt` and `timings.txt`, one directory per image,
`security-out/agent-sandbox` and `security-out/node-base`.

An SBOM belongs to the image it came from plus the run that produced it: image id and commit for a
build, digest for a pinned base. A rebuild of the same commit into a different image is a
different SBOM.

## Schedule

The weekly run rebuilds the default branch and scans the pinned base images again. A vulnerability
disclosed against an image nobody rebuilt surfaces there, on the repository's own schedule rather
than on the next pull request. GitHub disables a schedule on a repository that has been inactive
for 60 days, so a long quiet spell is worth a manual run.

## Run the same checks locally

`make scan` builds the image and writes the reports. `make gate` applies the policy to them.

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
- The Trivy database goes in a volume, which the CI job names once for both of its scans. Without
  one, every scan fetches the database again, so a local `make scan` fetches it twice where CI
  fetches it once.
