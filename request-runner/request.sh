#!/bin/bash
# request.sh: the request-runner action's step, on GitHub's own runner.
#
# dispatch: mvp (Phase A, dev only). Uses ci-service's job API the same way its
# deploy/examples/github-actions/brics-ci.yml does: POST a Slurm script to /jobs,
# then release it in the submitter at the job's address, with the origin token. The
# submitter adds --chdir and runs it through ssh -> sudo -> slurmspawner_sbatch as
# the chosen user.project.
#
# If the calling workflow grants `id-token: write`, it also sends GitHub's OIDC token
# for this job (audience isambard-ci), so the job API records which repo, commit and
# run the job came from: `Authorization: Bearer <GitHub token>` with the origin token
# in `Origin-Token`. That needs a job API that accepts GitHub tokens (ci-service's
# feature/github_oidc on). Without the permission, the origin token alone is sent, as
# before.
#
# The difference is the script: instead of the user's job, it starts a runner for
# this run's GH200 job. The runner config is created here with the repo's admin
# PAT and sits in the script, so it's stored in the jobs table and shown on the
# release page: acceptable on dev only.
#
# dispatch: service (Phase B) is not built yet.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
profiles=$here/profiles.json

fail() { echo "::error::$*"; exit 1; }

: "${REPO:?}" "${RUN_ID:?}" "${RUN_ATTEMPT:?}"
# The profile, from profiles.json: its runner minutes and Slurm options
p=$(jq -c --arg p "${PROFILE:-}" '.[$p] // empty' "$profiles")
[ -n "$p" ] || fail "Unknown profile '${PROFILE:-}'. Known: $(jq -r 'keys_unsorted | join(" ")' "$profiles")"
runner_minutes=$(jq -r .runner_minutes <<<"$p")
mapfile -t SBATCH_ARGS < <(jq -r '.slurm[]' <<<"$p")
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
  -f name="test-ci-$RUN_ID-$RUN_ATTEMPT-$PROFILE" -F runner_group_id=1 \
  -f "labels[]=test-ci-$PROFILE" -f "labels[]=test-ci-run-$RUN_ID" \
  --jq .encoded_jit_config) || fail "Couldn't create a runner config: check the PAT"
echo "::add-mask::$config"
[[ $config =~ ^[A-Za-z0-9+/=]+$ ]] || fail "Unexpected runner config from GitHub"

# 2. The Slurm job script: the profile's settings, the config, then the launcher
job=$(mktemp)
trap 'rm -f "$job"' EXIT
{
  echo '#!/bin/bash'
  echo "#SBATCH --job-name=test-ci-$PROFILE-$RUN_ID"
  for a in "${SBATCH_ARGS[@]}"; do echo "#SBATCH $a"; done
  echo '#SBATCH --output=%x-%j.out'
  echo "export ACTIONS_RUNNER_INPUT_JITCONFIG='$config'"
  printf 'exec %q --profile %q --runner-minutes %q --config-env --expect-repo %q --expect-run %q\n' \
    "$LAUNCHER" "$PROFILE" "$runner_minutes" "$REPO" "$RUN_ID"
} > "$job"

# 3. GitHub's OIDC token for this job, if the workflow allows it. It says which repo,
#    commit and run this is; it lasts minutes, and the job API accepts it once.
headers=(-H 'Content-Type: text/plain')
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  github_token=$(curl -fsS --retry 3 -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${AUDIENCE:-isambard-ci}" | jq -r '.value // empty') \
    || fail "Couldn't get GitHub's OIDC token for this job"
  [ -n "$github_token" ] || fail "GitHub's OIDC token was empty"
  echo "::add-mask::$github_token"
  headers+=(-H "Authorization: Bearer $github_token" -H "Origin-Token: $ORIGIN_TOKEN")
  echo "Sending GitHub's OIDC token, so the job API records where the job came from"
else
  headers+=(-H "Authorization: Bearer $ORIGIN_TOKEN")
  echo "::notice::No GitHub OIDC token: grant 'id-token: write' in the calling workflow, so the CI service can check which repo, commit and run the job came from"
fi

# 4. Add it to the job API. A person releases it there.
body=$(mktemp)
trap 'rm -f "$job" "$body"' EXIT
code=$(curl -sS --retry 3 -o "$body" -w '%{http_code}' -X POST "${URL%/}/jobs" \
  "${headers[@]}" --data-binary @"$job") || code=000
detail=$(jq -r '.detail // empty' "$body" 2>/dev/null || true)
case $code in
  2??) ;;
  000) fail "Couldn't reach the job API at $URL" ;;
  401 | 403) fail "The job API refused the request (HTTP $code): ${detail:-no reason given}" ;;
  *) fail "The job API at $URL answered HTTP $code${detail:+: $detail}. Is it, or its tunnel, up?" ;;
esac
# ci-service's reply: {id, release_url}; before its job IDs, {job_id, task_token, release_url}
job_id=$(jq -r '.id // .job_id' "$body")
task_token=$(jq -r '.task_token // empty' "$body")
release_url=$(jq -r '.release_url // empty' "$body")
[ -n "$release_url" ] || release_url="the submitter page"

echo "Job $job_id added. Release it at $release_url"
echo "release-url=$release_url" >> "$GITHUB_OUTPUT"
if [ -n "$task_token" ]; then
  # An older job API. The task token is printed on purpose, as in ci-service's example
  # then: releasing the job also needs the origin token, which only the repo's owner holds
  echo "Task token: $task_token"
  release="Release it at $release_url with the task token from the request step's log and your origin token."
else
  # Shown as code, not a link: a link clicked on github.com wouldn't carry the
  # submitter's login, so paste it into the browser after logging in
  release="Log in to the submitter, then copy this into your browser and give your origin token: \`$release_url\`"
fi
{
  echo "### test-ci"
  echo "The $PROFILE job is waiting for a runner on Isambard-AI (job $job_id)."
  echo "$release"
  echo "GitHub cancels the job if no runner starts within 24 hours."
} >> "$GITHUB_STEP_SUMMARY"
