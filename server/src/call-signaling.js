// Authenticated Socket.IO signaling for WebRTC calls. Media stays peer-to-peer;
// this module never receives or stores audio/video. The active-call map is process-local,
// so deployments with multiple API replicas should use a shared adapter or dedicated service.
const CALL_ID = /^[A-Za-z0-9_-]{8,80}$/;
const MAX_SIGNAL_BYTES = 16 * 1024;
const SIGNAL_TYPES = new Set(['offer', 'answer', 'ice']);

export function createCallSignaling({io, Conversation, User, isValidObjectId, now = () => Date.now()}) {
  const activeCalls = new Map();
  const cleanupTimer = setInterval(() => cleanupExpired(), 30_000);
  cleanupTimer.unref?.();

  async function getConversation(conversationId, userId) {
    if (typeof conversationId !== 'string' || !isValidObjectId(conversationId)) return null;
    return Conversation.findOne({_id: conversationId, participants: userId})
      .select('_id participants type').lean();
  }

  async function blockedEitherWay(callerId, calleeId) {
    const users = await User.find({_id: {$in: [callerId, calleeId]}, status: 'active'})
      .select('_id blockedUsers').lean();
    if (users.length !== 2) return true;
    const caller = users.find(user => String(user._id) === callerId);
    const callee = users.find(user => String(user._id) === calleeId);
    const contains = (list, id) => (list || []).some(value => String(value) === id);
    return !caller || !callee || contains(caller.blockedUsers, calleeId) || contains(callee.blockedUsers, callerId);
  }

  function emitToUser(userId, event, payload) {
    io.to('user:' + userId).emit(event, payload);
  }

  function register(socket, userId) {
    socket.on('call:invite', async payload => {
      try {
        cleanupExpired();
        if (!payload || typeof payload !== 'object' || !CALL_ID.test(payload.callId || '') ||
            !['audio', 'video'].includes(payload.callType)) {
          socket.emit('call:error', {callId: payload?.callId, message: 'Invalid call request.'});
          return;
        }
        const conversation = await getConversation(payload.conversationId, userId);
        const participants = (conversation?.participants || []).map(String);
        const calleeId = String(payload.calleeId || '');
        if (!conversation || !participants.includes(userId) || !participants.includes(calleeId) ||
            calleeId === userId || participants.length !== 2) {
          socket.emit('call:error', {callId: payload.callId, message: 'Call recipient is not an authorized conversation participant.'});
          return;
        }
        if (activeCalls.has(payload.callId)) {
          socket.emit('call:error', {callId: payload.callId, message: 'Call identifier is already in use.'});
          return;
        }
        if (await blockedEitherWay(userId, calleeId)) {
          socket.emit('call:error', {callId: payload.callId, message: 'This user cannot be called.'});
          return;
        }
        const call = {callId: payload.callId, conversationId: String(conversation._id), callerId: userId,
          calleeId, callType: payload.callType, createdAt: now(), acceptedAt: null};
        activeCalls.set(call.callId, call);
        emitToUser(calleeId, 'call:incoming', call);
        socket.emit('call:ringing', {callId: call.callId, calleeId});
      } catch {
        socket.emit('call:error', {callId: payload?.callId, message: 'Could not start call.'});
      }
    });

    for (const event of ['call:accept', 'call:reject', 'call:cancel', 'call:end']) {
      socket.on(event, payload => {
        const callId = typeof payload?.callId === 'string' ? payload.callId : '';
        const call = activeCalls.get(callId);
        if (!call || ![call.callerId, call.calleeId].includes(userId)) return;
        if (event === 'call:accept' && userId !== call.calleeId) return;
        if (event === 'call:cancel' && userId !== call.callerId) return;
        const targetId = userId === call.callerId ? call.calleeId : call.callerId;
        if (event === 'call:accept') call.acceptedAt = now();
        emitToUser(targetId, event, {callId, byUserId: userId});
        socket.emit(event, {callId, byUserId: userId});
        if (event !== 'call:accept') activeCalls.delete(callId);
      });
    }

    socket.on('call:signal', payload => {
      const callId = typeof payload?.callId === 'string' ? payload.callId : '';
      const call = activeCalls.get(callId);
      if (!call || ![call.callerId, call.calleeId].includes(userId) ||
          !SIGNAL_TYPES.has(payload?.signalType)) return;
      const encoded = JSON.stringify(payload.signal ?? null);
      if (Buffer.byteLength(encoded, 'utf8') > MAX_SIGNAL_BYTES) return;
      if (!payload.signal || typeof payload.signal !== 'object' || Array.isArray(payload.signal)) return;
      const targetId = userId === call.callerId ? call.calleeId : call.callerId;
      emitToUser(targetId, 'call:signal', {callId, signalType: payload.signalType, signal: payload.signal, fromUserId: userId});
    });

    socket.on('disconnect', () => {
      for (const [callId, call] of activeCalls) {
        if (call.callerId === userId || call.calleeId === userId) {
          const targetId = userId === call.callerId ? call.calleeId : call.callerId;
          emitToUser(targetId, 'call:end', {callId, byUserId: userId, reason: 'disconnected'});
          activeCalls.delete(callId);
        }
      }
    });
  }

  function cleanupExpired(maxAgeMs = 2 * 60 * 60 * 1000) {
    const current = now();
    for (const [callId, call] of activeCalls) {
      const timeoutMs = call.acceptedAt ? maxAgeMs : 60_000;
      if (current - call.createdAt < timeoutMs) continue;
      const reason = call.acceptedAt ? 'expired' : 'no-answer';
      emitToUser(call.callerId, 'call:end', {callId, reason});
      emitToUser(call.calleeId, 'call:end', {callId, reason});
      activeCalls.delete(callId);
    }
  }

  return {register, cleanupExpired, activeCalls, stop: () => clearInterval(cleanupTimer)};
}
