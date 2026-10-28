#!/bin/sh
# run inside hermes container. Each probe: GET https://example.com/ through the proxy under a given env.
PY=/opt/hermes/.venv/bin/python
probe() { # label, envprefix..., then cmd
  label=$1; shift
  out=$("$@" 2>&1 | tail -1 | cut -c1-160); echo "$label => $out"
}
BASE="env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE -u NODE_EXTRA_CA_CERTS"
REQ='import requests;r=requests.get("https://example.com/",timeout=40);print("OK",r.status_code,len(r.text))'
HTX='import httpx;r=httpx.get("https://example.com/",timeout=40);print("OK",r.status_code,len(r.text))'
OAI='import openai;c=openai.OpenAI(api_key="x",base_url="https://llm.mock.test/v1",timeout=40);print("OK",[m.id for m in c.models.list()])'
NODE='fetch("https://example.com/").then(r=>console.log("OK",r.status)).catch(e=>console.log("ERR",e.cause&&e.cause.code||e.message))'
NODEHTTPS='const https=require("https");const {HttpsProxyAgent}=0;https.get("https://example.com/",(r)=>console.log("OK",r.statusCode)).on("error",e=>console.log("ERR",e.code))'
for tag in "A_no_CA_env" "B_SSL_CERT_FILE_only" "C_REQUESTS_CA_BUNDLE_only" "D_both"; do
  case $tag in
    A*) E="$BASE";; B*) E="$BASE SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt";;
    C*) E="$BASE REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt";;
    D*) E="$BASE SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt";;
  esac
  echo "--- $tag (system store has CA: $(grep -c mitmproxy /etc/ssl/certs/ca-certificates.crt 2>/dev/null; ls /usr/local/share/ca-certificates | tr '\n' ' '))"
  probe "python requests" $E $PY -c "$REQ"
  probe "python httpx   " $E $PY -c "$HTX"
  probe "python openai  " $E $PY -c "$OAI"
done
echo "--- node"
probe "node fetch, no NODE_EXTRA_CA_CERTS, NODE_USE_ENV_PROXY unset" $BASE node -e "$NODE"
probe "node fetch, NODE_USE_ENV_PROXY=1, no CA" $BASE NODE_USE_ENV_PROXY=1 node -e "$NODE"
probe "node fetch, NODE_USE_ENV_PROXY=1 + NODE_EXTRA_CA_CERTS" $BASE NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/ca-public/mitmproxy-ca-cert.pem node -e "$NODE"
node --version
