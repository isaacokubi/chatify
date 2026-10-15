#!/usr/bin/env bash
# Create a private compressed MongoDB archive without printing the connection URI.
# Requires MongoDB Database Tools (mongodump), MONGODB_URI, and a writable BACKUP_DIR.
set -Eeuo pipefail
umask 077

: "\${MONGODB_URI:?Set MONGODB_URI in the shell or deployment secret store}"
command -v mongodump >/dev/null 2>&1 || { echo "mongodump is required (MongoDB Database Tools)." >&2; exit 127; }

BACKUP_DIR="\${BACKUP_DIR:-./backups}"
RETENTION_DAYS="\${RETENTION_DAYS:-14}"
if [[ ! "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS < 1 )); then
  echo "RETENTION_DAYS must be a positive integer." >&2
  exit 2
fi
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final="$BACKUP_DIR/chatify-$timestamp.archive.gz"
temporary="$final.tmp"
trap 'rm -f "$temporary"' EXIT

# Do not use --drop or expose MONGODB_URI in command output.
mongodump --uri="$MONGODB_URI" --archive="$temporary" --gzip
test -s "$temporary"
mv "$temporary" "$final"
sha256sum "$final" > "$final.sha256"
chmod 600 "$final" "$final.sha256"
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'chatify-*.archive.gz' -o -name 'chatify-*.archive.gz.sha256' \) -mtime "+$RETENTION_DAYS" -delete
printf 'Backup completed: %s\n' "$final"
printf 'SHA-256 checksum: %s.sha256\n' "$final"
