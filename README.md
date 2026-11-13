# brics-ci

Run a script from your GitHub repo on Isambard-AI's GH200 nodes, using GitHub
Actions with short-lived runners: one runner, in one Slurm job, for one job,
which exits when the job ends. No mirror of your repo, and no long-running
service on the cluster.

Status: **v0, Phase 1 draft.** Built from what worked in Phase 0 (13 Nov 2026);
see "Tested so far" below.

## What you write

```yaml
jobs:
  gh200:
    uses: PaulJWright/brics-ci/.github/workflows/gh200.yml@v0
    with:
      profile: gh200-1gpu      # 1 GPU, up to 50 minutes
      script: ci/gh200.sh      # run from your repo's root after checkout
      # args: "--quick"        # optional
      # image: ubuntu:24.04    # optional: run the script in this image with Apptainer
```

A full example is in `examples/gh200-tests.yml`.

| Profile | Slurm | Job time limit |
|---|---|---|
| `gh200-1gpu` | 1 GPU, 1 hour | 50 min |
| `gh200-4gpu` | 4 GPUs on one node, 2 hours | 110 min |

The script sees the usual `GITHUB_*` variables, runs as the Isambard-AI account
the runner started under, and gets node-local `TMPDIR` (in RAM). With `image`,
the GPU, the workspace and `$HOME` are inside the container; each step gets a
fresh container.

## What starts the runner

`gh200.yml` has two jobs. `request` runs on GitHub's own runner and asks BriCS
for a runner; `run` waits in GitHub until that runner starts on Isambard-AI.

| `dispatch` | What starts the Slurm job | Human step | Runs as |
|---|---|---|---|
| `manual` (Phase 1) | `tools/dispatch-runner.sh` on a laptop, or `--watch` | None with `--watch` | Whoever dispatches |
| `mvp` (Phase A, dev) | `request` adds a job script to the MVP job API; the submitter runs `sbatch` | Release on the submitter page | `user.project` |
| `service` (Phase B) | Not built yet | Release | `user.project` |
| `automatic` | A listener on our side (not built yet) | None | The account registered for the repo |

## Layout

```
.github/workflows/gh200.yml   the reusable workflow users call
request-runner/               the request job's action (mvp now; service in Phase B)
launcher/launch-runner.sh     runs inside every Slurm job: config, private copy, hook, SIGTERM, clean-up
launcher/submit.sh            on a login node: config on stdin -> 0600 file -> sbatch the launcher
launcher/hook.sh              pre-job hook: logs the job, refuses the wrong repo or run
launcher/profiles.sh          profile -> Slurm options and time limits (one source of truth)
bin/brics-apptainer           custom shell: runs a step's script in BRICS_IMAGE with Apptainer
tools/dispatch-runner.sh      on a laptop: one runner per queued BriCS job (manual dispatch)
examples/                     a caller workflow and a test script
tests/                        shellcheck, actionlint, profile drift check
```

## Try it now (Phase 1: manual, on your own account)

Once, on an Isambard-AI login node (the runner install from Phase 0 is reused):

```bash
git clone https://github.com/PaulJWright/brics-ci ~/brics-ci
ls ~/actions-runner/current/run.sh     # Phase 0's install; or set RUNNER_HOME
```

In a test repo of your own, add `examples/gh200-tests.yml` as
`.github/workflows/gh200-tests.yml`, and `examples/ci/gh200.sh` as `ci/gh200.sh`.

Then, on your laptop, with `gh` signed in and `clifton auth` done:

```bash
tools/dispatch-runner.sh --watch OWNER/REPO     # leave running
git push                                        # in the test repo; the GH200 jobs just run
```

Or, for one run: `tools/dispatch-runner.sh OWNER/REPO RUN_ID`.

Logs of each Slurm job are in `~/.brics-ci/logs/` on Isambard-AI.

**Manual dispatch runs every job as you, with no release step and no checks
beyond the pre-job hook. Use it on your own test repos only.**

## Phase A (dev): dispatch mvp, with ci-service as it is

`dispatch: mvp` uses ci-service's job API and submitter unchanged, the same way
its `deploy/examples/github-actions/brics-ci.yml` does:

1. The `request` job creates a runner config for this run with a repo admin PAT,
   and POSTs a short Slurm script to `$BRICS_CI_URL/jobs` with the origin token.
   The script holds the profile's `#SBATCH` lines, the config, and
   `exec /opt/brics-ci/launcher/launch-runner.sh …`.
2. The user releases it in the submitter, with the task token (in the request
   step's log) and their origin token, as one of their project accounts.
3. The submitter adds `--chdir` and runs the script through
   ssh -> sudo -> `slurmspawner_sbatch` as that `user.project`.
4. The runner starts, takes the waiting GH200 job, and exits.

In the calling repo: `dispatch: mvp`, the `BRICS_CI_ORIGIN_TOKEN` secret, a
fine-grained `RUNNER_ADMIN_PAT` for that repo only (Administration: write, short
expiry), and the `BRICS_CI_URL` variable. On the cluster, `brics-ci` at
`/opt/brics-ci` and a runner for the cluster's architecture at `RUNNER_HOME`
(default `~/actions-runner/current`). The runner config sits in the script, so
it's stored in the jobs table and shown on the release page: dev only.

## Tested so far

From Phase 0, on Isambard-AI, with the same code as `launch-runner.sh`,
`hook.sh` and `brics-apptainer`:

- the runner starts from the config in the environment, takes one job, reports
  pass or fail, and deletes its credentials;
- `scancel`: the runner tells GitHub within 16 s ("The operation was canceled");
- steps in an Apptainer image see the GH200 and the workspace, and outputs work;
- compute nodes reach GitHub, artifact and cache storage, and Docker Hub.

Not yet tested: `submit.sh`, `dispatch-runner.sh` and `request-runner` against
the real cluster and job API, `brics-apptainer` found on `PATH` rather than by
full path, the tar copy, the 4-GPU profile, and calling `gh200.yml` from another
repo.

## Versioning

`v0` while testing. `v1` waits for Phase B. New inputs are optional; breaking
changes go to a new major version.
