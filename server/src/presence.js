/** In-process authenticated socket sessions, keyed by account and socket ID. */
export function createPresenceTracker() {
  const sessionsByUser = new Map();

  return {
    connect(userId, socketId) {
      const id = String(userId);
      const sessions = sessionsByUser.get(id) ?? new Set();
      const wasOffline = sessions.size === 0;
      sessions.add(String(socketId));
      sessionsByUser.set(id, sessions);
      return wasOffline;
    },
    disconnect(userId, socketId) {
      const id = String(userId);
      const sessions = sessionsByUser.get(id);
      if (!sessions || !sessions.delete(String(socketId))) return false;
      if (sessions.size > 0) return false;
      sessionsByUser.delete(id);
      return true;
    },
    isOnline(userId) {
      return (sessionsByUser.get(String(userId))?.size ?? 0) > 0;
    },
    onlineUserIds() {
      return [...sessionsByUser.keys()];
    },
  };
}
