/** Validate mention targets against the conversation membership before storing or notifying. */
export function normalizeMentionIds(values, memberIds, senderId) {
  if (values === undefined || values === null) return [];
  if (!Array.isArray(values) || values.length > 49) return null;
  const members = new Set(memberIds.map(String));
  const sender = String(senderId);
  const result = [...new Set(values.map(value => String(value)))];
  if (result.some(id => !members.has(id) || id === sender)) return null;
  return result;
}

export function isMentionNotification(recipient, mentionIds) {
  return Array.isArray(mentionIds) &&
    mentionIds.some(id => String(id) === String(recipient?._id)) &&
    recipient?.notificationPreferences?.mentions !== false;
}
