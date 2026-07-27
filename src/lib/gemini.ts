import { GoogleGenAI, Type, Modality, type Schema } from '@google/genai';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { requireEnv } from './env';
import { ApiError } from './errors';
import { applyIdentifySafety } from './safety';

/**
 * Thin Gemini proxy. SDK is `@google/genai` (the legacy `@google/generative-ai`
 * is deprecated). Models come from env (default `gemini-3.5-flash`; do NOT
 * downgrade to a Lite tier). Structured output via responseMimeType +
 * responseSchema, with JSON.parse guarded. Images are forwarded inline and
 * discarded — never written to S3 (hard invariant #6).
 */

const DEFAULT_MODEL = 'gemini-3.5-flash';
// Image-output model for Plant Buddy sprites (override via BUDDY_MODEL_ID).
const DEFAULT_BUDDY_MODEL = 'gemini-2.5-flash-image';

const sm = new SecretsManagerClient({});
let client: GoogleGenAI | undefined;

async function getClient(): Promise<GoogleGenAI> {
  if (client) return client;
  const res = await sm.send(
    new GetSecretValueCommand({ SecretId: requireEnv('GEMINI_API_KEY_SECRET_NAME') }),
  );
  if (!res.SecretString) throw new Error('Gemini API key secret has no value');
  client = new GoogleGenAI({ apiKey: res.SecretString });
  return client;
}

const IDENTIFY_SYSTEM = [
  'You are a careful botanist. Identify and CLASSIFY the plant in the image and return JSON',
  'matching the schema. Return identity only — NO care schedule, watering, lighting, or',
  'fertilizer guidance (a separate step tailors care to the plant’s environment). Rules you',
  'MUST follow:',
  '(1) Provide the botanical taxonomy (family, genus, species; cultivar only if visually',
  'evident, else null). Use accepted horticultural naming.',
  '(2) No confident guesses: if the plant is unidentifiable or your confidence is Low, set',
  "common_name to 'Unknown Plant' and taxonomy to null. Never invent a classification.",
  "(3) Toxicity defaults safe: if toxicity to pets or children is unknown, return 'High'.",
].join(' ');

const DIAGNOSE_SYSTEM = [
  'You are a careful houseplant-health expert. Given an image of an ailing (or healthy) plant,',
  'diagnose the single most likely issue and return a triage plan as JSON matching the schema.',
  'Provide an ordered list of concrete steps, most important first. Bias conservative on watering:',
  'overwatering / root rot is the most common killer, so prefer letting soil dry when uncertain.',
  "If the plant looks healthy, set severity to 'Healthy' with simple maintenance steps. Report",
  'confidence honestly.',
].join(' ');

const TAXONOMY_SCHEMA: Schema = {
  type: Type.OBJECT,
  nullable: true,
  properties: {
    family: { type: Type.STRING },
    genus: { type: Type.STRING },
    species: { type: Type.STRING },
    cultivar: { type: Type.STRING, nullable: true },
  },
  required: ['family', 'genus', 'species'],
};

const IDENTIFY_SCHEMA: Schema = {
  type: Type.OBJECT,
  properties: {
    species: { type: Type.STRING },
    common_name: { type: Type.STRING },
    toxicity: { type: Type.STRING, enum: ['High', 'Medium', 'Low', 'None'] },
    taxonomy: TAXONOMY_SCHEMA,
    confidence: { type: Type.STRING, enum: ['High', 'Medium', 'Low'] },
  },
  required: ['species', 'common_name', 'toxicity', 'taxonomy', 'confidence'],
};

const DIAGNOSE_SCHEMA: Schema = {
  type: Type.OBJECT,
  properties: {
    issue: { type: Type.STRING },
    likely_cause: { type: Type.STRING },
    severity: { type: Type.STRING, enum: ['Critical', 'Moderate', 'Minor', 'Healthy'] },
    steps: { type: Type.ARRAY, items: { type: Type.STRING } },
    confidence: { type: Type.STRING, enum: ['High', 'Medium', 'Low'] },
  },
  required: ['issue', 'likely_cause', 'severity', 'steps', 'confidence'],
};

export interface Taxonomy {
  family: string;
  genus: string;
  species: string;
  cultivar: string | null;
}

export interface IdentifyResult {
  species: string;
  common_name: string;
  toxicity: 'High' | 'Medium' | 'Low' | 'None';
  taxonomy: Taxonomy | null;
  confidence: 'High' | 'Medium' | 'Low';
}

/** Environment inputs collected by the app's "personalize care" form. */
export interface CarePlanInputs {
  pot_size?: string | null;
  has_drainage?: boolean | null;
  soil_type?: string | null;
  indoor?: boolean | null;
  direct_sunlight?: boolean | null;
  direct_sunlight_hours?: number | null;
  window_orientation?: string | null;
  distance_from_window?: string | null;
  grow_light?: boolean | null;
}

export interface CarePlanResult {
  water: { amount: string; cadence_days: number; instruction: string };
  light: { summary: string; instruction: string };
  nutrients: { fertilize_cadence_days: number | null; instruction: string };
}

export interface DiagnoseResult {
  issue: string;
  likely_cause: string;
  severity: 'Critical' | 'Moderate' | 'Minor' | 'Healthy';
  steps: string[];
  confidence: 'High' | 'Medium' | 'Low';
}

async function generateJson<T>(
  model: string,
  system: string,
  schema: Schema,
  userText: string,
  imageBase64: string | null,
  temperature = 0.2,
): Promise<T> {
  const ai = await getClient();
  const parts: Array<Record<string, unknown>> = [{ text: userText }];
  if (imageBase64) parts.push({ inlineData: { mimeType: 'image/jpeg', data: imageBase64 } });
  const res = await ai.models.generateContent({
    model,
    contents: [{ role: 'user', parts }],
    config: {
      systemInstruction: system,
      responseMimeType: 'application/json',
      responseSchema: schema,
      temperature,
    },
  });
  const text = res.text;
  if (!text) throw new ApiError(500, 'AI returned an empty response');
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new ApiError(500, 'AI returned malformed JSON');
  }
}

export async function identify(imageBase64: string): Promise<IdentifyResult> {
  const model = process.env.IDENTIFY_MODEL_ID || DEFAULT_MODEL;
  const raw = await generateJson<IdentifyResult>(
    model,
    IDENTIFY_SYSTEM,
    IDENTIFY_SCHEMA,
    'Identify and classify this plant (name + taxonomy + toxicity only).',
    imageBase64,
  );
  return applyIdentifySafety(raw);
}

export async function diagnose(imageBase64: string): Promise<DiagnoseResult> {
  const model = process.env.DIAGNOSE_MODEL_ID || DEFAULT_MODEL;
  return generateJson<DiagnoseResult>(
    model,
    DIAGNOSE_SYSTEM,
    DIAGNOSE_SCHEMA,
    "Diagnose this plant's health and produce a triage plan.",
    imageBase64,
  );
}

// ---------------------------------------------------------------------------
// Personalized care plan (text-only, no image) — tailored to the plant's real
// environment. Subscriber-gated at the route; quota is reserved before this call.
// ---------------------------------------------------------------------------

const CARE_PLAN_SYSTEM = [
  'You are a premium houseplant-care expert. Given a plant species and the specifics of where',
  'and how the owner keeps it, produce a personalized care plan as JSON matching the schema.',
  'Write warm, concrete, second-person instructions — like a great plant app. Rules:',
  '(1) Water: bias CONSERVATIVE — when unsure between two intervals, choose the LONGER one;',
  'overwatering / root rot is the top killer. Size the water AMOUNT to the pot (e.g. a small',
  'pot may need "1/2 cup", a large pot "2 cups"); phrase `instruction` like',
  '"Water 1.5 cups every 10 days". `cadence_days` is a whole number of days.',
  '(2) Light: base the advice on the window orientation, distance from the window, direct-sun',
  'hours, indoor/outdoor, and any grow light. Phrase `instruction` like "Place it less than 6',
  'feet from a south-facing window to ensure it receives enough light to survive."',
  '(3) Nutrients: give repotting + fertilizing guidance, e.g. "To replenish this plant’s',
  'nutrients, repot it after it doubles in size or once a year—whichever comes first."',
  '`fertilize_cadence_days` is a whole number of days, or null if fertilizing isn’t needed.',
].join(' ');

const CARE_PLAN_SCHEMA: Schema = {
  type: Type.OBJECT,
  properties: {
    water: {
      type: Type.OBJECT,
      properties: {
        amount: { type: Type.STRING },
        cadence_days: { type: Type.INTEGER },
        instruction: { type: Type.STRING },
      },
      required: ['amount', 'cadence_days', 'instruction'],
    },
    light: {
      type: Type.OBJECT,
      properties: {
        summary: { type: Type.STRING },
        instruction: { type: Type.STRING },
      },
      required: ['summary', 'instruction'],
    },
    nutrients: {
      type: Type.OBJECT,
      properties: {
        fertilize_cadence_days: { type: Type.INTEGER, nullable: true },
        instruction: { type: Type.STRING },
      },
      required: ['fertilize_cadence_days', 'instruction'],
    },
  },
  required: ['water', 'light', 'nutrients'],
};

function describeEnvironment(inputs: CarePlanInputs): string {
  const lines: string[] = [];
  const yn = (v: boolean | null | undefined): string => (v ? 'yes' : 'no');
  if (inputs.pot_size) lines.push(`Pot size: ${inputs.pot_size}`);
  if (inputs.has_drainage != null)
    lines.push(`Pot has a drainage hole: ${yn(inputs.has_drainage)}`);
  if (inputs.soil_type) lines.push(`Soil: ${inputs.soil_type}`);
  if (inputs.indoor != null) lines.push(`Kept ${inputs.indoor ? 'indoors' : 'outdoors'}`);
  if (inputs.direct_sunlight != null)
    lines.push(`Gets direct sunlight: ${yn(inputs.direct_sunlight)}`);
  if (inputs.direct_sunlight_hours != null)
    lines.push(`Hours of direct sun per day: ${inputs.direct_sunlight_hours}`);
  if (inputs.window_orientation) lines.push(`Nearest window faces: ${inputs.window_orientation}`);
  if (inputs.distance_from_window)
    lines.push(`Distance from that window: ${inputs.distance_from_window}`);
  if (inputs.grow_light != null) lines.push(`Uses a grow light: ${yn(inputs.grow_light)}`);
  return lines.length > 0
    ? lines.join('\n')
    : 'No environment details provided; use sensible defaults.';
}

export async function generateCarePlan(
  commonName: string,
  species: string,
  inputs: CarePlanInputs,
): Promise<CarePlanResult> {
  const model = process.env.CARE_PLAN_MODEL_ID || process.env.IDENTIFY_MODEL_ID || DEFAULT_MODEL;
  const userText = [
    `Plant: ${commonName || 'Unknown'}${species ? ` (${species})` : ''}.`,
    'The owner keeps it as follows:',
    describeEnvironment(inputs),
  ].join('\n');
  return generateJson<CarePlanResult>(
    model,
    CARE_PLAN_SYSTEM,
    CARE_PLAN_SCHEMA,
    userText,
    null,
    0.4,
  );
}

// Plant Buddy sprite generation (PRD Appendix A). Fixed style prefix + species
// clause; flat magenta field so the background keys out cleanly. (Style-bible
// reference sprites can be added as extra input parts once the art exists.)
const BUDDY_STYLE_PREFIX = [
  'Generate a single cute pixel-art "plant buddy" mascot: a chibi anthropomorphic',
  'houseplant with a simple friendly face, clean 16-bit pixel-art style, bold dark',
  'outline, limited flat colors, centered, full body, front-facing, no text and no',
  'ground shadow. Put it on a completely flat solid magenta (#FF00FF) background',
  'with no gradient so the background can be keyed out.',
].join(' ');

export interface GeneratedImage {
  data: Buffer;
  mimeType: string;
}

export async function generateBuddyImage(species: string): Promise<GeneratedImage> {
  const ai = await getClient();
  const model = process.env.BUDDY_MODEL_ID || DEFAULT_BUDDY_MODEL;
  const res = await ai.models.generateContent({
    model,
    contents: [
      {
        role: 'user',
        parts: [{ text: `${BUDDY_STYLE_PREFIX} The plant species is: ${species}.` }],
      },
    ],
    config: { responseModalities: [Modality.IMAGE] },
  });
  const parts = res.candidates?.[0]?.content?.parts ?? [];
  for (const part of parts) {
    const inline = part.inlineData;
    if (inline?.data) {
      return { data: Buffer.from(inline.data, 'base64'), mimeType: inline.mimeType ?? 'image/png' };
    }
  }
  throw new ApiError(502, 'Image model returned no image');
}

/** Test-only: reset the cached client between unit tests. */
export function _resetClientForTest(): void {
  client = undefined;
}
