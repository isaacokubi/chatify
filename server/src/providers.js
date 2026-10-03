export function createStorageProvider(config={}){
  if (config.production && !config.cloudinaryUrl) {
    return {name:'unavailable',upload:async()=>{throw new Error('Image storage is not configured');}};
  }
  // The mock intentionally returns a data URL so the full image flow can be
  // demonstrated without storing user uploads or requiring credentials.
  return config.cloudinaryUrl
    ? {name:'cloudinary',upload:async()=>{throw new Error('Cloudinary credentials are configured but the production adapter is not installed')}}
    : {name:'development',upload:async file=>({url:file?.path||`data:${file?.mimeType};base64,${file?.data}`,mock:true})};
}
export function createNotificationProvider(config={},transport){
  if (transport?.send) return {name:config.fcmProjectId?'fcm':'custom',send:payload=>transport.send(payload)};
  if (config.fcmProjectId) return {name:'fcm-unavailable',send:async()=>{throw new Error('FCM credentials are configured but the production adapter is not installed');}};
  return {name:'mock',send:async()=>({mock:true})};
}
export function createEmailProvider(config={},transport){
  if (transport?.sendPasswordReset) return {name:config.smtpUrl?'smtp':'custom',sendPasswordReset:payload=>transport.sendPasswordReset(payload)};
  return {name:'mock',sendPasswordReset:async payload=>{
    // Development-only delivery path: the server operator can copy this token
    // into Chatify's reset form without exposing it through the public API.
    if (process.env.NODE_ENV !== 'production') console.info(`[Chatify development password reset] ${payload.email}: ${payload.token}`);
    return {mock:true,sent:false};
  }};
}
