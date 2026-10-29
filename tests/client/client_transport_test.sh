#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/silly-client-check.XXXXXX")
fixture_pid=
cleanup() {
    if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
    rm -rf "$check_dir"
}
trap cleanup EXIT HUP INT TERM
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$check_dir/ca.key" -out "$check_dir/ca.pem" \
    -days 1 -subj /CN=silly-local-test-ca >"$check_dir/cert.log" 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$check_dir/server.key" -out "$check_dir/server.csr" \
    -subj /CN=localhost >>"$check_dir/cert.log" 2>&1
cat > "$check_dir/extensions" <<'EXT'
subjectAltName=DNS:localhost
extendedKeyUsage=serverAuth
EXT
openssl x509 -req -in "$check_dir/server.csr" -CA "$check_dir/ca.pem" -CAkey "$check_dir/ca.key" \
    -CAcreateserial -out "$check_dir/server.pem" -days 1 -extfile "$check_dir/extensions" >>"$check_dir/cert.log" 2>&1
python3 "$repo_dir/tests/client/client_fixture.py" "$check_dir/ready.json" "$check_dir/server.pem" "$check_dir/server.key" &
fixture_pid=$!
for turn in $(seq 1 100); do
    if [ -f "$check_dir/ready.json" ]; then break; fi
    sleep 0.02
done
SILLY_CLIENT_HTTP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["http"])' "$check_dir/ready.json")
SILLY_CLIENT_HTTPS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["https"])' "$check_dir/ready.json")
SILLY_CLIENT_REFUSED=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["refused"])' "$check_dir/ready.json")
SILLY_CLIENT_STALL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stall"])' "$check_dir/ready.json")
SILLY_CLIENT_CA=$check_dir/ca.pem
export SILLY_CLIENT_HTTP SILLY_CLIENT_HTTPS SILLY_CLIENT_CA SILLY_CLIENT_REFUSED SILLY_CLIENT_STALL
cd "$repo_dir"
# Separate native caches: Goose currently reuses package C objects across optimization modes.
for mode in debug optimized; do
    if [ "$mode" = debug ]; then
        GOOSE_HOME="$check_dir/cache-$mode" goose build tests/client/client_transport_test.goose --offline -O0 --debug -o "$check_dir/$mode"
    else
        GOOSE_HOME="$check_dir/cache-$mode" goose build tests/client/client_transport_test.goose --offline -O2 -o "$check_dir/$mode"
    fi
    "$check_dir/$mode"
done
