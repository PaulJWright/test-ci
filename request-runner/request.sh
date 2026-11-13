#!/bin/bash
# request.sh: the request-runner action's step, on GitHub's own runner.
#
# dispatch: mvp (Phase A, dev only). Uses ci-service as it is today, the same way
# its deploy/examples/github-actions/brics-ci.yml does: POST a Slurm script to the
# job API's /jobs with the origin token, then release it in the submitter with the
# task token (printed here) and the origin token. The submitter adds --chdir and
# runs it through ssh -> sudo -> slurmspawner_sbatch as the chosen user.project.
#
# The difference is the script: instead of the user's job, it starts a runner for
# this run's GH200 job. The runner config is created here with the repo's admin
# PAT and sits in the script, so it's stored in the jobs table and shown on the
# release page: acceptable on dev only.
#
# dispatch: service (Phase B) is not built yet.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../launcher/profiles.sh
. "$here/../launcher/profiles.sh"

fail() { echo "::error::$*"; exit 1; }

: "${REPO:?}" "${RUN_ID:?}" "${RUN_ATTEMPT:?}"
profile_settings "${PROFILE:-}" || fail "Unknown profile '${PROFILE:-}'. Known: $PROFILES"
case ${DISPATCH:-} in
  mvp) ;;
  service) fail "dispatch: service arrives with Phase B. Use mvp on dev, or manual." ;;
  *) fail "request-runner handles dispatch mvp or service, not '${DISPATCH:-}'" ;;
esac
[ -n "${URL:-}" ] || fail "No job API URL: set the BRICS_CI_URL variable in the repo"
[ -n "${ORIGIN_TOKEN:-}" ] || fail "No origin token: pass the BRICS_CI_ORIGIN_TOKEN secret"
[ -n "${GH_TOKEN:-}" ] || fail "dispatch: mvp needs the runner-admin-pat secret"

# 1. A runner config that only this run's job can match
config=$(gh api -X POST "repos/$REPO/actions/runners/generate-jitconfig" \
  -f name="brics-$RUN_ID-$RUN_ATTEMPT-$PROFILE" -F runner_group_id=1 \
  -f "labels[]=brics-$PROFILE" -f "labels[]=brics-run-$RUN_ID" \
  --jq .encoded_jit_config) || fail "Couldn't create a runner config: check the PAT"
echo "::add-mask::$config"
[[ $config =~ ^[A-Za-z0-9+/=]+$ ]] || fail "Unexpected runner config from GitHub"

# 2. The Slurm job script: the profile's settings, the config, then the launcher
job=$(mktemp)
trap 'rm -f "$job"' EXIT
{
  echo '#!/bin/bash'
  echo "#SBATCH --job-name=brics-$PROFILE-$RUN_ID"
  for a in "${SBATCH_ARGS[@]}"; do echo "#SBATCH $a"; done
  echo '#SBATCH --output=%x-%j.out'
  echo "export ACTIONS_RUNNER_INPUT_JITCONFIG='$config'"
  printf 'exec %q --profile %q --config-env --expect-repo %q --expect-run %q\n' \
    "$LAUNCHER" "$PROFILE" "$REPO" "$RUN_ID"
} > "$job"

# 3. Add it to the job API. A person releases it there.
resp=$(curl -fsS --retry 3 -X POST "${URL%/}/jobs" \
  -H "Authorization: Bearer $ORIGIN_TOKEN" -H 'Content-Type: text/plain' \
  --data-binary @"$job") || fail "The job API refused the request"
job_id=$(jq -r .job_id <<<"$resp")
task_token=$(jq -r .task_token <<<"$resp")
release_url=$(jq -r '.release_url // "the submitter page"' <<<"$resp")

# The task token is printed on purpose, as in ci-service's own example: releasing
# the job also needs the origin token, which only the repo's owner holds.
echo "Job $job_id added. Release it at $release_url"
echo "Task token: $task_token"
echo "release-url=$release_url" >> "$GITHUB_OUTPUT"
{
  echo "### BriCS CI"
  echo "The $PROFILE job is waiting for a runner on Isambard-AI (job $job_id)."
  echo "Release it at $release_url with the task token from the request step's log and your origin token."
  echo "GitHub cancels the job if no runner starts within 24 hours."
} >> "$GITHUB_STEP_SUMMARY"
