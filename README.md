# renovate-runner

A GitHub Actions self-hosted runner image built on top of
[`ghcr.io/renovatebot/renovate`](https://github.com/renovatebot/renovate), intended for running Renovate from
workflows. It bundles:

- the [actions/runner](https://github.com/actions/runner) agent in `/home/runner`
- the [runner container hooks](https://github.com/actions/runner-container-hooks) (`k8s` and `k8s-novolume`)
- the `docker` CLI and the `buildx` plugin
- everything the Renovate image already has: `renovate`, `node`, `git` and the
  [containerbase](https://github.com/containerbase/base) toolchain installer

The container runs as the base image's `ubuntu` user (UID 12021, GID 0).

## Building

```sh
docker buildx build --platform linux/amd64 --build-arg RUNNER_VERSION=<actions/runner version> -t renovate-runner .
```

`RUNNER_VERSION` has no default. Use a release of [actions/runner](https://github.com/actions/runner/releases)
without the leading `v`, for example `2.338.0`.

Only `linux/amd64` has been built and tested. `linux/arm64` is untested: the development host had no QEMU/binfmt
emulation, and upstream builds arm64 on a native arm runner.

## Running

### Standalone container

`entrypoint.sh` is the image entrypoint. It decides what to do from the environment:

| Environment | Behaviour |
| --- | --- |
| `ACTIONS_RUNNER_INPUT_JITCONFIG` | Starts `run.sh` with a just-in-time config. No registration step, always ephemeral. |
| `RUNNER_URL` and `RUNNER_TOKEN` | Runs `config.sh` with the registration token, then `run.sh`. |
| neither | Hands off to the base image's Renovate entrypoint, so `docker run <image> --version` prints Renovate's version. |

Optional variables for the registration token mode: `RUNNER_NAME` (default: hostname), `RUNNER_LABELS`,
`RUNNER_GROUP`, `RUNNER_WORKDIR` (default: `_work`) and `RUNNER_EPHEMERAL` (default: `true`).

```sh
TOKEN=$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token)
docker run -d -e RUNNER_URL=https://github.com/OWNER/REPO -e RUNNER_TOKEN="$TOKEN" renovate-runner
```

- The token is removed from the environment before jobs run.
- An ephemeral runner (`exec ./run.sh`) takes one job and deregisters itself.
- A non-ephemeral runner unregisters itself with `config.sh remove` on SIGTERM/SIGINT.
- The non-ephemeral path calls `set -m` before backgrounding `run.sh`. Without it bash starts the background job with
  SIGINT ignored, `run.sh` forwards SIGTERM to the listener as SIGINT, the listener never exits, `docker stop` hits its
  timeout and the runner stays registered. Do not remove the `set -m`.

### actions-runner-controller (ARC)

ARC overrides the container command with `/home/runner/run.sh` and supplies a JIT config, so `entrypoint.sh` is not
used. The runner files sit at the paths ARC expects: `/home/runner/run.sh`, `/home/runner/_work`,
`/home/runner/externals`, `/home/runner/k8s` and `/home/runner/k8s-novolume`.

```yaml
githubConfigUrl: https://github.com/OWNER/REPO
githubConfigSecret: <secret-name>
template:
  spec:
    containers:
      - name: runner
        image: <registry>/renovate-runner:<tag>
        command: ["/home/runner/run.sh"]
```

Choose the container mode by what the jobs need:

- **unset (plain runner pod):** steps run directly in the runner container. No docker daemon. Enough for Renovate with
  `binarySource=install`.
- **`dind`:** adds a privileged docker sidecar. Steps still run in the runner container. The sidecar creates the socket
  with `--group=123`, which is why the Dockerfile sets the `docker` group to GID 123 (and `ubuntu` is in it).
- **`kubernetes` / `kubernetes-novolume`:** steps run in a separate job pod, and ARC sets
  `ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER=true`. The tools in this image are only used if the job's `container:` is this
  image, or if that variable is set to `false`.

**`kubernetes-novolume` needs `ACTIONS_RUNNER_IMAGE` set to the stock `ghcr.io/actions/actions-runner` image** (same
version as `RUNNER_VERSION`). The hook's `fs-init` init container runs `ACTIONS_RUNNER_IMAGE` as UID/GID 1001 and runs
`mv /home/runner/externals/* /mnt/externals/`. ARC defaults the variable to the runner container's own image, and in this
image those files belong to `ubuntu`, so the move fails with `Permission denied` (reproduced by running the image with
`--user 1001:1001`). The stock image owns them as 1001.

The ARC chart's documentation tells you to set `fsGroup` to the runner user's UID for IRSA-style projected tokens. For
this image that UID is 12021, not 1001. Not relevant outside AWS.

Not yet deployed to a cluster. The ARC notes above come from reading the chart and hook source.

## Why the image looks the way it does

These were all found by building and running it. Keep them in mind before "simplifying" the Dockerfile.

- **Runs as `ubuntu`, not a new `runner` user.** The base image's `ubuntu` user owns `/opt/containerbase`, so
  containerbase can install tools on demand (`install-tool` fails with `EACCES: can't write to /opt/containerbase/data`
  for any other user). It also has a writable `/home/ubuntu`. An earlier version created a `runner` user (UID 1001), which
  broke tool installs, and then needed `BASH_ENV`/`HOME` overrides to work around containerbase's `HOME` handling.
- **`USER root` at the start of the final stage.** The base image defaults to UID 12021, so `apt` fails otherwise.
- **No `add-apt-repository ppa:git-core/ppa`.** The base image already configures that PPA
  (`/etc/apt/sources.list.d/git.sources`); adding it again fails on a conflicting key path. `git` comes from it through a
  plain `apt install`.
- **The `docker` group already exists in the base image** (GID 999) and is renamed to GID 123 with `groupmod`.
- **`/usr/local/bin/docker` is deleted.** It is a containerbase wrapper that runs its own docker (28.5.2, no buildx) and
  comes first in `PATH`, shadowing the 29.9.0 CLI and the buildx plugin installed here.
- **The runner lives in `/home/runner`,** owned by `ubuntu`, while `HOME` is `/home/ubuntu`. This keeps ARC's paths
  unchanged.
- **`RUNNER_MANUALLY_TRAP_SIG=1`** makes `run.sh` forward signals to the listener (see the `set -m` note above).
  `ImageOS=ubuntu24` makes `actions/setup-*` treat the image like a hosted Ubuntu 24.04 runner.

## Compatibility with upstream expectations

Checked against the source of `actions/runner`, `actions/runner-container-hooks` (main and v0.7.0) and
`actions/actions-runner-controller`:

- **`actions/runner` has no hardcoded user and no `/home/runner`.** Its root is the directory containing `bin/`, the work
  folder is relative to it, and it only touches `HOME` for container actions (pointing it at a temp directory).
  It does need to write to its own directory (`.runner`, `.credentials`, `_diag`, self-update), which `ubuntu` owns.
- **Toolcache:** the runner reads `RUNNER_TOOL_CACHE`, then `RUNNER_TOOLSDIRECTORY`, then `AGENT_TOOLSDIRECTORY`, and
  falls back to `<root>/_work/_tool`. It is created per job and exposed as `runner.tool_cache`. Nothing defaults to
  `/opt/hostedtoolcache`; that path is only a hosted-image convention. `setup-*` actions download into `_work/_tool`.
  Under ARC `_work` is an emptyDir by default, so the toolcache starts empty for every runner pod. To share one, mount a
  volume writable by UID 12021 and set `RUNNER_TOOL_CACHE`.
- **`k8s` hook (v0.7.0):** no user/UID assumptions in its source.
- **`k8s-novolume` hook (v0.8.1):** hardcodes UID/GID 1001 (`fsGroup`, `fs-init`). See the ARC section.

## Tool installs (`binarySource=install`)

Renovate installs the tools a repo needs (Go, Java, PHP, Rust, ...) on demand through containerbase's `install-tool`,
choosing the version from the repo's constraints (for example the `go` directive in `go.mod`). Tools land in
`/opt/containerbase`, which is part of the pod's writable layer, so ephemeral pods start without them.

Verified: `install-tool` works as `ubuntu`, and Renovate itself installs Go and prepares the update branch (see the
`renovate-install` job below).

### Caching downloads

Read from the containerbase source and tested with `install-tool`:

- **`CONTAINERBASE_CACHE_DIR`** is the *download* cache. Each file is stored at
  `<dir>/<sha256 of url>/<file>` and reused while its checksum still matches. It is unset in this image.
  `/tmp/containerbase/cache` is **not** this cache; it holds package-manager caches (`.cache`, `.config`).
  Measured: Go 1.22.8 installs in 2.8 s instead of 4.6 s with a warm cache.
- **It does not make installs work offline.** `install-tool` sends a `HEAD` request for the `.sha512` URL before
  downloading, and that request is never cached.
- **`CONTAINERBASE_CDN`** rewrites every `https://<host>/<path>` to `<CDN>/<host>/<path>`. `URL_REPLACE_<n>_FROM` /
  `URL_REPLACE_<n>_TO` replace specific URL prefixes (Artifactory style). Both apply to the `HEAD` request too, so a caching
  reverse proxy in the cluster (nginx `proxy_cache`, Nexus, Artifactory) on a single RWO volume works without RWX storage
  or TLS interception. GitHub release downloads redirect to `objects.githubusercontent.com`, so the proxy must follow
  redirects itself or you need a second replacement for that host. Not run, only read from the source and docs.
- A plain `HTTPS_PROXY` does not cache: HTTPS goes through a `CONNECT` tunnel.
- **Not verified:** whether Renovate passes `CONTAINERBASE_*` and `URL_REPLACE_*` through to the `install-tool` processes
  it starts. It filters the environment of child processes, so `customEnvVariables` or `exposeAllEnv` may be needed.
  Check that before relying on either setting.

### Measurements

One version of each tool, on a fast link, `linux/amd64` (single run, so treat as indicative):

| Tool | Download | Cold install | Warm cache | Installed |
| --- | --- | --- | --- | --- |
| Java 21 | ~198 MB | 10 s | 1.5 s | 346 MB |
| Rust 1.82 | ~170 MB | 47 s | 12 s | 501 MB |
| Gradle 8.10.2 | ~131 MB | 7 s | 1.1 s | 146 MB |
| Go 1.22.8 | ~41 MB | 5 s | 3 s | 248 MB |
| PHP 8.3.12 | ~14 MB | 3 s | 1 s | 64 MB |
| Maven 3.9.9 | ~8 MB | 3 s | 1.2 s | 11 MB |
| Composer 2.8.1 | ~1 MB | 2 s | 0.4 s | 3 MB |
| **All** | **~563 MB** | **~77 s** | **~21 s** | **~1.36 GB** |

`install-tool php` needs a full version (`8.3.12`, not `8.3`), and `composer` needs `php` installed first.

### Guidance for many repositories

Planning figures for ~500 repositories across Java, Go, PHP and Rust, run hourly:

1. **Batch repositories per job.** Installs are idempotent within a pod, so one Renovate run over many repos downloads
   each toolchain version once per run instead of once per repo. This saves more than any cache.
2. **Put a pull-through mirror in front of the downloads** (`CONTAINERBASE_CDN`, RWO volume). Pulling everything from
   GitHub releases at this volume risks rate limiting (not measured). It also controls egress.
3. **Add a per-node hostPath download cache** (`CONTAINERBASE_CACHE_DIR`) when RWX storage is unavailable. It cuts a cold
   pod's installs from ~77 s to ~21 s; Rust extraction dominates what remains.
4. **Bake Rust into the image** (pinned with Renovate `constraints`) if many repos use it. It is the most expensive tool.
5. **Size ephemeral storage:** allow at least 2-3 GB per runner pod when all four ecosystems are in play.

Distinct versions across repos multiply the cache size.

## Testing

`.github/workflows/runner-smoke-test.yml` is a manually dispatched workflow for `runs-on: self-hosted`:

- `smoke-test`: prints the user, runner name, `HOME`, and the versions of `renovate`, `node`, `git`, `jq`, `docker`
  and `buildx`.
- `go-project`: checks out `testdata/go-project` (a Go module pinned to an old `github.com/google/uuid`), installs Go with
  `install-tool`, runs `go test`, and asserts that Renovate's local lookup reports an update.
- `renovate-install`: runs Renovate (`platform=github`, `binarySource=install`, `dry-run=full`, gomod only) with the
  workflow token. It asserts Go is absent beforehand, that Renovate ran `install-tool golang`, and that it prepared the
  update branch. Nothing is pushed.

To run it, start a runner (see the standalone example, with `RUNNER_EPHEMERAL=false` to keep it for several jobs) and
dispatch the workflow:

```sh
gh workflow run runner-smoke-test.yml --ref <branch>
```

GitHub only allows dispatching a workflow that already exists on the default branch, but the version used is the one on
`--ref`, so changes to this workflow can be tested from a branch. Start from a **fresh container** for `renovate-install`:
the `go-project` job installs Go in the same container, which would hide whether Renovate installs it itself.

Stop a non-ephemeral runner with `docker stop` so it unregisters itself.

## Open items

- `linux/arm64` is untested.
- Not deployed to an ARC cluster yet.
- Whether Renovate passes containerbase variables to `install-tool` (see above).
- The Go test checks Renovate's lookup and the branch preparation, but does not inspect the generated `go.sum` change.
