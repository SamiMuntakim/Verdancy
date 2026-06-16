/**
 * Normalize a species string once at identify time before persisting (PRD 4.3):
 * lowercase, trim, collapse whitespace, drop cultivar text after a comma. All
 * `SPECIES#` keys and `PLANT#.species` values use this form; display uses
 * `common_name`.
 */
export function normalizeSpecies(species: string): string {
  return (species ?? '').split(',')[0].toLowerCase().replace(/\s+/g, ' ').trim();
}
