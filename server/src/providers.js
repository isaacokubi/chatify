import nodemailer from 'nodemailer';
import {v2 as cloudinary} from 'cloudinary';
import {cert, getApps, initializeApp} from 'firebase-admin/app';
import {getMessaging} from 'firebase-admin/messaging';

const maxImageBytes = 10 * 1024 * 1024;
const maxVideoBytes = 50 * 1024 * 1024;
const supportedImageTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
const supportedVideoTypes = new Set(['video/mp4', 'video/webm', 'video/quicktime']);

export function isSupportedImageData(data, mimeType) {
  // Reject oversized and malformed-length payloads before running any regular
  // expression or allocating a decoded buffer. Base64 can expand a 10 MB image
  // to roughly 14 MB, and checking a huge string first can exhaust the JS stack.
  if (typeof data !== 'string' || !supportedImageTypes.has(mimeType) ||
      data.length === 0 || data.length % 4 !== 0 ||
      data.length > 4 * Math.ceil(maxImageBytes / 3)) {
    return false;
  }

  // Derive the decoded byte count from the encoded length and trailing padding.
  // This distinguishes a 10 MB payload from a slightly larger image that has
  // the same rounded-up base64 character count.
  const padding = data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0;
  const estimatedBytes = (data.length / 4) * 3 - padding;
  if (estimatedBytes > maxImageBytes) return false;

  // Buffer's base64 decoder is permissive, so the canonical round-trip below
  // validates the alphabet and padding without a large-input regular expression.
  const bytes = Buffer.from(data, 'base64');
  if (!bytes.length || bytes.length > maxImageBytes) return false;
  if (bytes.toString('base64') !== data) return false;

  if (mimeType === 'image/jpeg') {
    return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  }
  if (mimeType === 'image/png') {
    return bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  }
  return bytes.length >= 12 && bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP';
}

export function isSupportedVideoData(data, mimeType) {
  if (typeof data !== 'string' || !supportedVideoTypes.has(mimeType) ||
      data.length === 0 || data.length % 4 !== 0 ||
      data.length > 4 * Math.ceil(maxVideoBytes / 3)) return false;
  const padding = data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0;
  const estimatedBytes = (data.length / 4) * 3 - padding;
  if (estimatedBytes < 12 || estimatedBytes > maxVideoBytes) return false;
  const bytes = Buffer.from(data, 'base64');
  if (!bytes.length || bytes.length > maxVideoBytes || bytes.toString('base64') !== data) return false;
  if (mimeType === 'video/webm') {
    return bytes.length >= 4 && bytes.subarray(0, 4).equals(Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  }
  return bytes.toString('ascii', 4, 8) === 'ftyp';
}

export function isAllowedMessageMediaUrl(value, production = false) {
  if (typeof value !== 'string') return false;
  let url;
  try { url = new URL(value); } catch { return false; }
  const remote = url.protocol === 'https:' && value.length <= 2048 &&
    (!production || url.hostname === 'res.cloudinary.com');
  const developmentMock = !production &&
    /^data:image\/(jpeg|png|webp);base64,/i.test(value) && value.length <= 14 * 1024 * 1024;
  return remote || developmentMock;
}

export function createStorageProvider(config = {}, transport) {
  const cloudinaryUrl = config.cloudinaryUrl?.trim();
  if (transport?.upload) {
    return {
      name: 'cloudinary-test-transport',
      available: true,
      upload: file => uploadToCloudinary(file, transport),
    };
  }
  if (config.production && !cloudinaryUrl) {
    return {
      name: 'unavailable',
      available: false,
      upload: async () => { throw new Error('Image storage is not configured'); },
    };
  }
  if (cloudinaryUrl) {
    cloudinary.config({cloudinary_url: cloudinaryUrl, secure: true});
    return {
      name: 'cloudinary',
      available: true,
      upload: file => uploadToCloudinary(file, cloudinary.uploader),
    };
  }
  return {
    name: 'development',
    available: true,
    upload: async file => ({
      mediaUrl: file.path || `data:${file.mimeType};base64,${file.data}`,
      mock: true,
    }),
  };
}

async function uploadToCloudinary(file, uploader) {
  const isVideo = file.mediaType === 'video';
  const allowedData = isVideo
    ? isSupportedVideoData(file.data, file.mimeType)
    : isSupportedImageData(file.data, file.mimeType);
  let source;
  if (typeof file.path === 'string' && /^https:\/\//i.test(file.path) && file.path.length <= 2048) {
    source = file.path;
  } else {
    if (!allowedData) {
      throw new Error(isVideo
        ? 'Choose a valid MP4, WebM or MOV video no larger than 50 MB'
        : 'Choose a valid JPEG, PNG or WebP image no larger than 10 MB');
    }
    source = `data:${file.mimeType};base64,${file.data}`;
  }
  const result = await uploader.upload(source, {
    resource_type: isVideo ? 'video' : 'image',
    allowed_formats: isVideo ? ['mp4', 'webm', 'mov'] : ['jpg', 'jpeg', 'png', 'webp'],
    folder: 'chatify',
    unique_filename: true,
    overwrite: false,
  });
  if (typeof result?.secure_url !== 'string' || !/^https:\/\//i.test(result.secure_url)) {
    throw new Error('Image storage returned an invalid secure URL');
  }
  return {mediaUrl: result.secure_url};
}

export function createEmailProvider(config = {}, transport) {
  const smtpUrl = config.smtpUrl?.trim();
  const from = config.from?.trim();
  const injectedReset = typeof transport?.sendPasswordReset === 'function';
  const injectedVerification = typeof transport?.sendEmailVerification === 'function';
  const injectedSchoolReceipt = typeof transport?.sendSchoolFeeReceipt === 'function';
  const mailer = transport?.sendMail ? transport : (smtpUrl && from
    ? nodemailer.createTransport(smtpUrl)
    : null);
  const available = injectedReset || injectedVerification || injectedSchoolReceipt || Boolean(mailer && from);

  return {
    name: injectedReset || injectedSchoolReceipt || transport?.sendMail ? 'custom' : (available ? 'smtp' : 'unavailable'),
    available,
    async sendSchoolFeeReceipt(payload) {
      if (injectedSchoolReceipt) return transport.sendSchoolFeeReceipt(payload);
      if (!mailer || !from) {
        if (config.production) throw new Error('School fee receipt email is not configured');
        return { sent: false, mock: true };
      }
      const subject = `Official school fee receipt ${payload.receiptNumber || payload.paymentReference}`;
      const text = [
        `School: ${payload.schoolName}`,
        `Student: ${payload.studentName}`,
        `Term: ${payload.term}`,
        `Amount received: KSh ${Number(payload.amount).toLocaleString('en-KE')}`,
        `M-Pesa receipt: ${payload.receiptNumber}`,
        `Chatify reference: ${payload.paymentReference}`,
        '',
        'The official printable receipt is attached as an HTML file.',
      ].join('\n');
      await mailer.sendMail({
        from,
        to: payload.email,
        subject,
        text,
        attachments: [{
          filename: `school-fee-receipt-${String(payload.paymentReference).replace(/[^A-Z0-9-]/gi, '')}.html`,
          content: payload.receiptHtml,
          contentType: 'text/html; charset=utf-8',
        }],
      });
      return { sent: true };
    },
    async sendPasswordReset(payload) {
      if (injectedReset) return transport.sendPasswordReset(payload);
      if (!available) {
        if (config.production) throw new Error('Password reset email is not configured');
        return {sent: false, mock: true};
      }
      const expires = payload.expiresAt instanceof Date
        ? payload.expiresAt.toISOString()
        : String(payload.expiresAt);
      await mailer.sendMail({
        from,
        to: payload.email,
        subject: 'Reset your Chatify password',
        text: `Use this one-time reset token in Chatify:\n\n${payload.token}\n\nIt expires at ${expires}. If you did not request this, you can ignore this email.`,
      });
      return {sent: true};
    },
    async sendEmailVerification(payload) {
      if (injectedVerification) return transport.sendEmailVerification(payload);
      if (!available || !mailer) {
        if (config.production) throw new Error('Email confirmation is not configured');
        return {sent: false, mock: true};
      }
      const expires = payload.expiresAt instanceof Date
        ? payload.expiresAt.toISOString()
        : String(payload.expiresAt);
      await mailer.sendMail({
        from,
        to: payload.email,
        subject: 'Confirm your Chatify email address',
        text: `Welcome to Chatify. Confirm your email address by opening this link:\n\n${payload.verificationUrl}\n\nThis link expires at ${expires}. If you did not create this account, you can ignore this email.`,
      });
      return {sent: true};
    },
  };
}

let firebaseMessaging;
function getConfiguredMessaging(config) {
  if (firebaseMessaging) return firebaseMessaging;
  const account = JSON.parse(config.serviceAccountJson);
  if (account.project_id !== config.fcmProjectId) {
    throw new Error('Firebase project configuration does not match');
  }
  const app = getApps().find(item => item.name === 'chatify-notifications') ||
    initializeApp({credential: cert(account), projectId: config.fcmProjectId}, 'chatify-notifications');
  firebaseMessaging = getMessaging(app);
  return firebaseMessaging;
}

export function createNotificationProvider(config = {}, transport) {
  const injected = typeof transport?.send === 'function';
  const configured = Boolean(config.fcmProjectId && config.serviceAccountJson);
  const partialConfig = Boolean(config.fcmProjectId || config.serviceAccountJson);
  return {
    name: injected ? 'custom' : (configured ? 'fcm' : (partialConfig || config.production ? 'unavailable' : 'mock')),
    available: injected || configured,
    async send(payload) {
      if (typeof payload.token !== 'string' || !payload.token) {
        throw new Error('An FCM registration token is required');
      }
      const message = {
        token: payload.token,
        notification: {title: 'Chatify', body: 'You received a new message.'},
        android: {notification: {sound: 'default'}},
        apns: {payload: {aps: {sound: 'default'}}},
        data: {
          type: String(payload.type || 'message'),
          messageId: String(payload.messageId || ''),
          conversationId: String(payload.conversationId || ''),
        },
      };
      if (injected) return transport.send(message);
      if (!configured) {
        if (config.production || partialConfig) throw new Error('Push notifications are not configured');
        return {mock: true};
      }
      return getConfiguredMessaging(config).send(message);
    },
  };
}
