#!/usr/bin/env bash
# Headless end-to-end smoke test: a listen-server host and a knocking client on
# localhost, plus buttons, lobby, persistence, VNC and Whisper checks.
# Progress and each test's results are printed as they happen; full logs go
# to /tmp/opo_*.log.
#
# The tests run in their own throwaway data folder (Godot keeps app data under
# $XDG_DATA_HOME on Linux), never touching your saves, preferences or config,
# so it's safe to run while the app is open.
#   SKIP_WHISPER=1  skip the (slow) speech recognition test
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
# Own port, so a copy of the app you have running (on 7777) doesn't clash.
PORT="${SELFTEST_PORT:-7790}"
REAL_UD="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/Office Plus One"
export XDG_DATA_HOME="$(mktemp -d /tmp/opo_selftest_data.XXXXXX)"
UD="$XDG_DATA_HOME/godot/app_userdata/Office Plus One"
mkdir -p "$UD"
# Reuse the downloaded Whisper model rather than fetching it again.
[ -d "$REAL_UD/models" ] && ln -s "$REAL_UD/models" "$UD/models"
BG_PIDS=""
cleanup() {
	for p in $BG_PIDS; do kill "$p" 2>/dev/null; done
	rm -rf "${XDG_DATA_HOME:?}"
}
trap cleanup EXIT
START=$(date +%s)
FAILED=""

say() { printf '[%3ss] %s\n' "$(( $(date +%s) - START ))" "$*"; }

# Follow a running test's log, printing its results and errors as they appear.
follow() { # follow LOG PID
	tail -n +1 -f "$1" --pid="$2" 2>/dev/null | grep --line-buffered -E "^\[selftest(:|\])|SCRIPT ERROR|Parse Error|^ERROR: \[selftest\]" | sed -u 's/^/      /'
}

# Run one headless test role: run TIMEOUT NAME LOG ARGS…  (records failures)
run() {
	local timeout=$1 name=$2 log=$3
	shift 3
	say "$name (up to ${timeout}s)…"
	timeout "$timeout" "$GODOT" --headless --xr-mode off -- "$@" > "$log" 2>&1 &
	local pid=$!
	follow "$log" "$pid"
	wait "$pid"
	local rc=$?
	[ $rc -eq 124 ] && echo "      (timed out)"
	# A script error aborts the rest of that test function without failing it, so treat any as a failure.
	grep -q "SCRIPT ERROR\|Parse Error" "$log" && rc=1
	[ $rc -eq 0 ] || FAILED="$FAILED $name"
	return $rc
}

# 1. Host and a knocking client, at the same time (a fake OpenAI-compatible
#    server stands in for the AI fallback test).
OPENAI_PORT=$((PORT + 1))
python3 tests/fake_openai_server.py $OPENAI_PORT > /tmp/opo_fake_openai.log 2>&1 &
BG_PIDS="$BG_PIDS $!"
say "host + client (up to 120s)…"
timeout 120 "$GODOT" --headless --xr-mode off -- --host --desktop --selftest=host --name=HostPat --port=$PORT --fake_openai=$OPENAI_PORT > /tmp/opo_host.log 2>&1 &
HOST=$!
follow /tmp/opo_host.log $HOST &
BG_PIDS="$BG_PIDS $!"
sleep 5
if kill -0 $HOST 2>/dev/null; then
	run 40 client /tmp/opo_client.log --join=127.0.0.1 --desktop --selftest=client --name=ClientSam --port=$PORT
else
	say "client skipped: the host already stopped"
	FAILED="$FAILED client"
fi
wait $HOST
HOST_RC=$?
[ $HOST_RC -eq 124 ] && echo "      (host timed out)"
grep -q "SCRIPT ERROR\|Parse Error" /tmp/opo_host.log && HOST_RC=1
[ $HOST_RC -eq 0 ] || FAILED="$FAILED host"

# 2. Physical buttons (no server needed).
run 30 buttons /tmp/opo_buttons.log --desktop --selftest=buttons

# 3. The lobby: saved rooms, the help panel, the tutorial world.
rm -rf "${UD:?}/saves" # (the test data folder, not yours)
run 60 lobby /tmp/opo_lobby.log --desktop --selftest=lobby --name=HostPat --port=$PORT

# 4. Restart persistence: change the office and close it, then start again.
rm -rf "${UD:?}/saves"
run 40 "persist (part 1)" /tmp/opo_persist1.log --host --desktop --selftest=persist1 --name=HostPat --port=$PORT
run 40 "persist (part 2)" /tmp/opo_persist2.log --host --desktop --selftest=persist2 --name=HostPat --port=$PORT

# 5. The VNC viewer (TVs and monitors) against a fake VNC server.
say "vnc (up to 2 min)…"
tests/vnc_selftest.sh > /tmp/opo_vnc_all.log 2>&1 || FAILED="$FAILED vnc"
grep -E "FAIL|PASS$" /tmp/opo_vnc_all.log | sed 's/^/      /'

# 6. Offline speech recognition (downloads the Whisper model to user://models on first run).
if [ "${SKIP_WHISPER:-0}" != "1" ]; then
	run 400 whisper /tmp/opo_whisper.log --desktop --selftest=whisper
else
	say "whisper skipped (SKIP_WHISPER=1)"
fi

if [ -z "$FAILED" ]; then
	say "ALL PASS"
else
	say "FAILED:$FAILED (logs: /tmp/opo_*.log)"
	exit 1
fi
