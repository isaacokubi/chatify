#!/usr/bin/env bash
# Encrypted off-site Chatify MongoDB backup.
# Requires MongoDB Database Tools, age, AWS CLI, MONGODB_URI,
# BACKUP_AGE_RECIPIENT, and BACKUP_S3_URI. AWS credentials should come from
# an instance/workload role or the operator's secret manager, never this file.
set -Eeuo pipefail
umask 077

: "${MONGODB_URI:?Set MONGODB_URI in the secret store}"
: "${BACKUP_AGE_RECIPIENT:?Set BACKUP_AGE_RECIPIENT to the age public recipient}"
: "${BACKUP_S3_URI:?Set BACKUP_S3_URI to an s3://bucket/prefix destination}"
command -v mongodump >/dev/null 2>&1 || { echo "mongodump is required." >&2; exit 127; }
command -v age >/dev/null 2>&1 || { echo "age is required for encrypted backups." >&2; exit 127; }
command -v aws >/dev/null 2>&1 || { echo "AWS CLI is required for off-site upload." >&2; exit 127; }
[[ "$BACKUP_S3_URI" =~ ^s3://[A-Za-z0-9._-]+(/.*)?$ ]] || { echo "BACKUP_S3_URI must be an s3:// bucket/prefix URI." >&2; exit 2; }

BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
if [[ ! "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS < 1 )); then
  echo "RETENTION_DAYS must be a positive integer." >&2
  exit 2
fi
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final="$BACKUP_DIR/chatify-$timestamp.archive.gz.age"
temporary="$final.tmp"
trap 'rm -f "$temporary"' EXIT

# Stream directly from mongodump into age so an unencrypted archive is not
# written to disk. The encrypted temporary file is atomically renamed on success.
mongodump --uri="$MONGODB_URI" --archive=- --gzip | age --recipient "$BACKUP_AGE_RECIPIENT" > "$temporary"
test -s "$temporary"
mv "$temporary" "$final"
(cd "$BACKUP_DIR" && sha256sum "$(basename "$final")" > "$(basename "$final").sha256")
chmod 600 "$final" "$final.sha256"

# Upload encrypted data and checksum. Configure an S3 lifecycle policy separately
# for remote retention; this script never deletes remote backups.
aws s3 cp "$final" "$BACKUP_S3_URI/$(basename "$final")" --sse AES256
aws s3 cp "$final.sha256" "$BACKUP_S3_URI/$(basename "$final").sha256" --sse AES256

find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'chatify-*.archive.gz.age' -o -name 'chatify-*.archive.gz.age.sha256' \) -mtime "+$RETENTION_DAYS" -delete
printf 'Encrypted backup completed and uploaded: %s/%s\n' "${BACKUP_S3_URI%/}" "$(basename "$final")"
printf 'SHA-256 checksum: %s.sha256\n' "$final"
