#!/usr/bin/env sh
# The checks the gateway must pass on its own, with no service behind it (Annex F, "Como se verifica").
# Usage: sh tests/smoke.sh http://localhost:8000
set -u
BASE="${1:-http://localhost:8000}"
fail=0

check() {  # description, expected status, curl arguments...
  desc="$1"; want="$2"; shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$got" = "$want" ]; then echo "  ok    $desc ($got)"; else echo "  FAIL  $desc: want $want, got $got"; fail=1; fi
}

contains() {  # description, expected text, curl arguments...
  desc="$1"; want="$2"; shift 2
  if curl -s -i "$@" | grep -qi -- "$want"; then echo "  ok    $desc"; else echo "  FAIL  $desc: missing $want"; fail=1; fi
}

absent() {  # description, forbidden text, curl arguments...
  desc="$1"; bad="$2"; shift 2
  if curl -s -i "$@" | grep -qi -- "$bad"; then echo "  FAIL  $desc: found $bad"; fail=1; else echo "  ok    $desc"; fi
}

echo "the gateway on its own"
check    "health answers"                                  200 "$BASE/health"
contains "health says ok"                                  '"status":"ok"' "$BASE/health"
check    "an unknown route is 404"                         404 "$BASE/nope"
contains "the 404 uses the error envelope"                 '"error":"NOT_FOUND"' "$BASE/nope"
contains "the envelope carries a traceId"                  '"traceId":"' "$BASE/nope"
check    "the internal routes of the services are not routed" 404 -X POST "$BASE/internal/products/reserve-stock"
check    "nor under the public prefix"                     404 -X POST "$BASE/api/v1/internal/products/reserve-stock"

echo "correlation (norm 5.3.9)"
contains "a correlation id is generated"                   'X-Correlation-Id: [0-9a-f]\{32\}' "$BASE/health"
contains "the client's correlation id is kept"             'X-Correlation-Id: smoke-1' -H 'X-Correlation-Id: smoke-1' "$BASE/health"
contains "...and is the traceId of the envelope"           '"traceId":"smoke-2"' -H 'X-Correlation-Id: smoke-2' "$BASE/nope"
absent   "an id with forbidden characters is not echoed"   'smoke<script>' -H 'X-Correlation-Id: smoke<script>' "$BASE/health"
absent   "an absurdly long id is not echoed"               "$(printf 'x%.0s' $(seq 1 200))" -H "X-Correlation-Id: $(printf 'x%.0s' $(seq 1 200))" "$BASE/health"

echo "headers and CORS (Annex F)"
contains "responses are not sniffed"                       'X-Content-Type-Options: nosniff' "$BASE/health"
contains "responses cannot be framed"                      'X-Frame-Options: DENY' "$BASE/health"
contains "a known origin gets its CORS grant"              'Access-Control-Allow-Origin: http://localhost:3000' -H 'Origin: http://localhost:3000' "$BASE/health"
contains "CORS exposes X-Correlation-Id and Location"      'Access-Control-Expose-Headers: X-Correlation-Id, Location' -H 'Origin: http://localhost:3000' "$BASE/health"
contains "CORS allows Idempotency-Key"                     'Access-Control-Allow-Headers: .*Idempotency-Key' -H 'Origin: http://localhost:3000' "$BASE/health"
absent   "an unknown origin gets no CORS grant"            'Access-Control-Allow-Origin: http' -H 'Origin: http://evil.example' "$BASE/health"
absent   "the server does not say which nginx it is"       'nginx/' "$BASE/health"

exit $fail
