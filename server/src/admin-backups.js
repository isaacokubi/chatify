// Platform-admin backup controls. Restores are deliberately limited to a separately
// configured non-production target; the application never restores over its live database.
import {execFile as execFileCallback} from 'node:child_process';
import {promisify} from 'node:util';
import {readdir,stat,readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const execFile = promisify(execFileCallback);
const scriptsDir = fileURLToPath(new URL('../scripts/', import.meta.url));
const defaultBackupDir = path.resolve(process.cwd(), 'backups');
const backupNamePattern = /^chatify-\d{8}T\d{6}Z\.archive\.gz$/;

async function listArchives(directory) {
  let names;
  try { names = await readdir(directory); }
  catch (error) { if (error?.code === 'ENOENT') return []; throw error; }
  const rows = [];
  for (const name of names.filter(value => backupNamePattern.test(value)).sort().reverse().slice(0,100)) {
    const archivePath = path.join(directory, name);
    try {
      const [info, checksumInfo] = await Promise.all([
        stat(archivePath),
        stat(archivePath + '.sha256').catch(() => null),
      ]);
      rows.push({filename:name, sizeBytes:info.size, createdAt:info.mtime.toISOString(), hasChecksum:Boolean(checksumInfo && checksumInfo.size > 0)});
    } catch { /* Ignore files removed while listing. */ }
  }
  return rows;
}

export function registerAdminBackupRoutes({app, auth, requireAdmin}) {
  const backupDirectory = path.resolve(process.env.CHATIFY_BACKUP_DIR || defaultBackupDir);
  app.get('/api/admin/backups', auth, requireAdmin, async (_req, res) => {
    try {
      const backups = await listArchives(backupDirectory);
      const restoreConfigured = Boolean(
        process.env.CHATIFY_RESTORE_TARGET_URI &&
        process.env.CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION === 'YES'
      );
      res.json({
        backups,
        backupDirectoryConfigured: Boolean(process.env.CHATIFY_BACKUP_DIR),
        restoreConfigured,
        backupToolConfigured: Boolean(process.env.MONGODB_URI || process.env.MONGO_URL),
        note: 'Use persistent private storage and an encrypted off-site copy. Restores are only allowed to the separately configured non-production target.',
      });
    } catch (error) {
      res.status(500).json({error:'Could not inspect backup storage.'});
    }
  });

  app.post('/api/admin/backups', auth, requireAdmin, async (_req, res) => {
    const mongoUri = process.env.MONGODB_URI || process.env.MONGO_URL;
    if (!mongoUri) return res.status(503).json({error:'Database backup is not configured: MONGODB_URI is missing.'});
    try {
      const {stdout} = await execFile('bash', [path.join(scriptsDir, 'backup-mongodb.sh')], {
        env: {...process.env, MONGODB_URI:mongoUri, BACKUP_DIR:backupDirectory},
        timeout: 10 * 60 * 1000,
        maxBuffer: 1024 * 1024,
      });
      const backups = await listArchives(backupDirectory);
      return res.status(201).json({message:'Database archive created. Verify off-site replication before relying on it for disaster recovery.', backups, output:stdout.trim()});
    } catch (error) {
      const message = String(error?.stderr || error?.message || 'Backup failed.').slice(0,1200);
      return res.status(503).json({error:message});
    }
  });

  app.post('/api/admin/backups/:filename/restore', auth, requireAdmin, async (req, res) => {
    const filename = String(req.params.filename || '');
    if (!backupNamePattern.test(filename) || path.basename(filename) !== filename) {
      return res.status(400).json({error:'Invalid backup filename.'});
    }
    const targetUri = process.env.CHATIFY_RESTORE_TARGET_URI;
    if (!targetUri || process.env.CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION !== 'YES') {
      return res.status(503).json({error:'Recovery is disabled. Configure a separate staging/recovery database and set CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION=YES.'});
    }
    if (req.body?.confirmRestore !== true) {
      return res.status(400).json({error:'Explicit confirmation is required before restoring to the configured non-production database.'});
    }
    const archive = path.join(backupDirectory, filename);
    try {
      const backups = await listArchives(backupDirectory);
      if (!backups.some(item => item.filename === filename && item.hasChecksum)) {
        return res.status(404).json({error:'Backup or checksum file not found. Restore is blocked until the archive and checksum are available.'});
      }
      const productionUri = process.env.PRODUCTION_MONGODB_URI || process.env.MONGODB_URI || process.env.MONGO_URL || '';
      if (productionUri && targetUri === productionUri) {
        return res.status(403).json({error:'Recovery target matches the configured application database; restore is blocked.'});
      }
      const {stdout} = await execFile('bash', [path.join(scriptsDir, 'restore-mongodb.sh')], {
        env: {
          ...process.env,
          ARCHIVE:archive,
          RESTORE_TARGET_URI:targetUri,
          RESTORE_TARGET_IS_NON_PRODUCTION:'YES',
          CONFIRM_RESTORE:'YES',
        },
        timeout: 10 * 60 * 1000,
        maxBuffer: 1024 * 1024,
      });
      return res.json({message:'Restore command completed against the separately configured non-production target. Validate record counts, indexes, authentication, payments and application smoke tests before any cutover.', output:stdout.trim()});
    } catch (error) {
      const message = String(error?.stderr || error?.message || 'Restore failed.').slice(0,1200);
      return res.status(503).json({error:message});
    }
  });
}
