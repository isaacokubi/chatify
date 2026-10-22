#!/usr/bin/env bash
# Restore an encrypted Chatify archive into an explicitly confirmed non-production target.
# Requires age, MongoDB Database Tools, ARCHIVE, BACKUP_AGE_IDENTITY, and RESTORE_TARGET_URI.
set -Eeuo pipefail
umask 077

: "${ARCHIVE:?Set ARCHIVE to the exact encrypted .archive.gz.age file}"
: "${BACKUP_AGE_IDENTITY:?Set BACKUP_AGE_IDENTITY to the private age identity file}"
: "${RESTORE_TARGET_URI:?Set RESTORE_TARGET_URI to an isolated staging/recovery database}"
if [[ "${RESTORE_TARGET_IS_NON_PRODUCTION:-}" != "YES" || "${CONFIRM_RESTORE:-}" != "YES" ]]; then
  echo "Refusing restore: set RESTORE_TARGET_IS_NON_PRODUCTION=YES and CONFIRM_RESTORE=YES after verifying the target is non-production." >&2
  exit 2
fi
command -v age >/dev/null 2>&1 || { echo "age is required." >&2; exit 127; }
command -v mongorestore >/dev/null 2>&1 || { echo "mongorestore is required." >&2; exit 127; }
[[ -f "$ARCHIVE" && -s "$ARCHIVE" ]] || { echo "Encrypted archive does not exist or is empty." >&2; exit 2; }
[[ -f "$BACKUP_AGE_IDENTITY" && -s "$BACKUP_AGE_IDENTITY" ]] || { echo "Age identity file does not exist or is empty." >&2; exit 2; }
[[ -f "$ARCHIVE.sha256" && -s "$ARCHIVE.sha256" ]] || { echo "Checksum file is required: $ARCHIVE.sha256" >&2; exit 2; }

# Verify the encrypted bytes before decrypting. Plaintext is streamed to mongorestore
# rather than written to a temporary file; no --drop option is ever used.
(cd "$(dirname "$ARCHIVE")" && sha256sum --check "$(basename "$ARCHIVE").sha256")
age --decrypt --identity "$BACKUP_AGE_IDENTITY" "$ARCHIVE" | mongorestore --uri="$RESTORE_TARGET_URI" --archive --gzip
printf 'Encrypted restore command completed. Validate collections, counts, indexes, and app smoke tests before any cutover.\n'
