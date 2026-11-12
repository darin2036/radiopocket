#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .work
CHECK_DIR=$(mktemp -d "$PWD/.work/discovery-ui.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
clang -O2 -c Sources/CEQ/CEQ.c -I Sources/CEQ/include -o "$CHECK_DIR/eq.o"
clang -O2 -w -c Sources/CVorbis/stb_vorbis_impl.c -o "$CHECK_DIR/vorbis.o"
sources=(Sources/RadioPocket/*.swift)
sources=(${sources:#Sources/RadioPocket/main.swift})
swiftc -parse-as-library -I Sources/CEQ/include -I Sources/CVorbis/include "${sources[@]}" Tests/DiscoveryLoading.swift "$CHECK_DIR/eq.o" "$CHECK_DIR/vorbis.o" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"
