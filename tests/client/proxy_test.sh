#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/silly-proxy-check.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
cd "$repo_dir"
for mode in debug optimized; do
    if [ "$mode" = debug ]; then
        GOOSE_HOME="$check_dir/cache-$mode" goose build tests/client/proxy_test.goose --offline -O0 --debug -o "$check_dir/$mode"
    else
        GOOSE_HOME="$check_dir/cache-$mode" goose build tests/client/proxy_test.goose --offline -O2 -o "$check_dir/$mode"
    fi
    ruby tests/client/proxy_fixture.rb "$check_dir/$mode"
done
