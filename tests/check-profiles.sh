#!/bin/bash
# Fails if gh200.yml's timeout-minutes map drifts from request-runner/profiles.sh, or a
# profile's limits are in the wrong order (job < runner < Slurm).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../request-runner/profiles.sh
. "$root/request-runner/profiles.sh"

want="{"
for p in $PROFILES; do
  profile_settings "$p"
  want+="\"$p\":$JOB_MINUTES,"
  slurm=""
  for a in "${SBATCH_ARGS[@]}"; do case $a in --time=*) slurm=${a#--time=} ;; esac; done
  IFS=: read -r h m s <<<"$slurm"
  slurm_min=$(( 10#$h * 60 + 10#$m + (10#$s > 0) ))
  if [ "$JOB_MINUTES" -ge "$RUNNER_MINUTES" ] || [ "$RUNNER_MINUTES" -ge "$slurm_min" ]; then
    echo "profile $p: need job ($JOB_MINUTES) < runner ($RUNNER_MINUTES) < Slurm ($slurm_min) minutes" >&2
    exit 1
  fi
done
want="${want%,}}"

have=$(grep -o "fromJSON('{[^']*}')\[inputs.profile\]" "$root/.github/workflows/gh200.yml" \
  | sed "s/^fromJSON('//; s/')\[inputs.profile\]$//")
if [ "$have" != "$want" ]; then
  echo "gh200.yml timeout map is $have; profiles.sh says $want" >&2
  exit 1
fi
echo "profiles OK: $want"
