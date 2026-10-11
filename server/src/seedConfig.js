export function resolveDemoSeedConfig(env) {
  if(env.NODE_ENV!=='development')throw new Error('Demo seeding is allowed only when NODE_ENV=development');
  if(env.CHATIFY_SEED_DEMO!=='YES')throw new Error('Set CHATIFY_SEED_DEMO=YES to confirm demo seeding');
  const passwordValue=env.DEMO_SEED_PASSWORD;
  if(typeof passwordValue!=='string'||Buffer.byteLength(passwordValue,'utf8')<12||Buffer.byteLength(passwordValue,'utf8')>72)throw new Error('DEMO_SEED_PASSWORD must be 12–72 UTF-8 bytes');
  if(typeof env.MONGODB_URI!=='string'||!env.MONGODB_URI.trim())throw new Error('MONGODB_URI is required for demo seeding');
  return {uri:env.MONGODB_URI,passwordValue};
}
