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
- ~~`species_id`~~ — **ignored on this endpoint** (verified live; see below). Tree-Nation picks the species from the account's project. We don't send it.

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

## `species_id` is honored — but only for IN-STOCK species (verified)

Two live calls, 2026-08-13:

```jsonc
// A) requested 1342, which had stock: 0
// →  planted 3658 (Rhizophora mucronata)   ← SUBSTITUTED
// B) requested 3656, which had stock: 49,917
// →  planted 3656 (Avicennia marina)       ← HONORED
```

**Stock, not the parameter, decides whether we get what we ask for.** Request an in-stock species and you get exactly it; request one at `stock: 0` and Tree-Nation silently substitutes from the project.

Consequences for the integration:

1. **Never hardcode a `species_id`** — stock runs out (1342 went from 16k to 0 within days) and a hardcoded id rots into a silent substitution.
2. **Recompute the cheapest in-stock species per plant** from the live listing. That's how we hold the €0.35 floor.
3. **Still bound the substitution**, because our pick can stock out between the listing and the plant.

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

> `MAX_TREE_PRICE_EUR` must be **≥ €0.50** or planting is blocked entirely: it bounds a _substitution_, and Ocotea (€0.50) is in stock. What we actually pay is governed by `TARGET_TREE_PRICE_EUR` (€0.35).

### Cost model

We pay **€0.35** — we choose the species and Tree-Nation honors it. €0.50 only arises if our pick stocks out mid-flight.

At €0.35: **annual renewal = 10 trees = €3.50** · **referral = 2 trees = €0.70** (1 each side) · **streak = 1 tree / 30 real days ≈ €4.20/user/year**. Free users earn streak trees too, so spend scales with the whole user base — hence `DAILY_TREE_BUDGET` (30 → **≤ €10.50/day**).

### Spend guardrails implemented (see `src/lib/treenation.ts`, `src/lib/planting.ts`)

1. **Cheapest-in-stock selection** — the species id is recomputed from live stock on every plant, never hardcoded. This is what holds the €0.35 floor.
2. **Two-threshold guard** — the species we request must be ≤ `TARGET_TREE_PRICE_EUR` (what we intend to pay) _and_ the dearest in-stock species must be ≤ `MAX_TREE_PRICE_EUR` (what a substitution could cost). Either exceeded, nothing in stock, malformed, or unverifiable → **do not plant**. Failing means not spending, never over-spending.
3. **Substitution detection** — the response is compared against what we asked for; a mismatch logs loudly and drops the cached listing, so the next plant re-reads live stock instead of repeating a doomed request.
4. **Global daily cap** (`DAILY_TREE_BUDGET`) — bounds a runaway bug; auto-refill can't be disabled, so this is the real backstop.
5. **Claim-before-plant** — an atomic conditional milestone write decides who plants, so retries/concurrency can't double-spend; a failed plant rolls the claim back so the tree isn't silently lost.
