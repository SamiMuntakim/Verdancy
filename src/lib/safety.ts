import type { IdentifyResult } from './gemini';

/**
 * Enforce the plant-safety invariants server-side, regardless of what the model
 * returned (hard invariant #8):
 *  - low confidence / unidentifiable → "Unknown Plant" with null cadences;
 *  - unknown toxicity → "High" (assume the worst to protect pets/kids).
 *
 * Pure (no SDK imports) so it's unit-testable in isolation. The companion rule —
 * "when uncertain between watering intervals, return the LONGER one" — is enforced
 * in the model's system prompt (the model picks the interval, not the server).
 */
export function applyIdentifySafety(r: IdentifyResult): IdentifyResult {
  const out = { ...r };
  const validToxicity = ['High', 'Medium', 'Low', 'None'];
  if (!validToxicity.includes(out.toxicity)) out.toxicity = 'High';

  const unidentified = out.confidence === 'Low' || !out.common_name;
  if (unidentified) {
    out.common_name = 'Unknown Plant';
    out.water_cadence_days = null;
    out.fertilize_cadence_days = null;
    out.toxicity = 'High';
  }
  return out;
}
