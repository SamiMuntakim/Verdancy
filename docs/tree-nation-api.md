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
- **`species_id` IS IGNORED on `POST /api/plant`** — verified against the live API 2026-08-13 (see below). Do not build cost control on it.

---

## `species_id` is ignored — verified

A live call pinning `species_id: 1342` planted **3658 (Rhizophora mucronata)** instead:

```jsonc
// request:  {"recipients":[{"internal_id":"verdancy-config-test"}],"quantity":1,"species_id":1342,"language":"en"}
// response: "species_id": 3658, "species_name": "Rhizophora mucronata", "project_id": 269
```

Species 1342 had gone to `stock: 0`, and Tree-Nation substituted an in-stock species from the account's project. **Tree-Nation chooses the species; we cannot.**

Consequences for the integration:

1. Pricing a single pinned species is meaningless — it may not be the one planted.
2. Requiring the pinned species to be in stock would **block all planting** (1342 is at 0).
3. Cost control must bound the **worst case across every species the API could pick**.

## Species pricing — the worst-case model

**Prices differ per PROJECT.** The account plants from **project 269** ("Replanting the burnt Mkussu Forest", Tanzania). Project 3, by contrast, has a €2 floor — always price against the project actually in use.

### Project 269 — in stock as of 2026-08-13 (9 of 31 species)

| price     | stock   | name                                     |
| --------- | ------- | ---------------------------------------- |
| **€0.50** | 74,142  | Ocotea usambarensis ← **the worst case** |
| €0.35     | 49,917  | Avicennia marina                         |
| €0.35     | 124,986 | Ceriops tagal                            |
| €0.35     | 48,544  | Rhizophora mucronata                     |
| €0.35     | 49,531  | Xylocarpus granatum                      |
| €0.35     | 74,312  | Bruguiera gymnorhiza                     |
| €0.35     | 49,990  | Sonneratia alba                          |
| €0.35     | 49,970  | Lumnitzera racemosa                      |
| €0.35     | 49,745  | Heritiera littoralis                     |

Everything else in project 269 (including 1342, 1343, 2433, 2925, 2926) is **out of stock** and cannot be planted. Stock moves — re-check rather than trusting this table.

> `MAX_TREE_PRICE_EUR` must be **≥ €0.50** or planting is blocked entirely: the guard refuses when any in-stock species exceeds the cap, and Ocotea sits at €0.50.

### Cost model

Typical **€0.35**, worst case **€0.50**. At the worst case: **annual renewal = 10 trees = €5.00** · **referral = 2 trees = €1.00** (1 each side) · **streak = 1 tree / 30 real days ≈ €6/user/year**. Free users earn streak trees too, so spend scales with the whole user base — hence `DAILY_TREE_BUDGET` (30 → **≤ €15/day**).

### Spend guardrails implemented (see `src/lib/treenation.ts`, `src/lib/planting.ts`)

1. **Worst-case price guard** — before every plant, the dearest _in-stock_ species in the project must be ≤ `MAX_TREE_PRICE_EUR`. Whatever Tree-Nation then picks is within budget. Over cap / nothing in stock / malformed / unverifiable → **do not plant**. Failing means not spending, never over-spending. If they ever stock something pricier, planting halts until a human reviews it.
2. **Global daily cap** (`DAILY_TREE_BUDGET`) — bounds a runaway bug; auto-refill can't be disabled, so this is the real backstop.
3. **Claim-before-plant** — an atomic conditional milestone write decides who plants, so retries/concurrency can't double-spend; a failed plant rolls the claim back so the tree isn't silently lost.
