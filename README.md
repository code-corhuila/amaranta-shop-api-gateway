# amaranta-shop-api-gateway

> Single entry point: authentication, routing and rate limiting

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

Single entry point of the system: routing, the credential filter, rate limits and CORS (norm 4.3). No client reaches a domain service without going through it.

## Depends on

`amaranta-shop-sales-api` and `amaranta-shop-catalog-api`, as the targets of `/api/v1/orders*` and `/api/v1/products*`. It holds no secret and has no database.

## How to run

Nothing to run yet. Once the routes land, the gateway starts from its own `Dockerfile` and is checked with `curl` against its health route and one route per domain.

## Stack

nginx, from the teacher's `api-gateway-nginx` template ([ADR-012](https://github.com/code-corhuila/amaranta-shop-docs/blob/main/05-architecture/decisions/records/ADR-012-stack-of-extracted-services.md)). One public exception: `POST /api/v1/orders` accepts a request without an `Authorization` header, so a visitor can buy without an account (spec `specs/checkout.md`, DP-1). Each service still validates its own tokens.

## Status

**Skeleton.** Only the base of a code repository is here (norm 5.1); nothing in it runs yet, and this README says so
on purpose. Next pull request: `feat/gateway-routes`: the nginx configuration, one route file per domain.
