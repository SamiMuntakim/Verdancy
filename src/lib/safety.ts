import type { IdentifyResult } from './gemini';

/**
 * Enforce the plant-safety invariants server-side, regardless of what the model
 * returned (hard invariant #8):
 *  - low confidence / unidentifiable → "Unknown Plant" with no taxonomy;
 *  - unknown toxicity → "High" (assume the worst to protect pets/kids).
 *
 * Pure (no SDK imports) so it's unit-testable in isolation. Care cadences are no
 * longer part of identify — they're produced later by the environment-tailored
 * care plan (which biases conservative on watering in its own system prompt).
 */
export function applyIdentifySafety(r: IdentifyResult): IdentifyResult {
  const out = { ...r };
  const validToxicity = ['High', 'Medium', 'Low', 'None'];
  if (!validToxicity.includes(out.toxicity)) out.toxicity = 'High';

  const unidentified = out.confidence === 'Low' || !out.common_name;
  if (unidentified) {
    out.common_name = 'Unknown Plant';
    out.taxonomy = null;
    out.toxicity = 'High';
  }
  return out;
}
