# amaranta-shop-api-gateway

> Single entry point: routing, the credential filter, rate limiting and CORS

Part of the **Amaranta Shop** distributed system — team `amaranta-shop`, Grupo 2.
Governance and documentation live in [`amaranta-shop-docs`](https://github.com/code-corhuila/amaranta-shop-docs).

## Branching

Three permanent branches. **None of them accepts a direct commit** — you enter through a child
branch and leave through a Pull Request.

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/...  hotfix/...
```

Promotion happens **by re-application** (`git cherry-pick -x`), never by merging one permanent
branch into another: `merge develop -> qa` and `merge qa -> main` do not exist in this model.

`main` requires **1 approval from `ariel5253`**. On `develop` and `qa` the team sets its own review
rule.

Full policy: `00-governance/branching-policy.md` in `amaranta-shop-docs`.

## Role in the system

The only service that publishes a port to the host (`8000`). Every other service is reachable through it, or not at
all. It is **configuration, not code** (Annex F): nginx with the files of `nginx/`, nothing built and nothing installed.

| It does | It never does |
|---|---|
| Route `/api/v1/...` to the service that owns the path | Business rules |
| Refuse a protected request that carries **no** `Authorization` header | Read, verify or store a token: each service validates its own |
| Rate limit and CORS | Keep state, a database or a secret |
| Reuse or create `X-Correlation-Id`, pass it on, return it, log it | Publish the `/internal` routes of a service |
| Answer **its own** errors with the common envelope | |

## Routes

| Path | Target | Credential |
|---|---|---|
| `GET /health` | the gateway itself | none |
| `POST /api/v1/orders` | `sales-api:8080` | **none** (a visitor buys without an account; the service still validates a token if one is sent) |
| `GET /api/v1/orders` and everything under `/api/v1/orders/` | `sales-api:8080` | required |
| `GET /api/v1/products`, `GET /api/v1/products/{id}` | `catalog-api:8082` | none |
| `/api/v1/admin/products` and everything under it | `catalog-api:8082` | required (the service checks `ADMIN`) |
| `/api/v1/sagas/...` | `workflow:8083` | required |
| anything else, including every `/internal/...` | — | `404` with the envelope |

The gateway checks that the header **exists**; whether the token is valid, expired or has the right role is the
service's answer, and it passes through untouched.

### Its own errors

| Situation | Answer |
|---|---|
| Protected route without a credential | `401 {"error":"UNAUTHORIZED", ..., "traceId"}` and `WWW-Authenticate: Bearer` |
| No such route | `404 {"error":"NOT_FOUND", ...}` |
| Rate limit exceeded (100 a minute per address, burst 40) | `429 {"error":"TOO_MANY_REQUESTS", ...}` and `Retry-After` |
| The target service does not answer | `503 {"error":"SERVICE_UNAVAILABLE", ...}` |

`traceId` is the `X-Correlation-Id` the service received, so a user's complaint with that reference leads straight to
the log line. A `404` or `422` that a **service** returns is not replaced: it already uses the envelope.

## How it is organised

```
nginx/
├── nginx.conf              global settings: the JSON log format, body size, includes
├── conf.d/
│   ├── 00-resolver.conf    DNS on every request, not only at start
│   ├── 10-security.conf    CORS origins, correlation id, rate-limit zone, credential filter
│   └── 20-server.conf      the server: its own errors, the preflight, the 404, the routes
├── snippets/
│   ├── headers.conf        the headers every response carries
│   └── require-credential.conf   one line a protected route includes
└── routes/                 ONE FILE PER DOMAIN: _health, orders, catalog, workflow
```

- **One reason to change per file.** A new origin is a line in `10-security.conf`; a new domain is one new file in
  `routes/`; nothing else moves.
- **The policy is written once and used everywhere.** A route file never decides CORS, a limit or the shape of an
  error: it names its paths and includes the snippet. That is why a new domain cannot forget a header.
- **Every target is a variable** (`set $catalog_api http://catalog-api:8082; proxy_pass $catalog_api;`). nginx resolves
  a name once, at start, only when it is fixed. With a variable it resolves on every request, so a service that is
  down makes **its own routes** answer `503` while every other route keeps working, and the gateway always starts.
- **Every location is an exact path or a prefix that ends in `/`**, so `/api/v1/productsx` matches nothing.

### Logs, traces, metrics

| Pillar | State |
|---|---|
| **Logs** | One JSON line per request on stdout: time, `correlationId`, method, path, status, upstream, duration. Never a body, never a token. |
| **Traces** | `X-Correlation-Id` is reused (if it is a plain id) or created, sent to the service, returned to the client and used as `traceId`. It follows one request across services; there are no spans. |
| **Metrics** | **Not yet.** The log lines can be counted, but nothing exposes counters to Prometheus. |

### Two things worth knowing

- **The rate limit does not count a bare `return`.** nginx runs `return` before the limit, so the `401`, the preflight
  and the health probe are not counted. Proxied requests and unknown paths are. The limit protects the services, and
  those answers never reach one.
- **Docker reuses the address of a container that just left**, and the limit is keyed by address, so the tests restart
  the gateway before each phase.

## How to run

You need only Docker. The platform network is created once:

```bash
docker network create platform
```

```bash
docker compose -f deploy/compose.yml up -d --build
```

```bash
curl -i http://localhost:8000/health
```

Without a service behind it, a protected route answers `401` and a public one answers `503`; both are the envelope:

```bash
curl -i http://localhost:8000/api/v1/orders
```

## How it is checked

```bash
bash scripts/test.sh
```

It builds the image, runs `nginx -t`, and then runs two suites in containers, with nothing installed:

- `tests/smoke.sh` — the gateway on its own: health, `404`, the correlation id, security headers, CORS, the preflight
  and the `429`.
- `tests/routing.sh` — the gateway with a **stub** per service (`tests/stub/`) that echoes what it received. It proves
  what is routed where, what needs a credential, that the token, `Idempotency-Key`, correlation id and query string
  arrive intact, that `/internal` is unreachable (even by `../`, `%2e%2e` and `%2f`), that a service's own errors pass
  through, and that with one service stopped only its own routes answer `503`.

The same script runs in CI on every pull request (`.github/workflows/ci.yml`).

## Adding a domain

1. Create `nginx/routes/<domain>.conf` with its `location`s: an exact path and a `^~ /path/` prefix, a variable for the
   target, and `include /etc/nginx/snippets/require-credential.conf;` where a credential is required.
2. Add a stub in `tests/routing.sh` and a phase in `tests/routing-checks.sh` **first**, watch it fail, then add the route.
3. Run `bash scripts/test.sh`.

## Status

Routes for `sales-api`, `catalog-api` and the `workflow` are in place and verified against stubs. The workflow's port
(`8083`) is a choice made here, to be confirmed when that service defines its own. Not done: metrics, and a run against
the real services (that is `scripts/e2e-with-catalog.sh` in `amaranta-shop-sales-api`, plus the gateway in front).
