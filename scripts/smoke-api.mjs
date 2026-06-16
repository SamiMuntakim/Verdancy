// End-to-end smoke test for the deployed HTTP API. Exercises the non-AI paths
// (CRUD, presigned upload/download, care, milestone idempotency, delete cascade)
// so it costs no Gemini calls/quota. /identify and /diagnose are intentionally
// skipped (they need the Gemini key and consume the per-user allowance).
//
// Usage:
//   node scripts/smoke-api.mjs <ApiBaseUrl> <idToken>
//
// Get <ApiBaseUrl> from the `HttpApiUrl` deploy output, and <idToken> from
// scripts/smoke-auth.mjs (the JWT it authenticates).
//
// Side effects: creates then deletes one plant; pledges a 'smoke-test' milestone
// (milestones can't be un-pledged, so that one tree stays — idempotent on reruns).

const [, , apiBaseArg, token] = process.argv;
if (!apiBaseArg || !token) {
  console.error('Usage: node scripts/smoke-api.mjs <ApiBaseUrl> <idToken>');
  process.exit(2);
}
const base = apiBaseArg.replace(/\/$/, '');

let passed = 0;
let failed = 0;
function check(name, condition, detail) {
  if (condition) {
    passed += 1;
    console.log(`✓ ${name}`);
  } else {
    failed += 1;
    console.error(`✗ ${name}${detail !== undefined ? ` (${detail})` : ''}`);
  }
}

async function api(method, path, body) {
  const res = await fetch(base + path, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  let json;
  try {
    json = await res.json();
  } catch {
    json = undefined;
  }
  return { status: res.status, json };
}

async function main() {
  let r = await api('POST', '/users');
  check('POST /users', r.status === 200, r.status);

  r = await api('POST', '/uploads', { kind: 'plant' });
  const imageRef = r.json?.image_ref;
  const uploadUrl = r.json?.upload_url;
  check(
    'POST /uploads mints a key under u/<sub>/',
    r.status === 200 && /^u\//.test(imageRef ?? ''),
    r.status,
  );

  if (uploadUrl) {
    const put = await fetch(uploadUrl, {
      method: 'PUT',
      headers: { 'content-type': 'image/jpeg' },
      body: Buffer.from([0xff, 0xd8, 0xff, 0xd9]), // minimal JPEG-ish bytes
    });
    check('PUT presigned upload', put.status === 200, put.status);
  }

  r = await api('POST', '/plants', {
    image_ref: imageRef,
    common_name: 'Smoke Monstera',
    species: 'Monstera Deliciosa',
    water_cadence_days: 10,
    fertilize_cadence_days: 30,
    confidence: 'High',
    toxicity: 'Low',
  });
  const plantId = r.json?.plantId;
  check('POST /plants', r.status === 201 && !!plantId, r.status);

  r = await api('GET', '/plants');
  const found = (r.json?.plants ?? []).find((p) => p.plantId === plantId);
  check(
    'GET /plants returns the plant with a download_url',
    r.status === 200 && !!found?.download_url,
    r.status,
  );

  if (found?.download_url) {
    const dl = await fetch(found.download_url);
    check('GET presigned download', dl.status === 200, dl.status);
  }

  r = await api('POST', `/plants/${plantId}/care`, { type: 'water' });
  check('POST /plants/{id}/care water', r.status === 200, r.status);

  const m1 = (await api('POST', '/milestones', { milestoneId: 'smoke-test' })).json?.trees_pledged;
  const m2 = (await api('POST', '/milestones', { milestoneId: 'smoke-test' })).json?.trees_pledged;
  check('POST /milestones is idempotent', m1 === m2, `${m1} vs ${m2}`);

  r = await api('GET', '/me/trees');
  check(
    'GET /me/trees reflects the milestone',
    (r.json?.milestones ?? []).includes('smoke-test'),
    JSON.stringify(r.json),
  );

  r = await api('DELETE', `/plants/${plantId}`);
  check('DELETE /plants/{id} cascade', r.status === 200, r.status);

  r = await api('GET', '/plants');
  check(
    'plant removed from the garden',
    !(r.json?.plants ?? []).some((p) => p.plantId === plantId),
  );

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

main().catch((err) => {
  console.error('Smoke test crashed:', err?.message ?? err);
  process.exit(1);
});
