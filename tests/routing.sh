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

# smoke.sh emptied its client's rate-limit bucket on purpose; a restart gives these checks a gateway with a fresh one.
docker restart "$GW_NAME" > /dev/null
for _ in $(seq 1 30); do curl_in_network -c 'curl -sf http://gateway:8000/health > /dev/null' && break; sleep 1; done

stub sales sales-api 8080

for _ in $(seq 1 30); do curl_in_network -c 'curl -sf http://sales-api:8080/ > /dev/null' && break; sleep 1; done

curl_in_network /tests/routing-checks.sh http://gateway:8000 up

docker stop -t 0 "stub-sales-$TEST_ID" > /dev/null
curl_in_network /tests/routing-checks.sh http://gateway:8000 down
