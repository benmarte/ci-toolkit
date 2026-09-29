# ci-toolkit

Pay for each CI result once. A small, portable kit that cuts CI minutes by
**never rebuilding an image or re-running a job whose inputs have not
changed**, on GitHub Actions today and GitLab CI / Azure DevOps next.

| Saving | How |
|---|---|
| No rebuilds | `build-image.sh` tags each image with a hash of its inputs and skips the build when that tag is already in the registry; otherwise buildx builds against a shared registry cache (`mode=max`). |
| No re-runs | `pass-cache.sh` hashes a job's inputs; when those exact inputs already passed, the job exits in seconds. Re-pushes, rebases, docs-only commits and the post-merge push to the default branch stop re-paying for green work. Markers live in the registry, so a pass recorded on a PR is visible to the push that merges it. |
| No reinstalls | `detect-cache.sh` finds the package managers (go, bun, npm, pnpm, yarn, pip, poetry, uv, cargo) and prints cache paths and a lockfile-derived key. |
| Build once, run many | `run-tests.sh` runs any command inside the prebuilt image, so unit, integration and e2e jobs share one build. |
| Storage inside budget | `prune-images.sh` deletes image versions nothing reuses (keep newest N + last D days + protected tags). `docker-build` runs it after every new build, so registry storage stays flat. |
| Honest bills | `bill-report.sh` prints billed minutes per job and run, including GitHub's round-up-to-the-minute overhead, and what self-hosted jobs would cost hosted. |
| Parallelism | `shard.sh` splits a suite into N shards (native `--shard=i/N`, or file lists balanced by timings). Sharding buys wall-clock time and **costs** minutes — off by default. |

## Layout

```
scripts/                 all real logic — portable bash, no CI-platform variables
  build-image.sh         hash inputs → skip if tag exists → else buildx + registry cache
  run-tests.sh           run a command inside an image
  pass-cache.sh          skip-if-already-passed keys and markers
  detect-cache.sh        package managers → cache paths + key
  shard.sh               split a run into N shards
  bill-report.sh         billed minutes per job/run (GitHub)
  prune-images.sh        delete image versions nothing reuses (GHCR)
.github/workflows/       GitHub reusable workflows (GitHub requires this path)
  docker-build.yml       workflow_call → build-image.sh
  test-in-image.yml      workflow_call → run-in-image action
  e2e.yml                workflow_call, shard matrix → run-in-image action
  self-test.yml          this repo's own CI
github/actions/          GitHub composite actions, callable from any job
  setup-cache/           detect-cache.sh + actions/cache
  pass-cache/            pass-cache.sh check/save
  run-in-image/          skip check, caches, compose deps, run, record pass, artifact
gitlab/templates/        GitLab CI templates (include:) — STUB
azure/templates/         Azure DevOps step templates — STUB
tests/                   bats unit tests + real-registry integration test
```

Every wrapper only maps inputs to script flags. Scripts write their outputs as
`KEY=VALUE` to stdout and, when `CI_TOOLKIT_OUTPUT` names a file, append them
there — that is `$GITHUB_OUTPUT`'s format, a GitLab dotenv report, and
trivial to turn into an Azure `task.setvariable`.

## GitHub Actions

```yaml
jobs:
  image:
    uses: benmarte/ci-toolkit/.github/workflows/docker-build.yml@v1
    permissions: { contents: read, packages: write }
    with:
      name: test
      file: Dockerfile
      hash-paths: |
        Dockerfile
        go.mod
        go.sum

  unit:
    needs: image
    uses: benmarte/ci-toolkit/.github/workflows/test-in-image.yml@v1
    permissions: { contents: read, packages: write }
    with:
      image: ${{ needs.image.outputs.image }}
      command: go test ./...
      pass-name: unit
      pass-paths: |
        go.mod
        go.sum
        internal
        .github/workflows/ci.yml
      cache-paths: |
        /root/.cache/go-build
```

Or use the composite actions inside your own jobs:

```yaml
    steps:
      - uses: actions/checkout@v7
      - uses: benmarte/ci-toolkit/github/actions/setup-cache@v1
        with: { managers: go, rolling: "true" }
      - id: pass
        uses: benmarte/ci-toolkit/github/actions/pass-cache@v1
        with:
          mode: check
          name: lint
          paths: |
            internal
            .golangci.yml
          token: ${{ github.token }}
      - if: steps.pass.outputs.hit != 'true'
        run: golangci-lint run
      - if: steps.pass.outputs.hit != 'true'
        uses: benmarte/ci-toolkit/github/actions/pass-cache@v1
        with: { mode: save, key: "${{ steps.pass.outputs.key }}", token: "${{ github.token }}" }
```

Notes

- Pass `toolkit-ref` equal to the `@ref` you call a workflow with (default
  `v1`). Pin both to the same commit sha if you need them immutable.
- A floating `FROM` tag is not part of the image hash. Pin base images by
  digest, or pass the digest as a build arg, to rebuild when the base moves.
- `runs-on` takes JSON, so one repo variable can flip jobs between hosted and
  self-hosted: `runs-on: ${{ vars.CI_RUNS_ON || '"ubuntu-latest"' }}`.
- This repo is public so any org can call it; it holds no secrets. Callers
  pass their own registry credentials (GHCR uses the caller's `GITHUB_TOKEN`).
- Registry: GHCR by default; any registry via `image:` (ACR, GitLab, ECR…).

### Trust model

Skipping work is only safe if nobody can fake "this already passed".

- **Pass markers** default to the GitHub cache (`pass-backend: gha`). GitHub
  scopes it per branch: a PR sees its own markers and the default branch's,
  and nothing a PR writes is visible to the default branch. So PR code cannot
  plant a marker that makes the default branch skip its tests.
- **Images** are reused only when the GitHub cache holds an attestation for
  that tag's exact digest, recorded when this branch scope (or the default
  branch) built it. A tag overwritten by anyone else is rebuilt, not shipped
  (the self-test forges one to prove it).
- **BuildKit layer cache** defaults to the GitHub cache for the same reason,
  and because it does not count against package storage.
- Cost of this: the push that merges a PR re-runs work the PR already did,
  because the default branch cannot see the PR's markers.
- Remaining assumption: `cache-backend: registry` and `pass-backend: registry`
  are writable by any job with `packages:write`. Use them only where no
  branch-scoped cache exists, and never build release images from a cache
  PRs can write to.

### Choosing pass-cache inputs

`run-in-image` already adds the image digest, command, env (pass-through
values hashed), workdir, user, compose files and services, and the
toolkit's own scripts. A pass marker is only as honest as its key. Include everything else that can
change the outcome: the source the job tests, lockfiles, the CI workflow file
itself, config files (lint rules, tsconfig), and tool versions via `salts`.
Leave out what cannot matter (docs, other apps in a monorepo) — that is where
the savings come from. When unsure, include it: a missed skip costs minutes, a
false skip costs a bug.

## GitLab CI (stub)

```yaml
include:
  - remote: https://raw.githubusercontent.com/benmarte/ci-toolkit/v1/gitlab/templates/ci-toolkit.yml
build-image:
  extends: .ci-toolkit-build-image
  variables: { CT_IMAGE: $CI_REGISTRY_IMAGE/app, CT_HASH_PATHS: "src go.sum" }
```

## Azure DevOps (stub)

```yaml
resources:
  repositories:
    - { repository: citoolkit, type: github, name: benmarte/ci-toolkit, ref: refs/tags/v1, endpoint: github }
steps:
  - checkout: self
  - checkout: citoolkit
  - template: azure/templates/docker-build.yml@citoolkit
    parameters: { image: myacr.azurecr.io/team/app, hashPaths: [src, go.sum] }
```

The stubs are finished and tested by the `ci-onboard` skill the first time a
repo on that platform is onboarded.

## Measuring

```bash
scripts/bill-report.sh --repo OWNER/REPO --since 2026-09-01 --workflow ci.yml
scripts/bill-report.sh --repo OWNER/REPO --run 123456789 --per-job
```

## Development

```bash
shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh
bats tests/scripts.bats        # unit, fake docker
tests/integration.sh           # real registry:2 + buildx
```

Releases: semver tags `vX.Y.Z`, with the moving major tag `v1` pointing at the
latest compatible release.

MIT licensed.
