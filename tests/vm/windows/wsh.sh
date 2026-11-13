#!/usr/bin/env bash
# Run a shell script (stdin) as root in the helper distribution of the Windows VM.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${OS_SWITCH_VM_DIR:-$HOME/.cache/os-switch-vm}"
tmp=$(mktemp)
cat >"$tmp"
scp -q -i "$BASE/id" -P 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$tmp" test@127.0.0.1:C:/osw/t-$$.sh
rm -f "$tmp"
"$HERE/winvm.sh" ssh "\$env:WSL_UTF8=1; wsl -d os-switch -u root -- sh /mnt/c/osw/t-$$.sh; exit \$LASTEXITCODE"
