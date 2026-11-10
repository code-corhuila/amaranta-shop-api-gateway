#!/usr/bin/env bash
# Everything the gateway must pass, with Docker only (nothing is installed):
#
#   bash scripts/test.sh
#
# 1. the configuration is valid (nginx -t); 2. tests/smoke.sh against the gateway on its own; 3. tests/routing.sh against the
# gateway with a stub for each service behind it, when that file exists. It is the same script the pull request runs.
set -euo pipefail
cd "$(dirname "$0")/.."
# Git Bash on Windows must not rewrite the container paths given to docker.
docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }
HERE="$(pwd -W 2> /dev/null || pwd)"

ID=$$
NET="gateway-test-net-$ID"
GW="gateway-test-$ID"
cleanup() { docker rm -f "$GW" $(docker ps -aq --filter "label=gateway-test=$ID") > /dev/null 2>&1 || true; docker network rm "$NET" > /dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== the image builds and the configuration is valid"
docker build -q -f deploy/Dockerfile -t gateway:test . > /dev/null
docker run --rm gateway:test nginx -t 2>&1 | grep -E "successful|emerg|error"

docker network create "$NET" > /dev/null
docker run -d --name "$GW" --network "$NET" --network-alias gateway gateway:test > /dev/null
curl_in_network() { docker run --rm --network "$NET" -v "$HERE/tests:/tests:ro" --entrypoint sh curlimages/curl:latest "$@"; }
for _ in $(seq 1 30); do curl_in_network -c 'curl -sf http://gateway:8000/health > /dev/null' && break; sleep 1; done

echo "== tests/smoke.sh: the gateway on its own"
curl_in_network /tests/smoke.sh http://gateway:8000

if [ -f tests/routing.sh ]; then
  echo "== tests/routing.sh: the gateway with a stub for each service"
  GW_NAME="$GW" NET="$NET" TEST_ID="$ID" HERE="$HERE" bash tests/routing.sh
fi
echo "OK: the gateway passes every check"
