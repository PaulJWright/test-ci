# test-ci


Run a script from your GitHub repo on Isambard-AI's GH200 nodes, using GitHub Actions with short-lived runners. This is one runner, in one Slurm job, for one job, which exits when the job ends.
Unlike CSCS's Gitlab instance, we do not need a mirror of your repo, and/or a long-running service on the cluster. We do need a PAT though.

This is a repo is what you call from your workflow. 
[test-ci-runner](https://github.com/PaulJWright/test-ci-runner) is what runs on the Cluster

## What you write

```yaml
jobs:
  gh200:
    uses: PaulJWright/test-ci/.github/workflows/gh200.yml@v0
    with:
      profile: gh200-1gpu      # 1 GPU, up to 50 minutes
      script: ci/gh200.sh      # run from your repo's root after checkout
      # args: "--quick"        # optional
      # image: ubuntu:24.04    # optional: run the script in this image with Apptainer
```

A full example is in [`examples/gh200-tests.yml`](examples/gh200-tests.yml), with a test script in [`examples/ci/gh200.sh`](examples/ci/gh200.sh). A matrix over `profile` gives one job per profile.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `profile` | required | The resources your job gets (below) |
| `script` | required | Path to the script in your repo, run from the repo's root after checkout |
| `args` | `""` | Arguments for the script |
| `image` | `""` | Run the script in this container image with Apptainer and the GPU, for example `ubuntu:24.04` |
| `dispatch` | `manual` | How the runner starts (below) |

## Profiles

We need some pre-set profiles for the user to choose, but larger node profiles will wait longer. `dev-cpu` is for local slurm container development only 

| Profile | Slurm | Job time limit |
|---|---|---|
| `gh200-1gpu` | 1 GPU, 1 hour | 50 min |
| `gh200-4gpu` | 4 GPUs on one node, 2 hours | 110 min |
| `dev-cpu` | No GPU, 30 minutes: ci-service's dev stack only | 20 min |


- It runs on a GH200 node as the Isambard-AI account the runner started under, with the usual `GITHUB_*` variables and node-local `TMPDIR` (in RAM).
- With `image`, each `run:` step runs in that image with the GPU, the workspace and `$HOME`; each step gets a fresh container. `uses:` steps such as checkout run on the node.
- No Docker: GitHub's `container:`, `services:` and Docker actions don't work. Call Apptainer or podman-hpc (not sure if this is working on I-AI yet?) from your script instead.
- It can submit Slurm jobs of its own as the same account. `sbatch --wait` returns the child job's exit code, so your step passes or fails with it. Cancel your child jobs if your script is interrupted: they outlive the CI job otherwise.

## What starts the runner

`gh200.yml` has two jobs. `request` runs on GitHub's own runner and, for `mvp`, asks the CI service for a runner; `run` waits in GitHub until that runner starts on Isambard-AI.

| `dispatch` | What starts the Slurm job | Human step | Runs as | Secrets |
|---|---|---|---|---|
| `manual` (Phase 1) | test-ci-runner's dispatcher, on an operator's laptop | None | Whoever dispatches | None |
| `mvp` (Phase A, dev) | ci-service's submitter, after a release | Release on the submitter page | The releaser's `user.project` | `origin-token`, `runner-admin-pat` |
| `service` (Phase B) | Not built yet | Release | The releaser's `user.project` | `origin-token` |
| `automatic` | Not built yet | None | The account registered for the repo | None |

**For `mvp`** (local dev only), the calling repo needs:

- the `BRICS_CI_URL` variable: ci-service's job API (the names are ci-service's);
- `secrets: origin-token: ${{ secrets.BRICS_CI_ORIGIN_TOKEN }}`;
- `secrets: runner-admin-pat: ${{ secrets.RUNNER_ADMIN_PAT }}`: a fine-grained PAT for that repo only, with Administration: write and a short expiry.

The request job then posts a short Slurm script to the job API. It holds the profile's `#SBATCH` lines, the runner config, and `exec /opt/test-ci-runner/launcher/launch-runner.sh …`.
The task token for the release is in the request step's log.
The runner config sits in that script, so it's stored in ci-service's database and shown on the release page: dev only.

## Layout

```
.github/workflows/gh200.yml   the reusable workflow you call
request-runner/               the request job's action (mvp now; service in Phase B)
request-runner/profiles.json  the profiles: Slurm options and time limits. The only
                              copy; test-ci-runner reads it from here
examples/                     a caller workflow and a test script
tests/                        shellcheck, actionlint, the profile check, request-runner
```

## Versioning

Breaking changes mean a new major version has to be minted. A profile is changed in `request-runner/profiles.json` only: test-ci-runner's dispatcher reads that file at the version of `gh200.yml` each run uses.
