export function normalizeGroupDetails(value = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const title = typeof value.title === 'string' ? value.title.trim() : '';
  const description = typeof value.description === 'string' ? value.description.trim() : '';
  if (!title || title.length > 80 || description.length > 500) return null;
  return {title, description};
}

export function normalizeGroupMemberIds(values, ownerId, maximum = 50) {
  if (!Array.isArray(values) || values.length > maximum - 1) return null;
  const ids = [...new Set([String(ownerId), ...values.map(String)])];
  return ids.length > 1 && ids.length <= maximum ? ids : null;
}

export function canLeaveGroup(actorId, adminIds, participantIds) {
  const isOnlyAdmin = adminIds.map(String).includes(String(actorId)) &&
    adminIds.length === 1 && participantIds.map(String).length > 1;
  return !isOnlyAdmin;
}
