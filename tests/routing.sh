#!/usr/bin/env bash
# The gateway with a stub for each service behind it (tests/stub/): what is routed where, what needs a credential, what
# the service receives, and what happens when a service is down. Called by scripts/test.sh, which owns the network and the
# gateway container and passes them in: GW_NAME, NET, TEST_ID, HERE. Every container started here carries the label
# gateway-test=$TEST_ID, so test.sh removes them all when it ends.
set -euo pipefail
docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }

stub() {  # name, network alias (what the gateway resolves), port
  docker run -d --name "stub-$1-$TEST_ID" --label "gateway-test=$TEST_ID" --network "$NET" --network-alias "$2" \
    -e STUB_NAME="$1" -e STUB_PORT="$3" \
    -v "$HERE/tests/stub/stub.conf.template:/etc/nginx/templates/default.conf.template:ro" nginx:1.27-alpine > /dev/null
}
curl_in_network() { docker run --rm --network "$NET" -v "$HERE/tests:/tests:ro" --entrypoint sh curlimages/curl:latest "$@"; }

# The rate limit lives in the gateway's memory and is keyed by the client's address, and Docker hands a container the
# address of the one that just left. A restart empties it, so no phase inherits the bucket another one used up (smoke.sh
# empties its own on purpose).
fresh_gateway() {
  docker restart "$GW_NAME" > /dev/null
  for _ in $(seq 1 30); do curl_in_network -c 'curl -sf http://gateway:8000/health > /dev/null' && return 0; sleep 1; done
  echo "the gateway did not come back"; return 1
}

stub sales sales-api 8080
stub catalog catalog-api 8082
stub workflow workflow 8083

for _ in $(seq 1 30); do curl_in_network -c 'curl -sf http://sales-api:8080/ > /dev/null && curl -sf http://catalog-api:8082/ > /dev/null && curl -sf http://workflow:8083/ > /dev/null' && break; sleep 1; done

# Each phase runs in its own container against a freshly started gateway. The failures go one service at a time, so the
# later phases prove that a stopped service takes down only its own routes.
check_phase() { fresh_gateway && curl_in_network /tests/routing-checks.sh http://gateway:8000 "$1"; }

check_phase sales
check_phase catalog
check_phase workflow

docker stop -t 0 "stub-sales-$TEST_ID" > /dev/null
check_phase sales-down

docker stop -t 0 "stub-catalog-$TEST_ID" > /dev/null
check_phase catalog-down

docker stop -t 0 "stub-workflow-$TEST_ID" > /dev/null
check_phase workflow-down
