import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectsCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { requireEnv } from './env';

/**
 * Presigned-URL access only — image bytes never pass through Lambda (hard
 * invariant #6). URLs are short-lived; the app caches downloaded bytes locally.
 */
const s3 = new S3Client({});
const bucket = (): string => requireEnv('USER_IMAGE_BUCKET');
const EXPIRES_IN_SECONDS = 900; // 15 minutes

export function presignPut(key: string): Promise<string> {
  return getSignedUrl(
    s3,
    new PutObjectCommand({ Bucket: bucket(), Key: key, ContentType: 'image/jpeg' }),
    { expiresIn: EXPIRES_IN_SECONDS },
  );
}

export function presignGet(key: string): Promise<string> {
  return getSignedUrl(s3, new GetObjectCommand({ Bucket: bucket(), Key: key }), {
    expiresIn: EXPIRES_IN_SECONDS,
  });
}

/** Delete S3 objects (used by the plant-delete cascade). */
export async function deleteObjects(keys: string[]): Promise<void> {
  const unique = [...new Set(keys.filter((k) => typeof k === 'string' && k.length > 0))];
  for (let i = 0; i < unique.length; i += 1000) {
    const chunk = unique.slice(i, i + 1000);
    await s3.send(
      new DeleteObjectsCommand({
        Bucket: bucket(),
        Delete: { Objects: chunk.map((Key) => ({ Key })), Quiet: true },
      }),
    );
  }
}
