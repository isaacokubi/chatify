#!/usr/bin/env bash
# Restore a Chatify archive into an explicitly designated NON-PRODUCTION MongoDB target.
# This script intentionally has no --drop option and never reads MONGODB_URI.
set -Eeuo pipefail
umask 077

: "${ARCHIVE:?Set ARCHIVE to the exact backup archive path}"
: "${RESTORE_TARGET_URI:?Set RESTORE_TARGET_URI to a separate staging/recovery database}"

# Catch the most dangerous operator mistake when a production URI is available
# in the same environment. Never print either URI because it may contain credentials.
if [[ -n "${PRODUCTION_MONGODB_URI:-}" && "$RESTORE_TARGET_URI" == "$PRODUCTION_MONGODB_URI" ]]; then
  echo "Refusing restore: target URI exactly matches PRODUCTION_MONGODB_URI." >&2
  exit 2
fi
if [[ -n "${MONGODB_URI:-}" && "$RESTORE_TARGET_URI" == "$MONGODB_URI" ]]; then
  echo "Refusing restore: target URI exactly matches MONGODB_URI." >&2
  exit 2
fi
if [[ "${RESTORE_TARGET_IS_NON_PRODUCTION:-}" != "YES" || "${CONFIRM_RESTORE:-}" != "YES" ]]; then
  echo "Refusing restore: set RESTORE_TARGET_IS_NON_PRODUCTION=YES and CONFIRM_RESTORE=YES after verifying the target is non-production." >&2
  exit 2
fi
command -v mongorestore >/dev/null 2>&1 || { echo "mongorestore is required (MongoDB Database Tools)." >&2; exit 127; }
[[ -f "$ARCHIVE" && -s "$ARCHIVE" ]] || { echo "Archive file does not exist or is empty." >&2; exit 2; }
# Refuse to restore an archive without a checksum: corruption must not be silently accepted.
[[ -f "$ARCHIVE.sha256" && -s "$ARCHIVE.sha256" ]] || {
  echo "Checksum file is required: $ARCHIVE.sha256" >&2
  exit 2
}
(cd "$(dirname "$ARCHIVE")" && sha256sum --check "$(basename "$ARCHIVE").sha256")

# Restore into a fresh, isolated target first. Existing records are not dropped automatically.
mongorestore --uri="$RESTORE_TARGET_URI" --archive="$ARCHIVE" --gzip
printf 'Restore command completed. Validate collections, record counts, indexes, and app smoke tests before any cutover.\n'
