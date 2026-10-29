#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/silly-files-native-check.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
for mode in debug optimized; do
    opt=-O0
    if [ "$mode" = optimized ]; then opt=-O2; fi
    cc -std=c11 -Wall -Wextra -Werror "$opt" -g -pthread -DSILLY_FILES_TEST \
        "$repo_dir/tests/files/files_native_test.c" "$repo_dir/native/files.c" -o "$check_dir/files-$mode"
    "$check_dir/files-$mode"
done
