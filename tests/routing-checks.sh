#!/usr/bin/env sh
# The routing checks, run INSIDE the test network (by tests/routing.sh), against the gateway with a stub for each service.
# Usage: sh tests/routing-checks.sh http://gateway:8000 up|down
set -u
BASE="${1:-http://gateway:8000}"
PHASE="${2:-up}"
ORIGIN='Origin: http://localhost:3000'
BEARER='Authorization: Bearer abc.def.ghi'
fail=0

check() {  # description, expected status, curl arguments...
  desc="$1"; want="$2"; shift 2
  got=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "$@")
  if [ "$got" = "$want" ]; then echo "  ok    $desc ($got)"; else echo "  FAIL  $desc: want $want, got $got"; fail=1; fi
}

contains() {  # description, expected text, curl arguments...
  desc="$1"; want="$2"; shift 2
  if curl -s -i --max-time 15 "$@" | grep -qi -- "$want"; then echo "  ok    $desc"; else echo "  FAIL  $desc: missing $want"; fail=1; fi
}

absent() {  # description, forbidden text, curl arguments...
  desc="$1"; bad="$2"; shift 2
  if curl -s -i --max-time 15 "$@" | grep -qi -- "$bad"; then echo "  FAIL  $desc: found $bad"; fail=1; else echo "  ok    $desc"; fi
}

if [ "$PHASE" = "up" ]; then
  echo "orders -> sales-api"
  contains "a visitor with no token can place an order"        '"service":"sales"' -X POST "$BASE/api/v1/orders"
  check    "listing my orders needs a credential"              401 "$BASE/api/v1/orders"
  contains "...and answers with the envelope"                  '"error":"UNAUTHORIZED"' "$BASE/api/v1/orders"
  contains "...with a traceId"                                 '"traceId":"' "$BASE/api/v1/orders"
  contains "...and says how to authenticate"                   'WWW-Authenticate: Bearer' "$BASE/api/v1/orders"
  contains "...and the browser may read it (CORS)"             'Access-Control-Allow-Origin: http://localhost:3000' -H "$ORIGIN" "$BASE/api/v1/orders"
  contains "a listing with a credential reaches the service"   '"service":"sales"' -H "$BEARER" "$BASE/api/v1/orders"
  contains "the credential arrives untouched"                  '"authorization":"Bearer abc.def.ghi"' -H "$BEARER" "$BASE/api/v1/orders"
  contains "a broken token is the service's to refuse"         '"service":"sales"' -X POST -H 'Authorization: Bearer not-a-token' "$BASE/api/v1/orders"
  check    "an in-store order needs a credential"              401 -X POST "$BASE/api/v1/orders/in-store"
  contains "...and reaches the service with one"               '"uri":"/api/v1/orders/in-store"' -X POST -H "$BEARER" "$BASE/api/v1/orders/in-store"
  check    "marking an order paid needs a credential"          401 -X POST "$BASE/api/v1/orders/7f3a/mark-paid"
  contains "...and reaches the service with one"               '"uri":"/api/v1/orders/7f3a/mark-paid"' -X POST -H "$BEARER" "$BASE/api/v1/orders/7f3a/mark-paid"
  contains "the query string is kept"                          '"uri":"/api/v1/orders?page=2&limit=5"' -H "$BEARER" "$BASE/api/v1/orders?page=2&limit=5"
  contains "the Idempotency-Key reaches the service"           '"idempotencyKey":"key-1"' -X POST -H 'Idempotency-Key: key-1' "$BASE/api/v1/orders"
  contains "the correlation id reaches the service"            '"correlationId":"route-1"' -H 'X-Correlation-Id: route-1' -H "$BEARER" "$BASE/api/v1/orders"
  contains "a generated correlation id reaches it too"         '"correlationId":"[0-9a-f]\{32\}"' -H "$BEARER" "$BASE/api/v1/orders"
  check    "a rule of the business passes through untouched"   422 -X POST -H "$BEARER" "$BASE/api/v1/orders/force-422/mark-paid"
  contains "...with the service's own body"                    '"error":"BUSINESS_RULE"' -X POST -H "$BEARER" "$BASE/api/v1/orders/force-422/mark-paid"
  check    "a 404 of the service passes through untouched"     404 -X POST -H "$BEARER" "$BASE/api/v1/orders/force-404/mark-paid"
  contains "...with the service's own body, not the gateway's" '"error":"ORDER_NOT_FOUND"' -X POST -H "$BEARER" "$BASE/api/v1/orders/force-404/mark-paid"
  check    "a preflight needs no credential"                 204 -X OPTIONS -H "$ORIGIN" -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: idempotency-key' "$BASE/api/v1/orders"
  check    "a path that only starts like orders is not routed" 404 -H "$BEARER" "$BASE/api/v1/orders-archive"
fi

if [ "$PHASE" = "down" ]; then
  echo "a service is down"
  check    "its route answers 503"                             503 -X POST "$BASE/api/v1/orders"
  contains "...with the envelope"                              '"error":"SERVICE_UNAVAILABLE"' -X POST "$BASE/api/v1/orders"
  contains "...and a traceId"                                  '"traceId":"' -X POST "$BASE/api/v1/orders"
  contains "...and the browser may read it (CORS)"             'Access-Control-Allow-Origin: http://localhost:3000' -X POST -H "$ORIGIN" "$BASE/api/v1/orders"
  contains "...and the correlation id is returned"             'X-Correlation-Id: down-1' -X POST -H 'X-Correlation-Id: down-1' "$BASE/api/v1/orders"
  check    "the gateway itself stays healthy"                  200 "$BASE/health"
fi

exit $fail
