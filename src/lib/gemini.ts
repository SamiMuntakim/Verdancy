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
  'You are a careful botanist and houseplant-care expert. Identify the plant in the image',
  'and return care guidance as JSON matching the schema. Safety rules you MUST follow:',
  '(1) Bias conservative on watering: when uncertain between watering frequencies, return the',
  'LONGER interval — overwatering / root rot is the most common cause of houseplant death,',
  'while under-watering is far more recoverable.',
  '(2) No confident guesses: if the plant is unidentifiable or your confidence is Low, set',
  "common_name to 'Unknown Plant' and water_cadence_days to null. Never invent a schedule.",
  "(3) Toxicity defaults safe: if toxicity to pets or children is unknown, return 'High'.",
  '(4) Ground all cadences in horticultural norms; cadences are whole numbers of days.',
].join(' ');

const DIAGNOSE_SYSTEM = [
  'You are a careful houseplant-health expert. Given an image of an ailing (or healthy) plant,',
  'diagnose the single most likely issue and return a triage plan as JSON matching the schema.',
  'Provide an ordered list of concrete steps, most important first. Bias conservative on watering:',
  'overwatering / root rot is the most common killer, so prefer letting soil dry when uncertain.',
  "If the plant looks healthy, set severity to 'Healthy' with simple maintenance steps. Report",
  'confidence honestly.',
].join(' ');

const IDENTIFY_SCHEMA: Schema = {
  type: Type.OBJECT,
  properties: {
    species: { type: Type.STRING },
    common_name: { type: Type.STRING },
    toxicity: { type: Type.STRING, enum: ['High', 'Medium', 'Low', 'None'] },
    water_cadence_days: { type: Type.INTEGER, nullable: true },
    fertilize_cadence_days: { type: Type.INTEGER, nullable: true },
    lighting_needs: { type: Type.STRING },
    fertilizer_info: { type: Type.STRING },
    confidence: { type: Type.STRING, enum: ['High', 'Medium', 'Low'] },
  },
  required: [
    'species',
    'common_name',
    'toxicity',
    'water_cadence_days',
    'fertilize_cadence_days',
    'lighting_needs',
    'fertilizer_info',
    'confidence',
  ],
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

export interface IdentifyResult {
  species: string;
  common_name: string;
  toxicity: 'High' | 'Medium' | 'Low' | 'None';
  water_cadence_days: number | null;
  fertilize_cadence_days: number | null;
  lighting_needs: string;
  fertilizer_info: string;
  confidence: 'High' | 'Medium' | 'Low';
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
  imageBase64: string,
): Promise<T> {
  const ai = await getClient();
  const res = await ai.models.generateContent({
    model,
    contents: [
      {
        role: 'user',
        parts: [{ text: userText }, { inlineData: { mimeType: 'image/jpeg', data: imageBase64 } }],
      },
    ],
    config: {
      systemInstruction: system,
      responseMimeType: 'application/json',
      responseSchema: schema,
      temperature: 0.2,
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
    'Identify this plant and produce its care card.',
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
