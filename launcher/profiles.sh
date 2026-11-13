# shellcheck shell=bash
# profiles.sh: sourced by submit.sh, launch-runner.sh and request-runner.
#
# A profile names the resources a CI job gets on Isambard-AI. Each one sets:
#   SBATCH_ARGS     Slurm options for the job
#   RUNNER_MINUTES  how long the launcher lets the runner live
#   JOB_MINUTES     the job's timeout-minutes in .github/workflows/gh200.yml
#
# Keep JOB_MINUTES < RUNNER_MINUTES < the Slurm --time, so GitHub stops the job
# first, then the launcher stops the runner, and Slurm never has to kill it.
# tests/check-profiles.sh fails if gh200.yml's timeout map drifts from this file.

# shellcheck disable=SC2034  # the variables are used by the scripts that source this
PROFILES="gh200-1gpu gh200-4gpu"

profile_settings() {
  case ${1:-} in
    gh200-1gpu)
      SBATCH_ARGS=(--nodes=1 --gpus=1 --time=01:00:00)
      RUNNER_MINUTES=55 JOB_MINUTES=50 ;;
    gh200-4gpu)
      SBATCH_ARGS=(--nodes=1 --gpus=4 --time=02:00:00)
      RUNNER_MINUTES=115 JOB_MINUTES=110 ;;
    *) return 1 ;;
  esac
}
