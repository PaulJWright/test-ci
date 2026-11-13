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

# One tar file per runner version: each job then unpacks the runner in about
# a second, instead of copying its files one by one (45-54 s from home)
cd ~/actions-runner
tar -cf 2.338.2.tar -C 2.338.2 .
ln -sfn 2.338.2.tar current.tar
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

On Isambard-AI, 13 Nov, with `dispatch: manual` and `dispatch-runner.sh` from a
laptop, calling `gh200.yml@v0` from a test repo:

- a push runs the GH200 jobs with nobody touching Isambard-AI: about 25 s from
  push to the job starting with the tar copy, most of it the watcher's polling;
- a plain job, and one in `ubuntu:24.04` through `brics-apptainer` (found on
  `PATH`), both see the GH200 and pass;
- each runner takes one job, deletes its credentials and exits; the launcher
  cleans up, and no config files are left in `~/.brics-ci`;
- `scancel` mid-job: GitHub shows "The operation was canceled" 19 s later, inside
  Slurm's 30 s before SIGKILL;
- the tar copy unpacks the runner in 0-1 s, against 45-54 s copying file by file;
- two queued runs, one dispatched: the other run's jobs stay queued (run label);
- a runner started for run A that takes a job from run B is refused by the
  pre-job hook before checkout;
- a matrix gives one queued job per profile, each with its own label;
  `gh200-1gpu` gets one GPU, and `gh200-4gpu` a whole node with four (after
  40 min in the Slurm queue on a full machine);
- a runner config unused for 41 min still works.

From Phase 0: compute nodes reach GitHub, artifact and cache storage, and Docker
Hub; steps in an Apptainer image see the GPU and the workspace.

Not yet tested: a runner config used the day after it was made, the
`timeout-minutes` value GitHub applies, and `request-runner` (`dispatch: mvp`)
against the real job API.

Known gaps:

- a Slurm job cancelled before it starts leaves its config file in
  `~/.brics-ci` and its runner registration in GitHub;
- a runner that starts after its GitHub job has gone (cancelled, or failed
  after 24 h in the queue) sits idle and holds its node until `RUNNER_MINUTES`.
  The launcher should stop a runner with no job after about 10 minutes, and the
  dispatcher should cancel the Slurm job when its GitHub job goes.

## Versioning

`v0` while testing. `v1` waits for Phase B. New inputs are optional; breaking
changes go to a new major version.
