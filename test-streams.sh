#!/bin/zsh
# End-to-end stream checks against local fixtures (needs macOS audio output, afconvert and openssl).
# Each scenario launches the real app muted and passes only after real decoded audio reached the analyzer/EQ.
set -eu
cd "${0:A:h}"
APP="${RADIOPOCKET_APP_PATH:-${PWD}/dist/RadioPocket.app}"
[[ -x "$APP/Contents/MacOS/RadioPocket" ]] || ./build.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp/}radiopocket-streams.XXXXXX")
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 Tests/stream_fixtures.py "$PORT" >"$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; pkill -x RadioPocket 2>/dev/null || true; rm -rf "$WORK"' EXIT
for _ in {1..60}; do curl -s -o /dev/null "http://127.0.0.1:$PORT/hls/key.bin" && break; sleep 0.5; done

failures=0
scenario() {  # path flag timeout-seconds
  local result="$WORK/result.txt"; rm -f "$result"
  "$APP/Contents/MacOS/RadioPocket" --data-dir "$WORK/data" --smoke-stream "http://127.0.0.1:$PORT$1" --smoke-result "$result" $2 >/dev/null 2>&1 &
  local pid=$! waited=0
  while [[ ! -s "$result" && $waited -lt $3 ]]; do sleep 1; waited=$((waited+1)); done
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  if [[ -s "$result" ]] && grep -q '^PASS' "$result"; then echo "PASS $1 $2"; else echo "FAIL $1 $2: $(cat "$result" 2>/dev/null || echo 'no result')"; failures=$((failures+1)); fi
}
scenario /aac-icy --test-vis 30
scenario /opus --test-vis 30
if [[ $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/vorbis") == 200 ]]; then
  scenario /vorbis --test-vis 30
  scenario /vorbis --test-timeshift 40
else echo "SKIP /vorbis (install ffmpeg to build the Vorbis fixture)"; fi
scenario /hls/live.m3u8 --test-vis 40
scenario /hls/live-packed.m3u8 --test-vis 40
scenario /hls/live-aes.m3u8 --test-vis 40
scenario /hls/master.m3u8 --test-vis 40
scenario /hls/live.m3u8 --test-eq 40
scenario /aac-icy --test-timeshift 40
scenario /opus --test-timeshift 40
scenario /hls/live.m3u8 --test-timeshift 50
scenario /aac-flaky --test-reconnect 60
scenario /aac-stall --test-reconnect 90
echo "$failures stream scenario(s) failed"
exit $failures
