#!/usr/bin/env bash
# Restore a Chatify archive into an explicitly designated NON-PRODUCTION MongoDB target.
# This script intentionally has no --drop option and never reads MONGODB_URI.
set -Eeuo pipefail
umask 077

: "${ARCHIVE:?Set ARCHIVE to the exact backup archive path}"
: "${RESTORE_TARGET_URI:?Set RESTORE_TARGET_URI to a separate staging/recovery database}"
if [[ "${RESTORE_TARGET_IS_NON_PRODUCTION:-}" != "YES" || "${CONFIRM_RESTORE:-}" != "YES" ]]; then
  echo "Refusing restore: set RESTORE_TARGET_IS_NON_PRODUCTION=YES and CONFIRM_RESTORE=YES after verifying the target is non-production." >&2
  exit 2
fi
command -v mongorestore >/dev/null 2>&1 || { echo "mongorestore is required (MongoDB Database Tools)." >&2; exit 127; }
[[ -f "$ARCHIVE" && -s "$ARCHIVE" ]] || { echo "Archive file does not exist or is empty." >&2; exit 2; }
if [[ -f "$ARCHIVE.sha256" ]]; then
  (cd "$(dirname "$ARCHIVE")" && sha256sum --check "$(basename "$ARCHIVE").sha256")
fi

# Restore into a fresh, isolated target first. Existing records are not dropped automatically.
mongorestore --uri="$RESTORE_TARGET_URI" --archive="$ARCHIVE" --gzip
printf 'Restore command completed. Validate collections, record counts, indexes, and app smoke tests before any cutover.\n'
