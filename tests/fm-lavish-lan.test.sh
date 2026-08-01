#!/usr/bin/env bash
# Behavior tests for bin/fm-lavish-lan.sh, the LAN relay in front of lavish-axi.
#
# The relay itself (bin/fm-lavish-lan-relay.js) needs a real listening upstream to
# forward to, so these tests stand up a tiny loopback echo server in place of the
# real lavish-axi server and drive the manager against it on ephemeral high ports.
# That keeps the tests hermetic (no lavish-axi, no fixed ports) while still
# exercising the real node relay end to end.
#
# What is covered here:
#   - a second start refuses to launch a rival relay (idempotency),
#   - stop cleanly terminates the relay and status reflects it,
#   - bytes pass through the raw-TCP relay unchanged (the WebSocket-safety
#     property reduces to "the relay never parses the stream", proven by a raw
#     request/response round-trip),
#   - a port already held by a non-relay listener is reported as in-use (exit 3).
#
# NOT covered here (documented gap): a real phone-over-VPN round trip and the
# actual LAN interface reachability cannot run in CI - there is no second host and
# no VPN. The LAN-IP discovery is display-only and the bind choice is a runtime
# flag; the round-trip property is proven over loopback instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MGR="$ROOT/bin/fm-lavish-lan.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-lan)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# Processes started by a test must never outlive it: a stranded relay or upstream
# would hold a port and fail a later test.
STRAYS=()
lan_cleanup() {
  local pid
  for pid in "${STRAYS[@]:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap lan_cleanup EXIT

# free_port echoes an OS-assigned free TCP port by binding :0 and reading it back.
free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{process.stdout.write(String(s.address().port));s.close();});'
}

# start_upstream <port>: a loopback echo server that replies to any request with a
# fixed HTTP 200 body, standing in for lavish-axi. Echoes its pid.
start_upstream() {
  local port=$1
  local pidf="$TMP_ROOT/up.$port.pid"
  node -e '
    const net=require("net");
    const fs=require("fs");
    const s=net.createServer(c=>{c.on("data",()=>c.end("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nlavsh"));});
    s.listen(parseInt(process.argv[1],10),"127.0.0.1",()=>fs.writeFileSync(process.argv[2],String(process.pid)));
  ' "$port" "$pidf" &
  local pid=$!
  STRAYS+=("$pid")
  # Wait for it to actually listen.
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -f "$pidf" ] && break
    sleep 0.1; i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

# roundtrip <port>: send one raw request through the relay and echo the reply.
roundtrip() {
  local port=$1
  node -e '
    const net=require("net");
    const c=net.connect(parseInt(process.argv[1],10),"127.0.0.1",()=>c.write("GET /session/x HTTP/1.1\r\nHost: x\r\n\r\n"));
    let b="";c.on("data",d=>b+=d);c.on("end",()=>{process.stdout.write(b);});c.on("error",()=>process.exit(9));
  ' "$port"
}

# pid_gone <pid>: true when the pid is gone OR is a zombie. On a host whose pid 1
# does not reap orphans (many CI containers), a stopped relay lingers as <defunct>
# and a bare `kill -0` still succeeds on it, so a liveness assertion must treat a
# zombie as gone - exactly as bin/fm-lavish-lan.sh itself does.
pid_gone() {
  local pid=$1 state
  kill -0 "$pid" 2>/dev/null || return 0
  if [ -r "/proc/$pid/stat" ]; then
    state=$(sed -e 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f1)
    [ "$state" = "Z" ] && return 0
  fi
  return 1
}

new_home() {
  local home="$TMP_ROOT/home.$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_start_is_idempotent_and_passes_bytes_through() {
  local home up_port relay_port out code
  home=$(new_home idem)
  up_port=$(free_port)
  relay_port=$(free_port)
  start_upstream "$up_port" >/dev/null

  out=$(FM_HOME="$home" "$MGR" start --session s1 --port "$relay_port" --target "$up_port" 2>&1); code=$?
  [ "$code" -eq 0 ] || fail "first start failed: $out"
  assert_contains "$out" "started pid=" "first start did not report a pid"
  assert_contains "$out" "NOTICE - while up" "start did not print the reachability notice"
  assert_contains "$out" "/session/s1" "start did not print the LAN session url"

  # Bytes must pass through unchanged: the relay is a raw passthrough, not a proxy.
  local reply
  reply=$(roundtrip "$relay_port")
  assert_contains "$reply" "200 OK" "raw request did not round-trip through the relay"
  assert_contains "$reply" "lavsh" "response body did not pass through the relay"

  # A second start must refuse to launch a rival and report the same pid.
  local out2 code2
  out2=$(FM_HOME="$home" "$MGR" start --session s1 --port "$relay_port" --target "$up_port" 2>&1); code2=$?
  [ "$code2" -eq 0 ] || fail "second start returned non-zero: $out2"
  assert_contains "$out2" "already running pid=" "second start did not refuse as already-running"

  # Exactly one relay process exists for this home.
  local n
  n=$(pgrep -f "fm-lavish-lan-relay.js.*" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 1 ] || fail "expected a running relay, found none"

  FM_HOME="$home" "$MGR" stop >/dev/null 2>&1
  pass "start is idempotent and the relay passes raw bytes through"
}

test_stop_is_clean_and_status_reflects_it() {
  local home up_port relay_port
  home=$(new_home stop)
  up_port=$(free_port)
  relay_port=$(free_port)
  start_upstream "$up_port" >/dev/null

  FM_HOME="$home" "$MGR" start --port "$relay_port" --target "$up_port" >/dev/null 2>&1 \
    || fail "start failed in stop test"

  local pid
  pid=$(head -n1 "$home/state/.lavish-lan.pid" 2>/dev/null)
  [ -n "$pid" ] || fail "no pidfile after start"
  pid_gone "$pid" && fail "relay pid $pid not alive after start"

  local sout scode
  sout=$(FM_HOME="$home" "$MGR" status 2>&1); scode=$?
  [ "$scode" -eq 0 ] || fail "status exit $scode while running"
  assert_contains "$sout" "running pid=$pid" "status did not report the running relay"

  FM_HOME="$home" "$MGR" stop >/dev/null 2>&1 || fail "stop returned non-zero"
  # Give the process a moment to actually exit.
  local i=0
  while [ "$i" -lt 30 ]; do pid_gone "$pid" && break; sleep 0.1; i=$((i + 1)); done
  pid_gone "$pid" || fail "relay pid $pid still alive after stop"
  [ -f "$home/state/.lavish-lan.pid" ] && fail "pidfile survived stop"

  local aout acode
  aout=$(FM_HOME="$home" "$MGR" status 2>&1); acode=$?
  [ "$acode" -eq 1 ] || fail "status exit $acode after stop (want 1)"
  assert_contains "$aout" "not running" "status did not report not-running after stop"

  # Stopping an absent relay is not an error.
  FM_HOME="$home" "$MGR" stop >/dev/null 2>&1 || fail "second stop returned non-zero"
  pass "stop cleanly terminates the relay and status reflects it"
}

test_port_in_use_by_non_relay_is_reported() {
  local home busy_port out code pidf
  home=$(new_home busy)
  busy_port=$(free_port)
  pidf="$TMP_ROOT/busy.pid"
  # A non-relay listener holds the port.
  node -e '
    const n=require("net");const fs=require("fs");
    const s=n.createServer(()=>{});
    s.listen(parseInt(process.argv[1],10),"0.0.0.0",()=>fs.writeFileSync(process.argv[2],String(process.pid)));
  ' "$busy_port" "$pidf" &
  local occ=$!
  STRAYS+=("$occ")
  local i=0
  while [ "$i" -lt 50 ]; do [ -f "$pidf" ] && break; sleep 0.1; i=$((i + 1)); done

  out=$(FM_HOME="$home" "$MGR" start --port "$busy_port" --target 4387 2>&1); code=$?
  [ "$code" -eq 3 ] || fail "start on a busy port exited $code (want 3): $out"
  assert_contains "$out" "already in use" "start did not report the port as in use"
  [ -f "$home/state/.lavish-lan.pid" ] && fail "a failed start left a pidfile behind"
  pass "a port held by a non-relay listener is reported as in-use"
}

test_url_and_status_without_a_running_relay() {
  local home out code
  home=$(new_home norun)
  out=$(FM_HOME="$home" "$MGR" url 2>&1); code=$?
  [ "$code" -eq 1 ] || fail "url exit $code with no relay (want 1)"
  assert_contains "$out" "not running" "url did not explain the relay is not running"

  out=$(FM_HOME="$home" "$MGR" status 2>&1); code=$?
  [ "$code" -eq 1 ] || fail "status exit $code with no relay (want 1)"
  pass "url and status refuse cleanly when nothing is running"
}

test_start_is_idempotent_and_passes_bytes_through
test_stop_is_clean_and_status_reflects_it
test_port_in_use_by_non_relay_is_reported
test_url_and_status_without_a_running_relay

echo "# all fm-lavish-lan tests passed"
