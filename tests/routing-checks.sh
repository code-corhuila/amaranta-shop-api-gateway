#!/usr/bin/env sh
# The routing checks, run INSIDE the test network (by tests/routing.sh), against the gateway with a stub for each service.
# Usage: sh tests/routing-checks.sh http://gateway:8000 sales|catalog|workflow|sales-down|catalog-down|workflow-down
# Each phase runs in its own container, so each has its own rate-limit bucket: one phase must not use up another's.
set -u
BASE="${1:-http://gateway:8000}"
PHASE="${2:-sales}"
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

if [ "$PHASE" = "sales" ]; then
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

if [ "$PHASE" = "catalog" ]; then
  echo "products -> catalog-api (public)"
  contains "the catalog needs no token"                        '"service":"catalog"' "$BASE/api/v1/products"
  contains "the query string is kept"                          '"uri":"/api/v1/products?page=2&limit=5"' "$BASE/api/v1/products?page=2&limit=5"
  contains "one product needs no token either"                 '"uri":"/api/v1/products/7f3a"' "$BASE/api/v1/products/7f3a"
  contains "a token on a public route arrives untouched"       '"authorization":"Bearer abc.def.ghi"' -H "$BEARER" "$BASE/api/v1/products"
  contains "the correlation id reaches the service"            '"correlationId":"route-2"' -H 'X-Correlation-Id: route-2' "$BASE/api/v1/products"
  check    "a 404 of the service passes through untouched"     404 "$BASE/api/v1/products/force-404"
  contains "...with the service's own body"                    '"error":"ORDER_NOT_FOUND"' "$BASE/api/v1/products/force-404"
  check    "a path that only starts like products is not routed" 404 "$BASE/api/v1/productsx"

  echo "admin products -> catalog-api (credential required)"
  check    "listing admin products needs a credential"         401 "$BASE/api/v1/admin/products"
  contains "...with the envelope"                              '"error":"UNAUTHORIZED"' "$BASE/api/v1/admin/products"
  contains "...and a credential reaches the service"           '"uri":"/api/v1/admin/products"' -H "$BEARER" "$BASE/api/v1/admin/products"
  check    "creating a product needs a credential"             401 -X POST "$BASE/api/v1/admin/products"
  check    "editing a product needs a credential"              401 -X PATCH "$BASE/api/v1/admin/products/7f3a"
  check    "setting a stock needs a credential"                401 -X PATCH "$BASE/api/v1/admin/products/7f3a/stock"
  check    "activating a product needs a credential"           401 -X POST "$BASE/api/v1/admin/products/7f3a/activate"
  check    "deleting a product needs a credential"             401 -X DELETE "$BASE/api/v1/admin/products/7f3a"
  contains "...and with one the delete reaches the service"    '"method":"DELETE"' -X DELETE -H "$BEARER" "$BASE/api/v1/admin/products/7f3a"
  check    "a path that only starts like admin products is not routed" 404 -H "$BEARER" "$BASE/api/v1/admin/productsx"
  check    "the bare admin prefix is not routed"               404 -H "$BEARER" "$BASE/api/v1/admin"

  echo "the internal routes of catalog-api are never reachable (Annex F)"
  check    "reserve-stock is not routed"                       404 -X POST -H "$BEARER" "$BASE/internal/products/reserve-stock"
  check    "release-stock is not routed"                       404 -X POST -H "$BEARER" "$BASE/internal/products/release-stock"
  check    "not under the public prefix"                       404 -X POST -H "$BEARER" "$BASE/api/v1/internal/products/reserve-stock"
  check    "not by walking out of a public path"               404 -X POST -H "$BEARER" --path-as-is "$BASE/api/v1/products/../../../internal/products/reserve-stock"
  check    "not by encoding the walk"                          404 -X POST -H "$BEARER" --path-as-is "$BASE/api/v1/products/%2e%2e/%2e%2e/%2e%2e/internal/products/reserve-stock"
  check    "not by encoding the slash"                         404 -X POST -H "$BEARER" --path-as-is "$BASE/api/v1/products/..%2f..%2f..%2finternal/products/reserve-stock"
  check    "not by walking out of the admin prefix"            404 -X POST -H "$BEARER" --path-as-is "$BASE/api/v1/admin/products/../../../internal/products/reserve-stock"
fi

if [ "$PHASE" = "workflow" ]; then
  echo "sagas -> workflow (credential required: Annex E)"
  check    "starting a saga needs a credential"                401 -X POST "$BASE/api/v1/sagas/place-order"
  contains "...with the envelope"                              '"error":"UNAUTHORIZED"' -X POST "$BASE/api/v1/sagas/place-order"
  contains "...and a credential reaches the workflow"          '"service":"workflow"' -X POST -H "$BEARER" "$BASE/api/v1/sagas/place-order"
  contains "...with the credential untouched"                  '"authorization":"Bearer abc.def.ghi"' -X POST -H "$BEARER" "$BASE/api/v1/sagas/place-order"
  contains "the Idempotency-Key reaches the workflow"          '"idempotencyKey":"saga-key-1"' -X POST -H "$BEARER" -H 'Idempotency-Key: saga-key-1' "$BASE/api/v1/sagas/place-order"
  contains "the correlation id reaches the workflow"           '"correlationId":"route-3"' -X POST -H "$BEARER" -H 'X-Correlation-Id: route-3' "$BASE/api/v1/sagas/place-order"
  check    "reading a saga needs a credential"                 401 "$BASE/api/v1/sagas/7f3a"
  contains "...and with one the saga is read"                  '"uri":"/api/v1/sagas/7f3a"' -H "$BEARER" "$BASE/api/v1/sagas/7f3a"
  check    "a saga of the workflow that is not found passes through" 404 -H "$BEARER" "$BASE/api/v1/sagas/force-404"
  contains "...with the workflow's own body"                   '"error":"ORDER_NOT_FOUND"' -H "$BEARER" "$BASE/api/v1/sagas/force-404"
  check    "the bare prefix is not routed"                     404 -H "$BEARER" "$BASE/api/v1/sagas"
  check    "a path that only starts like sagas is not routed"  404 -H "$BEARER" "$BASE/api/v1/sagasx"
fi

# A failure stays inside its own route (Annex F): the gateway resolves each service on every request, so with one
# service stopped only ITS routes answer 503 and every other route keeps working.
if [ "$PHASE" = "sales-down" ]; then
  echo "sales-api is down"
  check    "its route answers 503"                             503 -X POST "$BASE/api/v1/orders"
  contains "...with the envelope"                              '"error":"SERVICE_UNAVAILABLE"' -X POST "$BASE/api/v1/orders"
  contains "...and a traceId"                                  '"traceId":"' -X POST "$BASE/api/v1/orders"
  contains "...and the browser may read it (CORS)"             'Access-Control-Allow-Origin: http://localhost:3000' -X POST -H "$ORIGIN" "$BASE/api/v1/orders"
  contains "...and the correlation id is returned"             'X-Correlation-Id: down-1' -X POST -H 'X-Correlation-Id: down-1' "$BASE/api/v1/orders"
  check    "the catalog still answers"                         200 "$BASE/api/v1/products"
  check    "the admin catalog still answers"                   200 -H "$BEARER" "$BASE/api/v1/admin/products"
  check    "the workflow still answers"                        200 -H "$BEARER" "$BASE/api/v1/sagas/7f3a"
  check    "the gateway itself stays healthy"                  200 "$BASE/health"
fi

if [ "$PHASE" = "workflow-down" ]; then
  echo "the workflow is down too"
  check    "its route answers 503"                             503 -X POST -H "$BEARER" "$BASE/api/v1/sagas/place-order"
  contains "...with the envelope"                              '"error":"SERVICE_UNAVAILABLE"' -X POST -H "$BEARER" "$BASE/api/v1/sagas/place-order"
  check    "a missing credential is still a 401, not a 503"    401 -X POST "$BASE/api/v1/sagas/place-order"
  check    "the gateway itself stays healthy"                  200 "$BASE/health"
fi

if [ "$PHASE" = "catalog-down" ]; then
  echo "catalog-api is down too"
  check    "the public catalog answers 503"                    503 "$BASE/api/v1/products"
  contains "...with the envelope"                              '"error":"SERVICE_UNAVAILABLE"' "$BASE/api/v1/products"
  check    "the admin catalog answers 503"                     503 -H "$BEARER" "$BASE/api/v1/admin/products"
  check    "a missing credential is still a 401, not a 503"    401 "$BASE/api/v1/admin/products"
  check    "the gateway itself stays healthy"                  200 "$BASE/health"
fi

exit $fail
