#!/bin/bash
# Runs the launcher, hook, submit.sh, dispatch-runner.sh and request-runner
# against stand-ins for the runner, sbatch, ssh, gh and the job API. No network,
# no Slurm. Catches wiring mistakes; it can't stand in for the real cluster.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
pass=0
ok() { echo "ok - $*"; pass=$((pass + 1)); }
fail() { echo "FAIL - $*" >&2; exit 1; }

# A stand-in runner: run.sh starts bin/Runner.Listener by its full path, as the real
# one does. The listener runs the pre-job hook with a fake job's GITHUB_* variables,
# records what it saw, then either finishes or (FAKE_HOLD=1) waits for SIGTERM.
fake=$t/actions-runner/current
mkdir -p "$fake/bin"
cat > "$fake/run.sh" <<'EOF'
#!/bin/bash
DIR="$(cd -P "$(dirname "$0")" && pwd)"
"$DIR/bin/Runner.Listener" run
EOF
cat > "$fake/bin/Runner.Listener" <<'EOF'
#!/bin/bash
[ -n "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" ] || { echo "listener: no config"; exit 3; }
root=$(cd "$(dirname "$0")/.." && pwd)
{ echo "config=$ACTIONS_RUNNER_INPUT_JITCONFIG"; echo "mode=$(stat -c %a "$root")";
  echo "path=$PATH"; } > "$FAKE_OUT/seen"
GITHUB_REPOSITORY=${FAKE_REPO:-o/r} GITHUB_RUN_ID=${FAKE_RUN:-1} GITHUB_RUN_ATTEMPT=1 \
  GITHUB_JOB=run GITHUB_SHA=abc "$ACTIONS_RUNNER_HOOK_JOB_STARTED" > "$FAKE_OUT/hook" 2>&1 \
  && echo "hook=0" >> "$FAKE_OUT/seen" || echo "hook=$?" >> "$FAKE_OUT/seen"
if [ "${FAKE_HOLD:-0}" = 1 ]; then
  trap 'echo "listener: SIGTERM, telling GitHub"; sleep 2; echo "listener: done"; exit 0' TERM
  sleep 300 & wait
fi
echo "listener: job finished"
EOF
chmod +x "$fake/run.sh" "$fake/bin/Runner.Listener"
export RUNNER_HOME=$fake FAKE_OUT=$t TMPDIR=$t/tmp HOME=$t/home
mkdir -p "$TMPDIR" "$HOME"

# 1. Launcher with a config file: reads and deletes it, 700 folder, hook passes, cleans up
echo "CFG1" > "$t/cfg" && chmod 600 "$t/cfg"
"$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-file "$t/cfg" \
  --expect-repo o/r --expect-run 1 > "$t/log1" 2>&1 || fail "launcher exited non-zero: $(cat "$t/log1")"
[ ! -e "$t/cfg" ] || fail "config file not deleted"
grep -q '^config=CFG1$' "$t/seen" || fail "runner didn't get the config"
grep -q '^mode=700$' "$t/seen" || fail "runner folder not 700: $(grep mode "$t/seen")"
grep -q "^path=$root/bin:" "$t/seen" || fail "brics-ci/bin not first on PATH"
grep -q '^hook=0$' "$t/seen" || fail "hook refused a matching job: $(cat "$t/hook")"
grep -q 'cleaned up' "$t/log1" || fail "no clean-up"
[ -z "$(ls -A "$TMPDIR")" ] || fail "runner folder left behind: $(ls -A "$TMPDIR")"
ok "launcher: config file, 700 folder, PATH, hook, clean-up"

# 2. The hook refuses another repo or run
echo CFG2 > "$t/cfg"
FAKE_RUN=2 "$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-file "$t/cfg" \
  --expect-repo o/r --expect-run 1 > "$t/log2" 2>&1 || true
grep -q '^hook=1$' "$t/seen" || fail "hook accepted the wrong run"
grep -q 'started for run 1, not 2' "$t/hook" || fail "hook message: $(cat "$t/hook")"
ok "hook: refuses a job from another run"

# 3. Config from the environment, and a missing config
ACTIONS_RUNNER_INPUT_JITCONFIG=CFG3 "$root/launcher/launch-runner.sh" --profile gh200-4gpu \
  --config-env > "$t/log3" 2>&1 || fail "launcher --config-env failed"
grep -q '^config=CFG3$' "$t/seen" || fail "runner didn't get the config from the environment"
if "$root/launcher/launch-runner.sh" --profile gh200-1gpu > "$t/log4" 2>&1; then fail "ran with no config"; fi
if "$root/launcher/launch-runner.sh" --profile nope --config-env > "$t/log5" 2>&1; then fail "ran with a bad profile"; fi
ok "launcher: --config-env; refuses no config and unknown profiles"

# 4. The tar copy, when <RUNNER_HOME>.tar exists
tar -C "$fake" -cf "$fake.tar" .
echo CFG4 > "$t/cfg"
"$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-file "$t/cfg" > "$t/log6" 2>&1 \
  || fail "launcher with tar failed: $(cat "$t/log6")"
grep -q '^mode=700$' "$t/seen" || fail "tar copy left the folder at $(grep mode "$t/seen")"
rm -f "$fake.tar"
ok "launcher: tar copy keeps the folder 700"

# 5. SIGTERM to the launcher only (as Slurm does): the runner gets it and finishes first
echo CFG5 > "$t/cfg"
FAKE_HOLD=1 setsid "$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-file "$t/cfg" \
  > "$t/log7" 2>&1 &
lpid=$!
for _ in $(seq 50); do grep -q 'runner starting' "$t/log7" 2>/dev/null && break; sleep 0.1; done
sleep 1
kill -TERM "$lpid"
wait "$lpid" || true
grep -q 'listener: done' "$t/log7" || fail "runner didn't finish after SIGTERM: $(cat "$t/log7")"
n_done=$(grep -n 'listener: done' "$t/log7" | cut -d: -f1)
n_clean=$(grep -n 'cleaned up' "$t/log7" | cut -d: -f1)
[ "$n_done" -lt "$n_clean" ] || fail "cleaned up before the runner finished"
ok "launcher: passes SIGTERM on and waits for the runner"

# 6. submit.sh: 0600 config file, arguments not --export, profile settings
mkdir -p "$t/stub"
cat > "$t/stub/sbatch" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_OUT/sbatch-args"
echo 4242
EOF
chmod +x "$t/stub/sbatch"
jobid=$(echo CFG6 | PATH="$t/stub:$PATH" "$root/launcher/submit.sh" gh200-4gpu o/r 77)
[ "$jobid" = 4242 ] || fail "submit.sh printed '$jobid'"
grep -qx -- '--gpus=4' "$t/sbatch-args" || fail "profile settings missing"
grep -qx -- '--job-name=brics-gh200-4gpu-77' "$t/sbatch-args" || fail "job name"
! grep -q -- '--export' "$t/sbatch-args" || fail "submit.sh uses --export"
wrap=$(grep -A1 -x -- '--wrap' "$t/sbatch-args" | tail -1)
case $wrap in "exec $root/launcher/launch-runner.sh --profile gh200-4gpu --config-file $HOME/.brics-ci/config."*" --expect-repo o/r --expect-run 77 ") ;;
  *) fail "wrap command: $wrap" ;; esac
cfg=$(sed -n 's/.*--config-file \([^ ]*\).*/\1/p' <<<"$wrap")
[ "$(stat -c %a "$cfg")" = 600 ] && [ "$(cat "$cfg")" = CFG6 ] || fail "config file mode or content"
[ "$(stat -c %a "$HOME/.brics-ci")" = 700 ] || fail "\$HOME/.brics-ci not 700"
if echo CFG | PATH="$t/stub:$PATH" "$root/launcher/submit.sh" gh200-1gpu 'o/r;rm' 1 >/dev/null 2>&1; then
  fail "submit.sh accepted a bad repo name"
fi
ok "submit.sh: 0600 config, profile settings, arguments not --export, input checks"

# 7. dispatch-runner.sh: one runner per queued BriCS job, with both labels
cat > "$t/stub/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$FAKE_OUT/gh-calls"
case "$*" in
  *"runs/555/jobs"*) printf '901 gh200-1gpu\n902 gh200-4gpu\n' ;;
  *generate-jitconfig*) echo "CFG-$(date +%N)" ;;
esac
EOF
cat > "$t/stub/ssh" <<'EOF'
#!/bin/bash
while [ "${1#-}" != "$1" ]; do shift 2; done; shift
echo "ssh $*" >> "$FAKE_OUT/ssh-calls"
case "$*" in *submit.sh*) cat > /dev/null; echo 5000 ;; esac
EOF
chmod +x "$t/stub/gh" "$t/stub/ssh"
out=$(PATH="$t/stub:$PATH" "$root/tools/dispatch-runner.sh" o/r 555)
[ "$(grep -c 'runner in Slurm job 5000' <<<"$out")" = 2 ] || fail "dispatch output: $out"
grep -q 'labels\[\]=brics-gh200-4gpu -f labels\[\]=brics-run-555' "$t/gh-calls" || fail "labels: $(cat "$t/gh-calls")"
grep -q 'brics-ci/launcher/submit.sh gh200-4gpu o/r 555' "$t/ssh-calls" || fail "submit call: $(cat "$t/ssh-calls")"
grep -q 'git -C brics-ci pull' "$t/ssh-calls" || fail "no git pull"
ok "dispatch-runner.sh: one runner per queued job, profile and run labels"

# 8. request-runner (dispatch: mvp): job script for the job API, summary and output
cat > "$t/stub/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do case $a in @*) cp "${a#@}" "$FAKE_OUT/job.sh" ;; esac; done
printf '%s\n' "$@" > "$FAKE_OUT/curl-args"
echo '{"job_id": 12, "task_token": "tt", "release_url": "https://ci.example/release/12"}'
EOF
cat > "$t/stub/gh" <<'EOF'
#!/bin/bash
echo "QUJDREVG" # base64 runner config
EOF
chmod +x "$t/stub/curl" "$t/stub/gh"
: > "$t/summary"; : > "$t/output"
PATH="$t/stub:$PATH" DISPATCH=mvp PROFILE=gh200-1gpu ORIGIN_TOKEN=ot GH_TOKEN=pat \
  URL=https://ci.example/ LAUNCHER=/opt/brics-ci/launcher/launch-runner.sh REPO=o/r RUN_ID=88 \
  RUN_ATTEMPT=1 GITHUB_STEP_SUMMARY=$t/summary GITHUB_OUTPUT=$t/output \
  "$root/request-runner/request.sh" > "$t/log8" 2>&1 || fail "request.sh: $(cat "$t/log8")"
grep -qx '#SBATCH --gpus=1' "$t/job.sh" || fail "job script: $(cat "$t/job.sh")"
grep -qx "export ACTIONS_RUNNER_INPUT_JITCONFIG='QUJDREVG'" "$t/job.sh" || fail "config in job script"
grep -qx 'exec /opt/brics-ci/launcher/launch-runner.sh --profile gh200-1gpu --config-env --expect-repo o/r --expect-run 88' \
  "$t/job.sh" || fail "launcher line: $(tail -1 "$t/job.sh")"
grep -qx 'https://ci.example/jobs' "$t/curl-args" || fail "job API URL"
grep -q 'release-url=https://ci.example/release/12' "$t/output" || fail "output"
grep -q 'https://ci.example/release/12' "$t/summary" || fail "summary"
bash -n "$t/job.sh" || fail "job script isn't valid bash"
if PATH="$t/stub:$PATH" DISPATCH=service PROFILE=gh200-1gpu REPO=o/r RUN_ID=1 RUN_ATTEMPT=1 \
    "$root/request-runner/request.sh" > /dev/null 2>&1; then fail "service should fail for now"; fi
ok "request-runner: mvp job script, job API call, release link; service not built"

echo "$pass checks passed"
