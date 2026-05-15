#!/bin/sh
set -eu

root="${1:-.}"
failed=0

scan() {
    label="$1"
    pattern="$2"
    if rg -n --hidden -I --glob '!.git/**' --glob '!*.lock' --glob '!scripts/privacy-scan.sh' "$pattern" "$root"; then
        printf 'privacy-scan: %s found\n' "$label" >&2
        failed=1
    fi
}

scan "private local path or host" '(/Users/heathrowandrews|/Users/thalia|tail0513ff|100\.105\.74\.110)'
scan "raw bearer token" 'Authorization: Bearer [A-Za-z0-9._~+/-]{16,}'
scan "64-char hex secret" '\b[a-f0-9]{64}\b'

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf 'privacy-scan: clean\n'
