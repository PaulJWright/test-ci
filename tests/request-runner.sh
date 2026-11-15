#!/bin/bash
# Runs request-runner's request.sh (dispatch: mvp) against stand-ins for gh and the
# job API: the job script it sends, the release link it reports, and its refusals.
# No network. The runner side is tested in test-ci-runner.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL - $*" >&2; exit 1; }
export FAKE_OUT=$t

mkdir -p "$t/stub"
cat > "$t/stub/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do case $a in @*) cp "${a#@}" "$FAKE_OUT/job.sh" ;; esac; done
printf '%s\n' "$@" > "$FAKE_OUT/curl-args"
echo '{"job_id": 12, "task_token": "tt", "release_url": "https://ci.example/release/12"}'
EOF
cat > "$t/stub/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_OUT/gh-args"
echo "QUJDREVG" # base64 runner config
EOF
chmod +x "$t/stub/curl" "$t/stub/gh"
launcher=/opt/test-ci-runner/launcher/launch-runner.sh

request() {   # request <profile> <run id> [<dispatch>]
  : > "$t/summary"; : > "$t/output"
  PATH="$t/stub:$PATH" DISPATCH=${3:-mvp} PROFILE=$1 ORIGIN_TOKEN=ot GH_TOKEN=pat \
    URL=https://ci.example/ LAUNCHER=$launcher REPO=o/r RUN_ID=$2 RUN_ATTEMPT=1 \
    GITHUB_STEP_SUMMARY=$t/summary GITHUB_OUTPUT=$t/output \
    "$root/request-runner/request.sh" > "$t/log" 2>&1
}

request gh200-1gpu 88 || fail "request.sh: $(cat "$t/log")"
grep -qx '#SBATCH --gpus=1' "$t/job.sh" || fail "job script: $(cat "$t/job.sh")"
grep -qx "export ACTIONS_RUNNER_INPUT_JITCONFIG='QUJDREVG'" "$t/job.sh" || fail "config in job script"
grep -qx "exec $launcher --profile gh200-1gpu --config-env --expect-repo o/r --expect-run 88" \
  "$t/job.sh" || fail "launcher line: $(tail -1 "$t/job.sh")"
grep -qxF 'labels[]=test-ci-gh200-1gpu' "$t/gh-args" || fail "profile label: $(cat "$t/gh-args")"
grep -qxF 'labels[]=test-ci-run-88' "$t/gh-args" || fail "run label: $(cat "$t/gh-args")"
grep -qx 'https://ci.example/jobs' "$t/curl-args" || fail "job API URL"
grep -q 'release-url=https://ci.example/release/12' "$t/output" || fail "output"
grep -q 'https://ci.example/release/12' "$t/summary" || fail "summary"
bash -n "$t/job.sh" || fail "job script isn't valid bash"
echo "ok - mvp: job script, labels, job API call, release link"

request dev-cpu 89 || fail "request.sh dev-cpu: $(cat "$t/log")"
! grep -q -- '--gpus' "$t/job.sh" || fail "dev-cpu job script asks for GPUs: $(cat "$t/job.sh")"
grep -qx '#SBATCH --time=00:30:00' "$t/job.sh" || fail "dev-cpu job script: $(cat "$t/job.sh")"
echo "ok - mvp: dev-cpu asks for no GPU"

if request gh200-1gpu 1 service; then fail "service should fail for now"; fi
if request no-such-profile 1; then fail "an unknown profile should fail"; fi
echo "ok - refuses dispatch: service (not built) and unknown profiles"
