import nodemailer from 'nodemailer';
import {v2 as cloudinary} from 'cloudinary';
import {cert, getApps, initializeApp} from 'firebase-admin/app';
import {getMessaging} from 'firebase-admin/messaging';

const maxImageBytes = 650 * 1024;
const supportedImageTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);

export function isSupportedImageData(data, mimeType) {
  if (typeof data !== 'string' || !supportedImageTypes.has(mimeType) ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)) {
    return false;
  }
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

export function isAllowedMessageMediaUrl(value, production = false) {
  if (typeof value !== 'string') return false;
  let url;
  try { url = new URL(value); } catch { return false; }
  const remote = url.protocol === 'https:' && value.length <= 2048 &&
    (!production || url.hostname === 'res.cloudinary.com');
  const developmentMock = !production &&
    /^data:image\/(jpeg|png|webp);base64,/i.test(value) && value.length <= 900000;
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
  let source;
  if (typeof file.path === 'string' && /^https:\/\//i.test(file.path) && file.path.length <= 2048) {
    source = file.path;
  } else {
    if (!isSupportedImageData(file.data, file.mimeType)) {
      throw new Error('Choose a valid JPEG, PNG or WebP image smaller than 650 KB');
    }
    source = `data:${file.mimeType};base64,${file.data}`;
  }
  const result = await uploader.upload(source, {
    resource_type: 'image',
    allowed_formats: ['jpg', 'jpeg', 'png', 'webp'],
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
  const mailer = transport?.sendMail ? transport : (smtpUrl && from
    ? nodemailer.createTransport(smtpUrl)
    : null);
  const available = injectedReset || Boolean(mailer && from);

  return {
    name: injectedReset || transport?.sendMail ? 'custom' : (available ? 'smtp' : 'unavailable'),
    available,
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
        data: {
          type: String(payload.type || 'message'),
          messageId: String(payload.messageId || ''),
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
