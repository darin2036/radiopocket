#!/bin/zsh
set -eu
cd "${0:A:h}"
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp/}radiopocket-network.XXXXXX")
TEST_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
RADIOPOCKET_TEST_PORT="$TEST_PORT" python3 Tests/mock_directory.py >"$CHECK_DIR/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$CHECK_DIR"' EXIT
clang -O2 -c Sources/CEQ/CEQ.c -I Sources/CEQ/include -o "$CHECK_DIR/eq.o"
swiftc -parse-as-library -I Sources/CEQ/include Sources/RadioPocket/Analyzer.swift Sources/RadioPocket/Library.swift Sources/RadioPocket/Equalizer.swift Sources/RadioPocket/Directory.swift Sources/RadioPocket/StationCache.swift Sources/RadioPocket/StationHealth.swift Sources/RadioPocket/StationSearch.swift Sources/RadioPocket/DirectorySources.swift Tests/DirectoryNetwork.swift "$CHECK_DIR/eq.o" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" "http://127.0.0.1:$TEST_PORT"
