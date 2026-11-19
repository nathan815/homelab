#!/usr/bin/env bash
# End-to-end tests. Needs docker + curl + jq on the host and internet access (uses example.com/.org/.net).
# KEEP=1 ./test.sh   leaves the stack running afterwards.
cd "$(dirname "$0")"
export APPROVAL_TIMEOUT=10          # short, so the timeout test is quick
API=http://127.0.0.1:8081
T=$(mktemp -d)
PASSED=0; FAILED=0

sb()   { docker compose exec -T sandbox "$@"; }
ok()   { echo "PASS  $1"; PASSED=$((PASSED+1)); }
bad()  { echo "FAIL  $1${2:+  -- $2}"; FAILED=$((FAILED+1)); }
check(){ if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }     # check NAME EXITCODE [detail]
clear_rules() { for id in $(curl -s $API/rules | jq -r '.[].id'); do curl -s -X DELETE $API/rules/$id >/dev/null; done; }
# wait_pending SUBSTRING -> prints approval id (waits up to 30s)
wait_pending() {
  for _ in $(seq 60); do
    id=$(curl -s $API/approvals | jq -r --arg s "$1" '[.[]|select(.url|contains($s))][0].id // empty')
    [ -n "$id" ] && { echo "$id"; return 0; }
    sleep 0.5
  done; return 1
}
decide() { curl -s -X POST $API/approvals/$1/decision -d "{\"decision\":\"$2\"}" >/dev/null; }
# bg_curl OUTFILE curl-args...   (runs in sandbox, in background; sets BGPID)
bg_curl() { local out=$1; shift; sb curl -sS -m 60 -w '\n%{http_code}' "$@" >"$out" 2>&1 & BGPID=$!; }
code_of() { tail -n1 "$1"; }
pending_count() { curl -s $API/approvals | jq length; }

cleanup() { [ -n "$KEEP" ] || docker compose down -v >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

echo "== starting stack (timeout=${APPROVAL_TIMEOUT}s)"
docker compose down -v >/dev/null 2>&1
docker compose up -d --build >"$T/up.log" 2>&1 || { cat "$T/up.log"; echo "compose up failed"; exit 2; }
for _ in $(seq 120); do curl -sf $API/healthz >/dev/null && sb test -f /tmp/ready 2>/dev/null && break; sleep 1; done
curl -sf $API/healthz >/dev/null && sb test -f /tmp/ready || { echo "stack did not become ready"; docker compose logs; exit 2; }
echo

# ---------------------------------------------------------------- 0. CA hygiene
files=$(sb ls /ca-public)
[ "$files" = "mitmproxy-ca-cert.pem" ]; check "sandbox sees only the public CA cert (/ca-public: $files)" $?
sb sh -c 'grep -rl "PRIVATE KEY" /ca-public / --include=*.pem -s 2>/dev/null | grep -v "^/proc" | head -1' | grep -q . ; [ $? -ne 0 ]
check "no private key material found in sandbox filesystem" $?

# ---------------------------------------------------------------- 1. hold -> allow once
clear_rules
bg_curl $T/a.out https://example.com/
ID=$(wait_pending https://example.com/); check "unlisted URL creates a pending approval" $?
sleep 1; kill -0 $BGPID 2>/dev/null; check "request is HELD (curl still running while pending)" $?
curl -s $API/approvals | jq -e '.[0].text == "Allow the agent to browse https://example.com/?"' >/dev/null
check "card text is human friendly" $?
decide "$ID" allow_once; wait $BGPID
grep -q "Example Domain" $T/a.out && [ "$(code_of $T/a.out)" = 200 ]; check "allow_once: request completes with real content (HTTP 200)" $?
curl -s $API/rules | jq -e 'length==0' >/dev/null; check "allow_once stores no rule" $?

# ---------------------------------------------------------------- 2. deny
bg_curl $T/b.out https://example.com/
ID=$(wait_pending https://example.com/); decide "$ID" deny; wait $BGPID
[ "$(code_of $T/b.out)" = 403 ] && grep -q "user denied" $T/b.out; check "deny: 403 with explanatory plain-text body" $?

# ---------------------------------------------------------------- 3. timeout
echo "(waiting ${APPROVAL_TIMEOUT}s for timeout ...)"
bg_curl $T/c.out https://example.net/
wait_pending https://example.net/ >/dev/null; wait $BGPID
[ "$(code_of $T/c.out)" = 403 ] && grep -q "did not respond" $T/c.out; check "timeout: default deny with explanatory 403" $?
[ "$(pending_count)" = 0 ]; check "timed-out approval is removed from pending list" $?

# ---------------------------------------------------------------- 4. always allow / revoke
clear_rules
bg_curl $T/d.out https://example.com/
ID=$(wait_pending https://example.com/); decide "$ID" always_allow; wait $BGPID
[ "$(code_of $T/d.out)" = 200 ]; check "always_allow: first request completes" $?
RULE=$(curl -s $API/rules | jq -r '.[0].id')
curl -s $API/rules | jq -e '.[0] | .origin=="https://example.com" and .methods==["GET","HEAD"] and .action=="allow"' >/dev/null
check "rule is scheme+host, GET/HEAD only" $?
start=$(date +%s)
sb curl -sS -m 20 -o /dev/null -w '%{http_code}' https://example.com/ >$T/e.out 2>&1
[ "$(cat $T/e.out)" = 200 ] && [ "$(pending_count)" = 0 ]; check "second request passes with no prompt" $?
sb curl -sS -m 20 -o /dev/null -w '%{http_code}' "https://example.com/other/path?x=1" >$T/e2.out 2>&1
[ "$(pending_count)" = 0 ] && [ "$(cat $T/e2.out)" != "" ]; check "rule covers other paths on the same host (no prompt)" $?

# ---------------------------------------------------------------- 5. POST asks despite GET rule
bg_curl $T/f.out -X POST -d 'password=hunter2&note=hello' https://example.com/
ID=$(wait_pending https://example.com/); check "POST creates a pending approval even with a host GET rule" $?
curl -s $API/approvals | jq -e '.[0] | .kind=="send_data" and (.text|startswith("Allow the agent to send data to")) and .body_size==27' >/dev/null
check "POST card says 'send data to' and shows body size" $?
curl -s $API/approvals | jq -e '.[0].body_preview | contains("hunter2") | not' >/dev/null
check "secret in body preview is redacted" $?
decide "$ID" deny; wait $BGPID
[ "$(code_of $T/f.out)" = 403 ]; check "denied POST returns 403" $?

# ---------------------------------------------------------------- 6. delete rule -> prompts again
curl -s -X DELETE $API/rules/$RULE | jq -e .deleted >/dev/null; check "rule can be deleted via API" $?
bg_curl $T/g.out https://example.com/
ID=$(wait_pending https://example.com/); check "after revoke, same URL prompts again" $?
decide "$ID" deny; wait $BGPID

# ---------------------------------------------------------------- 7. other clients through proxy
clear_rules
bg_curl $T/h.out https://example.org/
ID=$(wait_pending https://example.org/); decide "$ID" always_allow; wait $BGPID
sb python3 -c "import requests; r=requests.get('https://example.org/',timeout=20); print(r.status_code, 'Example Domain' in r.text)" >$T/py.out 2>&1
[ "$(cat $T/py.out)" = "200 True" ]; check "python requests works through proxy with CA trusted" $? "$(cat $T/py.out)"
sb node -e "fetch('https://example.org/').then(async r=>console.log(r.status,(await r.text()).includes('Example Domain'))).catch(e=>{console.log('ERR',e.cause||e);process.exit(1)})" >$T/node.out 2>&1
[ "$(cat $T/node.out)" = "200 true" ]; check "node fetch works through proxy with CA trusted" $? "$(cat $T/node.out)"
sb sh -c 'curl -sv https://example.org/ -o /dev/null 2>&1 | grep -i "issuer"' | grep -qi mitmproxy
check "TLS is actually intercepted (cert issuer is the mitmproxy CA)" $?

# ---------------------------------------------------------------- 8. no route for proxy-ignoring clients
sb curl -sS -m 8 --noproxy '*' -o /dev/null https://example.com/ >$T/n1.out 2>&1; rc=$?
[ $rc -ne 0 ]; check "curl --noproxy to example.com FAILS (exit $rc)" $? "$(cat $T/n1.out)"
sb curl -sS -m 8 --noproxy '*' -o /dev/null https://1.1.1.1/ >$T/n2.out 2>&1; rc=$?
[ $rc -ne 0 ]; check "curl --noproxy to 1.1.1.1 FAILS (exit $rc)" $? "$(cat $T/n2.out)"
sb python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(5)
try: s.connect(('1.1.1.1',443)); print('CONNECTED'); sys.exit(1)
except OSError as e: print('failed:',e); sys.exit(0)" >$T/sock.out 2>&1
check "raw python socket to 1.1.1.1:443 FAILS ($(cat $T/sock.out))" $?

# ---------------------------------------------------------------- 9. approval API unreachable from sandbox
for target in proxy 172.30.9.2; do
  sb curl -sS -m 5 --noproxy '*' http://$target:8081/approvals >$T/ap.out 2>&1; rc=$?
  [ $rc -ne 0 ]; check "sandbox -> http://$target:8081 direct: unreachable (curl exit $rc)" $?
done
sb curl -sS -m 10 http://172.30.9.2:8081/approvals -o /dev/null -w '%{http_code}' >$T/ap2.out 2>&1
[ "$(tail -c3 $T/ap2.out)" = 403 ] && [ "$(pending_count)" = 0 ]
check "sandbox -> approval API VIA the proxy: hard-blocked 403, no prompt created" $?
sb curl -sS -m 10 -X POST http://localhost:8081/ -o /dev/null -w '%{http_code}' >$T/ap3.out 2>&1
[ "$(tail -c3 $T/ap3.out)" = 403 ]; check "proxy refuses 'localhost' targets (SSRF guard)" $?
sb curl -sS -m 10 -p -x http://proxy:8080 https://172.30.9.2:8081/ -o /dev/null -w '%{http_code}' >$T/ap4.out 2>&1; rc=$?
[ $rc -ne 0 ] || [ "$(tail -c3 $T/ap4.out)" = 403 ]; check "CONNECT to non-80/443 port refused" $?

# ---------------------------------------------------------------- 10. decision log
docker compose exec -T proxy cat /data/decisions.jsonl >$T/log.jsonl
jq -e -s 'length>5 and all(.[]; has("time") and has("method") and has("url") and has("decision") and has("source"))' $T/log.jsonl >/dev/null
check "decisions.jsonl: every line is JSON with time/method/url/decision/source" $?
for want in 'user:allow_once' 'user:deny' 'timeout' 'guard' 'rule:'; do
  grep -q "\"source\": \"$want" $T/log.jsonl || grep -q "\"source\":\"$want" $T/log.jsonl
  check "log contains source '$want'" $?
done

# ---------------------------------------------------------------- info
echo
echo "INFO  sandbox DNS for an external name: $(sb getent hosts example.com 2>&1 | head -1 || true) (empty = no resolution)"
echo
echo "RESULT: $PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ]
