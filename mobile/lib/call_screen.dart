import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// One-to-one WebRTC call UI. Signaling is authenticated by Chatify's Socket.IO
/// server; production deployments should configure TURN for reliable cross-network calls.
class ChatifyCallScreen extends StatefulWidget {
  final io.Socket socket;
  final String callId;
  final String conversationId;
  final String peerId;
  final String peerName;
  final String callType;
  final bool isCaller;
  final Future<Map<String, dynamic>> Function() loadIceServers;

  const ChatifyCallScreen({
    super.key,
    required this.socket,
    required this.callId,
    required this.conversationId,
    required this.peerId,
    required this.peerName,
    required this.callType,
    required this.isCaller,
    required this.loadIceServers,
  });

  @override
  State<ChatifyCallScreen> createState() => _ChatifyCallScreenState();
}

class _ChatifyCallScreenState extends State<ChatifyCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  bool _muted = false;
  bool _cameraOff = false;
  bool _connected = false;
  bool _ended = false;
  bool _peerReady = false;
  bool _acceptedPending = false;
  String _status = 'Preparing call…';
  Timer? _durationTimer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    widget.socket.on('call:accept', _onAccepted);
    widget.socket.on('call:signal', _onSignal);
    widget.socket.on('call:reject', _onRejected);
    widget.socket.on('call:end', _onRemoteEnded);
    widget.socket.on('call:cancel', _onRemoteEnded);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      final audio = <String, dynamic>{'echoCancellation': true, 'noiseSuppression': true};
      final mediaConstraints = <String, dynamic>{
        'audio': audio,
        'video': widget.callType == 'video'
            ? <String, dynamic>{'facingMode': 'user', 'width': 640, 'height': 480, 'frameRate': 20}
            : false,
      };
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _localRenderer.srcObject = _localStream;
      Map<String, dynamic> iceConfig = {};
      try { iceConfig = await widget.loadIceServers(); } catch (_) {}
      final configuredServers = iceConfig['iceServers'];
      final iceServers = configuredServers is List && configuredServers.isNotEmpty
          ? configuredServers
          : <Map<String, dynamic>>[{'urls': 'stun:stun.l.google.com:19302'}];
      _peer = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': iceServers,
      });
      for (final track in _localStream!.getTracks()) {
        await _peer!.addTrack(track, _localStream!);
      }
      _peer!.onIceCandidate = (candidate) {
        if (candidate.candidate == null || _ended) return;
        widget.socket.emit('call:signal', {
          'callId': widget.callId,
          'signalType': 'ice',
          'signal': candidate.toMap(),
        });
      };
      _peer!.onTrack = (event) {
        if (event.streams.isNotEmpty && mounted) {
          setState(() {
            _remoteStream = event.streams.first;
            _remoteRenderer.srcObject = _remoteStream;
          });
        }
      };
      _peer!.onConnectionState = (state) {
        if (!mounted) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          setState(() { _connected = true; _status = 'Connected'; });
          _durationTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() => _seconds++);
          });
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          setState(() => _status = 'Connection failed. Check network or TURN configuration.');
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          setState(() => _status = 'Connection interrupted…');
        }
      };
      _peerReady = true;
      if (!mounted) return;
      setState(() => _status = widget.isCaller ? 'Calling…' : 'Connecting…');
      // The callee acknowledges only after media permissions and local setup succeed.
      if (!widget.isCaller) widget.socket.emit('call:accept', {'callId': widget.callId});
      if (widget.isCaller && _acceptedPending) {
        _acceptedPending = false;
        await _createOffer();
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not access camera or microphone. Check app permissions.');
      debugPrint('Chatify call initialization failed: $error');
    }
  }

  Future<void> _onAccepted(dynamic data) async {
    if (_ended || !widget.isCaller || data is! Map || data['callId'] != widget.callId) return;
    if (!_peerReady || _peer == null) {
      _acceptedPending = true;
      return;
    }
    await _createOffer();
  }

  Future<void> _createOffer() async {
    if (_ended || _peer == null) return;
    try {
      final offer = await _peer!.createOffer();
      await _peer!.setLocalDescription(offer);
      widget.socket.emit('call:signal', {
        'callId': widget.callId,
        'signalType': 'offer',
        'signal': {'sdp': offer.sdp, 'type': offer.type},
      });
      if (mounted) setState(() => _status = 'Ringing…');
    } catch (error) {
      debugPrint('Chatify call offer failed: $error');
      _finish(notifyPeer: true);
    }
  }

  Future<void> _onSignal(dynamic data) async {
    if (_ended || data is! Map || data['callId'] != widget.callId || data['signal'] is! Map) return;
    try {
      final signal = Map<String, dynamic>.from(data['signal'] as Map);
      switch (data['signalType']) {
        case 'offer':
          if (widget.isCaller) return;
          await _peer!.setRemoteDescription(RTCSessionDescription(signal['sdp']?.toString(), signal['type']?.toString()));
          final answer = await _peer!.createAnswer();
          await _peer!.setLocalDescription(answer);
          widget.socket.emit('call:signal', {
            'callId': widget.callId,
            'signalType': 'answer',
            'signal': {'sdp': answer.sdp, 'type': answer.type},
          });
          if (mounted) setState(() => _status = 'Connecting…');
          break;
        case 'answer':
          if (!widget.isCaller) return;
          await _peer!.setRemoteDescription(RTCSessionDescription(signal['sdp']?.toString(), signal['type']?.toString()));
          break;
        case 'ice':
          final candidate = signal['candidate']?.toString();
          if (candidate != null && candidate.isNotEmpty) {
            await _peer!.addCandidate(RTCIceCandidate(candidate, signal['sdpMid']?.toString(), (signal['sdpMLineIndex'] as num?)?.toInt()));
          }
          break;
      }
    } catch (error) {
      debugPrint('Chatify call signaling failed: $error');
      if (mounted) setState(() => _status = 'Could not establish the call.');
    }
  }

  void _onRejected(dynamic data) {
    if (data is Map && data['callId'] == widget.callId) {
      if (mounted) setState(() => _status = 'Call declined');
      Future<void>.delayed(const Duration(milliseconds: 900), () => _finish(notifyPeer: false));
    }
  }

  void _onRemoteEnded(dynamic data) {
    if (data is Map && data['callId'] == widget.callId) _finish(notifyPeer: false);
  }

  String get _duration {
    final minutes = (_seconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _finish({required bool notifyPeer}) async {
    if (_ended) return;
    _ended = true;
    if (notifyPeer) widget.socket.emit(widget.isCaller ? 'call:cancel' : 'call:end', {'callId': widget.callId});
    widget.socket.off('call:accept', _onAccepted);
    widget.socket.off('call:signal', _onSignal);
    widget.socket.off('call:reject', _onRejected);
    widget.socket.off('call:end', _onRemoteEnded);
    widget.socket.off('call:cancel', _onRemoteEnded);
    _durationTimer?.cancel();
    try { await _peer?.close(); } catch (_) {}
    try { await _localStream?.dispose(); } catch (_) {}
    try { await _remoteStream?.dispose(); } catch (_) {}
    try { await _localRenderer.dispose(); } catch (_) {}
    try { await _remoteRenderer.dispose(); } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    if (!_ended) {
      widget.socket.off('call:accept', _onAccepted);
      widget.socket.off('call:signal', _onSignal);
      widget.socket.off('call:reject', _onRejected);
      widget.socket.off('call:end', _onRemoteEnded);
      widget.socket.off('call:cancel', _onRemoteEnded);
      unawaited(_peer?.close() ?? Future<void>.value());
      unawaited(_localStream?.dispose() ?? Future<void>.value());
      unawaited(_remoteStream?.dispose() ?? Future<void>.value());
      unawaited(_localRenderer.dispose());
      unawaited(_remoteRenderer.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType == 'video';
    return Scaffold(
      backgroundColor: const Color(0xFF10131A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF10131A),
        foregroundColor: Colors.white,
        title: Text(isVideo ? 'Video call' : 'Voice call'),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _remoteStream != null && isVideo
                  ? RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                  : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircleAvatar(radius: 48, child: Icon(Icons.person, size: 52)),
                      const SizedBox(height: 16),
                      Text(widget.peerName, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text(_connected ? _duration : _status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                    ])),
            ),
            if (isVideo && _localStream != null)
              Positioned(right: 16, top: 16, width: 112, height: 160,
                child: ClipRRect(borderRadius: BorderRadius.circular(14), child: RTCVideoView(_localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover))),
            if (isVideo && _remoteStream != null)
              Positioned(left: 16, top: 16, child: Text(_connected ? _duration : _status, style: const TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 5, color: Colors.black)]))),
            Positioned(left: 0, right: 0, bottom: 28,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _control(Icons.mic_off, _muted ? 'Unmute' : 'Mute', () {
                  setState(() => _muted = !_muted);
                  for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) { track.enabled = !_muted; }
                }, active: _muted),
                if (isVideo) const SizedBox(width: 18),
                if (isVideo) _control(Icons.videocam_off, _cameraOff ? 'Camera on' : 'Camera off', () {
                  setState(() => _cameraOff = !_cameraOff);
                  for (final track in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) { track.enabled = !_cameraOff; }
                }, active: _cameraOff),
                if (isVideo) const SizedBox(width: 18),
                if (isVideo) _control(Icons.cameraswitch, 'Switch camera', () async {
                  final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
                  if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
                }),
                const SizedBox(width: 18),
                _control(Icons.call_end, 'End call', () => _finish(notifyPeer: true), active: true, danger: true),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _control(IconData icon, String label, VoidCallback onTap, {bool active = false, bool danger = false}) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      IconButton.filled(
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: danger ? Colors.red : active ? Colors.white24 : Colors.white12,
          foregroundColor: Colors.white,
          fixedSize: const Size(54, 54),
        ),
        icon: Icon(icon),
      ),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
    ]);
  }
}
