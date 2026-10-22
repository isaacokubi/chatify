import {isSupportedImageData, isSupportedVideoData} from './providers.js';

export const SPARK_LIFETIME_MS = 24 * 60 * 60 * 1000;
export const SPARK_VIDEO_MAX_BYTES = 50 * 1024 * 1024;

export function sparkExpiry(createdAt = new Date()) {
  return new Date(new Date(createdAt).getTime() + SPARK_LIFETIME_MS);
}
export function isSparkActive(spark, now = new Date()) {
  const expiry = new Date(spark?.expiresAt || 0).getTime();
  return Number.isFinite(expiry) && expiry > new Date(now).getTime();
}

export function normalizeSparkText(value) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  return text.length >= 1 && text.length <= 500 ? text : null;
}

export function normalizeSparkPayload(payload = {}, production = false) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
  if (payload.type !== undefined && !['text', 'image', 'video'].includes(payload.type)) return null;
  const type = payload.type ?? 'text';
  const text = typeof payload.text === 'string' ? payload.text.trim() : '';
  if (text.length > 500 || (type === 'text' && text.length === 0)) return null;
  if (type === 'text') return {type, text};

  const mediaUrl = payload.mediaUrl;
  if (!isAllowedSparkMediaUrl(mediaUrl, type, production)) return null;
  return {type, text, mediaUrl};
}

export function isAllowedSparkMediaUrl(value, type, production = false) {
  if (typeof value !== 'string') return false;
  let url;
  try {
    url = new URL(value);
  } catch (_) {}
  if (url?.protocol === 'https:') {
    return value.length <= 2048 && url.hostname === 'res.cloudinary.com' &&
      url.pathname.includes(type === 'video' ? '/video/upload/' : '/image/upload/');
  }
  if (production || !value.startsWith('data:') || value.length > 12 * 1024 * 1024) return false;
  const match = value.match(/^data:([^;]+);base64,(.+)$/i);
  if (!match) return false;
  if (type === 'image' && /^image\/(jpeg|png|webp)$/i.test(match[1])) {
    return isSupportedImageData(match[2], match[1].toLowerCase());
  }
  if (type === 'video' && /^video\/(mp4|webm|quicktime)$/i.test(match[1])) {
    return isSupportedVideoData(match[2], match[1].toLowerCase());
  }
  return false;
}
