import { normalizeSpecies } from '../src/lib/species';
import { newImageKey, assertOwnsKey, plantIdFromKey } from '../src/lib/keys';
import { applyIdentifySafety } from '../src/lib/safety';
import { ApiError } from '../src/lib/errors';
import type { IdentifyResult } from '../src/lib/gemini';

describe('normalizeSpecies', () => {
  test('lowercases, trims, collapses whitespace, drops cultivar after comma', () => {
    expect(normalizeSpecies('Monstera   Deliciosa, Variegata ')).toBe('monstera deliciosa');
    expect(normalizeSpecies('  Ficus  Lyrata  ')).toBe('ficus lyrata');
  });
});

describe('S3 keys & ownership', () => {
  test('newImageKey is under the caller prefix and ends .jpg', () => {
    const key = newImageKey('sub-1', 'plant-1');
    expect(key.startsWith('u/sub-1/p/plant-1/')).toBe(true);
    expect(key.endsWith('.jpg')).toBe(true);
  });

  test('assertOwnsKey accepts the caller’s own key', () => {
    expect(() => assertOwnsKey('sub-1', 'u/sub-1/p/p1/x.jpg')).not.toThrow();
  });

  test('assertOwnsKey rejects another user’s key with 403', () => {
    let status: number | undefined;
    try {
      assertOwnsKey('sub-1', 'u/sub-2/p/p1/x.jpg');
    } catch (e) {
      status = (e as ApiError).statusCode;
    }
    expect(status).toBe(403);
  });

  test('assertOwnsKey rejects non-strings with 403', () => {
    expect(() => assertOwnsKey('sub-1', undefined)).toThrow(ApiError);
  });

  test('plantIdFromKey extracts the plantId; rejects malformed', () => {
    expect(plantIdFromKey('u/sub-1/p/PID-9/abc.jpg')).toBe('PID-9');
    expect(() => plantIdFromKey('nonsense')).toThrow(ApiError);
  });
});

describe('applyIdentifySafety (invariant #8)', () => {
  const base: IdentifyResult = {
    species: 'monstera deliciosa',
    common_name: 'Monstera',
    toxicity: 'Low',
    water_cadence_days: 7,
    fertilize_cadence_days: 30,
    lighting_needs: 'bright indirect',
    fertilizer_info: 'monthly in spring',
    confidence: 'High',
  };

  test('high-confidence result passes through unchanged', () => {
    expect(applyIdentifySafety(base)).toEqual(base);
  });

  test('low confidence → Unknown Plant, null cadences, High toxicity', () => {
    const out = applyIdentifySafety({ ...base, confidence: 'Low' });
    expect(out.common_name).toBe('Unknown Plant');
    expect(out.water_cadence_days).toBeNull();
    expect(out.fertilize_cadence_days).toBeNull();
    expect(out.toxicity).toBe('High');
  });

  test('unknown/invalid toxicity defaults to High', () => {
    const out = applyIdentifySafety({ ...base, toxicity: 'Unsure' as unknown as 'High' });
    expect(out.toxicity).toBe('High');
  });
});
