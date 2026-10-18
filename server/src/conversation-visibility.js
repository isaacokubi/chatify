/**
 * Return a copy of the per-user hidden-conversation list without the user who
 * is actively sending a new message. A message must not unhide the conversation
 * for every other participant.
 */
export function unhideConversationForUser(hiddenFor, userId) {
  const currentUserId = String(userId);
  return Array.from(hiddenFor || []).filter(id => String(id) !== currentUserId);
}
