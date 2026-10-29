#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/silly-client-http-check.XXXXXX")
fixture_pid=
cleanup() {
    if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
    rm -rf "$check_dir"
}
trap cleanup EXIT HUP INT TERM
python3 "$repo_dir/tests/client/client_http_fixture.py" "$check_dir/ready.json" &
fixture_pid=$!
for turn in $(seq 1 100); do
    if [ -f "$check_dir/ready.json" ]; then break; fi
    sleep 0.02
done
SILLY_CLIENT_HTTP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["http"])' "$check_dir/ready.json")
export SILLY_CLIENT_HTTP
cd "$repo_dir"
for mode in debug optimized; do
    if [ "$mode" = debug ]; then
        GOOSE_HOME="$check_dir/cache-$mode" goose build tests/client/client_http_test.goose --offline -O0 --debug -o "$check_dir/$mode"
    else
        GOOSE_HOME="$check_dir/cache-$mode" goose build tests/client/client_http_test.goose --offline -O2 -o "$check_dir/$mode"
    fi
    "$check_dir/$mode"
done
