#!/bin/zsh
set -eu
cd "${0:A:h}"
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp/}radiopocket-checks.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
clang -O2 -c Sources/CEQ/CEQ.c -I Sources/CEQ/include -o "$CHECK_DIR/eq.o"
clang -O2 -w -c Sources/CVorbis/stb_vorbis_impl.c -o "$CHECK_DIR/vorbis.o"
swiftc -I Sources/CEQ/include -I Sources/CVorbis/include Sources/RadioPocket/Analyzer.swift Sources/RadioPocket/PacketRing.swift Sources/RadioPocket/Demux.swift Sources/RadioPocket/VorbisDecoder.swift Sources/RadioPocket/HLSPlaylist.swift Sources/RadioPocket/StreamSources.swift Sources/RadioPocket/Changelog.swift Sources/RadioPocket/ClassicUI.swift Sources/RadioPocket/ExternalRadioLink.swift Sources/RadioPocket/Library.swift Sources/RadioPocket/Skin.swift Sources/RadioPocket/Equalizer.swift Sources/RadioPocket/EQPresets.swift Sources/RadioPocket/EQFile.swift Sources/RadioPocket/Directory.swift Sources/RadioPocket/StationSearch.swift Sources/RadioPocket/DirectorySources.swift Tests/main.swift "$CHECK_DIR/eq.o" "$CHECK_DIR/vorbis.o" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"
