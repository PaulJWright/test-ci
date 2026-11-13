#!/bin/bash
# An example GH200 test script. The workflow runs it from the repo's root.
set -euo pipefail
echo "running as $(id -un) on $(hostname), in $(pwd)"
grep PRETTY_NAME /etc/os-release
nvidia-smi -L
test "$(uname -m)" = aarch64
echo "all good"
