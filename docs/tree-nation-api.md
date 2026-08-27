# Tree-Nation API — Reference

> Source: Tree-Nation API docs (kb.tree-nation.com + Postman collection), pasted by Sami 2026-08.
> Tree-creation (`POST /api/plant`) is captured below under "Plant / Offer trees".

---

## Model: two levels

- **Level 1 — the API user** (us / Verdancy): connects to the Tree-Nation API and holds the **tree credits**. Only the API user is invoiced.
- **Level 2 — end-users**: our app's users, who receive a **Tree-Gift** when they perform an action we choose (subscribe, hit a streak, etc.).

## Invoicing / credits

- Tree-Nation invoices **only the API user**, never the gift recipients (avoids recipient approval friction).
- The API user buys a **pack of tree credits** (e.g. €1000). Every triggered tree deducts that tree's price from the credit balance.
- **Invoices are paid by bank transfer**; billing period is adjustable.
- **Each tree creation draws from the tree credits and is limited to available credits** — i.e. when credits run out, tree creation is _capped_, not silently overcharged. (Sami has "autofill" top-up enabled, which he says cannot be disabled on the API — so our own server-side cap is the real spend guardrail.)

## Tree creation (concepts; the wire format is under "Plant / Offer trees")

- The **main function** of the API is to **trigger/create a tree**.
- On creation the API returns a **unique tree URL** = proof of planting + the tree's certificate. Passed to the end-user; lets them collect the tree and start their own forest.
- During initial config you decide whether **Tree-Nation sends the standard tree-gift email** (pass recipient name + email) or **we handle emailing** ourselves.
- Each tree links to **two forests**: the corporate/API-user forest (gifter) and the end-user forest (recipient). All trees are visible in the API-user (Verdancy) forest.

## Content endpoints (also available)

- Detailed **species** info.
- **Project** info.
- **Tree & CO2 counters** for any forest (Verdancy forest or an end-user forest).
- **Field updates** (short posts + longer articles w/ photos), requestable as: all updates / by project / by forest.

Support: support@tree-nation.com

---

## Species information

### GET species list — `{{url}}/api/projects/{projectId}/species`

Returns the species available in a project. **Only species with `stock > 0` can be used for planting.**

Fields per species:

- `id` — species id
- `project_id` — project id
- `name` — species name
- `life_time_CO2` — total CO2 compensated by the species
- `price` — price of the species (this is what's deducted from credits)
- `stock` — number of trees available to plant

Species **details** additionally include: `average_natural_life_span`, `category` {id,name}, `co2_offset`, `co2_offset_period`, `common_names`, `foliage` (deprecated) / `foliage_type` {id,name}, `height` (m), `image` (URL), `origin_type` {id,name}, `particularities`, `planter_likes`.

Example:

```bash
curl --location 'https://tree-nation.com/api/projects/3/species'
```

### GET species details — `{{url}}/api/species/{speciesId}`

```bash
curl --location 'https://tree-nation.com/api/species/727'
```

---

## Plant / Offer trees — `POST {{url}}/api/plant`

**Auth:** `Authorization: Bearer <TOKEN>` · **Header:** `Content-Type: application/json`

Body:

- `recipients` (optional) — array. Per recipient:
  - `internal_id` (optional) — the user's id in _our_ DB (use an opaque id, e.g. Cognito `sub` — **not** an email)
  - `name` (optional) — shown on the tree/certificate before collection
  - `email` (optional) — recipient email. **Put OUR account email to plant instead of gifting.** Omit to avoid Tree-Nation emailing anyone.
  - `quantity` (optional) — trees for this recipient
  - `language` (optional) — `en`|`es`|`fr`|`it` (default `en`)
  - **At least `internal_id` OR `name` is required per recipient**, else an anonymous recipient is created.
- `quantity` (top-level) — trees per trigger
- `language` — email language
- `message` (optional) — text shown under the tree when the recipient collects it
- `species_id` (optional, per KB overview) — include to pick a species (cost control, e.g. 518); omit → selected **by price**. **NOT shown in the example body — confirm it's accepted on this call before relying on it for cost control.**

Example:

```bash
curl --location 'https://tree-nation.com/api/plant' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer <TOKEN>' \
--data-raw '{
  "recipients": [ { "name": "test user", "email": "test875349@test.com" } ],
  "quantity": 1,
  "language": "en",
  "message": "thank you for planting trees at our forest!"
}'
```

Response `200 OK`:

```json
{
  "status": "ok",
  "trees": [
    {
      "id": 8693230,
      "internal_id": null,
      "token": "f0c3b76a9cab964d",
      "collect_url": "https://tree-nation.com/collect/f0c3b76a9cab964d",
      "certificate_url": "https://tree-nation.com/certificate/f0c3b76a9cab964d",
      "country": "Tanzania",
      "project_id": 269,
      "project_name": "Replanting the burnt Mkussu Forest",
      "species_id": 2924,
      "species_name": "Prunus africana",
      "species_life_time_CO2": 50
    }
  ],
  "payment_id": 5730995
}
```

### Integration-critical notes

- **No idempotency key on the API.** A double-POST = double plant = double spend. **We must dedupe BEFORE calling** — claim the grant/milestone with an atomic conditional write, and only then plant.
- **Batch with top-level `quantity`** — yearly renewal = one call with `quantity: 10`; streak = `quantity: 1`.
- **Privacy:** pass `internal_id` (opaque `sub`), **omit `email`** → no third-party email, no PII leak. User still gets `collect_url` + `certificate_url` to view in-app.
- **Store from the response:** `collect_url`, `certificate_url`, `token`, `payment_id` (per user, for the in-app reward + reconciliation).
- **The example auto-assigned project 269 / species 2924** (not project 3 / species 518). Confirm whether `species_id` on the plant body actually pins the species; if not, cost control may require Tree-Nation configuring our default project.

---

## Species pricing — what we plant and why

**Prices differ per PROJECT.** The account defaults to **project 269** ("Replanting the burnt Mkussu Forest", Tanzania), whose floor is **€0.35** — far cheaper than project 3 (floor €2). Always price a species against the project you're actually planting in.

### Project 269 — in-stock species (at capture time)

| id       | name                    | price     | stock      |
| -------- | ----------------------- | --------- | ---------- |
| **1342** | Albizia gummifera       | **€0.35** | **16,127** |
| 1343     | Markhamia lutea         | €0.35     | 14,379     |
| 2433     | Syzygium guineense      | €0.35     | 8,985      |
| 2925     | Afrocarpus usambarensis | €0.35     | 9,002      |
| 2926     | Bridelia micrantha      | €0.35     | 7,762      |
| 2086     | Ocotea usambarensis     | €0.50     | 101,322    |
| 2923     | Rauvolfia caffra        | €0.50     | 22,515     |

**We pin `species_id: 1342`** (`TREENATION_SPECIES_ID`) — cheapest tier, deepest stock. The other €0.35 ids are the fallback list if it ever stocks out.

> Species 2924 (Prunus africana) from the docs' example response is now **stock 0** — it can't be planted. Project 269 also contains €0.50 species, so "select by price" (omitting `species_id`) could still pick one: always pin.

### Cost model for our planting rules

At €0.35/tree: **annual renewal = 10 trees = €3.50** · **referral = 2 trees = €0.70** (1 each side) · **streak = 1 tree / 30 real days ≈ €4.20/user/year**. Free users also earn streak trees, so spend scales with the whole user base — hence `DAILY_TREE_BUDGET`, the global circuit breaker.

### Spend guardrails implemented (see `src/lib/treenation.ts`, `src/lib/planting.ts`)

1. **Pinned species** — never "select by price".
2. **Live price+stock re-check** before every plant against `MAX_TREE_PRICE_EUR` (0.35); over cap / out of stock / unverifiable → **do not plant**. Failing means not spending, never over-spending.
3. **Global daily cap** (`DAILY_TREE_BUDGET`) — bounds a runaway bug; Tree-Nation auto-refill can't be disabled, so this is the real backstop.
4. **Claim-before-plant** — an atomic conditional milestone write decides who plants, so retries/concurrency can't double-spend; a failed plant rolls the claim back so the tree isn't silently lost.
