#!/usr/bin/env bash
# Regression tests for the restore scripts' production-URI safety guard.
# These use fake local URIs and exit before invoking MongoDB tools.
set -Eeuo pipefail
cd "$(dirname "$0")"

assert_restore_refused() {
  local script="$1" guard_variable="$2"
  local fake_uri='mongodb://localhost:27017/chatify-production'
  local output
  local -a env_args=(
    "ARCHIVE=/tmp/chatify-nonexistent-test.archive.gz"
    "BACKUP_AGE_IDENTITY=/tmp/chatify-nonexistent-test.age"
    "RESTORE_TARGET_URI=$fake_uri"
    "RESTORE_TARGET_IS_NON_PRODUCTION=YES"
    "CONFIRM_RESTORE=YES"
  )
  if [[ "$guard_variable" == "PRODUCTION_MONGODB_URI" ]]; then
    env_args+=("PRODUCTION_MONGODB_URI=$fake_uri")
  else
    env_args+=("MONGODB_URI=$fake_uri")
  fi
  if output="$(env "${env_args[@]}" bash "$script" 2>&1)"; then
    echo "FAIL: $script accepted a target matching $guard_variable" >&2
    exit 1
  fi
  if ! grep -q 'Refusing restore:' <<<"$output"; then
    echo "FAIL: $script failed for an unexpected reason ($guard_variable)" >&2
    echo "$output" >&2
    exit 1
  fi
  if grep -q "$fake_uri" <<<"$output"; then
    echo "FAIL: $script exposed the MongoDB URI in its error output" >&2
    exit 1
  fi
  printf 'PASS: %s rejects target matching %s without exposing URI\n' "$script" "$guard_variable"
}

for restore_script in restore-mongodb.sh restore-mongodb-encrypted.sh; do
  assert_restore_refused "$restore_script" PRODUCTION_MONGODB_URI
  assert_restore_refused "$restore_script" MONGODB_URI
done
