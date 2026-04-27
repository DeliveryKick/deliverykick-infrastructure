# Cross-Repo Deployment Order

> When a feature touches more than one repo, the order of deploys matters.
> Out-of-order pushes cause silent breakage (e.g. DK requesting a field before
> the backend exposes it, or the backend dropping a field DK still reads).
> This runbook is the lookup table.

**Audience:** anyone pushing code that touches more than one of the four
DeliveryKick repos. Written so a developer who joined yesterday can follow it
without backfilling tribal knowledge.

**Companion docs:**
- [`.planning/cross-repo-integration-audit-2026-04-26.md`](https://github.com/DeliveryKick/Restaurant-Repository-Backend/blob/main/.planning/cross-repo-integration-audit-2026-04-26.md) in Restaurant-Backend — the topology this assumes.
- Skill: `dk-cross-repo-feature` — propagation checklist with file-level pointers.
- Skill: `dk-cross-repo-drift` — detection (run after to confirm nothing slipped).

---

## The four repos and what each owns

| Repo | Role | Deploy target | Push-to-deploy branch |
|---|---|---|---|
| `Restaurant-Repository-Backend` | Schema owner, scrapers, ES, image enrichment | AWS ECS | `main` (currently active branch: `feat/scraper-cutover-new-schema`) |
| `Ordering-Delivery-and-Payment-Backend` | Orders, payments, Stripe, accounts | AWS ECS | `main` |
| `DK` (Next.js) | Frontend — search-v2, web-v2, mobile-v2 | AWS Amplify / Vercel | `main` |
| `UberScraper` | Raw-SQL writer into shared schema | AWS Batch worker | `main` |

`deliverykick-infrastructure` (this repo) holds the Terraform, IAM, nginx — it
deploys infrastructure, not application code, so it isn't in the chain below.

---

## Deploy order by change type

Pick the row that matches what you're shipping. Follow top to bottom.

### A. Adding a new field on `NewRestaurant` / `RestaurantService` / `Brand` / `MenuItem`

**Example:** adding `accepting_orders_until` (datetime) on `NewRestaurant`.

| # | Step | Where | Notes |
|---|---|---|---|
| 1 | Land migration + serializer change | Restaurant-Backend | Field MUST be nullable or have a default. No NOT-NULL on a 850k-row table without a backfill plan. See `django-migration-safety` skill. |
| 2 | Verify deploy | Restaurant-Backend ECS | `curl https://<backend>/api/schema/?format=json | jq '.paths' | grep <field>` — field appears in OpenAPI schema. `X-Backend-Schema-Version` header bumps automatically. |
| 3 | Run backfill if needed | Restaurant-Backend mgmt command | After backfill, the backfill command itself enqueues reindex via `enqueue_restaurant_reindex` (see `dk-elasticsearch-sync` skill). For external writers (UberScraper), POST to `/api/v2/internal/reindex/`. |
| 4 | Update `RestaurantAPIClient._coerce_restaurant_types` if the field needs type coercion | Ordering-Backend | `Decimal` / `datetime` / etc. need explicit handling — strings pass through fine. |
| 5 | Update `_normalize_restaurant` if Ordering re-exposes the field to DK | Ordering-Backend | `orders/utils/restaurant_service.py:_normalize_restaurant` |
| 6 | Deploy | Ordering ECS | After ECS deploys, hit `/api/orders/get_menu/` with a known restaurant — confirm new field surfaces in response. |
| 7 | Regenerate DK types | DK | `cd ~/DK/deliverykick-search-v2 && bun gen:types` (against deployed backend or staging). Commit `api-schema.ts`. |
| 8 | Update DK `shared/src/types/*.ts` if anything hand-typed references the old shape | DK | Or migrate to `ApiResponse<P, M>` from `lib/api-types.ts` while you're in there. |
| 9 | Render the field in the UI | DK web-v2 / mobile-v2 / search-v2 | Whichever surfaces it. |
| 10 | Deploy DK | Amplify / Vercel | Verify in browser after the build promotes. |

**Rollback:** if (6) breaks Ordering, ECS rolls forward by deploying the previous task definition. Field stays on backend / nullable, so old Ordering still works.

### B. Removing or renaming a field

Strict two-phase. Out-of-order kills caches.

| # | Step | Where | Notes |
|---|---|---|---|
| 1 | Grep both consumer repos for the field name | Ordering + DK | Anywhere it's read needs to be planned for. |
| 2 | Phase 1 release: keep old field, expose new name in parallel | Restaurant-Backend | Add `# deprecated 2026-MM-DD — use NEW_NAME` to serializer. Both fields populated in responses. |
| 3 | Migrate Ordering to read new name | Ordering | After Restaurant-Backend Phase 1 is in prod. |
| 4 | Migrate DK to read new name | DK | After Ordering is in prod. Regenerate types. |
| 5 | Phase 2 release: drop old field + drop column | Restaurant-Backend | Migration drops the column. By now no callers reference it. Verify with `dk-cross-repo-drift` skill. |

**Never** drop a column without Phase 1 shipping first. If you do, every cached response in Ordering's Redis (TTL up to 5 min for non-menu, 30s for menu/v2) will still contain the old key for a window after the deploy — fine — but if Ordering's code reads it as required, it 500s during that window.

### C. Adding a new `/api/v2/*` endpoint

| # | Step | Where | Notes |
|---|---|---|---|
| 1 | View + URL + test | Restaurant-Backend | `ServiceKeyAuthentication` + `IsServiceAuthenticated`. Test missing/wrong/right key. |
| 2 | Add to `restaurant/v2_urls.py` with `name=` kwarg | Restaurant-Backend | so `reverse()` works in tests. |
| 3 | Deploy | Restaurant-Backend ECS | New path appears in `/api/schema/`. |
| 4 | Add a method on `RestaurantAPIClient` | Ordering-Backend | Wraps `_get` / `_post`. Cache only if read-mostly. Pricing-sensitive: `MENU_V2_CACHE_TTL` (30s). |
| 5 | Unit test in `tests/unit/test_restaurant_service.py` | Ordering | `mock_settings.RESTAURANT_API_BASE_URL = 'http://restaurant-backend:8000'` |
| 6 | Deploy | Ordering ECS | |
| 7 | Surface in DK only if user-facing | DK | Regenerate types first. |

### D. Adding a new platform / `service_name` value (toast / clover / chowly precedent)

| # | Step | Where | Notes |
|---|---|---|---|
| 1 | Scraper detection patterns | Restaurant-Backend | `restaurant/find_websites.py` + `restaurant/website_details.py`. No model change needed (`service_name` is a free-form `CharField`). |
| 2 | URL→service map fallback | Ordering-Backend | `orders/views/elastic/elastic_find_restaurant_enhanced.py` — see commit `1b55d2d` for the toast/clover/chowly precedent. |
| 3 | Order-execution router | Ordering-Backend | `orders/utils/order_execution_service.py` — add to `PLAYWRIGHT_PLATFORMS` (browser automation supported) OR `GUEST_PLATFORMS` (guest checkout supported). Pick correctly. |
| 4 | Integration API defaults + priority | Ordering-Backend | `orders/views/integration/restaurant_integration_api.py` — both `services` default and `service_priority`. |
| 5 | DK merchant onboarding catalog | DK | `~/DK/deliverykick-web/src/app/merchant/fixtures/onboarding.ts:DELIVERY_SERVICES` |
| 6 | DK display path | DK | No change — components read `service_name` as free-form string. |

After deploy, run `dk-cross-repo-drift` skill's Check 2. It'll grep all five sites and confirm no new `service_name` was missed.

### E. UberScraper changes (raw-SQL writes to shared schema)

UberScraper is the highest-risk repo because writes bypass Django signals and the ES reindex queue.

| # | Step | Where | Notes |
|---|---|---|---|
| 1 | Make the change | UberScraper | Whatever scraper / ingestion logic. |
| 2 | After every batch commit, POST to internal reindex | UberScraper | `requests.post(f"{RESTAURANT_API_BASE_URL}/api/v2/internal/reindex/", json={"restaurant_ids": [...]}, headers={"X-Service-Key": SERVICE_API_KEY_UBERSCRAPER})` |
| 3 | Use the per-caller key | UberScraper | `SERVICE_API_KEY_UBERSCRAPER` env var (per-caller rotation). The legacy `SERVICE_API_KEY` is also accepted but should be migrated off. |
| 4 | Deploy UberScraper | AWS Batch task definition | New job def revision. |

Without step (2), Postgres has the new data and Elasticsearch silently drifts. Run `dk-cross-repo-drift` Check 5 after to confirm no missed reindexes.

---

## Schema-affecting deploy: pre-flight checklist

Before pushing Restaurant-Backend `main` with a migration, walk through:

- [ ] Is the field nullable or defaulted? (Migration safety — 850k rows.)
- [ ] Is the migration reversible? (`makemigrations --check` clean.)
- [ ] Have you decorated the new endpoint with `@extend_schema(...)` if shape matters? (Path inventory works without; field shapes need decorators.)
- [ ] Is the change captured in `dk-cross-repo-feature` skill's Section A checklist?
- [ ] Have you grepped Ordering + DK for old field name (if removing/renaming)?
- [ ] Have you flagged the change in any in-flight `260427-XX` cluster tag?

---

## Tag convention for cross-repo work

Use a date+letter cluster tag in commit messages when work spans more than one repo:

```
feat(260427-00c): close guest-checkout address gap (place_id + dict)        # Ordering
feat(web-v2/260427-00c): guest-aware AddressPicker — send {place_id} for anon # DK
```

The recipe: `<date YYMMDD>-<sequential-letter>`. `git log --grep=260427-00c` across all four repos shows the cluster.

This isn't enforced anywhere — it's a courtesy to future-you and to anyone reviewing the deploy chain.

---

## Rollback paths

| Repo | Mechanism |
|---|---|
| Restaurant-Backend | ECS task definition rollback (last-known-good revision). Migrations are NOT auto-reversed; if migration was destructive (Phase 2 column drop), restore from RDS snapshot. |
| Ordering-Backend | ECS task definition rollback. Stateless except for Stripe webhook idempotency keys (in DB). |
| DK | Vercel/Amplify previous deployment promotion. |
| UberScraper | Previous AWS Batch job-def revision. |

If a partial deploy is in flight (backend deployed, Ordering not yet), the system stays correct because backend changes are backwards-compatible by design (per the field-add rule above). If a removal Phase 2 deployed before Ordering migrated, that's the breaking case — restore Phase 1 backend until Ordering catches up.

---

## Verification per deploy

Always after a deploy:

1. **Restaurant-Backend** — `curl https://<backend>/api/schema/?format=json | jq '.info.version'` should bump if a migration ran. `X-Backend-Schema-Version` response header shows the same. `/health/ready/` returns 200.
2. **Ordering-Backend** — `/health/` returns 200. Sentry releases page shows the new release tag (set via `SENTRY_RELEASE` env var at build time).
3. **DK** — Build succeeds; deployed URL returns 200. If types regenerated this deploy, check the diff in `api-schema.ts` matches the backend change you intended.
4. **Cross-repo** — run the `dk-cross-repo-drift` skill weekly OR after any non-trivial multi-repo cluster. The 5 checks catch the silent-drift class of failure.

---

## Open questions to resolve

- [ ] Where does staging live? Today there's no shared staging; integration tests run against local docker compose or against prod (terrible). Audit §8.5 — pending.
- [ ] What triggers the schema-aware DK type regeneration in CI? Today: manual `bun gen:types`. Better: a CI step that fetches the backend schema and fails if `api-schema.ts` is stale.
- [ ] Should `repository_dispatch` events fire from each repo's `main`-push CI to a central integration workflow? Useful when staging exists.
