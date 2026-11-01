#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/silly-promptnook-check.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$check_dir/ca.key" -out "$check_dir/ca.pem" \
    -days 1 -subj /CN=silly-contract-test-ca >"$check_dir/cert.log" 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$check_dir/server.key" -out "$check_dir/server.csr" \
    -subj /CN=localhost >>"$check_dir/cert.log" 2>&1
printf '%s\n' 'subjectAltName=DNS:localhost' 'extendedKeyUsage=serverAuth' > "$check_dir/extensions"
openssl x509 -req -in "$check_dir/server.csr" -CA "$check_dir/ca.pem" -CAkey "$check_dir/ca.key" \
    -CAcreateserial -out "$check_dir/server.pem" -days 1 -extfile "$check_dir/extensions" >>"$check_dir/cert.log" 2>&1
cd "$repo_dir"
for mode in debug optimized; do
    if [ "$mode" = debug ]; then
        GOOSE_HOME="$check_dir/cache-$mode" goose build tests/integration/promptnook/promptnook_proxy_test.goose --offline -O0 --debug -o "$check_dir/$mode"
    else
        GOOSE_HOME="$check_dir/cache-$mode" goose build tests/integration/promptnook/promptnook_proxy_test.goose --offline -O2 -o "$check_dir/$mode"
    fi
    ruby tests/integration/promptnook/promptnook_proxy_fixture.rb "$check_dir/$mode" "$check_dir"
done
