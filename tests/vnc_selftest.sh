#!/usr/bin/env bash
# Read-only VNC viewer test: a fake VNC server + the viewer (no app data touched).
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
PORT="${VNC_TEST_PORT:-5977}"
rc=0
for mode in none password; do
	python3 tests/fake_vnc_server.py $PORT $([ $mode = password ] && echo --password) > /tmp/opo_vnc_server.log 2>&1 &
	SERVER=$!
	sleep 0.5
	timeout 60 "$GODOT" --headless --xr-mode off --script tests/vnc_test.gd -- $PORT $([ $mode = password ] && echo secret) > /tmp/opo_vnc.log 2>&1 || rc=1
	wait $SERVER || rc=1
	echo "--- $mode auth"
	grep -h "^\[vnc\]\|SCRIPT ERROR" /tmp/opo_vnc.log
	grep -h "SERVER\|FAIL" /tmp/opo_vnc_server.log
done
[ $rc -eq 0 ] && echo "VNC PASS" || { echo "VNC FAILED"; exit 1; }
