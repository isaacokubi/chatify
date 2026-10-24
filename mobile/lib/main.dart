// CHATIFY MOBILE APP — READING GUIDE
// This file contains the Flutter screens and much of the client-side state management.
// Api sends authenticated HTTP requests to the Express server; AppState stores session,
// conversations, contacts, memories, notifications and payment state; the widgets below
// turn that data into the welcome, sign-in, chat, memory, payment and profile screens.
// Real-time chat updates arrive through Socket.IO. Keep server-side authorization and
// payment decisions on the server; a mobile-side check is never a security boundary.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:file_saver/file_saver.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'security/chatify_e2ee.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

String _conversationParticipantId(Map participant) {
  final nested = participant['user'];
  final nestedId = nested is Map ? (nested['_id'] ?? nested['id']) : null;
  return (participant['_id'] ??
          participant['id'] ??
          participant['userId'] ??
          nestedId ??
          '')
      .toString();
}

String _authenticatedUserId(Map<String, dynamic>? user) =>
    (user?['id'] ?? user?['_id'] ?? user?['userId'] ?? '').toString();

List<Map<String, dynamic>> eligibleMentionParticipants(
  Iterable<dynamic> rawParticipants, {
  required String currentUserId,
  String query = '',
  int limit = 6,
}) {
  String foldSearchText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[áàâäãå]'), 'a')
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[íìîï]'), 'i')
      .replaceAll(RegExp('[óòôöõ]'), 'o')
      .replaceAll(RegExp('[úùûü]'), 'u')
      .replaceAll('ý', 'y')
      .replaceAll('ñ', 'n')
      .replaceAll('ç', 'c');
  final normalizedQuery = foldSearchText(query.trim());
  final candidates = <Map<String, dynamic>>[];
  final seenIds = <String>{};
  for (final raw in rawParticipants) {
    if (raw is! Map) continue;
    final participant = Map<String, dynamic>.from(raw);
    final id = _conversationParticipantId(participant);
    final name = participant['name']?.toString().trim() ?? '';
    if (id.isEmpty ||
        id == currentUserId ||
        name.isEmpty ||
        !seenIds.add(id) ||
        !foldSearchText(name).contains(normalizedQuery)) {
      continue;
    }
    candidates.add(participant);
    if (candidates.length >= limit) break;
  }
  return candidates;
}

String _mentionDisambiguator(
  Map<String, dynamic> participant,
  Iterable<dynamic> participants,
) {
  final name = participant['name']?.toString().trim().toLowerCase() ?? '';
  final duplicates = participants.where((raw) {
    if (raw is! Map) return false;
    return raw['name']?.toString().trim().toLowerCase() == name;
  }).length;
  if (duplicates < 2) return '';
  final contact = (participant['email'] ?? participant['phone'])?.toString();
  if (contact != null && contact.isNotEmpty) return contact;
  final id = _conversationParticipantId(participant);
  return id.length > 6 ? 'ID …${id.substring(id.length - 6)}' : 'ID $id';
}

// Swipe gestures are reserved for compact Android/iOS layouts. Laptop and desktop
// users receive explicit delete buttons that work with a mouse or trackpad.
bool _useSwipeToDelete(BuildContext context) {
  final platform = Theme.of(context).platform;
  return (platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS) &&
      MediaQuery.sizeOf(context).shortestSide < 600;
}

class _SparkVideoThumbnail extends StatefulWidget {
  final String url;
  final VoidCallback? onTap;
  const _SparkVideoThumbnail({required this.url, this.onTap});

  @override
  State<_SparkVideoThumbnail> createState() => _SparkVideoThumbnailState();
}

class _SparkVideoThumbnailState extends State<_SparkVideoThumbnail> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller = controller;
    controller.initialize().then((_) {
      if (mounted) setState(() {});
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: const Center(child: Icon(Icons.videocam_outlined)),
      );
    }
    final ratio = controller.value.aspectRatio;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: ratio > 0 ? 50 * ratio : 50,
          height: 50,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

class _SparkGlitter extends StatefulWidget {
  final Color color;
  final bool animate;

  const _SparkGlitter({super.key, required this.color, required this.animate});

  @override
  State<_SparkGlitter> createState() => _SparkGlitterState();
}

class _SparkGlitterState extends State<_SparkGlitter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _controller.repeat();
    } else {
      _controller.value = .25;
    }
  }

  @override
  void didUpdateWidget(covariant _SparkGlitter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate == oldWidget.animate) return;
    if (widget.animate) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = .25;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _SparkGlitterPainter(
          progress: _controller.value,
          color: widget.color,
        ),
        child: const SizedBox.expand(),
      );
}

class _SparkGlitterPainter extends CustomPainter {
  final double progress;
  final Color color;

  static const _stars = <(double, double, double, double)>[
    (.08, .12, 5, .0),
    (.34, .05, 3, .4),
    (.83, .08, 5, .2),
    (.96, .31, 3, .7),
    (.93, .79, 5, .3),
    (.72, .96, 3, .8),
    (.26, .95, 5, .5),
    (.05, .71, 3, .1),
    (.04, .42, 4, .6),
  ];

  const _SparkGlitterPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    for (final (x, y, radius, phase) in _stars) {
      final twinkle =
          .25 + .5 * (0.5 + .5 * math.sin((progress + phase) * math.pi * 2));
      final paint = Paint()..color = color.withValues(alpha: twinkle);
      final center = Offset(size.width * x, size.height * y);
      final path = Path()
        ..moveTo(center.dx, center.dy - radius)
        ..lineTo(center.dx + radius * .24, center.dy - radius * .24)
        ..lineTo(center.dx + radius, center.dy)
        ..lineTo(center.dx + radius * .24, center.dy + radius * .24)
        ..lineTo(center.dx, center.dy + radius)
        ..lineTo(center.dx - radius * .24, center.dy + radius * .24)
        ..lineTo(center.dx - radius, center.dy)
        ..lineTo(center.dx - radius * .24, center.dy - radius * .24)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkGlitterPainter oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}

class _SparkStatusViewer extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final int initialIndex;
  final ValueChanged<Map<String, dynamic>> onViewed;
  final ValueChanged<Map<String, dynamic>> onDelete;

  const _SparkStatusViewer({
    required this.items,
    this.initialIndex = 0,
    required this.onViewed,
    required this.onDelete,
  });

  @override
  State<_SparkStatusViewer> createState() => _SparkStatusViewerState();
}

class _SparkStatusViewerState extends State<_SparkStatusViewer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..addStatusListener(_onProgressStatus);
  VideoPlayerController? _video;
  int _index = 0;
  bool _paused = false;
  bool _mediaError = false;
  bool _initialLoadStarted = false;
  int _loadGeneration = 0;
  int? _loadingIndex;
  bool _playbackActionPending = false;
  bool _longPressStarted = false;
  bool _longPressPausedVideo = false;
  bool _closing = false;
  final Map<VideoPlayerController, Future<void>> _controllerDisposals = {};

  Map<String, dynamic> get _item => widget.items[_index];



  @override
  void initState() {
    super.initState();
    _index = widget.items.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.items.length - 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery is available here, and the guard prevents rebuilds from
    // restarting playback or creating duplicate video controllers.
    if (_initialLoadStarted) return;
    _initialLoadStarted = true;
    unawaited(_loadItem());
  }

  void _onProgressStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_paused) _advance(1);
  }

  Future<void> _loadItem() async {
    // A dialog route can briefly build without an inherited MediaQuery in
    // widget tests or unusual embedding contexts. Treat that as animations
    // enabled instead of aborting media loading before the video controller is
    // created.
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final itemIndex = _index;
    if (_loadingIndex == itemIndex) return;
    final generation = ++_loadGeneration;
    _loadingIndex = itemIndex;
    _progress.stop();
    _progress.value = 0;
    // Capture the item and detach the previous controller before awaiting.
    // Awaiting a nullable dispose future even when there is no controller
    // yields before the first controller is created, which can leave a newly
    // opened viewer without media during short route transitions.
    final item = _item;
    final previousVideo = _video;
    _video = null;
    _mediaError = false;
    _paused = false;
    if (previousVideo != null) {
      await _releaseVideo(previousVideo);
      if (!mounted || generation != _loadGeneration || itemIndex != _index) {
        return;
      }
    }
    if (!mounted || generation != _loadGeneration || itemIndex != _index) {
      return;
    }
    widget.onViewed(item);
    if (item['mediaType'] == 'video') {
      final url = item['mediaUrl']?.toString() ?? '';
      if (!url.startsWith('https://')) {
        _loadingIndex = null;
        if (mounted) setState(() => _mediaError = true);
        return;
      }
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      _video = controller;
      try {
        await controller.initialize();
        if (!mounted ||
            generation != _loadGeneration ||
            itemIndex != _index ||
            _video != controller) {
          await _releaseVideo(controller);
          return;
        }
        controller.addListener(_onVideoUpdate);
        setState(() {});
        await _playVideo(controller);
      } catch (_) {
        if (mounted && _video == controller) {
          setState(() => _mediaError = true);
        }
      } finally {
        if (generation == _loadGeneration && _loadingIndex == itemIndex) {
          _loadingIndex = null;
        }
      }
      return;
    }
    _loadingIndex = null;
    if (!disableAnimations) _progress.forward();
  }

  Future<void> _playVideo(VideoPlayerController controller) async {
    if (!controller.value.isInitialized || controller.value.isPlaying) return;
    try {
      await controller.play();
    } catch (_) {
      // Browser autoplay policies may require the user's direct gesture.
      if (mounted && _video == controller) setState(() {});
    }
  }

  Future<void> _pauseVideo(VideoPlayerController controller) async {
    if (!controller.value.isInitialized || !controller.value.isPlaying) return;
    try {
      await controller.pause();
    } catch (_) {
      if (mounted && _video == controller) setState(() {});
    }
  }

  Future<void> _releaseVideo(VideoPlayerController controller) =>
      _controllerDisposals.putIfAbsent(controller, () {
        controller.removeListener(_onVideoUpdate);
        return controller.dispose();
      });

  void _onVideoUpdate() {
    final controller = _video;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.hasError) {
      if (mounted) setState(() => _mediaError = true);
    } else if (controller.value.position >= controller.value.duration &&
        controller.value.duration > Duration.zero) {
      _advance(1);
    } else if (mounted) {
      setState(() {});
    }
  }

  void _advance(int amount) {
    if (!mounted || _closing) return;
    final next = _index + amount;
    if (next < 0) return;
    if (next >= widget.items.length) {
      unawaited(_closeViewer());
      return;
    }
    setState(() => _index = next);
    _loadItem();
  }

  Future<void> _closeViewer() async {
    if (_closing) return;
    _closing = true;
    ++_loadGeneration;
    final controller = _video;
    _video = null;
    final release = controller == null ? null : _releaseVideo(controller);
    if (mounted) Navigator.of(context).pop();
    if (release != null) await release;
  }

  void _togglePause() {
    if (_playbackActionPending) return;
    final video = _video;
    if (video != null && video.value.isInitialized) {
      _playbackActionPending = true;
      if (video.value.isPlaying && !_paused) {
        setState(() => _paused = true);
        unawaited(_pauseVideo(video).whenComplete(() {
          _playbackActionPending = false;
        }));
      } else {
        setState(() => _paused = false);
        unawaited(_playVideo(video).whenComplete(() {
          _playbackActionPending = false;
        }));
      }
    } else if (_paused) {
      setState(() => _paused = false);
      _progress.forward();
    } else {
      _progress.stop();
      setState(() => _paused = true);
    }
  }

  void _onContentTap() {
    if (_item['mediaType'] == 'video') {
      if (_mediaError) {
        _loadItem();
      } else {
        _togglePause();
      }
      return;
    }
    _advance(1);
  }

  double _currentProgress() {
    final video = _video;
    if (video != null &&
        video.value.isInitialized &&
        video.value.duration > Duration.zero) {
      return (video.value.position.inMilliseconds /
              video.value.duration.inMilliseconds)
          .clamp(0.0, 1.0);
    }
    return _progress.value;
  }

  Future<void> _retryVideo() async {
    final controller = _video;
    if (controller == null) return;
    try {
      await _playVideo(controller);
      if (mounted) setState(() => _mediaError = false);
    } catch (_) {
      if (mounted) setState(() => _mediaError = true);
    }
  }

  Widget _sparkContent() {
    final type = _item['mediaType']?.toString();
    final url = _item['mediaUrl']?.toString() ?? '';
    if (type == 'image') {
      if (url.startsWith('data:image/')) {
        return Image.memory(
          base64Decode(url.split(',').last),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _mediaUnavailable(),
        );
      }
      if (url.startsWith('https://')) {
        return Image.network(
          url,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : const Center(child: CircularProgressIndicator()),
          errorBuilder: (_, __, ___) => _mediaUnavailable(),
        );
      }
      return _mediaUnavailable();
    }
    if (type == 'video') {
      final controller = _video;
      if (_mediaError) return _mediaUnavailable(video: true);
      if (controller == null || !controller.value.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }
      if (!controller.value.isPlaying && !_paused) {
        return Center(
          child: IconButton.filled(
            tooltip: 'Play Spark video',
            onPressed: _retryVideo,
            icon: const Icon(Icons.play_arrow),
          ),
        );
      }
      return Center(
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio > 0
              ? controller.value.aspectRatio
              : 16 / 9,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(controller),
              if (_paused || !controller.value.isPlaying)
                IconButton.filled(
                  tooltip: 'Resume Spark video',
                  onPressed: _togglePause,
                  icon: const Icon(Icons.play_arrow),
                ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          _item['text']?.toString() ?? '',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _mediaUnavailable({bool video = false}) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                video
                    ? Icons.videocam_off_outlined
                    : Icons.broken_image_outlined,
                color: Colors.white70,
                size: 42),
            const SizedBox(height: 10),
            const Text('This Spark media is unavailable.',
                style: TextStyle(color: Colors.white70)),
            if (video)
              TextButton.icon(
                onPressed: () => setState(() {
                  _mediaError = false;
                  _loadItem();
                }),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
          ],
        ),
      );

  @override
  void dispose() {
    ++_loadGeneration;
    _progress.dispose();
    final controller = _video;
    _video = null;
    if (controller != null) unawaited(_releaseVideo(controller));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final duration = DateTime.tryParse(_item['createdAt']?.toString() ?? '');
    final age = duration == null
        ? 'Recently'
        : DateFormat.yMMMd().add_jm().format(duration.toLocal());
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: GestureDetector(
          onLongPressStart: (_) {
            _longPressStarted = true;
            _longPressPausedVideo = !_paused;
            if (_longPressPausedVideo) _togglePause();
          },
          onLongPressEnd: (_) {
            if (_longPressStarted) {
              _longPressStarted = false;
              if (_longPressPausedVideo && _paused) _togglePause();
              _longPressPausedVideo = false;
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(child: _sparkContent()),
              Positioned.fill(
                child: Row(
                  children: [
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width * .24,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => _advance(-1),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onContentTap,
                        child: const SizedBox.expand(),
                      ),
                    ),
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width * .24,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => _advance(1),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
              if (!MediaQuery.disableAnimationsOf(context))
                Positioned.fill(
                  child: IgnorePointer(
                    child: _SparkGlitter(
                      key: const ValueKey('spark-glitter-overlay'),
                      color: switch (_item['mediaType']) {
                        'image' => const Color(0xFFB8A1FF),
                        'video' => const Color(0xFF7EDBD0),
                        _ => const Color(0xFFF2C66D),
                      },
                      animate: true,
                    ),
                  ),
                ),
              Positioned(
                top: 8,
                left: 10,
                right: 10,
                child: Row(
                  children: [
                    for (var i = 0; i < widget.items.length; i++) ...[
                      if (i > 0) const SizedBox(width: 3),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            minHeight: 3,
                            value: i < _index
                                ? 1
                                : i > _index
                                    ? 0
                                    : _currentProgress(),
                            backgroundColor: Colors.white30,
                            valueColor:
                                const AlwaysStoppedAnimation(Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Positioned(
                top: 24,
                left: 12,
                right: 8,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _item['authorName']?.toString() ?? 'Chatify user',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700),
                          ),
                          Text(age,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                    if (_item['isMine'] == true)
                      IconButton(
                        tooltip: 'Delete Spark',
                        color: Colors.white,
                        onPressed: () => widget.onDelete(_item),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    IconButton(
                      tooltip: 'Close Spark viewer',
                      color: Colors.white,
                      onPressed: _closeViewer,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (_item['text']?.toString().isNotEmpty == true &&
                  _item['mediaType'] != null)
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 38,
                  child: Text(
                    _item['text'].toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        shadows: [Shadow(blurRadius: 8, color: Colors.black)]),
                  ),
                ),
              if (video != null && video.value.isInitialized)
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 8,
                  child: VideoProgressIndicator(video,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                          playedColor: Colors.white,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24)),
                ),
              if (video != null && video.value.isInitialized && _paused)
                Center(
                  child: IconButton.filled(
                    tooltip: 'Resume Spark video',
                    onPressed: _togglePause,
                    icon: const Icon(Icons.play_arrow),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateSparkTextDialog extends StatefulWidget {
  const _CreateSparkTextDialog();

  @override
  State<_CreateSparkTextDialog> createState() => _CreateSparkTextDialogState();
}

class _CreateSparkTextDialogState extends State<_CreateSparkTextDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Create a Spark'),
        content: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 500,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'What would you like to share?',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _controller.text.trim()),
            child: const Text('Share Spark'),
          ),
        ],
      );
}

// School workspace uses the shared authenticated API and URL launcher.

// Displays remote images from a small persistent cache first, so previously
// viewed profile, catalogue and attachment images remain available offline.
// Cache only small images to avoid exhausting browser local storage on web.
class OfflineCachedImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  const OfflineCachedImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
  });

  @override
  State<OfflineCachedImage> createState() => _OfflineCachedImageState();
}

class _OfflineCachedImageState extends State<OfflineCachedImage> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _failed = false;

  String get _key {
    var hash = 2166136261;
    for (final unit in widget.url.codeUnits) {
      hash = ((hash ^ unit) * 16777619) & 0xffffffff;
    }
    return 'chatify_image_cache_v1_${hash.toRadixString(16)}';
  }

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant OfflineCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _loading = true;
      _failed = false;
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    // Paint the last downloaded copy immediately before attempting a refresh.
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 2));
      final encoded = prefs.getString(_key);
      if (encoded != null && encoded.isNotEmpty) {
        final cached = base64Decode(encoded);
        if (mounted) setState(() => _bytes = cached);
      }
    } catch (_) {
      // Cache is optional; continue to the network without blocking the UI.
    }

    try {
      final uri = Uri.tryParse(widget.url);
      if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
        throw const FormatException('Unsupported image URL');
      }
      final response = await http.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Image request failed');
      }
      final bytes = response.bodyBytes;
      // Keep individual entries modest: base64 expands data and web storage is limited.
      if (bytes.isNotEmpty && bytes.length <= 350 * 1024) {
        try {
          final prefs = await SharedPreferences.getInstance()
              .timeout(const Duration(seconds: 2));
          await prefs.setString(_key, base64Encode(bytes));
        } catch (_) {
          // A storage quota or platform plugin issue must not hide the image.
        }
      }
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = _bytes == null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: widget.errorBuilder,
      );
    }
    if (_loading) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_failed && widget.errorBuilder != null) {
      return widget.errorBuilder!(
          context, StateError('Image unavailable'), StackTrace.current);
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: const Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
}

// Represents a readable API failure so screens can show a useful message instead of raw transport errors.
// Builds a portable PDF receipt from a confirmed school-fee record.
// The authenticated receipt endpoint is checked before this function is called.
String schoolPaymentMethodLabel(dynamic value) {
  final raw = value?.toString().trim().toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
  return switch (raw) {
    'mpesa_paybill' || 'paybill' || 'mpesa' || 'm_pesa_paybill' => 'M-Pesa Paybill',
    'mpesa_till' || 'till' || 'buy_goods' || 'm_pesa_till' => 'M-Pesa Till',
    'mpesa_send_money' || 'send_money' || 'm_pesa_send_money' => 'M-Pesa Send Money',
    'bank' || 'bank_transfer' || 'banktransfer' => 'Bank transfer',
    'stk' || 'stk_push' || 'mpesa_stk' || 'mpesa_stk_push' || 'm_pesa_(stk_push)' || 'daraja' => 'M-Pesa (STK Push)',
    _ => '—',
  };
}

String schoolPaymentMethodForRecord(Map<String, dynamic> payment, {dynamic configuredFallback}) {
  for (final candidate in [
    payment['paymentMethod'], payment['method'], payment['paymentMethodLabel'],
    payment['paymentDestination'] is Map ? payment['paymentDestination']['method'] : null,
  ]) {
    if (candidate == null || candidate.toString().trim().isEmpty) continue;
    final label = schoolPaymentMethodLabel(candidate);
    if (label != '—') return label;
  }
  final fallback = schoolPaymentMethodLabel(configuredFallback);
  return fallback == '—' ? 'Not recorded' : fallback;
}

Size? _schoolReceiptJpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var offset = 2;
  const sof = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF};
  while (offset + 8 < bytes.length) {
    if (bytes[offset] != 0xFF) { offset++; continue; }
    final marker = bytes[offset + 1];
    offset += 2;
    if (marker == 0xD8 || marker == 0xD9 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
    if (offset + 4 > bytes.length) return null;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) return null;
    if (sof.contains(marker) && length >= 7) {
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      if (width > 0 && height > 0) return Size(width.toDouble(), height.toDouble());
      return null;
    }
    offset += length;
  }
  return null;
}

Uint8List _buildSchoolFeeReceiptPdf(Map<String, dynamic> payment) {
  String safe(dynamic value) => (value ?? '')
      .toString()
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '?')
      .replaceAll(r'\', r'\\')
      .replaceAll('(', r'\(')
      .replaceAll(')', r'\)');

  final reference =
      payment['paymentReference'] ?? payment['reference'] ?? 'N/A';
  final amount = payment['amount'] ?? payment['amountPaid'] ?? 'N/A';
  final school = [
    payment['schoolName'],
    payment['school'] is Map ? payment['school']['name'] : null,
    payment['schoolDisplayName'],
  ].map((value) => (value ?? '').toString().trim())
      .firstWhere((value) => value.isNotEmpty, orElse: () => 'School name unavailable');
  final paidAt = payment['paidAt'] ??
      payment['confirmedAt'] ??
      payment['updatedAt'] ??
      payment['createdAt'] ??
      DateTime.now().toIso8601String();
  final method = schoolPaymentMethodForRecord(payment, configuredFallback: payment['configuredPaymentMethod']);
  final formattedAmount = double.tryParse(amount.toString())?.toStringAsFixed(2) ?? amount.toString();
  final stampDataUrl = payment['receiptStampDataUrl']?.toString() ?? '';
  Uint8List? stampBytes;
  if (stampDataUrl.startsWith('data:image/jpeg;base64,')) {
    try { stampBytes = base64Decode(stampDataUrl.substring(stampDataUrl.indexOf(',') + 1)); } catch (_) {}
  }
  final stampSize = stampBytes == null ? null : _schoolReceiptJpegDimensions(stampBytes);
  final lines = <String>[
    'School: ' + safe(school),
    'Receipt number: ' + safe(payment['mpesaReceipt'] ?? reference),
    'Chatify payment reference: ' + safe(reference),
    'Student: ' + safe(payment['studentName'] ?? 'Not provided'),
    'Term / fee period: ' + safe(payment['term'] ?? 'Not provided'),
    'Amount received: KES ' + safe(formattedAmount),
    'Payment status: ' + safe(payment['status'] ?? 'CONFIRMED'),
    'Date confirmed: ' + safe(paidAt),
    'Payment method: ' + safe(method),
    'Total term charge: KES ' + safe(payment['totalFeeDue'] ?? payment['chargeAmount'] ?? 'Refer to fee statement'),
    'Remaining balance: KES ' + safe(payment['outstandingBalance'] ?? payment['balance'] ?? 'Refer to fee statement'),
  ];

  final wrapped = <String>[];
  for (final line in lines) {
    if (line.isEmpty) {
      wrapped.add('');
      continue;
    }
    var remaining = line;
    while (remaining.length > 78) {
      var cut = remaining.lastIndexOf(' ', 78);
      if (cut < 1) cut = 78;
      wrapped.add(remaining.substring(0, cut));
      remaining = remaining.substring(cut).trimLeft();
    }
    wrapped.add(remaining);
  }

  final content = StringBuffer()
    // Strong outer frame and branded header.
    ..write('0.07 0.19 0.34 RG\n3 w\n28 28 539 786 re S\n')
    ..write('0.07 0.19 0.34 rg\n30 750 535 92 re f\n')
    ..write('0.10 0.63 0.55 rg\n30 742 535 8 re f\n')
    ..write('BT\n/F2 18 Tf\n1 1 1 rg\n50 805 Td\n(' + safe('OFFICIAL SCHOOL FEE RECEIPT') + ') Tj\nET\n')
    ..write('BT\n/F2 11 Tf\n0.88 0.95 1 rg\n50 781 Td\n(' + safe(school) + ') Tj\nET\n')
    // Amount card with a thick teal rule.
    ..write('0.91 0.96 1 rg\n40 670 515 55 re f\n')
    ..write('0.10 0.63 0.55 RG\n3 w\n40 670 515 55 re S\n')
    ..write('BT\n/F2 9 Tf\n0.20 0.34 0.47 rg\n55 706 Td\n(' + safe('AMOUNT RECEIVED') + ') Tj\nET\n')
    ..write('BT\n/F2 21 Tf\n0.07 0.19 0.34 rg\n55 682 Td\n(' + safe('KES ' + formattedAmount) + ') Tj\nET\n')
    ..write('0.07 0.19 0.34 RG\n2 w\n40 655 m\n555 655 l\nS\n');
  var detailY = 632.0;
  var detailIndex = 0;
  for (final line in wrapped.skip(1)) {
    final isMethod = line.toLowerCase().startsWith('payment method:');
    final isBalance = line.toLowerCase().startsWith('remaining balance:');
    final rowY = detailY - 7;
    if (isMethod) {
      content.write('0.87 0.97 0.93 rg\n40 ' + (rowY - 5).toStringAsFixed(2) + ' 515 21 re f\n');
      content.write('0.10 0.63 0.55 RG\n1.5 w\n40 ' + (rowY - 5).toStringAsFixed(2) + ' 515 21 re S\n');
    } else if (isBalance) {
      content.write('1 0.96 0.86 rg\n40 ' + (rowY - 5).toStringAsFixed(2) + ' 515 21 re f\n');
      content.write('0.80 0.48 0.06 RG\n1.5 w\n40 ' + (rowY - 5).toStringAsFixed(2) + ' 515 21 re S\n');
    } else if (detailIndex.isEven) {
      content.write('0.95 0.97 0.99 rg\n40 ' + (rowY - 5).toStringAsFixed(2) + ' 515 21 re f\n');
    }
    content.write('BT\n' + (isMethod || isBalance ? '/F2 10 Tf\n' : '/F1 10 Tf\n') +
      (isMethod ? '0.04 0.40 0.31 rg\n' : isBalance ? '0.55 0.31 0.02 rg\n' : '0.10 0.17 0.25 rg\n') +
      '50 ' + detailY.toStringAsFixed(2) + ' Td\n(' + safe(line) + ') Tj\nET\n');
    detailY -= 22;
    detailIndex++;
  }
  content
    ..write('0.07 0.19 0.34 RG\n2 w\n40 88 m\n555 88 l\nS\n')
    ..write('BT\n/F1 8 Tf\n0.25 0.34 0.43 rg\n50 68 Td\n(' + safe('Please retain this receipt. Quote the Chatify reference for any enquiry.') + ') Tj\nET\n');
  if (stampBytes != null && stampSize != null) {
    final scale = math.min(120 / stampSize.width, 66 / stampSize.height);
    final width = stampSize.width * scale;
    final height = stampSize.height * scale;
    content.write('q\n' + width.toStringAsFixed(2) + ' 0 0 ' + height.toStringAsFixed(2) + ' 425 100 cm\n/Stamp Do\nQ\n');
  }
  final stream = content.toString();
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R /F2 6 0 R >>' + (stampBytes != null && stampSize != null ? ' /XObject << /Stamp 7 0 R >>' : '') + ' >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    '<< /Length ' + utf8.encode(stream).length.toString() + ' >>\nstream\n' + stream + 'endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>',
  ];
  if (stampBytes != null && stampSize != null) {
    final hex = stampBytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    objects.add('<< /Type /XObject /Subtype /Image /Width ' + stampSize.width.toInt().toString() + ' /Height ' + stampSize.height.toInt().toString() + ' /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter [/ASCIIHexDecode /DCTDecode] /Length ' + (hex.length + 1).toString() + ' >>\nstream\n' + hex + '>\nendstream');
  }
  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(utf8.encode(output.toString()).length);
    output.write((i + 1).toString() + ' 0 obj\n' + objects[i] + '\nendobj\n');
  }
  final xrefOffset = utf8.encode(output.toString()).length;
  output.write(
      'xref\n0 ' + (objects.length + 1).toString() + '\n0000000000 65535 f \n');
  for (var i = 1; i < offsets.length; i++) {
    output.write(offsets[i].toString().padLeft(10, '0') + ' 00000 n \n');
  }
  output.write('trailer\n<< /Size ' +
      (objects.length + 1).toString() +
      ' /Root 1 0 R >>\nstartxref\n' +
      xrefOffset.toString() +
      '\n%%EOF\n');
  return Uint8List.fromList(utf8.encode(output.toString()));
}

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);
  @override
  String toString() => message;
}

// Central HTTP client: adds the API base URL and authentication token, sends requests, and parses responses.
class Api {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  final http.Client client;
  final DateTime Function() _now;
  Api({http.Client? client, DateTime Function()? now})
      : client = client ?? http.Client(),
        _now = now ?? DateTime.now;
  static const Duration _cachedResponseLifetime = Duration(days: 7);
  String get base => const String.fromEnvironment('CHATIFY_API',
      defaultValue: 'https://chatify-api-c1eh.onrender.com');
  String? token;
  // Cached GET responses let a previously signed-in user read the last synced
  // conversations and account data while the API or internet is unavailable.
  // The cache scope is derived from the authenticated account, never shared
  // between different signed-in users on the same device.
  bool lastResponseFromCache = false;
  bool offlineDataMode = false;
  String get accountScope => _cacheScope();
  // Coalesce simultaneous identical GETs (for example multiple widgets loading
  // the same profile/conversation) into one network request.
  final Map<String, Future<Map<String, dynamic>>> _inFlightGets = {};
  // Secure storage exposes whole-value writes, so serialize read/modify/write
  // operations for each account and conversation to avoid losing concurrent
  // queued messages.
  final Map<String, Future<void>> _outboxOperations = {};

  Future<T> _withOutboxLock<T>(
      String key, Future<T> Function() operation) async {
    final previous = _outboxOperations[key] ?? Future<void>.value();
    final release = Completer<void>();
    final current = previous.then((_) => release.future);
    _outboxOperations[key] = current;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
      if (identical(_outboxOperations[key], current)) {
        _outboxOperations.remove(key);
      }
    }
  }

  String _stableCacheHash(String value) {
    var hash = 2166136261;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 16777619) & 0xffffffff;
    }
    return hash.toRadixString(16);
  }

  String _cacheScope() {
    final currentToken = token;
    if (currentToken == null || currentToken.isEmpty) return 'anonymous';
    final parts = currentToken.split('.');
    if (parts.length == 3) {
      try {
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        if (payload is Map) {
          final accountId =
              (payload['sub'] ?? payload['userId'] ?? payload['id'])
                  ?.toString();
          if (accountId != null && accountId.isNotEmpty) {
            return _stableCacheHash(accountId);
          }
        }
      } catch (_) {
        // Non-JWT tokens still get an isolated, stable cache namespace.
      }
    }
    return _stableCacheHash(currentToken);
  }

  String _cacheKey(String path, {String? accountScope}) =>
      'chatify_offline_v1_${accountScope ?? _cacheScope()}_${Uri.encodeComponent(path)}';

  // Private API and conversation caches may contain personal messages and records.
  // Migrate old plaintext preference entries only when secure storage accepts the
  // value, then remove the legacy copy. If secure storage is unavailable, do not
  // expose cached private data through plaintext SharedPreferences/localStorage.
  Future<String?> _readPrivateCacheValue(String key) async {
    try {
      final secure = await _secureStorage.read(key: key);
      if (secure != null && secure.isNotEmpty) {
        try {
          await (await SharedPreferences.getInstance()).remove(key);
        } catch (_) {}
        return secure;
      }
    } catch (_) {
      // Try one-time migration of a legacy plaintext cache below.
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      final legacy = preferences.getString(key);
      if (legacy == null || legacy.isEmpty) return null;
      try {
        await _secureStorage.write(key: key, value: legacy);
        await preferences.remove(key);
        return legacy;
      } catch (_) {
        // Never return plaintext cached conversations when secure storage fails.
        await preferences.remove(key);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePrivateCacheValue(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
    } catch (_) {
      // Offline cache is optional; a secure-storage failure must not write
      // private records into plaintext browser storage.
    }
    try {
      // Remove any old plaintext copy, even if the secure write failed.
      await (await SharedPreferences.getInstance()).remove(key);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _readCachedResponse(String path,
      {String? accountScope}) async {
    if (token == null || token!.isEmpty) return null;
    try {
      final key = _cacheKey(path, accountScope: accountScope);
      final cached = await _readPrivateCacheValue(key);
      if (cached == null || cached.isEmpty) return null;
      final decoded = jsonDecode(cached);
      if (decoded is! Map ||
          decoded['_chatifyCacheExpiresAt'] is! String ||
          decoded['data'] is! Map) {
        // Older cache entries had no expiry metadata. Drop them once so they
        // cannot become an indefinitely stale fallback after an upgrade.
        await _secureStorage.delete(key: key);
        return null;
      }
      final expiresAt = DateTime.tryParse(
          decoded['_chatifyCacheExpiresAt']?.toString() ?? '');
      if (expiresAt == null || !_now().isBefore(expiresAt)) {
        await _secureStorage.delete(key: key);
        return null;
      }
      return Map<String, dynamic>.from(decoded['data'] as Map);
    } catch (_) {
      // A corrupt cache must never break the app.
    }
    return null;
  }

  Future<void> _writeCachedResponse(String path, Map<String, dynamic> response,
      {String? accountScope}) async {
    if (token == null || token!.isEmpty) return;
    try {
      final cachedAt = _now().toUtc();
      final encoded = jsonEncode({
        '_chatifyCacheCreatedAt': cachedAt.toIso8601String(),
        '_chatifyCacheExpiresAt':
            cachedAt.add(_cachedResponseLifetime).toIso8601String(),
        'data': response,
      });
      // Keep individual entries bounded so large histories do not exhaust
      // secure storage or make a small device unresponsive.
      if (encoded.length > 700000) return;
      await _writePrivateCacheValue(
          _cacheKey(path, accountScope: accountScope), encoded);
    } catch (_) {
      // Caching is best-effort and must never break a successful API request.
    }
  }

  Future<void> _invalidateCachedResponses({String? accountScope}) async {
    final prefix = 'chatify_offline_v1_${accountScope ?? _cacheScope()}_';
    try {
      final secureValues = await _secureStorage.readAll();
      for (final key
          in secureValues.keys.where((key) => key.startsWith(prefix))) {
        await _secureStorage.delete(key: key);
      }
    } catch (_) {
      // Invalidation is best-effort; the mutation result must remain visible.
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      for (final key
          in preferences.getKeys().where((key) => key.startsWith(prefix))) {
        await preferences.remove(key);
      }
    } catch (_) {}
  }

  String _conversationSnapshotKey(String conversationId) =>
      'chatify_secure_messages_v1_${_cacheScope()}_${_stableCacheHash(conversationId)}';

  String _conversationMetadataKey(String conversationId) =>
      'chatify_secure_conversation_v1_${_cacheScope()}_${_stableCacheHash(conversationId)}';

  String _outgoingMessageOutboxKey(String conversationId,
          {String? accountScope}) =>
      'chatify_secure_outbox_v1_${accountScope ?? _cacheScope()}_${_stableCacheHash(conversationId)}';

  // The outbox contains encrypted envelopes and retry metadata only. Never
  // fall back to plaintext preferences if secure storage is unavailable.
  Future<List<Map<String, dynamic>>> readOutgoingMessageOutbox(
      String conversationId,
      {String? accountScope}) async {
    if (token == null || token!.isEmpty) return [];
    final encoded = await _secureStorage.read(
        key: _outgoingMessageOutboxKey(conversationId,
            accountScope: accountScope));
    if (encoded == null || encoded.isEmpty) return [];
    final decoded = jsonDecode(encoded);
    if (decoded is! List) {
      throw StateError('The secure outgoing-message queue is invalid.');
    }
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where(
            (item) => item['clientMutationId'] is String && item['body'] is Map)
        .toList();
  }

  Future<void> enqueueOutgoingMessage(
      String conversationId, Map<String, dynamic> item) async {
    if (token == null || token!.isEmpty) {
      throw StateError('Sign in before saving an outgoing message for retry.');
    }
    final mutationId = item['clientMutationId']?.toString() ?? '';
    if (mutationId.length < 16 || mutationId.length > 100) {
      throw ArgumentError(
          'A stable message ID is required for offline queuing.');
    }
    final accountScope = _cacheScope();
    final key =
        _outgoingMessageOutboxKey(conversationId, accountScope: accountScope);
    await _withOutboxLock(key, () async {
      final queued = await readOutgoingMessageOutbox(conversationId,
          accountScope: accountScope);
      if (queued.any((entry) => entry['clientMutationId'] == mutationId))
        return;
      if (queued.length >= 50) {
        throw StateError(
            'The secure outgoing queue is full. Connect and send queued messages before adding more.');
      }
      queued.add(item);
      final encoded = jsonEncode(queued);
      if (encoded.length > 700000) {
        throw StateError(
            'The secure outgoing queue is full. Connect and send queued messages before adding more.');
      }
      await _secureStorage.write(key: key, value: encoded);
    });
  }

  Future<void> removeOutgoingMessageFromOutbox(
      String conversationId, String mutationId,
      {String? accountScope}) async {
    final scope = accountScope ?? _cacheScope();
    final key = _outgoingMessageOutboxKey(conversationId, accountScope: scope);
    await _withOutboxLock(key, () async {
      final queued =
          await readOutgoingMessageOutbox(conversationId, accountScope: scope);
      queued.removeWhere((item) => item['clientMutationId'] == mutationId);
      if (queued.isEmpty) {
        await _secureStorage.delete(key: key);
      } else {
        await _secureStorage.write(key: key, value: jsonEncode(queued));
      }
    });
  }

  Future<Map<String, dynamic>?> readConversationMetadata(
      String conversationId) async {
    try {
      final encoded = await _readPrivateCacheValue(
          _conversationMetadataKey(conversationId));
      if (encoded == null || encoded.isEmpty) return null;
      final decoded = jsonDecode(encoded);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // A corrupt cache must not block online use.
    }
    return null;
  }

  Future<void> writeConversationMetadata(
      String conversationId, Map<String, dynamic> conversation) async {
    try {
      final encoded = jsonEncode(conversation);
      if (encoded.length <= 200000) {
        await _writePrivateCacheValue(
            _conversationMetadataKey(conversationId), encoded);
      }
    } catch (_) {
      // Do not let local cache failures affect normal messaging.
    }
  }

  Future<List<dynamic>?> readConversationSnapshot(String conversationId) async {
    try {
      final encoded = await _readPrivateCacheValue(
          _conversationSnapshotKey(conversationId));
      if (encoded == null || encoded.isEmpty) return null;
      final decoded = jsonDecode(encoded);
      if (decoded is List) return List<dynamic>.from(decoded);
    } catch (_) {
      // A corrupt cache must not block online use.
    }
    return null;
  }

  Future<void> writeConversationSnapshot(
      String conversationId, List<dynamic> messages) async {
    try {
      // Avoid storing an unbounded history in one secure-storage value.
      final bounded = messages.length > 300
          ? messages.sublist(messages.length - 300)
          : messages;
      final value = jsonEncode(bounded);
      if (value.length > 900000) return;
      await _writePrivateCacheValue(
          _conversationSnapshotKey(conversationId), value);
    } catch (_) {
      // Local persistence is best-effort and must not interrupt chat delivery.
    }
  }

  Future<void> restore() async {
    try {
      token = await _secureStorage.read(key: 'token');
    } catch (_) {
      token = null;
    }
    final preferences = await SharedPreferences.getInstance();
    // Restore browser sessions from persistent fallback storage if secure
    // storage is unavailable; native still migrates its legacy token once.
    if (token == null) {
      final legacyToken = preferences.getString('token');
      if (legacyToken != null && legacyToken.isNotEmpty) {
        token = legacyToken;
        try {
          await _secureStorage.write(key: 'token', value: legacyToken);
          if (!kIsWeb) await preferences.remove('token');
        } catch (_) {
          // Keep fallback token so the account can restore while offline.
        }
      }
    }
  }

  Future<void> saveToken(String value) async {
    token = value;
    var secureWriteSucceeded = false;
    try {
      await _secureStorage.write(key: 'token', value: value);
      secureWriteSucceeded = true;
    } catch (_) {}
    if (kIsWeb || !secureWriteSucceeded) {
      await (await SharedPreferences.getInstance()).setString('token', value);
    }
  }

  Future<void> clearToken() async {
    token = null;
    try {
      await _secureStorage.delete(key: 'token');
    } catch (_) {}
    await (await SharedPreferences.getInstance()).remove('token');
  }

  Future<Map<String, dynamic>> call(String method, String path,
      [Map<String, dynamic>? body]) {
    final accountScope = _cacheScope();
    if (method != 'GET') {
      return _callUncoalesced(method, path, body, accountScope: accountScope);
    }
    final key = '$accountScope|$path';
    final existing = _inFlightGets[key];
    if (existing != null) return existing;
    final request =
        _callUncoalesced(method, path, body, accountScope: accountScope);
    _inFlightGets[key] = request;
    return request.whenComplete(() {
      if (identical(_inFlightGets[key], request)) _inFlightGets.remove(key);
    });
  }

  /// GET a resource, returning null only when the request fails and no secure
  /// account-scoped cached response is available.
  Future<Map<String, dynamic>?> cachedGet(String path) =>
      _readCachedResponse(path);

  Future<Map<String, dynamic>> _callUncoalesced(
      String method, String path, Map<String, dynamic>? body,
      {String? accountScope}) async {
    final scope = accountScope ?? _cacheScope();
    final requestToken = token;
    final h = {
      'Content-Type': 'application/json',
      if (requestToken != null) 'Authorization': 'Bearer $requestToken'
    };
    final u = Uri.parse('$base$path');
    // Check whether a previous response is available before waiting on the
    // network. A cached signed-in user should not wait through long API cold-start
    // timeouts just to open their saved chats while offline.
    final cachedBeforeRequest = method == 'GET'
        ? await _readCachedResponse(path, accountScope: scope)
        : null;
    // Daraja may need one OAuth request followed by the STK request. Give
    // payment initiation enough time to finish so the UI doesn't report a
    // timeout while Safaricom may already be processing the prompt.
    final requestTimeout = cachedBeforeRequest != null
        ? const Duration(seconds: 5)
        : ((path.contains('/api/payments/') && path.endsWith('/initiate')) ||
                path.endsWith('/stk-push') ||
                (path.contains('/pos/charges/') && path.endsWith('/stk')))
            ? const Duration(seconds: 35)
            : const Duration(seconds: 20);
    Future<http.Response> sendRequest() {
      if (method == 'POST') {
        return client.post(u, headers: h, body: jsonEncode(body ?? {}));
      } else if (method == 'PATCH') {
        return client.patch(u, headers: h, body: jsonEncode(body ?? {}));
      } else if (method == 'PUT') {
        return client.put(u, headers: h, body: jsonEncode(body ?? {}));
      } else if (method == 'DELETE') {
        return client.delete(u,
            headers: h, body: body == null ? null : jsonEncode(body));
      }
      return client.get(u, headers: h);
    }

    late http.Response r;
    lastResponseFromCache = false;
    try {
      r = await sendRequest().timeout(requestTimeout);
    } on TimeoutException {
      // Retry only safe GET requests. Writes and payments are never replayed.
      if (method != 'GET') rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        r = await sendRequest().timeout(cachedBeforeRequest != null
            ? const Duration(seconds: 5)
            : const Duration(seconds: 25));
      } catch (retryError) {
        if (method == 'GET') offlineDataMode = true;
        final cached = await _readCachedResponse(path, accountScope: scope);
        if (cached != null) {
          lastResponseFromCache = true;
          offlineDataMode = true;
          return cached;
        }
        if (retryError is TimeoutException) {
          throw ApiException(408,
              'Chatify is taking longer than expected to respond. Check your connection and retry.');
        }
        rethrow;
      }
    } catch (_) {
      // A failed read should fall back to the last account-scoped response.
      // Never do this for POST/PATCH/PUT/DELETE, especially payment requests.
      if (method == 'GET') {
        offlineDataMode = true;
        final cached = await _readCachedResponse(path, accountScope: scope);
        if (cached != null) {
          lastResponseFromCache = true;
          offlineDataMode = true;
          return cached;
        }
      }
      rethrow;
    }

    // A server outage can also arrive as HTTP 5xx rather than a socket error.
    // Use cached data for reads only; authentication failures still surface.
    if (method == 'GET' && r.statusCode >= 500) {
      offlineDataMode = true;
      final cached = await _readCachedResponse(path, accountScope: scope);
      if (cached != null) {
        lastResponseFromCache = true;
        offlineDataMode = true;
        return cached;
      }
    }
    // API routes must return JSON. Render/Vercel error pages and stale deployments
    // sometimes return HTML (starting with "<"), which jsonDecode would expose as
    // an unhelpful FormatException when the Business tab loads.
    dynamic decoded;
    if (r.body.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(r.body);
      } on FormatException {
        final contentType = r.headers['content-type'] ?? '';
        final bodyStart = r.body.trimLeft();
        final looksLikeHtml = contentType.contains('text/html') ||
            bodyStart.startsWith('<!DOCTYPE') ||
            bodyStart.startsWith('<html') ||
            bodyStart.startsWith('<');
        if (looksLikeHtml) {
          throw ApiException(
            r.statusCode,
            'Chatify API returned an HTML page instead of JSON for $path '
            '(HTTP ${r.statusCode}). This usually means the backend deployment '
            'is outdated or CHATIFY_API points to the wrong service. '
            'Check the Render deployment for https://chatify-api-c1eh.onrender.com '
            'and confirm it is running the latest main branch.',
          );
        }
        throw ApiException(
            r.statusCode,
            'Chatify API returned an invalid JSON response for $path '
            '(HTTP ${r.statusCode}).');
      }
    } else {
      decoded = <String, dynamic>{};
    }
    if (r.statusCode >= 400) {
      throw ApiException(
          r.statusCode,
          decoded is Map && decoded['error'] != null
              ? decoded['error'].toString()
              : 'Request failed (HTTP ${r.statusCode})');
    }
    final result = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{'data': decoded};
    if (method == 'GET') {
      offlineDataMode = false;
      await _writeCachedResponse(path, result, accountScope: scope);
    } else {
      await _invalidateCachedResponses(accountScope: scope);
    }
    return result;
  }

  Future<Map<String, dynamic>> paymentStatus(String paymentId) =>
      call('GET', '/api/payments/$paymentId');

  Future<Map<String, dynamic>> publicStatus() async {
    final response = await client
        .get(Uri.parse('$base/api/status'))
        .timeout(const Duration(seconds: 10));
    final decoded = jsonDecode(response.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('Service status response was not an object.');
  }
}

String? normalizeKenyanPhone(String value) {
  final digits = value.trim().replaceAll(RegExp(r'[\s()+-]'), '');
  if (RegExp(r'^0[17]\d{8}$').hasMatch(digits)) {
    return '254${digits.substring(1)}';
  }
  if (RegExp(r'^\+?254[17]\d{8}$').hasMatch(digits)) {
    return digits.replaceFirst('+', '');
  }
  return null;
}

List<dynamic> mergeMessages(List<dynamic> current, List<dynamic> fetched) {
  final merged = <dynamic>[];
  final indices = <String, int>{};
  for (final message in [...current, ...fetched]) {
    if (message is! Map || message['_id'] == null) {
      merged.add(message);
      continue;
    }
    final id = message['_id'].toString();
    final index = indices[id];
    if (index == null) {
      indices[id] = merged.length;
      merged.add(message);
    } else {
      merged[index] = message;
    }
  }
  merged.sort((a, b) {
    if (a is! Map || b is! Map) return 0;
    final aDate = DateTime.tryParse(a['createdAt']?.toString() ?? '');
    final bDate = DateTime.tryParse(b['createdAt']?.toString() ?? '');
    if (aDate == null || bDate == null) return 0;
    return aDate.compareTo(bDate);
  });
  return merged;
}

// Resolve a reply reference only against messages loaded for the active conversation.
// Supporting both a raw ID and a populated reference keeps old and new API payloads readable.
Map<String, dynamic>? findReplyTarget(
    List<dynamic> conversationMessages, dynamic replyTo) {
  final replyId = replyTo is Map
      ? (replyTo['_id'] ?? replyTo['id'])?.toString()
      : replyTo?.toString();
  if (replyId == null || replyId.isEmpty) return null;
  for (final item in conversationMessages) {
    if (item is Map && item['_id']?.toString() == replyId) {
      return Map<String, dynamic>.from(item);
    }
  }
  return null;
}

List<dynamic> mergePayment(
    List<dynamic> current, Map<String, dynamic> payment) {
  final updated = List<dynamic>.from(current);
  final id = payment['paymentId']?.toString();
  if (id == null) return updated;
  final index = updated
      .indexWhere((item) => item is Map && item['paymentId']?.toString() == id);
  if (index < 0) {
    updated.insert(0, payment);
  } else {
    updated[index] = payment;
  }
  return updated;
}

// Resolve the display name for a direct conversation consistently in the chat list and chat header.
String? conversationPeerName(
    Map<String, dynamic> conversation, Map<String, dynamic>? currentUser) {
  if (conversation['type'] == 'group') return null;

  final currentIds = <String>{
    currentUser?['id']?.toString() ?? '',
    currentUser?['_id']?.toString() ?? '',
  }..remove('');
  final currentEmail =
      currentUser?['email']?.toString().trim().toLowerCase() ?? '';
  final rawParticipants = conversation['participants'];
  if (rawParticipants is! List) return null;

  String? firstAvailableName;
  for (final raw in rawParticipants) {
    if (raw is! Map) continue;
    final participant = Map<String, dynamic>.from(raw);
    final nested = participant['user'] is Map
        ? Map<String, dynamic>.from(participant['user'] as Map)
        : <String, dynamic>{};
    final id = (participant['_id'] ??
                participant['id'] ??
                participant['userId'] ??
                nested['_id'] ??
                nested['id'])
            ?.toString() ??
        '';
    final email = (participant['email'] ?? nested['email'])
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';
    final name = (participant['name'] ??
                nested['name'] ??
                participant['displayName'] ??
                nested['displayName'] ??
                participant['username'] ??
                nested['username'])
            ?.toString()
            .trim() ??
        '';

    // Exclude the signed-in user by ID or email before choosing the chat peer.
    if ((id.isNotEmpty && currentIds.contains(id)) ||
        (currentEmail.isNotEmpty &&
            email.isNotEmpty &&
            email == currentEmail)) {
      continue;
    }
    if (name.isNotEmpty) return name;
    // Keep the first usable fallback name; null needs no explicit assignment.
  }
  return firstAvailableName;
}

// Extract candidate memories locally on the device. This is intentionally heuristic and
// suggestion-only: decrypted end-to-end encrypted messages never leave the device for analysis.
List<Map<String, dynamic>> extractMemoryCandidatesLocally(String input) {
  final text = input.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length < 8) return [];
  final candidates = <Map<String, dynamic>>[];
  final date = memoryDateFromText(text);
  final timeMatch = RegExp(
    r'\b(?:at\s+)?(1[0-2]|0?[1-9])(?::([0-5]\d))?\s?(AM|PM)\b',
    caseSensitive: false,
  ).firstMatch(text);
  final time = timeMatch
      ?.group(0)
      ?.replaceFirst(
        RegExp(r'^at\s+', caseSensitive: false),
        '',
      )
      .trim();
  if (RegExp(
    r'\b(meet(?:ing)?|appointment|doctor|interview|flight|deadline|due date|reservation|call with|scheduled|tomorrow|tonight|today|next week|this (?:morning|afternoon|evening)|on (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    candidates.add({
      'type': 'EVENT',
      'title': RegExp(r'\b(deadline|due date)\b', caseSensitive: false)
              .hasMatch(text)
          ? 'Deadline'
          : RegExp(r'\b(doctor|appointment)\b', caseSensitive: false)
                  .hasMatch(text)
              ? 'Appointment'
              : 'Upcoming event',
      'description': text,
      if (date != null) 'date': date.toIso8601String(),
      if (time != null) 'time': time,
    });
  }
  final task = RegExp(
    r'\b(?:remember to|don.t forget to|do not forget to|remind me to|need to|have to|must|todo|to-do|task is to)\s+(.+?)(?:[.!?]|$)',
    caseSensitive: false,
  ).firstMatch(text);
  if (task != null && (task.group(1)?.trim().length ?? 0) >= 4) {
    candidates.add({
      'type': 'TASK',
      'title': 'Reminder',
      'description': task.group(1)!.trim(),
      if (date != null) 'date': date.toIso8601String(),
      if (time != null) 'time': time,
    });
  }
  final hasMoney = RegExp(
    r'\b(?:KES|KSh|shillings?)\s*[0-9][0-9,]*(?:\.\d{1,2})?\b|\b(?:pay|paid|owe|owed|costs?|rent|bill|payment)\b[^.!?]{0,70}\b[0-9][0-9,]*(?:\.\d{1,2})?\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (hasMoney) {
    candidates.add({
      'type': 'PAYMENT',
      'title': 'Payment or amount',
      'description': text,
    });
  }
  if (RegExp(
    r'\b(?:my birthday is|my anniversary is|i live in|i work at|i work in|i am based in|i.m based in|my job is|i work as|my goal is|my favorite|my favourite|i prefer|my child.s name is|my dog.s name is|my cat.s name is)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    candidates.add({
      'type': 'NOTE',
      'title':
          RegExp(r'birthday|anniversary', caseSensitive: false).hasMatch(text)
              ? 'Important date'
              : RegExp(r'prefer|favorite|favourite', caseSensitive: false)
                      .hasMatch(text)
                  ? 'Preference'
                  : RegExp(r'work|job', caseSensitive: false).hasMatch(text)
                      ? 'Work detail'
                      : 'Personal detail',
      'description': text,
    });
  }
  final seen = <String>{};
  return candidates
      .where((item) {
        final key = '${item['type']}:${item['title']}';
        return seen.add(key);
      })
      .take(3)
      .toList();
}

/// Extracts only explicitly supported memory dates and validates calendar
/// components before constructing a DateTime (which otherwise normalizes).
DateTime? memoryDateFromText(String input, {DateTime? now}) {
  final relative = RegExp(r'\btomorrow\b', caseSensitive: false);
  if (relative.hasMatch(input)) {
    final reference = now ?? DateTime.now();
    return DateTime(reference.year, reference.month, reference.day + 1);
  }
  const months = <String, int>{
    'january': 1,
    'february': 2,
    'march': 3,
    'april': 4,
    'may': 5,
    'june': 6,
    'july': 7,
    'august': 8,
    'september': 9,
    'october': 10,
    'november': 11,
    'december': 12,
  };
  final match = RegExp(
    r'\b(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})\b',
    caseSensitive: false,
  ).firstMatch(input);
  if (match == null) return null;
  final day = int.parse(match.group(1)!);
  final month = months[match.group(2)!.toLowerCase()]!;
  final year = int.parse(match.group(3)!);
  final parsed = DateTime(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

// Buttons that perform asynchronous work disable themselves while the action is running.
// This prevents rapid repeat taps and gives a consistent inline progress indicator.
class AsyncActionButton extends StatefulWidget {
  final String label;
  final FutureOr<void> Function() onPressed;
  final IconData icon;
  const AsyncActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.check,
  });

  @override
  State<AsyncActionButton> createState() => _AsyncActionButtonState();
}

class _AsyncActionButtonState extends State<AsyncActionButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton.icon(
        onPressed: _busy ? null : _run,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(widget.icon),
        label: Text(_busy ? 'Please wait…' : widget.label),
      );
}

// Shared app state. Screens listen to this object and rebuild after login, chat, contact, memory, or payment data changes.
class AppState extends ChangeNotifier {
  final Api api;
  ThemeMode themeMode = ThemeMode.dark;
  bool ready = false;
  bool authRequested = false;
  bool startRegistration = false;
  Map<String, dynamic>? user;
  String? restoreError;
  String? encryptionError;
  final Set<String> onlineUserIds = {};
  // Monotonic counter lets chat-list screens refresh summaries without polling.
  int messageEventVersion = 0;
  io.Socket? _presenceSocket;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  String? _registeredPushToken;
  DateTime? _lastIncomingBellAt;

  // Use the device's notification tone for a familiar bell-like alert. A short
  // cooldown prevents Socket.IO and Firebase from sounding twice for one message.
  void _playIncomingMessageBell() {
    final now = DateTime.now();
    final last = _lastIncomingBellAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastIncomingBellAt = now;
    try {
      unawaited(FlutterRingtonePlayer().playNotification());
    } catch (_) {
      // Audio is best-effort; messaging must continue if the platform has no tone.
      unawaited(SystemSound.play(SystemSoundType.alert).catchError((_) {}));
    }
  }
  AppState({Api? api, bool autoInit = true}) : api = api ?? Api() {
    if (autoInit) init();
  }

  // Update the signed-in account and notify listeners from inside ChangeNotifier.
  void updateCurrentUser(Map<String, dynamic> updatedUser) {
    user = updatedUser;
    notifyListeners();
  }

  Future<void> init() async {
    ready = false;
    restoreError = null;
    try {
      await api.restore().timeout(const Duration(seconds: 5));
    } catch (error) {
      // A storage plugin failure must not leave the app stuck on its splash.
      restoreError = 'Could not restore the saved session: $error';
    }
    try {
      final preferences = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 3));
      themeMode = preferences.getBool('chatify_dark_mode') == false
          ? ThemeMode.light
          : ThemeMode.dark;
    } catch (error) {
      restoreError ??= 'Could not load local preferences: $error';
    }
    if (api.token != null) {
      try {
        user = Map<String, dynamic>.from((await api
            .call('GET', '/api/auth/me')
            .timeout(const Duration(seconds: 8)))['user']);
      } catch (error) {
        if (error is ApiException && error.statusCode == 401) {
          // Only a confirmed authentication rejection invalidates the saved token.
          await logout();
        } else {
          // The 8-second startup guard can expire before Api's longer offline
          // fallback runs. Read the last account-scoped /me response directly,
          // keep the token, and let cached screens open without internet.
          Map<String, dynamic>? cachedMe;
          try {
            cachedMe = await api
                ._readCachedResponse('/api/auth/me')
                .timeout(const Duration(seconds: 2));
          } catch (_) {
            cachedMe = null;
          }
          final cachedUser = cachedMe?['user'];
          if (cachedUser is Map) {
            user = Map<String, dynamic>.from(cachedUser);
            api.offlineDataMode = true;
            restoreError = null;
          } else if (error is TimeoutException ||
              (error is ApiException && error.statusCode == 408)) {
            // Don't display a raw timeout exception or discard credentials.
            api.offlineDataMode = true;
            restoreError = null;
          } else {
            restoreError = error.toString();
          }
        }
      }
    }
    // Show the app as soon as the session is restored. Key provisioning and
    // push registration are independent background tasks and must not hold the
    // first frame hostage on slow networks or a cold API instance.
    if (user != null) {
      _connectPresence();
      unawaited(_finishBackgroundStartup());
    }
    ready = true;
    notifyListeners();
  }

  Future<void> _finishBackgroundStartup() async {
    try {
      await ensureEncryptionKey().timeout(const Duration(seconds: 12));
    } catch (error) {
      encryptionError = error.toString();
      notifyListeners();
    }
    try {
      await _initializePushNotifications().timeout(const Duration(seconds: 8));
    } catch (_) {
      // Push is best-effort; it must not block opening the app.
    }
  }

  /// Creates the device-local key on first use and registers only its public half.
  Future<String> ensureEncryptionKey() async {
    final accountId = user?['id']?.toString() ?? '';
    if (accountId.isEmpty)
      throw StateError('Sign in before enabling encryption.');
    final registered = user?['encryptionPublicKey']?.toString();
    final publicKey = await ChatifyE2EE.instance.publicKeyFor(
      accountId,
      registeredPublicKey:
          (registered == null || registered.isEmpty) ? null : registered,
    );
    if (registered == null || registered.isEmpty) {
      await api.call(
          'PUT', '/api/users/me/encryption-key', {'publicKey': publicKey});
      user!['encryptionPublicKey'] = publicKey;
      encryptionError = null;
      notifyListeners();
    }
    return publicKey;
  }

  /// Rebuilds the presence connection after credentials rotate.
  void refreshRealtimeAuthentication() {
    _connectPresence();
    // Notify active conversation widgets so their sockets can rotate the same token.
    notifyListeners();
  }

  void _connectPresence() {
    final token = api.token;
    if (token == null || token.isEmpty) return;
    _presenceSocket?.dispose();
    onlineUserIds.clear();
    _presenceSocket = io.io(
      api.base,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableAutoConnect()
          .enableReconnection()
          .build(),
    );
    // Refresh the chat list after the socket reconnects so messages sent while
    // this device was offline are reflected in conversation previews.
    _presenceSocket!.onConnect((_) {
      messageEventVersion++;
      notifyListeners();
    });
    // Play one alert for incoming messages even when the user is viewing another tab.
    // The active chat screen deliberately does not play a second copy of this sound.
    _presenceSocket!.on('message:new', (data) {
      if (data is! Map) return;
      final senderId = data['senderId']?.toString();
      final currentId = user?['id']?.toString();
      messageEventVersion++;
      notifyListeners();
      if (senderId != null && senderId.isNotEmpty && senderId != currentId) {
        // Bell alert for incoming messages, never for messages sent by this user.
        _playIncomingMessageBell();
      }
    });
    _presenceSocket!.on('presence:initial', (data) {
      if (data is! Map || data['userIds'] is! List) return;
      onlineUserIds
        ..clear()
        ..addAll((data['userIds'] as List).map((id) => id.toString()));
      notifyListeners();
    });
    _presenceSocket!.on('user:online', (data) {
      if (data is Map &&
          data['userId'] != null &&
          onlineUserIds.add(data['userId'].toString())) {
        notifyListeners();
      }
    });
    _presenceSocket!.on('user:offline', (data) {
      if (data is Map &&
          data['userId'] != null &&
          onlineUserIds.remove(data['userId'].toString())) {
        notifyListeners();
      }
    });
    _presenceSocket!.onDisconnect((_) {
      if (onlineUserIds.isNotEmpty) {
        onlineUserIds.clear();
        notifyListeners();
      }
    });
    _presenceSocket!.connect();
  }

  Future<void> _initializePushNotifications() async {
    // Firebase is optional in development. Missing native Firebase configuration
    // must never prevent the user from signing in or using chat.
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) await _registerPushToken(token);
      await _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = messaging.onTokenRefresh.listen((token) {
        unawaited(_registerPushToken(token));
      }, onError: (_) {});
      await _messageOpenedSubscription?.cancel();
      _messageOpenedSubscription = FirebaseMessaging.onMessageOpenedApp
          .listen(_openConversationFromNotification);
      await _foregroundMessageSubscription?.cancel();
      _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen((_) {
        _playIncomingMessageBell();
        chatifyScaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('You received a new message.')),
        );
      });
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        await _openConversationFromNotification(initialMessage);
      }
    } catch (_) {
      // No Firebase project or denied platform capability: chat remains usable.
    }
  }

  Future<void> _registerPushToken(String token) async {
    if (api.token == null || token.isEmpty) return;
    try {
      final previousToken = _registeredPushToken;
      await api.call('POST', '/api/devices', {'token': token});
      _registeredPushToken = token;
      if (previousToken != null && previousToken != token) {
        try {
          await api.call('DELETE', '/api/devices', {'token': previousToken});
        } catch (_) {
          // The newly registered token remains usable if stale-token cleanup fails.
        }
      }
    } catch (_) {
      // Registration is best-effort; a later token refresh or sign-in retries it.
    }
  }

  Future<void> _openConversationFromNotification(RemoteMessage message) async {
    final conversationId = message.data['conversationId']?.toString();
    if (conversationId == null || conversationId.isEmpty || api.token == null) {
      return;
    }
    try {
      final response = await api.call('GET', '/api/conversations');
      final conversations =
          List<dynamic>.from(response['conversations'] ?? const []);
      final matching = conversations.whereType<Map>().firstWhere(
            (item) => item['_id']?.toString() == conversationId,
            orElse: () => <String, dynamic>{},
          );
      if (matching.isEmpty) return;
      final navigator = chatifyNavigatorKey.currentState;
      if (navigator == null) return;
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => Chat(
          conversation: Map<String, dynamic>.from(matching),
        ),
      ));
    } catch (_) {
      // The server remains authoritative for conversation membership.
    }
  }

  Future<String?> auth(
      bool reg, String name, String email, String pass, String phone) async {
    try {
      final d = await api.call(
          'POST',
          reg ? '/api/auth/register' : '/api/auth/login',
          reg
              ? {
                  'name': name,
                  'email': email,
                  'password': pass,
                  'phone': normalizeKenyanPhone(phone)
                }
              : {'email': email, 'password': pass});
      if (reg && d['verificationRequired'] == true) {
        return d['message']?.toString() ??
            'Check your email and confirm your address before signing in.';
      }
      await api.saveToken(d['token'].toString());
      user = Map<String, dynamic>.from(d['user']);
      try {
        await ensureEncryptionKey();
      } catch (error) {
        encryptionError = error.toString();
      }
      _connectPresence();
      await _initializePushNotifications();
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  Future<void> setDarkMode(bool enabled) async {
    themeMode = enabled ? ThemeMode.dark : ThemeMode.light;
    await (await SharedPreferences.getInstance())
        .setBool('chatify_dark_mode', enabled);
    notifyListeners();
  }

  void openAuth({bool register = false}) {
    authRequested = true;
    startRegistration = register;
    notifyListeners();
  }

  void returnToWelcome() {
    authRequested = false;
    startRegistration = false;
    notifyListeners();
  }

  Future<void> logout() async {
    final registeredToken = _registeredPushToken;
    if (registeredToken != null && api.token != null) {
      try {
        await api.call('DELETE', '/api/devices', {'token': registeredToken});
      } catch (_) {
        // Local sign-out must still complete when the API is unavailable.
      }
    }
    _registeredPushToken = null;
    _presenceSocket?.dispose();
    _presenceSocket = null;
    onlineUserIds.clear();
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    await _messageOpenedSubscription?.cancel();
    _messageOpenedSubscription = null;
    await _foregroundMessageSubscription?.cancel();
    _foregroundMessageSubscription = null;
    await api.clearToken();
    user = null;
    authRequested = false;
    startRegistration = false;
    restoreError = null;
    notifyListeners();
  }
}

final GlobalKey<NavigatorState> chatifyNavigatorKey =
    GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> chatifyScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() => runApp(ChangeNotifierProvider(
    create: (_) => AppState(), child: const ChatifyApp()));

// Root widget that configures app-wide Material styling and chooses the first screen.
class ChatifyApp extends StatelessWidget {
  const ChatifyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        themeMode: context.watch<AppState>().themeMode,
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF087F8C),
            brightness: Brightness.dark,
          ).copyWith(
            primary: const Color(0xFF7EDBD0),
            onPrimary: const Color(0xFF082F49),
            secondary: const Color(0xFFB8A1FF),
            onSecondary: const Color(0xFF2E1065),
            tertiary: const Color(0xFFF2C66D),
            surface: const Color(0xFF1C2433),
            onSurface: const Color(0xFFE9EDF7),
            error: const Color(0xFFFF8A80),
            outline: const Color(0xFF465268),
          ),
          scaffoldBackgroundColor: const Color(0xFF111827),
          canvasColor: const Color(0xFF111827),
          cardColor: const Color(0xFF1C2433),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF111827),
            foregroundColor: Color(0xFFE9EDF7),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF1C2433),
            hintStyle: const TextStyle(color: Color(0xFF9AA6BA)),
            labelStyle: const TextStyle(color: Color(0xFFBAC4D5)),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF465268)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF465268)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Color(0xFF7EDBD0), width: 1.6),
            ),
          ),
          navigationBarTheme: const NavigationBarThemeData(
            backgroundColor: Color(0xFF1C2433),
            indicatorColor: Color(0xFF263D5B),
            elevation: 0,
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF273246),
            contentTextStyle: const TextStyle(color: Color(0xFFE9EDF7)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        debugShowCheckedModeBanner: false,
        title: 'Chatify',
        navigatorKey: chatifyNavigatorKey,
        scaffoldMessengerKey: chatifyScaffoldMessengerKey,
        theme: ThemeData(
          useMaterial3: true,
          visualDensity: VisualDensity.standard,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF087F8C),
            brightness: Brightness.light,
          ).copyWith(
            primary: const Color(0xFF087F8C),
            onPrimary: Colors.white,
            secondary: const Color(0xFF7C4DFF),
            onSecondary: Colors.white,
            tertiary: const Color(0xFFD97706),
            onTertiary: Colors.white,
            surface: Colors.white,
            onSurface: const Color(0xFF123B67),
            error: const Color(0xFFDC2626),
            outline: const Color(0xFFDCE4EE),
          ),
          scaffoldBackgroundColor: const Color(0xFFF4F7FB),
          canvasColor: const Color(0xFFF4F7FB),
          cardColor: Colors.white,
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF4F7FB),
            foregroundColor: Color(0xFF123B67),
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            centerTitle: false,
            titleTextStyle: TextStyle(
              color: Color(0xFF123B67),
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.35,
            ),
          ),
          textTheme: const TextTheme(
            displayLarge: TextStyle(
              color: Color(0xFF123B67),
              fontWeight: FontWeight.w800,
              letterSpacing: -1.2,
            ),
            headlineMedium: TextStyle(
              color: Color(0xFF123B67),
              fontWeight: FontWeight.w700,
              letterSpacing: -0.65,
            ),
            titleLarge: TextStyle(
              color: Color(0xFF123B67),
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
            titleMedium: TextStyle(
              color: Color(0xFF243B53),
              fontWeight: FontWeight.w600,
            ),
            bodyLarge: TextStyle(
              color: Color(0xFF243B53),
              fontSize: 16,
              height: 1.45,
            ),
            bodyMedium: TextStyle(
              color: Color(0xFF52627A),
              fontSize: 14,
              height: 1.45,
            ),
            bodySmall: TextStyle(
              color: Color(0xFF68788D),
              fontSize: 12,
              height: 1.4,
            ),
            labelLarge: TextStyle(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.05,
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 15,
            ),
            hintStyle: const TextStyle(
              color: Color(0xFF8A94A8),
              fontSize: 14,
            ),
            labelStyle: const TextStyle(
              color: Color(0xFF52627A),
              fontSize: 14,
            ),
            helperStyle: const TextStyle(
              color: Color(0xFF68788D),
              fontSize: 12,
            ),
            errorStyle: const TextStyle(
              color: Color(0xFFDC2626),
              fontSize: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
              borderSide: BorderSide(color: Color(0xFFDCE4EE)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
              borderSide: BorderSide(color: Color(0xFFDCE4EE)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
              borderSide: BorderSide(color: Color(0xFF087F8C), width: 1.6),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
              borderSide: BorderSide(color: Color(0xFFDC2626)),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
              borderSide: BorderSide(color: Color(0xFFDC2626), width: 1.6),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF087F8C),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFFE5E7EB),
              disabledForegroundColor: const Color(0xFF8A94A8),
              minimumSize: const Size(48, 50),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
              ),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF344054),
              minimumSize: const Size(44, 48),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              side: const BorderSide(color: Color(0xFFDCE4EE)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF087F8C),
              minimumSize: const Size(40, 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          iconButtonTheme: IconButtonThemeData(
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xFF52627A),
              minimumSize: const Size(44, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
              ),
            ),
          ),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: Colors.white,
            indicatorColor: const Color(0xFFDDF5F2),
            elevation: 0,
            height: 70,
          ),
          floatingActionButtonTheme: FloatingActionButtonThemeData(
            backgroundColor: const Color(0xFF087F8C),
            foregroundColor: Colors.white,
            elevation: 3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF123B67),
            contentTextStyle: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          chipTheme: ChipThemeData(
            backgroundColor: const Color(0xFFF0F5FA),
            selectedColor: const Color(0xFFDDF5F2),
            secondarySelectedColor: const Color(0xFFDDF5F2),
            disabledColor: const Color(0xFFF4F7FB),
            labelStyle: const TextStyle(
              color: Color(0xFF344054),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
          listTileTheme: ListTileThemeData(
            iconColor: const Color(0xFF52627A),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          dividerTheme: const DividerThemeData(
            color: Color(0xFFE4EAF2),
            thickness: 1,
            space: 1,
          ),
          progressIndicatorTheme: const ProgressIndicatorThemeData(
            color: Color(0xFF087F8C),
            linearTrackColor: Color(0xFFDDF5F2),
            circularTrackColor: Color(0xFFDDF5F2),
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            titleTextStyle: const TextStyle(
              color: Color(0xFF123B67),
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        home: Consumer<AppState>(
          builder: (_, appState, __) {
            if (!appState.ready) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (appState.restoreError != null) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Could not restore your session.'),
                        const SizedBox(height: 12),
                        Text(appState.restoreError!,
                            textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        AsyncActionButton(
                          label: 'Retry',
                          icon: Icons.refresh,
                          onPressed: appState.init,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            if (appState.user != null) return const Home();
            // Open directly to authentication; the marketing homepage is no longer
            // a mandatory stop before a user can sign in or create an account.
            return Auth(startWithRegistration: appState.startRegistration);
          },
        ),
      );
}

// Public welcome/marketing screen shown before a user enters the authenticated app.
class Welcome extends StatelessWidget {
  const Welcome({
    super.key,
    required this.onSignIn,
    required this.onGetStarted,
  });

  final VoidCallback onSignIn;
  final VoidCallback onGetStarted;

  static const ink = Color(0xFF123B67);
  static const muted = Color(0xFF68788D);
  static const violet = Color(0xFF087F8C);
  static const mint = Color(0xFF7EDBD0);

  // Let customers discover published stores instead of needing to know a store slug.
  void _browseStore(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const StoreDirectoryPage(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: LayoutBuilder(
        builder: (context, viewport) {
          final wide = viewport.maxWidth >= 820;
          final mobile = viewport.maxWidth < 820;
          return SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1160),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      mobile ? 16 : 30, 18, mobile ? 16 : 30, 30),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Use a separate action row on narrow screens so Explore stores
                      // never gets pushed off-screen by the sign-in and account buttons.
                      if (mobile) ...[
                        Row(children: [
                          Container(
                            height: 42,
                            width: 42,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [
                                Color(0xFF087F8C),
                                Color(0xFF065F68)
                              ]),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.forum_rounded,
                                color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 11),
                          const Text('Chatify',
                              style: TextStyle(
                                  color: ink,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.8)),
                        ]),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.start,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _browseStore(context),
                              icon: const Icon(Icons.storefront_outlined),
                              label: const Text('Explore stores'),
                            ),
                            TextButton(
                                onPressed: onSignIn,
                                child: const Text('Sign in')),
                            FilledButton(
                              onPressed: onGetStarted,
                              style: FilledButton.styleFrom(
                                backgroundColor: violet,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 13),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(13)),
                              ),
                              child: const Text('Create account'),
                            ),
                          ],
                        ),
                      ] else
                        Row(children: [
                          Container(
                            height: 42,
                            width: 42,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [
                                Color(0xFF087F8C),
                                Color(0xFF065F68)
                              ]),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.forum_rounded,
                                color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 11),
                          const Text('Chatify',
                              style: TextStyle(
                                  color: ink,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.8)),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => _browseStore(context),
                            icon: const Icon(Icons.storefront_outlined),
                            label: const Text('Explore stores'),
                          ),
                          TextButton(
                              onPressed: onSignIn,
                              child: const Text('Sign in')),
                          const SizedBox(width: 5),
                          FilledButton(
                            onPressed: onGetStarted,
                            style: FilledButton.styleFrom(
                              backgroundColor: violet,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 13),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(13)),
                            ),
                            child: const Text('Create account'),
                          ),
                        ]),
                      SizedBox(height: wide ? 34 : 22),
                      if (wide)
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                flex: 4,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 26),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 7),
                                          decoration: BoxDecoration(
                                              color: const Color(0xFFDDF5F2),
                                              borderRadius:
                                                  BorderRadius.circular(30)),
                                          child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.circle,
                                                    color: Color(0xFF7EDBD0),
                                                    size: 8),
                                                SizedBox(width: 7),
                                                Text('YOUR PEOPLE, RIGHT HERE',
                                                    style: TextStyle(
                                                        color:
                                                            Color(0xFF087F8C),
                                                        fontSize: 9,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        letterSpacing: 0.8)),
                                              ]),
                                        ),
                                        const SizedBox(height: 20),
                                        const Text('Just chat.',
                                            style: TextStyle(
                                                color: ink,
                                                fontSize: 54,
                                                height: 1.0,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: -2.8)),
                                        const SizedBox(height: 10),
                                        const Text('The moments matter.',
                                            style: TextStyle(
                                                color: violet,
                                                fontSize: 30,
                                                height: 1.1,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: -1.2)),
                                        const SizedBox(height: 16),
                                        const Text(
                                            'Real conversations. Memories worth keeping.',
                                            style: TextStyle(
                                                color: muted,
                                                fontSize: 14,
                                                height: 1.6)),
                                        const SizedBox(height: 24),
                                        FilledButton.icon(
                                          onPressed: onGetStarted,
                                          icon: const Icon(
                                              Icons.chat_bubble_outline_rounded,
                                              size: 18),
                                          label: const Text('Start chatting'),
                                          style: FilledButton.styleFrom(
                                            backgroundColor: violet,
                                            minimumSize: const Size(190, 50),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(14)),
                                          ),
                                        ),
                                      ]),
                                ),
                              ),
                              const Expanded(
                                  flex: 6, child: _ConversationPreview()),
                            ])
                      else ...[
                        const Text('Your people. Your conversations.',
                            style: TextStyle(
                                color: ink,
                                fontSize: 27,
                                height: 1.1,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1)),
                        const SizedBox(height: 7),
                        const Text('Chat, remember, let go.',
                            style: TextStyle(color: muted, fontSize: 13)),
                        const SizedBox(height: 20),
                        const _ConversationPreview(),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: onGetStarted,
                          icon: const Icon(Icons.chat_bubble_outline_rounded,
                              size: 18),
                          label: const Text('Start chatting'),
                          style: FilledButton.styleFrom(
                            backgroundColor: violet,
                            minimumSize: const Size.fromHeight(50),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.lock_outline_rounded,
                                color: muted, size: 15),
                            SizedBox(width: 7),
                            Flexible(
                                child: Text(
                                    'Private by design · Yours to manage',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: muted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600))),
                          ]),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// Small illustrative conversation used by the welcome screen; it is presentation-only, not a real chat.
class _ConversationPreview extends StatelessWidget {
  const _ConversationPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: const LinearGradient(
          colors: [Color(0xFF082F49), Color(0xFF151B30)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [
          BoxShadow(
              color: Color(0x1C292C57), blurRadius: 44, offset: Offset(0, 22)),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.forum_rounded, color: Welcome.mint, size: 20),
              const SizedBox(width: 8),
              const Text('A little preview',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                    color: const Color(0x223DD7B0),
                    borderRadius: BorderRadius.circular(20)),
                child: const Row(
                  children: [
                    Icon(Icons.circle, color: Welcome.mint, size: 7),
                    SizedBox(width: 6),
                    Text('CONNECTED',
                        style: TextStyle(
                            color: Welcome.mint,
                            fontSize: 9,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFF7EDBD0), Color(0xFFB8A1FF)]),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(Icons.people_alt_rounded,
                          color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Weekend plans',
                              style: TextStyle(
                                  color: Welcome.ink,
                                  fontWeight: FontWeight.w800)),
                          SizedBox(height: 3),
                          Text('Maya, Alex · 3 members',
                              style: TextStyle(
                                  color: Welcome.muted, fontSize: 11)),
                        ],
                      ),
                    ),
                    const Icon(Icons.more_horiz, color: Welcome.muted),
                  ],
                ),
                const SizedBox(height: 20),
                const _PreviewBubble(
                  initials: 'M',
                  name: 'Maya',
                  text: 'Let’s meet at 10 on Saturday ☀️',
                  mine: false,
                ),
                const SizedBox(height: 10),
                const _PreviewBubble(
                  initials: 'Y',
                  name: 'You',
                  text: 'Perfect! I’ll save that so we don’t forget.',
                  mine: true,
                ),
                const SizedBox(height: 15),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDDF5F2),
                    border: Border.all(color: const Color(0xFFDDF5F2)),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.auto_awesome_rounded,
                          color: Color(0xFF087F8C), size: 19),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('MEMORY CARD',
                                style: TextStyle(
                                    color: Color(0xFF087F8C),
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.1)),
                            SizedBox(height: 5),
                            Text('Saturday · 10:00 AM',
                                style: TextStyle(
                                    color: Color(0xFF082F49),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800)),
                            SizedBox(height: 3),
                            Text(
                                'A detail worth keeping, right when you need it.',
                                style: TextStyle(
                                    color: Color(0xFF52627A),
                                    fontSize: 11,
                                    height: 1.45)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.add_circle_outline_rounded,
                        color: Color(0xFF929AAF), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                            color: const Color(0xFFF4F7FB),
                            borderRadius: BorderRadius.circular(13)),
                        child: const Text('Write a message…',
                            style: TextStyle(
                                color: Color(0xFF929AAF), fontSize: 11)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 38,
                      width: 38,
                      decoration: BoxDecoration(
                          color: Welcome.violet,
                          borderRadius: BorderRadius.circular(13)),
                      child: const Icon(Icons.arrow_upward_rounded,
                          color: Colors.white, size: 19),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline_rounded,
                  color: Color(0xFFDCE4EE), size: 14),
              SizedBox(width: 7),
              Text('Your conversations, with you in control',
                  style: TextStyle(color: Color(0xFFDCE4EE), fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }
}

// Reusable message bubble for the welcome-screen preview.
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.initials,
    required this.name,
    required this.text,
    required this.mine,
  });
  final String initials;
  final String name;
  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!mine) ...[
          CircleAvatar(
              radius: 15,
              backgroundColor: const Color(0xFFDDF5F2),
              child: Text(initials,
                  style: const TextStyle(
                      color: Welcome.violet,
                      fontSize: 11,
                      fontWeight: FontWeight.w800))),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: mine ? const Color(0xFFDDF5F2) : const Color(0xFFF3F5FA),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(15),
                topRight: const Radius.circular(15),
                bottomLeft: Radius.circular(mine ? 15 : 5),
                bottomRight: Radius.circular(mine ? 5 : 15),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        color: Welcome.violet,
                        fontSize: 10,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(text,
                    style: const TextStyle(
                        color: Welcome.ink, fontSize: 12, height: 1.4)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// Reusable icon-and-text item for the welcome screen's feature/trust list.
class Auth extends StatefulWidget {
  const Auth({super.key, this.startWithRegistration = false});
  final bool startWithRegistration;
  @override
  State<Auth> createState() => _AuthState();
}

// Validates the form, calls the authentication API, and updates AppState after success.
class _AuthState extends State<Auth> {
  late bool reg;
  bool busy = false, hide = true;

  @override
  void initState() {
    super.initState();
    reg = widget.startWithRegistration;
  }

  final n = TextEditingController(),
      e = TextEditingController(),
      p = TextEditingController(),
      mpesaPhone = TextEditingController();
  @override
  void dispose() {
    n.dispose();
    e.dispose();
    p.dispose();
    mpesaPhone.dispose();
    super.dispose();
  }

  Future<void> recover() async {
    final email = TextEditingController(text: e.text.trim());
    final token = TextEditingController();
    final password = TextEditingController();
    var requested = false;
    final key = GlobalKey<FormState>();
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
                title: const Text('Reset password'),
                content: Form(
                    key: key,
                    child: TextFormField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration:
                            const InputDecoration(labelText: 'Account email'),
                        validator: (v) => v == null || !v.contains('@')
                            ? 'Enter a valid email'
                            : '')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(d),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (!key.currentState!.validate()) return;
                        try {
                          await context.read<AppState>().api.call(
                              'POST',
                              '/api/auth/forgot-password',
                              {'email': email.text.trim()});
                          requested = true;
                          if (d.mounted) Navigator.pop(d);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'If the account exists, reset instructions will be sent.')));
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.toString())));
                          }
                        }
                      },
                      child: const Text('Send instructions'))
                ]));
    email.dispose();
    if (requested && mounted) {
      await showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
                  title: const Text('Choose a new password'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: token,
                        decoration:
                            const InputDecoration(labelText: 'Reset token')),
                    TextField(
                        controller: password,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'New password (8+ characters)'))
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            await context.read<AppState>().api.call(
                                'POST', '/api/auth/reset-password', {
                              'token': token.text.trim(),
                              'newPassword': password.text
                            });
                            if (d.mounted) Navigator.pop(d);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Password updated. Sign in with your new password.')));
                            }
                          } catch (error) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error.toString())));
                            }
                          }
                        },
                        child: const Text('Reset password'))
                  ]));
    }
    token.dispose();
    password.dispose();
  }

  Future<void> submit() async {
    if (e.text.trim().isEmpty ||
        p.text.length < 8 ||
        (reg &&
            (n.text.trim().isEmpty ||
                normalizeKenyanPhone(mpesaPhone.text) == null))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Complete all fields. Password must be 8+ characters.')));
      return;
    }
    setState(() => busy = true);
    final err = await context.read<AppState>().auth(
        reg, n.text.trim(), e.text.trim(), p.text, mpesaPhone.text.trim());
    if (mounted) {
      setState(() => busy = false);
      if (err != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0D172033),
                        blurRadius: 36,
                        offset: Offset(0, 14),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          height: 56,
                          width: 56,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF7C4DFF), Color(0xFF065F68)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x264F46E5),
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.forum_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Chatify',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF123B67),
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Chat. Remember. Let Go.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF68788D),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        reg ? 'Create your account' : 'Welcome back',
                        style: const TextStyle(
                          color: Color(0xFF123B67),
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.55,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        reg
                            ? 'Join the conversation and keep what matters.'
                            : 'Sign in to pick up where your conversations left off.',
                        style: const TextStyle(
                          color: Color(0xFF68788D),
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (reg)
                        TextField(
                          controller: n,
                          autofillHints: const [AutofillHints.name],
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                        ),
                      if (reg) const SizedBox(height: 10),
                      if (reg)
                        TextField(
                          controller: mpesaPhone,
                          keyboardType: TextInputType.phone,
                          autofillHints: const [AutofillHints.telephoneNumber],
                          decoration: const InputDecoration(
                            labelText: 'M-Pesa phone number',
                            hintText: '0712345678 or 254712345678',
                            helperText:
                                'Your default payment number. You can change it per request.',
                            prefixIcon:
                                Icon(Icons.account_balance_wallet_outlined),
                          ),
                        ),
                      if (reg) const SizedBox(height: 10),
                      TextField(
                        controller: e,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: p,
                        obscureText: hide,
                        autofillHints: [
                          reg
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        onSubmitted: (_) => submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            tooltip: hide ? 'Show password' : 'Hide password',
                            onPressed: () => setState(() => hide = !hide),
                            icon: Icon(
                              hide
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: busy ? null : submit,
                        child: busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(reg ? 'Create account' : 'Sign in'),
                      ),
                      if (!reg)
                        Align(
                          alignment: Alignment.center,
                          child: TextButton(
                            onPressed: busy ? null : recover,
                            child: const Text('Forgot password?'),
                          ),
                        ),
                      const SizedBox(height: 0),
                      const Divider(),
                      const SizedBox(height: 2),
                      TextButton(
                        onPressed:
                            busy ? null : () => setState(() => reg = !reg),
                        child: Text(
                          reg
                              ? 'Already have an account? Sign in'
                              : 'Create a new account',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

// Platform operations dashboard. Every action is re-authorized by the API.
class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});
  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

enum _AdminSection { overview, approvals, people, payments, billing }

class _AdminDashboardState extends State<AdminDashboard> {
  Map<String, dynamic> overview = {};
  Map<String, dynamic> platformStatus = {};
  List<dynamic> users = [], payments = [], schoolApprovals = [], businessApprovals = [];
  bool approvalsLoading = false;
  String? approvalsError;
  List<dynamic> workspaceBillingRows = [];
  bool workspaceBillingRowsLoading = false;
  String? workspaceBillingRowsError;
  bool loading = true,
      usersLoading = false,
      paymentsLoading = false,
      statusLoading = false;
  String? error;
  String userQuery = '', paymentStatus = '';
  String? statusError;
  Map<String, dynamic> feeWalletSettings = {};
  bool feeWalletLoading = false,
      feeWalletSaving = false,
      feeWalletEnabled = true;
  String feeWalletType = 'mpesa_phone';
  final TextEditingController feeRateController =
      TextEditingController(text: '0.5');
  final TextEditingController feeWalletPhoneController =
      TextEditingController();
  final TextEditingController feePaybillController = TextEditingController();
  final TextEditingController feeTillController = TextEditingController();
  final TextEditingController feeAccountReferenceController =
      TextEditingController(text: 'CHATIFY-FEE');
  Map<String, dynamic> workspaceBillingSettings = {};
  bool workspaceBillingSettingsLoading = false,
      workspaceBillingSettingsSaving = false;
  final TextEditingController businessSetupFeeController =
      TextEditingController(text: '1000');
  final TextEditingController businessMonthlyFeeController =
      TextEditingController(text: '500');
  final TextEditingController schoolSetupFeeController =
      TextEditingController(text: '5000');
  final TextEditingController schoolMonthlyFeeController =
      TextEditingController(text: '2500');
  final TextEditingController billingGraceDaysController =
      TextEditingController(text: '3');
  int userPage = 1, paymentPage = 1, userTotal = 0, paymentTotal = 0;
  DateTime? refreshedAt;
  _AdminSection section = _AdminSection.overview;
  final TextEditingController searchController = TextEditingController();
  Api get api => context.read<AppState>().api;

  Future<void> loadOverview() async {
    if (mounted && overview.isEmpty) setState(() => loading = true);
    try {
      final result = await api.call('GET', '/api/admin/overview');
      if (!mounted) return;
      setState(() {
        overview = Map<String, dynamic>.from(result['stats'] ?? {});
        users = List<dynamic>.from(result['recentUsers'] ?? []);
        payments = List<dynamic>.from(result['recentPayments'] ?? []);
        userTotal = result['userTotal'] is num
            ? (result['userTotal'] as num).toInt()
            : userTotal;
        refreshedAt = DateTime.now();
        error = null;
        loading = false;
      });
    } catch (e) {
      if (mounted)
        setState(() {
          error = e.toString();
          loading = false;
        });
    }
  }

  Future<void> loadPlatformStatus() async {
    if (mounted) setState(() => statusLoading = true);
    try {
      final result = await api.publicStatus();
      if (!mounted) return;
      setState(() {
        platformStatus = result;
        statusError = null;
      });
    } catch (e) {
      if (mounted)
        setState(() {
          statusError = e.toString();
        });
    } finally {
      if (mounted) setState(() => statusLoading = false);
    }
  }

  Future<void> refreshDashboard() async {
    await loadOverview();
    if (!mounted) return;
    await Future.wait([loadUsers(), loadPayments(), loadPlatformStatus()]);
  }

  Future<void> loadUsers() async {
    if (mounted) setState(() => usersLoading = true);
    try {
      final query = userQuery.trim();
      final path = '/api/admin/users?page=$userPage&limit=20' +
          (query.isEmpty ? '' : '&q=' + Uri.encodeQueryComponent(query));
      final result = await api.call('GET', path);
      if (mounted)
        setState(() {
          users = List<dynamic>.from(result['users'] ?? []);
          userTotal = (result['total'] as num?)?.toInt() ?? users.length;
        });
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not load users: ' + e.toString())));
    } finally {
      if (mounted) setState(() => usersLoading = false);
    }
  }

  Future<void> loadPayments() async {
    if (mounted) setState(() => paymentsLoading = true);
    try {
      final path = '/api/admin/payments?page=$paymentPage&limit=20' +
          (paymentStatus.isEmpty ? '' : '&status=' + paymentStatus);
      final result = await api.call('GET', path);
      if (mounted)
        setState(() {
          payments = List<dynamic>.from(result['payments'] ?? []);
          paymentTotal = (result['total'] as num?)?.toInt() ?? payments.length;
        });
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not load payments: ' + e.toString())));
    } finally {
      if (mounted) setState(() => paymentsLoading = false);
    }
  }

  Future<void> loadApprovals() async {
    if (mounted) setState(() { approvalsLoading = true; approvalsError = null; });
    try {
      final schoolsResult = await api.call('GET', '/api/schools/verification-requests');
      if (schoolsResult['reviewer'] != true) throw Exception('This account is not authorized to review school applications.');
      final businessesResult = await api.call('GET', '/api/admin/business-approvals');
      if (!mounted) return;
      setState(() {
        schoolApprovals = List<dynamic>.from(schoolsResult['requests'] ?? []);
        businessApprovals = List<dynamic>.from(businessesResult['businesses'] ?? []);
      });
    } catch (e) {
      if (mounted) setState(() => approvalsError = e.toString());
    } finally {
      if (mounted) setState(() => approvalsLoading = false);
    }
  }

  Future<void> reviewApproval(String type, Map<String, dynamic> item, String decision) async {
    final isSchool = type == 'school';
    final label = (item[isSchool ? 'schoolName' : 'name'] ?? type).toString();
    final approved = decision == 'APPROVE';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${approved ? 'Approve' : 'Reject'} $label?'),
        content: Text(approved
            ? 'This verifies the ${isSchool ? 'school' : 'business'} for Chatify. Workspace subscription payment remains a separate requirement.'
            : 'This marks the ${isSchool ? 'school' : 'business'} application as rejected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: approved ? null : FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(approved ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final id = (item['id'] ?? item['_id'] ?? '').toString();
      if (id.isEmpty) throw Exception('The application is missing its ID.');
      if (isSchool) {
        await api.call('POST', '/api/schools/verification-requests/$id/review', {
          'decision': decision,
          'reviewNote': approved ? 'Approved from Chatify Control Center.' : 'Rejected from Chatify Control Center.',
        });
      } else {
        await api.call('POST', '/api/admin/business-approvals/$id/review', {
          'decision': decision,
          'reviewNote': approved ? 'Approved from Chatify Control Center.' : 'Rejected from Chatify Control Center.',
        });
      }
      await loadApprovals();
      await loadOverview();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label ${approved ? 'approved' : 'rejected'}.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not review $label: $e')));
    }
  }

  Widget _approvalCard({
    required String name,
    required String detail,
    required String location,
    required VoidCallback onApprove,
    required VoidCallback onReject,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(backgroundColor: theme.colorScheme.primaryContainer, child: Icon(Icons.verified_user_outlined, color: theme.colorScheme.onPrimaryContainer)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(detail, style: theme.textTheme.bodySmall),
              if (location.isNotEmpty) ...[const SizedBox(height: 3), Text(location, style: theme.textTheme.bodySmall)],
            ])),
            _statusChip('PENDING', Colors.orange.shade800),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: onApprove, icon: const Icon(Icons.check_circle_outline), label: const Text('Approve')),
            OutlinedButton.icon(onPressed: onReject, icon: const Icon(Icons.close), label: const Text('Reject')),
          ]),
        ]),
      ),
    );
  }

  Widget _approvalsSection(ThemeData theme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Applications and verification', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      const Text('Review school identity requests and business workspace applications. Approval is separate from subscription payment.'),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _metric('Schools awaiting review', schoolApprovals.length, Icons.school_outlined)),
        const SizedBox(width: 10),
        Expanded(child: _metric('Businesses awaiting review', businessApprovals.length, Icons.business_outlined)),
      ]),
      const SizedBox(height: 12),
      Align(alignment: Alignment.centerRight, child: OutlinedButton.icon(onPressed: approvalsLoading ? null : loadApprovals, icon: const Icon(Icons.refresh), label: const Text('Refresh applications'))),
      if (approvalsLoading) const LinearProgressIndicator(),
      if (approvalsError != null) Card(child: ListTile(leading: const Icon(Icons.error_outline), title: const Text('Applications could not be loaded'), subtitle: Text(approvalsError!), trailing: IconButton(onPressed: loadApprovals, icon: const Icon(Icons.refresh)))),
      Text('School applications', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (!approvalsLoading && schoolApprovals.isEmpty) const Card(child: ListTile(leading: Icon(Icons.school_outlined), title: Text('No pending school applications'))),
      ...schoolApprovals.map((raw) {
        final item = Map<String, dynamic>.from(raw as Map);
        return _approvalCard(
          name: (item['schoolName'] ?? 'Unnamed school').toString(),
          detail: 'Code: ${item['proposedCode'] ?? '—'} · County: ${item['county'] ?? '—'}',
          location: '${item['officialEmail'] ?? ''} · ${item['officialPhone'] ?? ''}',
          onApprove: () => reviewApproval('school', item, 'APPROVE'),
          onReject: () => reviewApproval('school', item, 'REJECT'),
        );
      }),
      const SizedBox(height: 12),
      Text('Business applications', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (!approvalsLoading && businessApprovals.isEmpty) const Card(child: ListTile(leading: Icon(Icons.business_outlined), title: Text('No pending business applications'))),
      ...businessApprovals.map((raw) {
        final item = Map<String, dynamic>.from(raw as Map);
        final owner = item['owner'] is Map ? Map<String, dynamic>.from(item['owner'] as Map) : <String, dynamic>{};
        return _approvalCard(
          name: (item['name'] ?? 'Unnamed business').toString(),
          detail: '${item['industry'] ?? 'Business'} · Owner: ${owner['name'] ?? 'Unknown'}',
          location: '${owner['email'] ?? item['email'] ?? ''} · ${item['phone'] ?? owner['phone'] ?? ''}',
          onApprove: () => reviewApproval('business', item, 'APPROVE'),
          onReject: () => reviewApproval('business', item, 'REJECT'),
        );
      }),
    ]);
  }

  Future<void> loadWorkspaceBillingRows() async {
    if (mounted) setState(() { workspaceBillingRowsLoading = true; workspaceBillingRowsError = null; });
    try {
      final result = await api.call('GET', '/api/admin/workspace-billing-status');
      if (mounted) setState(() => workspaceBillingRows = List<dynamic>.from(result['workspaces'] ?? []));
    } catch (e) {
      if (mounted) setState(() => workspaceBillingRowsError = e.toString());
    } finally {
      if (mounted) setState(() => workspaceBillingRowsLoading = false);
    }
  }

  Widget _workspaceBillingStatusSection(ThemeData theme) {
    final active = workspaceBillingRows.where((raw) {
      final row = raw is Map ? raw : <String, dynamic>{};
      final billing = row['billing'] is Map ? row['billing'] as Map : <String, dynamic>{};
      return billing['locked'] != true;
    }).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Workspace subscription monitor', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
            IconButton(tooltip: 'Refresh workspace billing', onPressed: workspaceBillingRowsLoading ? null : loadWorkspaceBillingRows, icon: const Icon(Icons.refresh)),
          ]),
          const SizedBox(height: 4),
          Text('${workspaceBillingRows.length} workspaces tracked · $active currently within their billing access window'),
          const SizedBox(height: 10),
          if (workspaceBillingRowsLoading) const LinearProgressIndicator(),
          if (workspaceBillingRowsError != null) ListTile(leading: const Icon(Icons.error_outline), title: const Text('Could not load workspace billing'), subtitle: Text(workspaceBillingRowsError!)),
          if (!workspaceBillingRowsLoading && workspaceBillingRows.isEmpty) const ListTile(leading: Icon(Icons.info_outline), title: Text('No school or business workspaces found')),
          ...workspaceBillingRows.map((raw) {
            final row = Map<String, dynamic>.from(raw as Map);
            final billing = row['billing'] is Map ? Map<String, dynamic>.from(row['billing'] as Map) : <String, dynamic>{};
            final owner = row['owner'] is Map ? Map<String, dynamic>.from(row['owner'] as Map) : <String, dynamic>{};
            final locked = billing['locked'] == true;
            final status = (billing['status'] ?? (locked ? 'PAYMENT REQUIRED' : 'ACTIVE')).toString().toUpperCase();
            final expiry = row['subscriptionExpiresAt']?.toString();
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(child: Icon(row['type'] == 'school' ? Icons.school_outlined : Icons.business_outlined)),
                title: Text((row['name'] ?? 'Unnamed workspace').toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${(row['type'] ?? 'workspace').toString().toUpperCase()} · ${owner['name'] ?? owner['email'] ?? 'Owner unavailable'}\nSetup: ${row['setupFeePaid'] == true ? 'Paid' : 'Unpaid'} · Subscription expiry: ${expiry == null ? 'Not active' : expiry.split('T').first}\nApproval: ${row['approvalStatus'] ?? '—'}'),
                isThreeLine: true,
                trailing: _statusChip(status, locked ? theme.colorScheme.error : Colors.green),
              ),
            );
          }),
        ]),
      ),
    );
  }

  Future<void> loadFeeWalletSettings() async {
    if (mounted) setState(() => feeWalletLoading = true);
    try {
      final result = await api.call('GET', '/api/admin/platform-fee-settings');
      final settings = Map<String, dynamic>.from(result['settings'] ?? {});
      if (!mounted) return;
      setState(() {
        feeWalletSettings = settings;
        feeWalletEnabled = settings['enabled'] != false;
        feeWalletType = settings['walletType']?.toString() ?? 'mpesa_phone';
        feeRateController.text = (settings['feeRate'] ?? 0.5).toString();
        feeWalletPhoneController.text =
            settings['walletPhone']?.toString() ?? '';
        feePaybillController.text = settings['paybillNumber']?.toString() ?? '';
        feeTillController.text = settings['tillNumber']?.toString() ?? '';
        feeAccountReferenceController.text =
            settings['accountReference']?.toString() ?? 'CHATIFY-FEE';
      });
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not load platform wallet settings: $e')));
    } finally {
      if (mounted) setState(() => feeWalletLoading = false);
    }
  }

  Future<void> saveFeeWalletSettings() async {
    final rate = double.tryParse(feeRateController.text.trim());
    if (rate == null || rate < 0 || rate > 5) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Legacy fee settings are retained for historical compatibility; they do not apply to new transactions.')));
      return;
    }
    setState(() => feeWalletSaving = true);
    try {
      final result = await api.call('PUT', '/api/admin/platform-fee-settings', {
        'enabled': feeWalletEnabled,
        'feeRate': rate,
        'walletType': feeWalletType,
        'walletPhone': feeWalletPhoneController.text.trim(),
        'paybillNumber': feePaybillController.text.trim(),
        'tillNumber': feeTillController.text.trim(),
        'accountReference': feeAccountReferenceController.text.trim(),
      });
      if (!mounted) return;
      setState(() => feeWalletSettings =
          Map<String, dynamic>.from(result['settings'] ?? {}));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Legacy settings saved. These do not apply transaction commissions.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Settings were not saved: $e')));
    } finally {
      if (mounted) setState(() => feeWalletSaving = false);
    }
  }

  Future<void> loadWorkspaceBillingSettings() async {
    if (mounted) setState(() => workspaceBillingSettingsLoading = true);
    try {
      final result =
          await api.call('GET', '/api/admin/workspace-billing-settings');
      final settings = Map<String, dynamic>.from(result['settings'] ?? {});
      if (!mounted) return;
      setState(() {
        workspaceBillingSettings = settings;
        businessSetupFeeController.text =
            (settings['businessSetupFee'] ?? 1000).toString();
        businessMonthlyFeeController.text =
            (settings['businessMonthlyFee'] ?? 500).toString();
        schoolSetupFeeController.text =
            (settings['schoolSetupFee'] ?? 5000).toString();
        schoolMonthlyFeeController.text =
            (settings['schoolMonthlyFee'] ?? 2500).toString();
        billingGraceDaysController.text =
            (settings['gracePeriodDays'] ?? 3).toString();
      });
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not load workspace billing settings: $e')));
    } finally {
      if (mounted) setState(() => workspaceBillingSettingsLoading = false);
    }
  }

  Future<void> saveWorkspaceBillingSettings() async {
    int? parse(TextEditingController controller) =>
        int.tryParse(controller.text.trim());
    final businessSetup = parse(businessSetupFeeController);
    final businessMonthly = parse(businessMonthlyFeeController);
    final schoolSetup = parse(schoolSetupFeeController);
    final schoolMonthly = parse(schoolMonthlyFeeController);
    final graceDays = parse(billingGraceDaysController);
    final amounts = [
      businessSetup,
      businessMonthly,
      schoolSetup,
      schoolMonthly
    ];
    if (amounts.any((value) => value == null || value < 0 || value > 1000000) ||
        graceDays == null ||
        graceDays < 0 ||
        graceDays > 30) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Enter whole-number prices from KSh 0 to KSh 1,000,000 and a grace period from 0 to 30 days.')));
      return;
    }
    setState(() => workspaceBillingSettingsSaving = true);
    try {
      final result =
          await api.call('PUT', '/api/admin/workspace-billing-settings', {
        'businessSetupFee': businessSetup,
        'businessMonthlyFee': businessMonthly,
        'schoolSetupFee': schoolSetup,
        'schoolMonthlyFee': schoolMonthly,
        'gracePeriodDays': graceDays,
      });
      if (!mounted) return;
      setState(() => workspaceBillingSettings =
          Map<String, dynamic>.from(result['settings'] ?? {}));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Workspace setup and subscription prices saved.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Billing settings were not saved: $e')));
    } finally {
      if (mounted) setState(() => workspaceBillingSettingsSaving = false);
    }
  }

  Widget _workspaceBillingSection(ThemeData theme) {
    Widget amountField(TextEditingController controller, String label) =>
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: label,
              prefixText: 'KSh ',
              border: const OutlineInputBorder()),
        );
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Workspace setup and monthly subscriptions',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                  'These prices apply to new workspaces. Setup is a one-time payment; subscriptions renew monthly. Existing workspaces are grandfathered until migrated deliberately.'),
              if (workspaceBillingSettingsLoading)
                const LinearProgressIndicator(),
              const SizedBox(height: 12),
              amountField(
                  businessSetupFeeController, 'Business one-time setup fee'),
              const SizedBox(height: 10),
              amountField(businessMonthlyFeeController,
                  'Business monthly subscription'),
              const SizedBox(height: 10),
              amountField(
                  schoolSetupFeeController, 'School one-time setup fee'),
              const SizedBox(height: 10),
              amountField(
                  schoolMonthlyFeeController, 'School monthly subscription'),
              const SizedBox(height: 10),
              TextField(
                  controller: billingGraceDaysController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Grace period after expiry (days)',
                      border: OutlineInputBorder(),
                      helperText: 'Allowed range: 0–30 days.')),
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: workspaceBillingSettingsSaving ||
                          workspaceBillingSettingsLoading
                      ? null
                      : saveWorkspaceBillingSettings,
                  icon: workspaceBillingSettingsSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: Text(workspaceBillingSettingsSaving
                      ? 'Saving…'
                      : 'Save workspace billing prices')),
            ])));
  }

  Future<void> changeStatus(Map<String, dynamic> user) async {
    final id = user['_id']?.toString() ?? user['id']?.toString();
    if (id == null || id.isEmpty) return;
    final current = user['status']?.toString() ?? 'active';
    final next = current == 'active' ? 'suspended' : 'active';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
            next == 'suspended' ? 'Suspend account?' : 'Reactivate account?'),
        content: Text(
            (user['email'] ?? user['name'] ?? 'This user').toString() +
                ' will ' +
                (next == 'suspended' ? 'lose access' : 'regain access') +
                ' to Chatify.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(next == 'suspended' ? 'Suspend' : 'Reactivate')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.call(
          'PATCH', '/api/admin/users/' + id + '/status', {'status': next});
      await loadOverview();
      await loadUsers();
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Account ' +
                (next == 'active' ? 'reactivated.' : 'suspended.'))));
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Account status was not changed: ' + e.toString())));
    }
  }

  @override
  void initState() {
    super.initState();
    refreshDashboard();
  }

  @override
  void dispose() {
    searchController.dispose();
    feeRateController.dispose();
    feeWalletPhoneController.dispose();
    businessSetupFeeController.dispose();
    businessMonthlyFeeController.dispose();
    schoolSetupFeeController.dispose();
    schoolMonthlyFeeController.dispose();
    billingGraceDaysController.dispose();
    feePaybillController.dispose();
    feeTillController.dispose();
    feeAccountReferenceController.dispose();
    super.dispose();
  }

  Widget _metric(String label, dynamic value, IconData icon) {
    final shown = value is num ? value.toString() : (value?.toString() ?? '0');
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon,
                size: 21, color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 12),
          Text(shown,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(label, maxLines: 2, style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }

  Widget _healthPanel(ThemeData theme) {
    final components = (platformStatus['components'] as List?) ?? const [];
    final status = platformStatus['status']?.toString() ?? 'unknown';
    final healthy = status == 'operational';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(
                healthy
                    ? Icons.health_and_safety_outlined
                    : Icons.warning_amber_rounded,
                color: healthy
                    ? Colors.green.shade700
                    : theme.colorScheme.tertiary),
            const SizedBox(width: 10),
            Expanded(
                child: Text('Service health',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800))),
            if (statusLoading)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            _statusChip(status.toUpperCase(),
                healthy ? Colors.green : theme.colorScheme.tertiary),
          ]),
          const SizedBox(height: 8),
          Text(
              statusError ??
                  platformStatus['notice']?.toString() ??
                  'Checking the public service status endpoint…',
              style: theme.textTheme.bodySmall),
          if (components.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
                spacing: 8,
                runSpacing: 8,
                children: components.whereType<Map>().map((item) {
                  final componentStatus =
                      item['status']?.toString() ?? 'unknown';
                  final color = componentStatus == 'operational'
                      ? Colors.green
                      : theme.colorScheme.tertiary;
                  return _statusChip(
                      '${item['name']}: $componentStatus', color);
                }).toList()),
          ],
        ]),
      ),
    );
  }

  Widget _statusChip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(20)),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  Widget _pager(
      {required int page,
      required int total,
      required VoidCallback previous,
      required VoidCallback next}) {
    final pages = total == 0 ? 0 : (total / 20).ceil();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Text(total == 0
            ? 'No records'
            : 'Page $page of $pages · $total records'),
        const Spacer(),
        IconButton(
            tooltip: 'Previous page',
            onPressed: page > 1 ? previous : null,
            icon: const Icon(Icons.chevron_left)),
        IconButton(
            tooltip: 'Next page',
            onPressed: page < pages ? next : null,
            icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }

  // Retained for compatibility with the legacy platform-fee settings API; it is intentionally not shown because new transactions use workspace subscriptions, not percentage commissions.
  // ignore: unused_element
  Widget _feeWalletSection(ThemeData theme) {
    final walletNeedsPhone = feeWalletType == 'mpesa_phone';
    final walletNeedsPaybill = feeWalletType == 'mpesa_paybill';
    final walletNeedsTill = feeWalletType == 'mpesa_till';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Platform fee and wallet',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
              'Chatify no longer charges a percentage commission on transfers, business payments, POS sales or school-fee payments. Use Workspace billing to configure one-time setup and monthly subscription prices. These legacy settings do not control current transaction payments.'),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Legacy fee toggle (not used)'),
            subtitle: const Text(
                'Only eligible business checkout flows currently apply this setting.'),
            value: feeWalletEnabled,
            onChanged: feeWalletSaving
                ? null
                : (value) => setState(() => feeWalletEnabled = value),
          ),
          TextField(
            controller: feeRateController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Legacy platform fee (%)',
                helperText:
                    'Historical setting only; current transactions are commission-free.'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: feeWalletType,
            decoration: const InputDecoration(
                labelText: 'Platform wallet account type'),
            items: const [
              DropdownMenuItem(
                  value: 'mpesa_phone', child: Text('M-Pesa phone')),
              DropdownMenuItem(value: 'mpesa_paybill', child: Text('Paybill')),
              DropdownMenuItem(value: 'mpesa_till', child: Text('Till')),
            ],
            onChanged: feeWalletSaving
                ? null
                : (value) {
                    if (value != null) setState(() => feeWalletType = value);
                  },
          ),
          if (walletNeedsPhone)
            TextField(
              controller: feeWalletPhoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Wallet phone (254XXXXXXXXX)'),
            ),
          if (walletNeedsPaybill)
            TextField(
              controller: feePaybillController,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'Platform Paybill number'),
            ),
          if (walletNeedsTill)
            TextField(
              controller: feeTillController,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'Platform Till number'),
            ),
          TextField(
            controller: feeAccountReferenceController,
            decoration:
                const InputDecoration(labelText: 'Account/reference label'),
          ),
          const SizedBox(height: 12),
          const Text(
              'Important: this saves the fee destination for reconciliation. Automatic splitting/transfer of collected funds requires the platform’s Safaricom merchant and disbursement integration; saving a wallet number alone does not move money.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: feeWalletSaving || feeWalletLoading
                ? null
                : saveFeeWalletSettings,
            icon: feeWalletSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: Text(feeWalletSaving ? 'Saving…' : 'Save wallet settings'),
          ),
        ]),
      ),
    );
  }

  Widget _peopleSection(ThemeData theme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('People and access',
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(
          'Review account status and verification. Every change is checked by the server.',
          style: theme.textTheme.bodyMedium),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
            child: TextField(
          controller: searchController,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search name or email',
              border: OutlineInputBorder()),
          onSubmitted: (value) {
            userQuery = value;
            userPage = 1;
            loadUsers();
          },
        )),
        const SizedBox(width: 8),
        IconButton.filledTonal(
            tooltip: 'Search accounts',
            onPressed: () {
              userQuery = searchController.text;
              userPage = 1;
              loadUsers();
            },
            icon: const Icon(Icons.search)),
      ]),
      if (usersLoading) const LinearProgressIndicator(),
      if (!usersLoading && users.isEmpty)
        const Card(
            child: ListTile(
                leading: Icon(Icons.people_outline),
                title: Text('No accounts found'),
                subtitle: Text('Try a different name or email.'))),
      ...users.map((item) {
        final user = Map<String, dynamic>.from(item as Map);
        final role = user['role']?.toString() ?? 'user';
        final status = user['status']?.toString() ?? 'active';
        final name = user['name']?.toString() ?? 'Unnamed user';
        return Card(
            child: ListTile(
          leading: CircleAvatar(
              child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              '${user['email'] ?? ''}\n${role.toUpperCase()} · ${status.toUpperCase()} · ${user['emailVerified'] == true ? 'Verified' : 'Unverified'}'),
          isThreeLine: true,
          trailing: role == 'admin'
              ? const Chip(label: Text('Admin'))
              : PopupMenuButton<String>(
                  tooltip: 'Account actions',
                  onSelected: (_) => changeStatus(user),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'toggle',
                        child: Text(status == 'active'
                            ? 'Suspend account'
                            : 'Reactivate account'))
                  ],
                ),
        ));
      }),
      _pager(
          page: userPage,
          total: userTotal,
          previous: () {
            setState(() => userPage--);
            loadUsers();
          },
          next: () {
            setState(() => userPage++);
            loadUsers();
          }),
    ]);
  }

  Widget _paymentsSection(ThemeData theme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Payment operations',
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(
          'Monitor transaction states and investigate pending or failed activity.',
          style: theme.textTheme.bodyMedium),
      const SizedBox(height: 12),
      Align(
          alignment: Alignment.centerLeft,
          child: DropdownButton<String>(
            value: paymentStatus,
            items: const [
              DropdownMenuItem(value: '', child: Text('All statuses')),
              DropdownMenuItem(value: 'PENDING', child: Text('Pending')),
              DropdownMenuItem(value: 'SUCCESS', child: Text('Successful')),
              DropdownMenuItem(value: 'FAILED', child: Text('Failed')),
              DropdownMenuItem(value: 'CANCELLED', child: Text('Cancelled')),
            ],
            onChanged: (value) {
              setState(() {
                paymentStatus = value ?? '';
                paymentPage = 1;
              });
              loadPayments();
            },
          )),
      if (paymentsLoading) const LinearProgressIndicator(),
      if (!paymentsLoading && payments.isEmpty)
        const Card(
            child: ListTile(
                leading: Icon(Icons.payments_outlined),
                title: Text('No payments found'),
                subtitle: Text('There are no transactions for this filter.'))),
      ...payments.map((item) {
        final payment = Map<String, dynamic>.from(item as Map);
        final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
        final platformFee = (payment['platformFee'] as num?)?.toDouble() ?? 0;
        final totalAmount = (payment['totalAmount'] as num?)?.toDouble() ??
            amount + platformFee;
        final status = payment['status']?.toString() ?? 'Unknown';
        final color = status == 'SUCCESS'
            ? Colors.green
            : status == 'FAILED'
                ? theme.colorScheme.error
                : theme.colorScheme.tertiary;
        return Card(
            child: ListTile(
          leading: CircleAvatar(
              backgroundColor: color.withValues(alpha: .1),
              child: Icon(
                  status == 'SUCCESS'
                      ? Icons.check_circle_outline
                      : status == 'FAILED'
                          ? Icons.error_outline
                          : Icons.payments_outlined,
                  color: color)),
          title: Text(payment['description']?.toString() ??
              payment['paymentId']?.toString() ??
              'Payment'),
          subtitle: Text(
              '${payment['provider'] ?? 'Provider'} · $status\n${payment['paymentId'] ?? ''}${platformFee > 0 ? '\nHistorical platform fee KSh ${platformFee.toStringAsFixed(0)} · ${payment['platformFeeStatus'] ?? 'PENDING_SETTLEMENT'}' : ''}'),
          isThreeLine: true,
          trailing: Text('KES ${totalAmount.toStringAsFixed(2)}',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ));
      }),
      _pager(
          page: paymentPage,
          total: paymentTotal,
          previous: () {
            setState(() => paymentPage--);
            loadPayments();
          },
          next: () {
            setState(() => paymentPage++);
            loadPayments();
          }),
      const SizedBox(height: 8),
      const Text(
          'A successful payment is recorded only after the provider confirmation is validated.'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading && overview.isEmpty)
      return const Center(child: CircularProgressIndicator());
    if (error != null && overview.isEmpty)
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.admin_panel_settings_outlined, size: 48),
          const SizedBox(height: 12),
          Text('Administrator dashboard could not load',
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          AsyncActionButton(
              label: 'Try again', icon: Icons.refresh, onPressed: loadOverview),
        ]),
      ));
    final money =
        (overview['successfulPaymentAmount'] as num?)?.toDouble() ?? 0;
    final screenWidth = MediaQuery.sizeOf(context).width;
    return RefreshIndicator(
      onRefresh: refreshDashboard,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            screenWidth > 900 ? 32 : 16, 20, screenWidth > 900 ? 32 : 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                theme.colorScheme.primary,
                theme.colorScheme.secondary
              ], begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(children: [
              const CircleAvatar(
                  radius: 26,
                  backgroundColor: Colors.white24,
                  child: Icon(Icons.space_dashboard_rounded,
                      color: Colors.white, size: 28)),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('Chatify Control Center',
                        style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                        'Communication, business activity, accounts and payment operations.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withValues(alpha: .9))),
                    if (refreshedAt != null) ...[
                      const SizedBox(height: 8),
                      Text(
                          'Updated ${TimeOfDay.fromDateTime(refreshedAt!).format(context)}',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: Colors.white70)),
                    ],
                  ])),
              IconButton(
                  tooltip: 'Refresh control center',
                  onPressed: refreshDashboard,
                  color: Colors.white,
                  icon: const Icon(Icons.refresh_rounded)),
            ]),
          ),
          const SizedBox(height: 14),
          _healthPanel(theme),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_AdminSection>(
            segments: const [
              ButtonSegment(
                  value: _AdminSection.overview,
                  label: Text('Overview'),
                  icon: Icon(Icons.dashboard_outlined)),
              ButtonSegment(
                  value: _AdminSection.approvals,
                  label: Text('Approvals'),
                  icon: Icon(Icons.fact_check_outlined)),
              ButtonSegment(
                  value: _AdminSection.people,
                  label: Text('People'),
                  icon: Icon(Icons.people_outline)),
              ButtonSegment(
                  value: _AdminSection.payments,
                  label: Text('Payments'),
                  icon: Icon(Icons.payments_outlined)),
              ButtonSegment(
                  value: _AdminSection.billing,
                  label: Text('Workspace billing'),
                  icon: Icon(Icons.workspace_premium_outlined)),
            ],
            selected: {section},
            onSelectionChanged: (value) {
              setState(() => section = value.first);
              if (section == _AdminSection.approvals) loadApprovals();
              if (section == _AdminSection.people && users.isEmpty) loadUsers();
              if (section == _AdminSection.payments && payments.isEmpty)
                loadPayments();
              if (section == _AdminSection.billing) {
                loadWorkspaceBillingSettings();
                loadWorkspaceBillingRows();
              }
            },
            ),
          ),
          const SizedBox(height: 18),
          if (section == _AdminSection.overview) ...[
            Text('Platform snapshot',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
                'Live counts from Chatify records. “Active” means an enabled account, not an online presence.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: screenWidth > 1100
                  ? 4
                  : screenWidth > 700
                      ? 3
                      : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: screenWidth > 700 ? 1.4 : 1.2,
              children: [
                _metric('Accounts', overview['totalUsers'],
                    Icons.people_alt_outlined),
                _metric('Enabled accounts', overview['activeUsers'],
                    Icons.verified_user_outlined),
                _metric('Verified email', overview['verifiedUsers'],
                    Icons.mark_email_read_outlined),
                _metric('Businesses', overview['totalBusinesses'],
                    Icons.business_outlined),
                _metric('Business customers', overview['businessCustomers'],
                    Icons.groups_2_outlined),
                _metric('Published catalogue items', overview['catalogItems'],
                    Icons.inventory_2_outlined),
                _metric('Conversations', overview['totalConversations'],
                    Icons.forum_outlined),
                _metric('Messages', overview['totalMessages'],
                    Icons.chat_bubble_outline),
                _metric('Saved memories', overview['totalMemories'],
                    Icons.auto_awesome_outlined),
                _metric('Open business cases', overview['openCases'],
                    Icons.support_agent_outlined),
                _metric('Pending payments', overview['pendingPayments'],
                    Icons.hourglass_top),
                _metric('Failed payments', overview['failedPayments'],
                    Icons.error_outline),
                _metric('School workspaces', overview['totalSchools'],
                    Icons.school_outlined),
                _metric('Enrolled students', overview['totalStudents'],
                    Icons.groups_outlined),
                _metric(
                    'Attendance records',
                    overview['totalAttendanceRecords'],
                    Icons.fact_check_outlined),
                _metric('Academic assessments', overview['totalAssessments'],
                    Icons.grading_outlined),
                _metric('School fee records', overview['totalSchoolFees'],
                    Icons.receipt_long_outlined),
              ],
            ),
            const SizedBox(height: 12),
            Card(
                child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Last 24 hours',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 10, runSpacing: 8, children: [
                      Chip(
                          avatar: const Icon(Icons.person_add_alt_1, size: 18),
                          label: Text(
                              '${overview['newUsers24h'] ?? 0} new accounts')),
                      Chip(
                          avatar: const Icon(Icons.forum_outlined, size: 18),
                          label: Text(
                              '${overview['newMessages24h'] ?? 0} messages')),
                      Chip(
                          avatar:
                              const Icon(Icons.add_business_outlined, size: 18),
                          label: Text(
                              '${overview['newBusinesses24h'] ?? 0} new businesses')),
                    ]),
                  ]),
            )),
            Card(
                child: ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('Recorded successful payment volume'),
              subtitle: const Text(
                  'Gross confirmed transaction volume; it is not revenue or net profit.'),
              trailing: Text('KES ${money.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
            )),
            const SizedBox(height: 12),
            Card(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Chatify income', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text('Confirmed school and business workspace setup fees and subscriptions only. School fees paid directly to schools and ordinary business sales are not counted as Chatify income.'),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _metric('Total earned', 'KSh ${((overview['chatifyTotalIncome'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}', Icons.account_balance_wallet_outlined)),
                  const SizedBox(width: 10),
                  Expanded(child: _metric('This month', 'KSh ${((overview['currentMonthChatifyIncome'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}', Icons.calendar_month_outlined)),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _metric('Setup fees', 'KSh ${((overview['workspaceSetupIncome'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}', Icons.receipt_long_outlined)),
                  const SizedBox(width: 10),
                  Expanded(child: _metric('Subscriptions', 'KSh ${((overview['workspaceSubscriptionIncome'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}', Icons.autorenew_outlined)),
                ]),
              ]),
            )),
            const SizedBox(height: 12),
            Card(
                child: ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Protected operations'),
              subtitle: const Text(
                  'Account actions and platform data are authorized by the API for administrator accounts.'),
              trailing: const Icon(Icons.lock_outline),
            )),
          ] else if (section == _AdminSection.approvals) ...[
            _approvalsSection(theme),
          ] else if (section == _AdminSection.people) ...[
            _peopleSection(theme),
          ] else if (section == _AdminSection.payments) ...[
            _paymentsSection(theme),
          ] else ...[
            _workspaceBillingSection(theme),
            const SizedBox(height: 12),
            _workspaceBillingStatusSection(theme),
          ],
        ],
      ),
    );
  }
}

// Return the other participant's HTTPS profile image for a direct chat. Group chats
// intentionally use their title initial until a dedicated group image is configured.
String? _conversationProfileImage(dynamic conversation, dynamic currentUser) {
  // Only direct chats use a participant's profile photo. Group imagery is a
  // separate conversation-level field and must never inherit a member's avatar.
  if (conversation is! Map ||
      conversation['type'] != 'direct' ||
      conversation['participants'] is! List) return null;
  final currentId = currentUser is Map
      ? (currentUser['id'] ?? currentUser['_id'])?.toString()
      : null;
  for (final person
      in (conversation['participants'] as List).whereType<Map>()) {
    final personId = (person['_id'] ?? person['id'])?.toString();
    if (currentId != null && personId == currentId) continue;
    final image = person['profileImage'];
    if (image is String && image.startsWith('https://')) return image;
  }
  return null;
}

String? _conversationGroupImage(dynamic conversation) {
  if (conversation is! Map || conversation['type'] != 'group') return null;
  final image = conversation['image'];
  return image is String && image.startsWith('https://') ? image : null;
}

// Main authenticated workspace containing chats, contacts and saved memories.

/// School workspace UI for administrators, parents and staff.
class SchoolWorkspacePage extends StatefulWidget {
  const SchoolWorkspacePage({super.key});
  @override
  State<SchoolWorkspacePage> createState() => _SchoolWorkspacePageState();
}

class _SchoolWorkspacePageState extends State<SchoolWorkspacePage> {
  AppState get app => context.read<AppState>();
  List<dynamic> schools = [],
      messages = [],
      fees = [],
      feeStructures = [],
      schoolClasses = [],
      feeBalances = [],
      members = [],
      students = [],
      feeStudents = [],
      attendance = [],
      assessments = [],
      schoolVerificationRequests = [];
  Map<String, dynamic> feePaymentOptions = {};
  String receiptStampDataUrl = '';
  String feeStudentName = '';
  String parentFeePaymentMethod = '';
  String? schoolId, role, error;
  bool isOwner = false;
  bool isSchoolVerificationReviewer = false;
  Map<String, dynamic> schoolBilling = {};
  bool schoolBillingLoading = false;
  bool loading = false;
  int section = 0, recordPage = 1, recordTotal = 0;
  // Local search and class filtering for school record views.
  String schoolSearchQuery = '';
  String schoolClassFilter = 'all';
  String messageAudienceFilter = 'all';
  String messagePeriodFilter = 'all';
  bool scheduleSchoolEvent = false;
  final TextEditingController schoolSearchController = TextEditingController();
  static const int _recordPageSize = 50;
  final schoolName = TextEditingController(),
      schoolCode = TextEditingController(),
      schoolCounty = TextEditingController(),
      schoolOfficialEmail = TextEditingController(),
      schoolOfficialPhone = TextEditingController(),
      joinSchoolCode = TextEditingController(),
      joinStaffCode = TextEditingController(),
      staffInviteCode = TextEditingController();
  final memberEmail = TextEditingController(),
      studentNames = TextEditingController(),
      recipientIdController = TextEditingController();
  final messageBody = TextEditingController(),
      messageSubject = TextEditingController();
  final amount = TextEditingController(),
      feeStudent = TextEditingController(),
      feeTerm = TextEditingController(),
      payerPhone = TextEditingController();
  final newSchoolClass = TextEditingController();
  final feeStructureClass = TextEditingController(),
      feeStructureYear = TextEditingController(text: DateTime.now().year.toString()),
      feeStructureTerm = TextEditingController(text: 'Term 1'),
      feeStructureItems = TextEditingController();
  final paybill = TextEditingController(),
      till = TextEditingController(),
      bank = TextEditingController(),
      account = TextEditingController();
  final darajaConsumerKey = TextEditingController(),
      darajaConsumerSecret = TextEditingController(),
      darajaPasskey = TextEditingController();
  final conferenceTitle = TextEditingController(),
      conferenceAgenda = TextEditingController(),
      conferenceLocation = TextEditingController();
  final conferenceDate = TextEditingController(
      text: DateTime.now()
          .add(const Duration(days: 1))
          .toIso8601String()
          .substring(0, 10));
  final conferenceStartTime = TextEditingController(text: '10:00'),
      conferenceEndTime = TextEditingController(text: '11:00');
  final admissionNumber = TextEditingController(),
      registeredStudentName = TextEditingController(),
      studentClass = TextEditingController(),
      guardianName = TextEditingController(),
      guardianPhone = TextEditingController(),
      guardianEmail = TextEditingController();
  final promotionFromClass = TextEditingController(),
      promotionToClass = TextEditingController(),
      promotionYear = TextEditingController(text: DateTime.now().year.toString());
  final attendanceDate = TextEditingController(
          text: DateTime.now().toIso8601String().substring(0, 10)),
      attendanceNote = TextEditingController();
  final subjectName = TextEditingController(),
      assessmentName = TextEditingController(),
      assessmentTerm = TextEditingController(),
      assessmentScore = TextEditingController(),
      assessmentOutOf = TextEditingController(text: '100'),
      teacherNote = TextEditingController();
  String attendanceStudentId = '',
      attendanceStatus = 'present',
      assessmentStudentId = '';
  String memberRole = 'parent',
      staffDesignation = 'Teacher',
      audience = 'direct',
      paymentMethod = 'mpesa_paybill',
      darajaMode = 'production';

  @override
  void initState() {
    super.initState();
    payerPhone.text =
        (app.user?['mpesaPhone'] ?? app.user?['phone'] ?? '').toString();
    loadSchools();
  }

  @override
  void dispose() {
    for (final c in [
      schoolName,
      schoolCode,
      schoolCounty,
      schoolOfficialEmail,
      schoolOfficialPhone,
      joinSchoolCode,
      joinStaffCode,
      staffInviteCode,
      memberEmail,
      studentNames,
      messageBody,
      messageSubject,
      recipientIdController,
      amount,
      feeStudent,
      feeTerm,
      payerPhone,
      newSchoolClass,
      feeStructureClass,
      feeStructureYear,
      feeStructureTerm,
      feeStructureItems,
      paybill,
      till,
      bank,
      account,
      darajaConsumerKey,
      darajaConsumerSecret,
      darajaPasskey,
      conferenceTitle,
      conferenceAgenda,
      conferenceLocation,
      conferenceDate,
      conferenceStartTime,
      conferenceEndTime,
      admissionNumber,
      registeredStudentName,
      studentClass,
      guardianName,
      guardianPhone,
      guardianEmail,
      promotionFromClass,
      promotionToClass,
      promotionYear,
      attendanceDate,
      attendanceNote,
      subjectName,
      assessmentName,
      assessmentTerm,
      assessmentScore,
      assessmentOutOf,
      teacherNote
    ]) {
      c.dispose();
    }
    schoolSearchController.dispose();
    super.dispose();
  }

  Future<void> loadSchools() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await app.api.call('GET', '/api/schools');
      schools = List<dynamic>.from(result['schools'] ?? []);
      try {
        final verification =
            await app.api.call('GET', '/api/schools/verification-requests');
        schoolVerificationRequests =
            List<dynamic>.from(verification['requests'] ?? []);
        isSchoolVerificationReviewer = verification['reviewer'] == true;
      } catch (_) {
        // Existing school access remains usable if verification-request listing is unavailable.
      }
      if (schoolId == null && schools.isNotEmpty)
        _selectSchool(Map<String, dynamic>.from(schools.first));
      if (mounted) setState(() {});
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  void _selectSchool(Map<String, dynamic> s) {
    schoolId = s['id']?.toString();
    // A previous school's class/search filters must never leak into another workspace.
    schoolSearchQuery = '';
    schoolSearchController.clear();
    schoolClassFilter = 'all';
    messageAudienceFilter = 'all';
    messagePeriodFilter = 'all';
    role = s['role']?.toString();
    isOwner = s['isOwner'] == true;
    schoolCode.text = (s['code'] ?? '').toString();
    staffInviteCode.text = (s['staffInviteCode'] ?? '').toString();
    final p = s['paymentProfile'];
    if (p is Map) {
      paymentMethod = (p['method'] ?? 'mpesa_paybill').toString();
      paybill.text = (p['paybillNumber'] ?? '').toString();
      till.text = (p['tillNumber'] ?? '').toString();
      bank.text = (p['bankName'] ?? '').toString();
      account.text = (p['accountNumber'] ?? '').toString();
      darajaMode = (p['darajaMode'] ?? darajaMode).toString();
    }
    loadSection();
    loadSchoolBilling();
    loadReceiptStampSettings();
  }

  Future<void> loadReceiptStampSettings() async {
    final id = schoolId;
    if (id == null || role != 'admin') {
      if (mounted) setState(() => receiptStampDataUrl = '');
      return;
    }
    try {
      final result = await app.api.call('GET', '/api/schools/$id/receipt-settings');
      if (mounted && schoolId == id) setState(() => receiptStampDataUrl = (result['receiptStampDataUrl'] ?? '').toString());
    } catch (_) {}
  }

  Future<void> pickReceiptStamp() async {
    final id = schoolId;
    if (id == null || role != 'admin') return;
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg'], withData: true);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) throw const FormatException('The selected image could not be read.');
      if (bytes.length > 700 * 1024) throw const FormatException('Choose a JPEG stamp image smaller than 700 KB.');
      if (_schoolReceiptJpegDimensions(bytes) == null) throw const FormatException('Choose a valid JPEG image of the school stamp.');
      final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      await app.api.call('PUT', '/api/schools/$id/receipt-settings', {'receiptStampDataUrl': dataUrl});
      if (mounted) setState(() {
        receiptStampDataUrl = dataUrl;
        feePaymentOptions['receiptStampDataUrl'] = dataUrl;
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('School stamp saved and will appear on receipts.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save school stamp: $e')));
    }
  }

  Future<void> removeReceiptStamp() async {
    final id = schoolId;
    if (id == null || role != 'admin') return;
    await _action(() async {
      await app.api.call('PUT', '/api/schools/$id/receipt-settings', {'receiptStampDataUrl': ''});
      if (mounted) setState(() {
        receiptStampDataUrl = '';
        feePaymentOptions['receiptStampDataUrl'] = '';
      });
    });
  }

  Future<void> loadSchoolBilling() async {
    final id = schoolId;
    if (id == null || !isOwner) {
      if (mounted) setState(() => schoolBilling = {});
      return;
    }
    if (mounted) setState(() => schoolBillingLoading = true);
    try {
      final result = await app.api.call(
          'GET', '/api/workspace-billing/school/${Uri.encodeComponent(id)}');
      if (mounted && schoolId == id)
        setState(() =>
            schoolBilling = Map<String, dynamic>.from(result['billing'] ?? {}));
    } catch (e) {
      if (mounted && schoolId == id) setState(() => error = e.toString());
    } finally {
      if (mounted && schoolId == id)
        setState(() => schoolBillingLoading = false);
    }
  }

  Future<void> paySchoolWorkspaceBilling(String billingType) async {
    final id = schoolId;
    if (id == null || !isOwner || schoolBillingLoading) return;
    final phoneController = TextEditingController(text: payerPhone.text.trim());
    final phone = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Workspace subscription payment'),
              content: TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                      labelText: 'M-Pesa phone number',
                      hintText: '07XXXXXXXX or 2547XXXXXXXX')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(
                        dialogContext, phoneController.text.trim()),
                    child: const Text('Continue to M-Pesa'))
              ],
            ));
    phoneController.dispose();
    if (phone == null || phone.isEmpty || !mounted) return;
    setState(() => schoolBillingLoading = true);
    try {
      final checkout = await app.api.call(
          'POST',
          '/api/workspace-billing/school/${Uri.encodeComponent(id)}/checkout',
          {'billingType': billingType});
      if (checkout['paid'] == true) {
        await loadSchoolBilling();
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content:
                  Text(checkout['notice']?.toString() ?? 'Billing updated.')));
        return;
      }
      final payment = Map<String, dynamic>.from(checkout['payment'] ?? {});
      final paymentId = payment['paymentId']?.toString();
      if (paymentId == null || paymentId.isEmpty)
        throw Exception(
            'The billing checkout did not return a payment reference.');
      if (payment['initiatedAt'] == null) {
        await app.api.call(
            'POST',
            '/api/payments/${Uri.encodeComponent(paymentId)}/initiate',
            {'phone': phone});
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'M-Pesa prompt requested. Approve it on your phone; the workspace unlocks only after confirmation.')));
      for (var attempt = 0; attempt < 20 && mounted; attempt++) {
        await Future.delayed(const Duration(seconds: 3));
        final statusResult = await app.api
            .call('GET', '/api/payments/${Uri.encodeComponent(paymentId)}');
        final current =
            Map<String, dynamic>.from(statusResult['payment'] ?? {});
        final status = current['status']?.toString().toUpperCase();
        if (status == 'SUCCESS') {
          await loadSchoolBilling();
          await loadSchools();
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'Payment confirmed. Refreshing school workspace access.')));
          return;
        }
        if (status == 'FAILED' || status == 'CANCELLED')
          throw Exception(
              'M-Pesa payment $status. You can retry from workspace billing.');
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Payment is still pending. Refresh billing shortly; do not pay again unless the first payment has failed.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => schoolBillingLoading = false);
    }
  }

  Future<void> showSchoolSupportOptions() async {
    final id = schoolId;
    if (id == null || !mounted) return;
    final donationAmount = TextEditingController();
    final donationPhone = TextEditingController(text: payerPhone.text.trim());
    final formKey = GlobalKey<FormState>();
    var busy = false;
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.volunteer_activism_outlined),
            SizedBox(width: 8),
            Expanded(child: Text('Donate / Support Us')),
          ]),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Enter your donation amount and M-Pesa number. Safaricom will send an STK prompt to your phone. Payment goes to the school’s configured Paybill or Till.'),
                const SizedBox(height: 12),
                TextFormField(
                  controller: donationAmount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Donation amount (KSh)', border: OutlineInputBorder()),
                  validator: (value) {
                    final n = int.tryParse((value ?? '').trim());
                    return n == null || n < 1 || n > 150000 ? 'Enter KSh 1–150,000' : null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: donationPhone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'M-Pesa phone number', hintText: '07XXXXXXXX or 2547XXXXXXXX', border: OutlineInputBorder()),
                  validator: (value) => normalizeKenyanPhone((value ?? '').trim()) == null ? 'Enter a valid Kenyan mobile number' : null,
                ),
              ],
            )),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: busy ? null : () async {
                if (!(formKey.currentState?.validate() ?? false)) return;
                setDialogState(() => busy = true);
                try {
                  final result = await app.api.call('POST', '/api/schools/$id/donations', {
                    'amount': int.parse(donationAmount.text.trim()),
                    'phone': donationPhone.text.trim(),
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                  if (mounted) {
                    final reference = result['donation']?['paymentReference'] ?? '';
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${result['note'] ?? 'M-Pesa prompt requested.'} Reference: $reference')));
                  }
                } catch (error) {
                  setDialogState(() => busy = false);
                  if (dialogContext.mounted) ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text(error.toString())));
                }
              },
              icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.lock_outline),
              label: Text(busy ? 'Requesting prompt…' : 'Send M-Pesa prompt'),
            ),
          ],
        ),
      ),
    );
    donationAmount.dispose();
    donationPhone.dispose();
    if (submitted == true) return;
  }

  Future<void> loadSection() async {
    final id = schoolId;
    if (id == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    final pageQuery = '?page=$recordPage&limit=$_recordPageSize';
    try {
      if (section == 0) {
        final r =
            await app.api.call('GET', '/api/schools/$id/messages$pageQuery${schoolSearchQuery.trim().isEmpty ? '' : '&q=${Uri.encodeQueryComponent(schoolSearchQuery.trim())}'}${messageAudienceFilter == 'all' ? '' : '&audience=$messageAudienceFilter'}${messagePeriodFilter == 'all' ? '' : '&period=$messagePeriodFilter'}');
        recordTotal = (r['total'] as num?)?.toInt() ?? 0;
        messages = List<dynamic>.from(r['messages'] ?? []);
        final directory = await app.api
            .call('GET', '/api/schools/$id/members?page=1&limit=50${schoolSearchQuery.trim().isEmpty ? '' : '&q=${Uri.encodeQueryComponent(schoolSearchQuery.trim())}'}');
        members = List<dynamic>.from(directory['members'] ?? []);
      } else if (section == 9) {
        final results = await Future.wait([
          app.api.call('GET', '/api/schools/$id/fee-structures?page=$recordPage&limit=$_recordPageSize&includeArchived=true'),
          app.api.call('GET', '/api/schools/$id/fee-balances'),
          app.api.call('GET', '/api/schools/$id/classes'),
        ]);
        feeStructures = List<dynamic>.from(results[0]['structures'] ?? []);
        feeBalances = List<dynamic>.from(results[1]['balances'] ?? []);
        schoolClasses = List<dynamic>.from(results[2]['classes'] ?? []);
        if (feeStructureClass.text.trim().isNotEmpty && !schoolClasses.map((v) => v.toString()).contains(feeStructureClass.text.trim())) {
          schoolClasses = [...schoolClasses, feeStructureClass.text.trim()];
        }
        recordTotal = (results[0]['total'] as num?)?.toInt() ?? feeStructures.length;
      } else if (section == 2 || section == 8) {
        final feesResult =
            await app.api.call('GET', '/api/schools/$id/fees$pageQuery');
        Map<String, dynamic> studentResult = {};
        try {
          // The roster is useful for fee filters and parent student selection,
          // but a roster failure must not hide the fee payment form.
          studentResult = await app.api.call(
              'GET', '/api/schools/$id/students?page=1&limit=100');
          students = List<dynamic>.from(studentResult['students'] ?? []);
        } catch (_) {
          students = [];
        }
        final r = feesResult;
        recordTotal = (r['total'] as num?)?.toInt() ?? 0;
        fees = List<dynamic>.from(r['payments'] ?? []);
        feePaymentOptions = r['paymentOptions'] is Map
            ? Map<String, dynamic>.from(r['paymentOptions'])
            : {};
        // Older or partially migrated API responses may omit paymentOptions.
        // Fall back to the selected school's saved profile rather than hiding
        // valid payment choices from parents.
        if (section == 2 &&
            role == 'parent' &&
            feePaymentOptions.isEmpty) {
          final selectedSchool = schools.cast<Map>().firstWhere(
                (school) => school['id']?.toString() == id,
                orElse: () => <String, dynamic>{},
              );
          final profile = selectedSchool['paymentProfile'];
          if (profile is Map) {
            final method = profile['method']?.toString() ?? '';
            feePaymentOptions = <String, dynamic>{
              'configured': method == 'mpesa_till'
                  ? (profile['tillNumber']?.toString().isNotEmpty ?? false)
                  : method == 'mpesa_paybill'
                      ? (profile['paybillNumber']?.toString().isNotEmpty ?? false)
                      : method == 'bank',
              'method': method,
              'tillNumber': profile['tillNumber'],
              'paybillNumber': profile['paybillNumber'],
              'officialPhone': profile['officialPhone'] ??
                  selectedSchool['officialPhone'] ??
                  selectedSchool['phone'],
            };
          }
        }
        if (section == 2) {
          // Fee balances are supplementary to the payment form. A failure to
          // load them must not prevent parents from seeing configured payment
          // methods or entering the phone used for an M-Pesa STK prompt.
          try {
            final balanceResult =
                await app.api.call('GET', '/api/schools/$id/fee-balances');
            feeBalances = List<dynamic>.from(balanceResult['balances'] ?? []);
          } catch (_) {
            feeBalances = [];
          }
        }
        if (section == 2 && role == 'parent') {
          final options = _parentFeePaymentOptions();
          if (!options
              .any((option) => option['value'] == parentFeePaymentMethod)) {
            parentFeePaymentMethod =
                options.isEmpty ? '' : options.first['value']!.toString();
          }
        }
        if (section == 2 && role == 'parent') {
          feeStudents = List<dynamic>.from(studentResult['students'] ?? []);
          if (!feeStudents.any(
              (student) => student['fullName']?.toString() == feeStudentName)) {
            feeStudentName = feeStudents.isNotEmpty
                ? (feeStudents.first['fullName'] ?? '').toString()
                : '';
          }
          feeStudent.text = feeStudentName;
        }
      } else if (section == 3 && role != 'parent') {
        final r =
            await app.api.call('GET', '/api/schools/$id/members$pageQuery');
        members = List<dynamic>.from(r['members'] ?? []);
        recordTotal = (r['total'] as num?)?.toInt() ?? 0;
      } else if (section == 5 || section == 6 || section == 7) {
        final results = await Future.wait([
          app.api.call(
              'GET',
              section == 5
                  ? '/api/schools/$id/students?page=$recordPage&limit=$_recordPageSize'
                  : '/api/schools/$id/students?page=1&limit=100'),
          if (section == 6)
            app.api.call('GET', '/api/schools/$id/attendance$pageQuery'),
          if (section == 7)
            app.api.call('GET', '/api/schools/$id/academics$pageQuery'),
        ]);
        students = List<dynamic>.from(results.first['students'] ?? []);
        recordTotal = (results.first['total'] as num?)?.toInt() ?? 0;
        if (section == 6 && results.length > 1) {
          attendance = List<dynamic>.from(results[1]['attendance'] ?? []);
          recordTotal = (results[1]['total'] as num?)?.toInt() ?? 0;
        }
        if (section == 7 && results.length > 1) {
          assessments = List<dynamic>.from(results[1]['assessments'] ?? []);
          recordTotal = (results[1]['total'] as num?)?.toInt() ?? 0;
        }
        if (!students.any(
            (student) => student['_id']?.toString() == attendanceStudentId)) {
          attendanceStudentId = students.isNotEmpty
              ? (students.first['_id']?.toString() ?? '')
              : '';
        }
        if (!students.any(
            (student) => student['_id']?.toString() == assessmentStudentId)) {
          assessmentStudentId = students.isNotEmpty
              ? (students.first['_id']?.toString() ?? '')
              : '';
        }
      }
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  String _selectedParentFeePaymentMethod() {
    final options = _parentFeePaymentOptions();
    if (options.any((option) => option['value'] == parentFeePaymentMethod)) {
      return parentFeePaymentMethod;
    }
    return options.isEmpty ? '' : options.first['value']!;
  }

  List<Map<String, String>> _parentFeePaymentOptions() {
    final options = <Map<String, String>>[];
    final configuredMethod = feePaymentOptions['method']?.toString();
    if (feePaymentOptions['configured'] == true &&
        configuredMethod == 'mpesa_till' &&
        (feePaymentOptions['tillNumber']?.toString().isNotEmpty ?? false)) {
      options.add({
        'value': 'mpesa_till',
        'label': 'Lipa na Till (${feePaymentOptions['tillNumber']})',
      });
    }
    if (feePaymentOptions['configured'] == true &&
        configuredMethod == 'mpesa_paybill' &&
        (feePaymentOptions['paybillNumber']?.toString().isNotEmpty ?? false)) {
      options.add({
        'value': 'mpesa_paybill',
        'label': 'Lipa na Paybill (${feePaymentOptions['paybillNumber']})',
      });
    }
    final schoolMpesaPhone =
        feePaymentOptions['officialPhone']?.toString() ?? '';
    if (normalizeKenyanPhone(schoolMpesaPhone) != null) {
      options.add({
        'value': 'mpesa_send_money',
        'label': 'Send Money ($schoolMpesaPhone)',
      });
    }
    if (configuredMethod == 'bank') {
      options.add({'value': 'bank', 'label': 'Bank transfer'});
    }
    return options;
  }

  // Keep billing UI implementation available for a future compact settings screen while hiding the large banner.
  // ignore: unused_element
  Widget _schoolBillingCard() {
    final prices = schoolBilling['prices'] is Map
        ? Map<String, dynamic>.from(schoolBilling['prices'] as Map)
        : <String, dynamic>{};
    final setupPaid = schoolBilling['setupFeePaid'] == true;
    final locked = schoolBilling['locked'] == true;
    final status = schoolBilling['status']?.toString() ?? 'Loading';
    final legacy = status == 'LEGACY_GRANDFATHERED';
    final setupFee = (prices['setupFee'] as num?)?.toInt() ?? 5000;
    final monthlyFee = (prices['monthlyFee'] as num?)?.toInt() ?? 2500;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.workspace_premium_outlined),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('School workspace billing',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
            if (schoolBillingLoading)
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 6),
          Text('Status: $status${locked ? ' · Workspace locked' : ''}'),
          if (legacy)
            const Text(
                'This existing workspace is grandfathered. No new billing lock or setup payment is being enforced yet.'),
          if (!legacy)
            Text(
                'One-time setup: KSh $setupFee${setupPaid ? ' · Paid' : ' · Unpaid'}'),
          if (!legacy) Text('Monthly subscription: KSh $monthlyFee'),
          if (schoolBilling['subscriptionExpiresAt'] != null)
            Text(
                'Subscription expiry: ${schoolBilling['subscriptionExpiresAt']}'),
          const SizedBox(height: 8),
          const Text(
              'School fee payments collected from parents are separate from this Chatify workspace subscription. No 0.5% Chatify transaction commission is charged.'),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!legacy && !setupPaid)
              FilledButton.icon(
                  onPressed: schoolBillingLoading
                      ? null
                      : () => paySchoolWorkspaceBilling('workspace_setup'),
                  icon: const Icon(Icons.payment),
                  label: Text('Pay setup · KSh $setupFee')),
            if (!legacy && setupPaid)
              FilledButton.icon(
                  onPressed: schoolBillingLoading
                      ? null
                      : () =>
                          paySchoolWorkspaceBilling('workspace_subscription'),
                  icon: const Icon(Icons.autorenew),
                  label: Text('Pay monthly · KSh $monthlyFee')),
            OutlinedButton.icon(
                onPressed: schoolBillingLoading ? null : loadSchoolBilling,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh billing')),
          ]),
        ]),
      ),
    );
  }

  Widget _schoolPager() {
    final pages = recordTotal == 0 ? 0 : (recordTotal / _recordPageSize).ceil();
    if (pages <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
            child: Text('Page $recordPage of $pages · $recordTotal records')),
        IconButton(
            tooltip: 'Previous page',
            onPressed: recordPage > 1
                ? () {
                    setState(() => recordPage--);
                    loadSection();
                  }
                : null,
            icon: const Icon(Icons.chevron_left)),
        IconButton(
            tooltip: 'Next page',
            onPressed: recordPage < pages
                ? () {
                    setState(() => recordPage++);
                    loadSection();
                  }
                : null,
            icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }

  Widget _responsiveSchoolTable({
    required List<DataColumn> columns,
    required List<DataRow> rows,
  }) {
    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: DataTable(columns: columns, rows: rows),
        ),
      );
    });
  }

  Future<void> _removeSchoolRecord(
      {required String label, required String endpoint}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete $label?'),
        content: Text(label == 'student'
            ? 'This archives the student and preserves historical school records.'
            : 'This action cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await app.api.call('DELETE', '/api/schools/$schoolId/$endpoint');
      await loadSection();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$label removed.')));
    } catch (error) {
      if (!mounted) return;
      await loadSection();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not delete $label: $error')));
    }
  }

  Widget _swipeSchoolRecord(
      {required String id,
      required String label,
      required String endpoint,
      required Widget child,
      bool showDeleteButton = true}) {
    final swipe = Dismissible(
      key: ValueKey('school-$section-$id'),
      direction: DismissDirection.startToEnd,
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12)),
        child: Icon(Icons.delete_outline,
            color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      confirmDismiss: (_) async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text('Delete $label?'),
            content: Text(label == 'student'
                ? 'This archives the student and preserves historical school records.'
                : 'This action cannot be undone.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Delete')),
            ],
          ),
        );
        return confirmed == true;
      },
      onDismissed: (_) async {
        try {
          await app.api.call('DELETE', '/api/schools/$schoolId/$endpoint');
          await loadSection();
        } catch (error) {
          await loadSection();
          if (context.mounted)
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Could not delete $label: $error')));
        }
      },
      child: child,
    );
    if (_useSwipeToDelete(context)) return swipe;
    if (!showDeleteButton) return child;
    return Row(children: [
      Expanded(child: child),
      IconButton(
        tooltip: 'Delete $label',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _removeSchoolRecord(label: label, endpoint: endpoint),
      ),
    ]);
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Saved successfully.')));
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> createSchool() async {
    if (schoolName.text.trim().isEmpty ||
        schoolCode.text.trim().isEmpty ||
        schoolCounty.text.trim().isEmpty ||
        schoolOfficialEmail.text.trim().isEmpty ||
        schoolOfficialPhone.text.trim().isEmpty) {
      setState(() => error =
          'Complete all school verification details before submitting.');
      return;
    }
    await _action(() async {
      await app.api.call('POST', '/api/schools/verification-requests', {
        'schoolName': schoolName.text.trim(),
        'proposedCode': schoolCode.text.trim(),
        'county': schoolCounty.text.trim(),
        'officialEmail': schoolOfficialEmail.text.trim(),
        'officialPhone': schoolOfficialPhone.text.trim(),
      });
      schoolName.clear();
      schoolCode.clear();
      schoolCounty.clear();
      schoolOfficialEmail.clear();
      schoolOfficialPhone.clear();
      await loadSchools();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Verification request submitted. The workspace will only be created after Chatify verifies the school.')),
        );
    });
  }

  Future<void> reviewSchoolVerification(
      Map<String, dynamic> request, String decision) async {
    final requestId = request['id']?.toString();
    if (!isSchoolVerificationReviewer || requestId == null) return;
    await _action(() async {
      await app.api.call(
          'POST', '/api/schools/verification-requests/$requestId/review', {
        'decision': decision,
        'reviewNote': decision == 'APPROVE'
            ? 'School identity verified by Chatify reviewer.'
            : 'School identity could not be verified.',
      });
      await loadSchools();
    });
  }

  Future<void> sendMessage() async {
    final id = schoolId;
    if (id == null) return;
    final schoolInboxOnly = role == 'parent' || role == 'staff';
    DateTime? startsAt;
    DateTime? endsAt;
    if (scheduleSchoolEvent) {
      final dateText = conferenceDate.text.trim();
      final startText = conferenceStartTime.text.trim();
      final endText = conferenceEndTime.text.trim();
      if (role != 'admin' ||
          conferenceTitle.text.trim().isEmpty || conferenceAgenda.text.trim().isEmpty ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateText) ||
          !RegExp(r'^\d{2}:\d{2}$').hasMatch(startText) ||
          !RegExp(r'^\d{2}:\d{2}$').hasMatch(endText)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an event title, agenda, date and valid start/end times.')));
        return;
      }
      final d = dateText.split('-').map(int.parse).toList();
      final st = startText.split(':').map(int.parse).toList();
      final et = endText.split(':').map(int.parse).toList();
      startsAt = DateTime(d[0], d[1], d[2], st[0], st[1]);
      endsAt = DateTime(d[0], d[1], d[2], et[0], et[1]);
      if (startsAt.year != d[0] || startsAt.month != d[1] || startsAt.day != d[2] ||
          st[0] > 23 || et[0] > 23 || st[1] > 59 || et[1] > 59 ||
          !startsAt.isAfter(DateTime.now()) || !endsAt.isAfter(startsAt)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choose a valid future date and an end time after the start time.')));
        return;
      }
    } else if (messageBody.text.trim().isEmpty) {
      return;
    }
    await _action(() async {
      await app.api.call('POST', '/api/schools/$id/messages', {
        'body': scheduleSchoolEvent ? conferenceAgenda.text.trim() : messageBody.text.trim(),
        'subject': scheduleSchoolEvent ? conferenceTitle.text.trim() : messageSubject.text.trim(),
        'audience': schoolInboxOnly ? 'school_inbox' : audience,
        if (!schoolInboxOnly && audience == 'direct' && !scheduleSchoolEvent)
          'recipientId': recipientIdController.text.trim(),
        if (scheduleSchoolEvent) ...{
          'messageType': 'conference',
          'startsAt': startsAt!.toUtc().toIso8601String(),
          'endsAt': endsAt!.toUtc().toIso8601String(),
          'location': conferenceLocation.text.trim(),
        },
      });
      messageBody.clear();
      messageSubject.clear();
      conferenceTitle.clear();
      conferenceAgenda.clear();
      conferenceLocation.clear();
      setState(() => scheduleSchoolEvent = false);
      await loadSection();
    });
  }

  Future<void> joinSchool() async {
    final code = joinSchoolCode.text.trim();
    if (code.isEmpty) {
      setState(() => error = 'Enter the school invite code.');
      return;
    }
    await _action(() async {
      final joined = await app.api.call('POST', '/api/schools/join', {
        'code': code,
        'role': memberRole,
        if (memberRole == 'staff') 'staffDesignation': staffDesignation,
        if (memberRole == 'staff') 'staffInviteCode': joinStaffCode.text.trim(),
        'studentNames': studentNames.text
            .split(',')
            .map((x) => x.trim())
            .where((x) => x.isNotEmpty)
            .toList(),
      });
      joinSchoolCode.clear();
      joinStaffCode.clear();
      studentNames.clear();
      await loadSchools();
      final joinedId =
          (joined['school'] is Map) ? joined['school']['id']?.toString() : null;
      final joinedSchool = schools
          .where((x) => x is Map && x['id']?.toString() == joinedId)
          .toList();
      if (joinedSchool.isNotEmpty)
        setState(
            () => _selectSchool(Map<String, dynamic>.from(joinedSchool.first)));
    });
  }

  Future<void> addMember() async {
    final id = schoolId;
    if (id == null || memberEmail.text.trim().isEmpty) return;
    await _action(() async {
      await app.api.call('POST', '/api/schools/$id/members', {
        'email': memberEmail.text.trim(),
        'role': memberRole,
        if (memberRole == 'staff') 'staffDesignation': staffDesignation,
        'studentNames': studentNames.text
            .split(',')
            .map((x) => x.trim())
            .where((x) => x.isNotEmpty)
            .toList()
      });
      memberEmail.clear();
      studentNames.clear();
      await loadSection();
    });
  }

  Future<void> editParentPupilInfo(Map<String, dynamic> member) async {
    final id = schoolId;
    if (id == null ||
        !isOwner ||
        role != 'admin' ||
        !['parent', 'staff'].contains(member['role'])) return;
    final namesController = TextEditingController(
      text: (member['studentNames'] is List
          ? (member['studentNames'] as List)
              .map((value) => value.toString())
              .join(', ')
          : ''),
    );
    final correctedNames = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Correct linked pupil information'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${member['role'] == 'staff' ? 'Staff member' : 'Parent'}: ${member['name'] ?? member['email'] ?? 'Member'}'),
              const SizedBox(height: 8),
              const Text(
                  'Set the exact pupil name(s) this member is authorized to view. Use names from the school register and separate multiple pupils with commas.'),
              const SizedBox(height: 12),
              TextField(
                controller: namesController,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Linked pupil name(s)',
                  hintText: 'e.g. Brian Otieno, Mary Otieno',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, namesController.text),
              child: const Text('Save corrections')),
        ],
      ),
    );
    final input = correctedNames;
    if (input == null) {
      namesController.dispose();
      return;
    }
    final names = input
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    namesController.dispose();
    if (names.isEmpty ||
        names.length > 10 ||
        names.any((name) => name.length > 100)) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Enter 1–10 pupil names, each no longer than 100 characters.')),
        );
      return;
    }
    await _action(() async {
      await app.api.call(
        'PUT',
        '/api/schools/$id/members/${member['id']}/student-info',
        {'studentNames': names},
      );
      await loadSection();
    });
  }

  Future<void> savePaymentProfile() async {
    final id = schoolId;
    if (id == null) return;
    await _action(() async {
      await app.api.call('PUT', '/api/schools/$id/payment-profile', {
        'method': paymentMethod,
        'paybillNumber': paybill.text.trim(),
        'tillNumber': till.text.trim(),
        'bankName': bank.text.trim(),
        'accountNumber': account.text.trim(),
        if (paymentMethod != 'bank') 'darajaMode': darajaMode,
        if (paymentMethod != 'bank')
          'darajaConsumerKey': darajaConsumerKey.text.trim(),
        if (paymentMethod != 'bank')
          'darajaConsumerSecret': darajaConsumerSecret.text.trim(),
        if (paymentMethod != 'bank') 'darajaPasskey': darajaPasskey.text.trim(),
      });
      darajaConsumerKey.clear();
      darajaConsumerSecret.clear();
      darajaPasskey.clear();
      await loadSchools();
    });
  }

  Future<void> downloadSchoolFeeReceipt(Map<String, dynamic> payment) async {
    final id = schoolId;
    final reference = payment['paymentReference']?.toString() ?? '';
    if (id == null || reference.isEmpty) return;
    if (payment['status'] != 'CONFIRMED') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'A receipt is available only after payment is confirmed.')),
      );
      return;
    }
    try {
      final uri =
          Uri.parse('${app.api.base}/api/schools/$id/fees/$reference/receipt');
      final response = await app.api.client.get(
        uri,
        headers: {
          if (app.api.token != null) 'Authorization': 'Bearer ${app.api.token}'
        },
      );
      if (response.statusCode >= 400) {
        throw ApiException(response.statusCode,
            'Receipt is unavailable. Refresh the fee records and try again.');
      }
      Map<String, dynamic> receiptSettings = {};
      try {
        receiptSettings = await app.api.call('GET', '/api/schools/$id/receipt-settings');
      } catch (_) {
        // Receipts remain downloadable even if optional stamp settings are unavailable.
      }
      await FileSaver.instance.saveFile(
        name: 'school-fee-receipt-$reference',
        bytes: _buildSchoolFeeReceiptPdf({
          ...Map<String, dynamic>.from(payment),
          'schoolName': (payment['schoolName'] ??
              feePaymentOptions['schoolName'] ??
              (payment['school'] is Map ? payment['school']['name'] : null)),
          'paymentMethod': schoolPaymentMethodForRecord(payment, configuredFallback: feePaymentOptions['method']),
          'configuredPaymentMethod': feePaymentOptions['method'],
          'receiptStampDataUrl': receiptSettings['receiptStampDataUrl'] ?? feePaymentOptions['receiptStampDataUrl'] ?? '',
        }),
        fileExtension: 'pdf',
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('School fee receipt downloaded successfully.')),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> verifyFee(Map<String, dynamic> payment) async {
    final id = schoolId;
    if (id == null) return;
    final receiptController = TextEditingController();
    final receipt = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Verify school fee payment'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(
                    'Confirm the real transaction in the school statement before entering its receipt/reference number. Ref: ${payment['paymentReference'] ?? ''}'),
                const SizedBox(height: 12),
                TextField(
                    controller: receiptController,
                    decoration: const InputDecoration(
                        labelText:
                            'Actual payment receipt / transaction reference')),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(ctx, receiptController.text.trim()),
                    child: const Text('Confirm payment'))
              ],
            ));
    final value = receipt?.trim() ?? '';
    if (value.isEmpty) {
      receiptController.dispose();
      return;
    }
    await _action(() async {
      await app.api.call(
          'POST',
          '/api/schools/$id/fees/${payment['paymentReference']}/verify',
          {'mpesaReceipt': value});
      await loadSection();
    });
    receiptController.dispose();
  }

  Future<void> showFeePaymentStatus(Map<String, dynamic> payment) async {
    final method = schoolPaymentMethodForRecord(payment, configuredFallback: feePaymentOptions['method']);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Payment status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Student: ${payment['studentName'] ?? 'Student'}'),
            Text('Status: ${payment['status'] ?? 'Unknown'}'),
            Text('Amount: KSh ${payment['amount'] ?? '—'}'),
            Text('Method: ${method ?? '—'}'),
            Text('Reference: ${payment['paymentReference'] ?? '—'}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> resendSchoolReceipt(Map<String, dynamic> payment) async {
    final id = schoolId;
    if (id == null) return;
    try {
      final result = await app.api.call('POST',
          '/api/schools/$id/fees/${payment['paymentReference']}/receipt/resend');
      final delivery = Map<String, dynamic>.from(result['emailDelivery'] ?? {});
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(delivery['pending'] == true
                ? 'Receipt remains stored and downloadable; email delivery is still pending. Check SMTP configuration.'
                : 'Receipt email sent to the parent and school administrators.')));
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> saveSchoolClass() async {
    final id = schoolId;
    final name = newSchoolClass.text.trim();
    if (id == null || name.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a class or grade name first.')));
      return;
    }
    await _action(() async {
      final result = await app.api.call('POST', '/api/schools/$id/classes', {'className': name});
      schoolClasses = List<dynamic>.from(result['classes'] ?? schoolClasses);
      final savedName = (result['className'] ?? name).toString();
      feeStructureClass.text = savedName;
      newSchoolClass.clear();
      if (mounted) setState(() {});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Class/grade "$savedName" is configured and available in fee setup.')));
    });
  }

  /// Saves a new class/academic-period fee template version.
  /// The API validates amounts and leaves previously issued charges unchanged.
  Future<void> saveFeeStructure() async {
    final id = schoolId;
    final className = feeStructureClass.text.trim();
    final academicYear = feeStructureYear.text.trim();
    final term = feeStructureTerm.text.trim();
    final items = <Map<String, dynamic>>[];
    for (final line in feeStructureItems.text.split(RegExp(r'\r?\n'))) {
      final value = line.trim();
      if (value.isEmpty) continue;
      final separator = value.lastIndexOf(':');
      final description = separator > 0 ? value.substring(0, separator).trim() : '';
      final itemAmount = separator > 0 ? int.tryParse(value.substring(separator + 1).trim()) : null;
      if (description.isEmpty || itemAmount == null || itemAmount <= 0) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter each fee as Description:Amount, for example Tuition:12000.')));
        return;
      }
      items.add({'description': description, 'amount': itemAmount});
    }
    if (id == null || className.isEmpty || academicYear.isEmpty || term.isEmpty || items.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Complete the class, academic year, term and at least one fee item.')));
      return;
    }
    await _action(() async {
      final result = await app.api.call('POST', '/api/schools/$id/fee-structures', {
        'className': className, 'academicYear': academicYear, 'term': term, 'items': items,
      });
      feeStructureItems.clear();
      await loadSection();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text((result['note'] ?? 'Fee structure saved as a new version.').toString())));
    });
  }

  Future<void> issueFeeStructure(Map<String, dynamic> structure) async {
    final id = schoolId;
    final structureId = structure['_id']?.toString() ?? '';
    if (id == null || structureId.isEmpty) return;
    await _action(() async {
      final result = await app.api.call('POST', '/api/schools/$id/fee-structures/$structureId/issue', {});
      await loadSection();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Charges created: ${result['chargesCreated'] ?? 0}; existing charges preserved: ${result['existingChargesPreserved'] ?? 0}.')));
    });
  }

  Future<void> startFeePayment() async {
    final id = schoolId;
    if (id == null) return;
    if (_parentFeePaymentOptions().isEmpty || _selectedParentFeePaymentMethod().isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The school has not configured a supported payment destination. Please contact the school office.'),
      ));
      return;
    }
    final n = int.tryParse(amount.text.trim());
    if (n == null ||
        n < 1 ||
        feeStudent.text.trim().isEmpty ||
        feeTerm.text.trim().isEmpty ||
        parentFeePaymentMethod.isEmpty) return;
    await _action(() async {
      final r = await app.api.call('POST', '/api/schools/$id/fees', {
        'studentName': feeStudent.text.trim(),
        'amount': n,
        'term': feeTerm.text.trim(),
        'phone': payerPhone.text.trim(),
        'paymentMethod': parentFeePaymentMethod,
      });
      final p = Map<String, dynamic>.from(r['paymentDestination'] ?? {});
      final method = switch (p['method']) {
        'mpesa_send_money' => 'Send Money to ${p['officialPhone']}',
        'mpesa_paybill' => 'Paybill: ${p['paybillNumber']}',
        'mpesa_till' => 'Till: ${p['tillNumber']}',
        'bank' => 'Bank: ${p['bankName']} / ${p['accountNumber']}',
        _ => 'School payment destination',
      };
      final isManualMpesa = p['method'] == 'mpesa_send_money';
      if (mounted)
        showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: Text((r['payment']?['status'] ?? '').toString() ==
                            'PENDING_STK'
                        ? 'M-Pesa prompt requested'
                        : 'Fee payment recorded as pending'),
                    content: Text(
                        '${r['note'] ?? ''}\n\nSchool destination: $method${isManualMpesa ? '\nSend KSh $n using M-Pesa Send Money, then share the M-Pesa receipt with the school. This payment remains pending until the school verifies it.' : ''}\nReference: ${r['payment']?['paymentReference'] ?? ''}'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Close'))
                    ]));
      amount.clear();
      await loadSection();
    });
  }

  Future<void> registerStudent() async {
    final id = schoolId;
    if (id == null ||
        admissionNumber.text.trim().isEmpty ||
        registeredStudentName.text.trim().isEmpty ||
        studentClass.text.trim().isEmpty) return;
    await _action(() async {
      await app.api.call('POST', '/api/schools/$id/students', {
        'admissionNumber': admissionNumber.text.trim(),
        'fullName': registeredStudentName.text.trim(),
        'className': studentClass.text.trim(),
        'guardianName': guardianName.text.trim(),
        'guardianPhone': guardianPhone.text.trim(),
        'guardianEmail': guardianEmail.text.trim()
      });
      admissionNumber.clear();
      registeredStudentName.clear();
      studentClass.clear();
      guardianName.clear();
      guardianPhone.clear();
      guardianEmail.clear();
      await loadSection();
    });
  }

  Future<void> promoteSchoolClass() async {
    final id = schoolId;
    final fromClass = promotionFromClass.text.trim();
    final toClass = promotionToClass.text.trim();
    final academicYear = promotionYear.text.trim();
    if (id == null || fromClass.isEmpty || toClass.isEmpty || academicYear.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter the current class, next class and academic year first.'),
        ));
      }
      return;
    }
    if (fromClass.toLowerCase() == toClass.toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The next class must be different from the current class.'),
      ));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Promote the whole class?'),
        content: Text('Move every active pupil in "$fromClass" to "$toClass" for academic year $academicYear? This operation is recorded in each pupil’s promotion history and cannot be repeated for the same class and year.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Promote class')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _action(() async {
      final result = await app.api.call('POST', '/api/schools/$id/students/promote-class', {
        'fromClass': fromClass,
        'toClass': toClass,
        'academicYear': academicYear,
      });
      await loadSection();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result['message']?.toString() ?? 'Class promotion completed.'),
      ));
      promotionFromClass.clear();
      promotionToClass.clear();
    });
  }

  Future<void> _transferSchoolStudent(String studentId, String studentName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Remove transferred pupil?'),
        content: Text('Mark $studentName as transferred and remove them from this school’s active register? Historical fees, receipts, attendance and academic records will be preserved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Mark transferred')),
        ],
      ),
    );
    if (confirmed != true || !mounted || schoolId == null) return;
    try {
      await app.api.call('POST', '/api/schools/$schoolId/students/$studentId/transfer', {});
      await loadSection();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$studentName was removed from the active register. Historical records were preserved.'),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not mark pupil as transferred: $error'),
      ));
    }
  }

  Future<void> saveAttendance() async {
    final id = schoolId;
    if (id == null || attendanceStudentId.isEmpty) return;
    await _action(() async {
      await app.api.call('POST', '/api/schools/$id/attendance', {
        'studentId': attendanceStudentId,
        'date': attendanceDate.text.trim(),
        'status': attendanceStatus,
        'note': attendanceNote.text.trim()
      });
      attendanceNote.clear();
      await loadSection();
    });
  }

  Future<void> saveAssessment() async {
    final id = schoolId;
    final score = double.tryParse(assessmentScore.text.trim()),
        outOf = double.tryParse(assessmentOutOf.text.trim());
    if (id == null ||
        assessmentStudentId.isEmpty ||
        score == null ||
        outOf == null) return;
    await _action(() async {
      await app.api.call('POST', '/api/schools/$id/academics', {
        'studentId': assessmentStudentId,
        'subject': subjectName.text.trim(),
        'assessment': assessmentName.text.trim(),
        'term': assessmentTerm.text.trim(),
        'score': score,
        'outOf': outOf,
        'teacherNote': teacherNote.text.trim()
      });
      subjectName.clear();
      assessmentName.clear();
      assessmentScore.clear();
      teacherNote.clear();
      await loadSection();
    });
  }

  Future<void> _openPrivateParentChat(String userId) async {
    if (!['admin', 'staff', 'parent'].contains(role) ||
        userId.isEmpty ||
        userId == 'null' ||
        userId == app.user?['id']?.toString()) return;
    // Parents may only start school-private chats with an active school
    // administrator/staff member returned by this school's member directory.
    if (role == 'parent' &&
        !members.whereType<Map>().any((member) =>
            member['userId']?.toString() == userId &&
            ['admin', 'staff'].contains(member['role']?.toString()))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Choose an administrator or staff member from this school.')));
      return;
    }
    try {
      final result = await app.api.call('POST', '/api/conversations/direct', {'userId': userId});
      if (!mounted) return;
      final conversation = Map<String, dynamic>.from(result['conversation']);
      await Navigator.push(context, MaterialPageRoute(builder: (_) => Chat(conversation: conversation)));
      if (mounted) loadSection();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open private chat: $error')));
    }
  }

  Future<void> _startPrivateSchoolConversation() async {
    if (role != 'parent') return;

    // Parents should contact the school office or staff linked to their own
    // children, rather than unrelated staff such as cooks or cleaners.
    final parentStudentNames = students.whereType<Map>()
        .map((student) => (student['fullName'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    final linkedClassByStudent = <String, String>{};
    for (final student in students.whereType<Map>()) {
      final name = (student['fullName'] ?? '').toString().trim();
      final className = (student['className'] ?? '').toString().trim();
      if (name.isNotEmpty && className.isNotEmpty) {
        linkedClassByStudent[name.toLowerCase()] = className;
      }
    }

    String contactDescription(Map member) {
      final contactRole = (member['role'] ?? '').toString().toLowerCase();
      if (contactRole == 'admin') return 'School administrator';
      final designation = (member['staffDesignation'] ?? '').toString().trim();
      final linkedNames = (member['studentNames'] as List? ?? [])
          .map((name) => name.toString().trim())
          .where((name) => name.isNotEmpty && parentStudentNames.any(
              (parentName) => parentName.toLowerCase() == name.toLowerCase()))
          .toList();
      final classes = linkedNames
          .map((name) => linkedClassByStudent[name.toLowerCase()] ?? '')
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      final label = designation.isNotEmpty ? designation : 'Staff';
      if (classes.isNotEmpty) return '$label • ${classes.join(', ')}';
      if (linkedNames.isNotEmpty) return '$label • linked to your child';
      return label;
    }

    final contacts = members.whereType<Map>().where((member) {
      final contactRole = member['role']?.toString();
      final userId = member['userId']?.toString() ?? '';
      if (userId.isEmpty || !['admin', 'staff'].contains(contactRole)) return false;
      if (contactRole == 'admin') return true;
      final designation = (member['staffDesignation'] ?? '').toString().trim().toLowerCase();
      if (!['teacher', 'class teacher', 'subject teacher', 'head teacher'].contains(designation)) return false;
      final linkedNames = (member['studentNames'] as List? ?? [])
          .map((name) => name.toString().trim().toLowerCase())
          .where((name) => name.isNotEmpty)
          .toSet();
      // Teachers are selectable even when the school has not linked individual pupils to them.
      return linkedNames.isEmpty || linkedNames.any((name) => parentStudentNames.any(
          (parentName) => parentName.toLowerCase() == name));
    }).toList()
      ..sort((a, b) {
        final roleOrder = (a['role'] == 'admin' ? 0 : 1)
            .compareTo(b['role'] == 'admin' ? 0 : 1);
        if (roleOrder != 0) return roleOrder;
        return (a['name'] ?? a['email'] ?? '').toString().toLowerCase()
            .compareTo((b['name'] ?? b['email'] ?? '').toString().toLowerCase());
      });

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No school administrator or teaching staff contact is available yet.')));
      return;
    }
    String? selectedUserId = contacts.first['userId'].toString();
    final recipient = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Start a private school conversation'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Choose the school administrator or a teacher (class teacher, subject teacher, or head teacher). Non-teaching staff such as cooks and cleaners are not listed. Only you and the selected contact will see this private conversation.'),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                value: selectedUserId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'School contact',
                  border: OutlineInputBorder(),
                ),
                items: contacts.map((member) => DropdownMenuItem<String>(
                  value: member['userId'].toString(),
                  child: Text(
                    '${member['name'] ?? member['email'] ?? 'School contact'} • ${contactDescription(member)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                )).toList(),
                onChanged: (value) => setDialogState(() => selectedUserId = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: selectedUserId == null
                  ? null
                  : () => Navigator.pop(dialogContext, selectedUserId),
              icon: const Icon(Icons.lock_outline),
              label: const Text('Open private chat'),
            ),
          ],
        ),
      ),
    );
    if (recipient != null && mounted) await _openPrivateParentChat(recipient);
  }
  Widget field(TextEditingController c, String label,
          {String? hint, TextInputType? keyboard}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
              controller: c,
              keyboardType: keyboard,
              decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  border: const OutlineInputBorder())));
  Widget secretField(TextEditingController c, String label) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
          controller: c,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder())));
  Widget actionButton(String label, FutureOr<void> Function() onPressed,
          {IconData icon = Icons.check}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
              width: double.infinity,
              child: AsyncActionButton(
                  label: label, onPressed: onPressed, icon: icon)));

  @override
  Widget build(BuildContext context) {
    final isAdmin = role == 'admin' && isOwner;
    final searchNeedle = schoolSearchQuery.trim().toLowerCase();
    final schoolClasses = students
        .whereType<Map>()
        .map((student) => (student['className'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    String searchableSchoolText(dynamic value) {
      if (value == null) return '';
      if (value is Map) {
        return value.entries
            .map((entry) =>
                '${entry.key} ${searchableSchoolText(entry.value)}')
            .join(' ')
            .toLowerCase();
      }
      if (value is Iterable) {
        return value.map(searchableSchoolText).join(' ').toLowerCase();
      }
      return value.toString().toLowerCase();
    }

    bool matchesSchoolRecord(dynamic raw, {bool applyClassFilter = true}) {
      if (raw is! Map) return false;
      if (applyClassFilter && schoolClassFilter != 'all') {
        final rawClass = (raw['className'] ?? '').toString().trim();
        if (rawClass != schoolClassFilter) {
          final studentId = (raw['studentId'] ?? '').toString();
          final studentName = (raw['studentName'] ?? '').toString().trim().toLowerCase();
          final linked = students.whereType<Map>().where((student) =>
              (studentId.isNotEmpty &&
                  (student['_id'] ?? '').toString() == studentId) ||
              (studentName.isNotEmpty &&
                  (student['fullName'] ?? '').toString().trim().toLowerCase() ==
                      studentName)).toList();
          if (linked.isEmpty ||
              (linked.first['className'] ?? '').toString().trim() !=
                  schoolClassFilter) {
            return false;
          }
        }
      }
      return searchNeedle.isEmpty ||
          searchableSchoolText(raw).contains(searchNeedle);
    }

    List<dynamic> filterSchoolRecords(
      List<dynamic> records, {
      bool applyClassFilter = true,
    }) =>
        records
            .where((record) => matchesSchoolRecord(
                  record,
                  applyClassFilter: applyClassFilter,
                ))
            .toList();

    final visibleStudents = filterSchoolRecords(students);
    final visibleMembers =
        filterSchoolRecords(members, applyClassFilter: false);
    final visibleFees = filterSchoolRecords(fees);
    final visibleReceipts = visibleFees
        .where((payment) => payment is Map && payment['status'] == 'CONFIRMED')
        .toList();
    final visibleFeeBalances = filterSchoolRecords(feeBalances);
    final visibleAttendance = filterSchoolRecords(
      role == 'parent' && attendanceStudentId.isNotEmpty
          ? attendance.where((item) => item is Map &&
              item['studentId']?.toString() == attendanceStudentId).toList()
          : attendance);
    final visibleAssessments = filterSchoolRecords(
      role == 'parent' && assessmentStudentId.isNotEmpty
          ? assessments.where((item) => item is Map &&
              item['studentId']?.toString() == assessmentStudentId).toList()
          : assessments);
    return Scaffold(
      body: RefreshIndicator(
          onRefresh: loadSchools,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Text('School workspace',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
                'Admissions, attendance, academic records, parent communication, conferences and fee management. M-Pesa remains pending until the school merchant credentials are configured.'),
            const SizedBox(height: 14),
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Join a school workspace',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          field(joinSchoolCode, 'School invite code',
                              hint:
                                  'Ask the school administrator for its code'),
                          DropdownButtonFormField<String>(
                              initialValue: memberRole,
                              decoration: const InputDecoration(
                                  labelText: 'Join as',
                                  border: OutlineInputBorder()),
                              items: const [
                                DropdownMenuItem(
                                    value: 'parent',
                                    child: Text('Parent / guardian')),
                                DropdownMenuItem(
                                    value: 'staff',
                                    child: Text('Teacher / staff'))
                              ],
                              onChanged: (v) =>
                                  setState(() => memberRole = v ?? 'parent')),
                          if (memberRole == 'staff') ...[
                            DropdownButtonFormField<String>(
                              value: staffDesignation,
                              decoration: const InputDecoration(labelText: 'Staff role / designation', border: OutlineInputBorder()),
                              items: const [
                                DropdownMenuItem(value: 'Teacher', child: Text('Teacher')),
                                DropdownMenuItem(value: 'Class teacher', child: Text('Class teacher')),
                                DropdownMenuItem(value: 'Subject teacher', child: Text('Subject teacher')),
                                DropdownMenuItem(value: 'Head teacher', child: Text('Head teacher')),
                                DropdownMenuItem(value: 'Cook', child: Text('Cook')),
                                DropdownMenuItem(value: 'Cleaner', child: Text('Cleaner')),
                                DropdownMenuItem(value: 'Other staff', child: Text('Other staff')),
                              ],
                              onChanged: (value) => setState(() => staffDesignation = value ?? 'Teacher'),
                            ),
                            field(joinStaffCode, 'Staff invitation code',
                                hint:
                                    'Separate code supplied by the school administrator'),
                          ],
                          field(studentNames, 'Linked student name(s)',
                              hint:
                                  'Enter exact registered names, separated by commas'),
                          actionButton('Join school', joinSchool,
                              icon: Icons.group_add),
                        ]))),
            if (schools.isNotEmpty)
              DropdownButtonFormField<String>(
                  initialValue: schoolId,
                  decoration: const InputDecoration(
                      labelText: 'Your school', border: OutlineInputBorder()),
                  items: schools
                      .map((s) => DropdownMenuItem<String>(
                          value: s['id'].toString(),
                          child: Text(s['name'].toString(),
                              overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (id) {
                    final s =
                        schools.cast<Map>().firstWhere((x) => x['id'] == id);
                    setState(() => _selectSchool(Map<String, dynamic>.from(s)));
                  }),
            if (schoolId != null)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      isOwner
                          ? 'Owner verified: you created this school workspace. Only your account can change school settings and administer it.'
                          : "Membership verified: your account is not this school's owner. Owner-only settings and administration are locked.",
                      style: TextStyle(
                          color: isOwner
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.secondary,
                          fontWeight: FontWeight.w600))),
            if (isAdmin && schoolCode.text.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      'Share this school invitation code with parents and staff: ${schoolCode.text}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600))),
            if (isAdmin && staffInviteCode.text.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'Private staff invitation code (share with staff only): ${staffInviteCode.text}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.secondary,
                          fontWeight: FontWeight.w600))),
            ...[
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                          'Create a school workspace request. Parents, staff, and other users can submit a school for verification. Chatify verifies the school before activating its workspace. Only submit details for a school you are authorized to represent.'))),
              field(schoolName, 'Official school name'),
              field(schoolCode, 'Proposed unique school code',
                  hint: 'e.g. NAIROBI-PRI'),
              field(schoolCounty, 'County where the school is located'),
              field(schoolOfficialEmail, 'Official school email',
                  hint: 'Use the school’s official contact email'),
              field(schoolOfficialPhone, 'Official school phone number',
                  hint: 'The school office contact number',
                  keyboard: TextInputType.phone),
              actionButton('Create a school workspace', createSchool,
                  icon: Icons.add_business),
            ],
            if (schoolVerificationRequests.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('School verification requests',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ...schoolVerificationRequests.map((raw) {
                final request = Map<String, dynamic>.from(raw as Map);
                final status = (request['status'] ?? 'PENDING').toString();
                return Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  (request['schoolName'] ?? 'School request')
                                      .toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              Text(
                                  'Code: ${request['proposedCode'] ?? ''} • County: ${request['county'] ?? ''}'),
                              Text(
                                  'Official contact: ${request['officialEmail'] ?? ''} • ${request['officialPhone'] ?? ''}'),
                              Text('Status: $status'),
                              if ((request['reviewNote'] ?? '')
                                  .toString()
                                  .isNotEmpty)
                                Text((request['reviewNote']).toString()),
                              if (isSchoolVerificationReviewer &&
                                  status == 'PENDING')
                                Wrap(spacing: 8, children: [
                                  FilledButton.icon(
                                      onPressed: () => reviewSchoolVerification(
                                          request, 'APPROVE'),
                                      icon: const Icon(Icons.verified),
                                      label: const Text('Approve')),
                                  OutlinedButton.icon(
                                      onPressed: () => reviewSchoolVerification(
                                          request, 'REJECT'),
                                      icon: const Icon(Icons.block),
                                      label: const Text('Reject')),
                                ]),
                            ])));
              }),
            ],
            if (schoolId != null && isOwner) ...[
              const SizedBox(height: 12),
              // Billing logic remains available for future settings screens, but the large billing banner is intentionally hidden.
            ],
            if (schoolId != null) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                ChoiceChip(
                    label: const Text('Messages'),
                    selected: section == 0,
                    onSelected: (_) {
                      setState(() {
                        section = 0;
                        recordPage = 1;
                      });
                      loadSection();
                    }),
                ChoiceChip(
                    label: const Text('Fees'),
                    selected: section == 2,
                    onSelected: (_) {
                      setState(() {
                        section = 2;
                        recordPage = 1;
                      });
                      loadSection();
                    }),
                ChoiceChip(
                    label: const Text('Receipts'),
                    selected: section == 8,
                    onSelected: (_) {
                      setState(() {
                        section = 8;
                        recordPage = 1;
                      });
                      loadSection();
                    }),
                if (role == 'staff' || isAdmin)
                  ChoiceChip(
                      label: const Text('Members'),
                      selected: section == 3,
                      onSelected: (_) {
                        setState(() {
                          section = 3;
                          recordPage = 1;
                        });
                        loadSection();
                      }),
                if (isAdmin)
                  ChoiceChip(
                      label: const Text('Fee setup'),
                      selected: section == 9,
                      onSelected: (_) {
                        setState(() { section = 9; recordPage = 1; });
                        loadSection();
                      }),
                if (isAdmin)
                  ChoiceChip(
                      label: const Text('Payment setup'),
                      selected: section == 4,
                      onSelected: (_) {
                        setState(() => section = 4);
                      }),
                ChoiceChip(
                    label: const Text('Students'),
                    selected: section == 5,
                    onSelected: (_) {
                      setState(() {
                        section = 5;
                        recordPage = 1;
                      });
                      loadSection();
                    }),
                ChoiceChip(
                    label: const Text('Attendance'),
                    selected: section == 6,
                    onSelected: (_) {
                      setState(() {
                        section = 6;
                        recordPage = 1;
                      });
                      loadSection();
                    }),
                ChoiceChip(
                    label: const Text('Academics'),
                    selected: section == 7,
                    onSelected: (_) {
                      setState(() {
                        section = 7;
                        recordPage = 1;
                      });
                      loadSection();
                    }),
              ]),
              const SizedBox(height: 12),
              if (schoolId != null && [0, 2, 3, 5, 6, 7, 8].contains(section)) ...[
                TextField(
                  key: ValueKey('school-record-search-$schoolId-$section'),
                  controller: schoolSearchController,
                  onChanged: (value) => setState(() => schoolSearchQuery = value),
                  onSubmitted: (_) {
                    setState(() => recordPage = 1);
                    loadSection();
                  },
                  decoration: InputDecoration(
                    labelText: section == 0 ? 'Search messages and parent/staff names' : 'Search school records',
                    hintText: section == 0 ? 'Type a parent/staff name or message text, then submit' : 'Student, admission number, subject, status or receipt',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: schoolSearchQuery.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              schoolSearchController.clear();
                              setState(() => schoolSearchQuery = '');
                            },
                            icon: const Icon(Icons.clear)),
                    border: const OutlineInputBorder(),
                    filled: true,
                  ),
                ),
                if (section != 3 && schoolClasses.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('school-record-class-filter'),
                    value: schoolClassFilter,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Filter by class / grade',
                      prefixIcon: Icon(Icons.class_outlined),
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(value: 'all', child: Text('All classes / grades')),
                      ...schoolClasses.map((name) => DropdownMenuItem(value: name, child: Text(name))),
                    ],
                    onChanged: (value) => setState(() => schoolClassFilter = value ?? 'all'),
                  ),
                ],
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 14),
              if (loading)
                const Center(
                    child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator())),
              if (error != null)
                Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              if (section == 0) ...[
                if (role == 'parent')
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.lock_outline, color: Colors.indigo),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Private conversation with school',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text('Send a confidential message directly to a school administrator or staff member. Other parents cannot see this chat.'),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _startPrivateSchoolConversation,
                              icon: const Icon(Icons.chat_bubble_outline),
                              label: const Text('Start private conversation'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        role == 'parent'
                            ? 'Filter school messages'
                            : 'Filter messages by date',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in const [
                            ('today', 'Today'),
                            ('week', 'This week'),
                            ('month', 'This month'),
                            ('all', 'All messages'),
                          ])
                            ChoiceChip(
                              label: Text(option.$2),
                              selected: messagePeriodFilter == option.$1,
                              onSelected: (selected) {
                                if (!selected) return;
                                setState(() {
                                  messagePeriodFilter = option.$1;
                                  recordPage = 1;
                                });
                                loadSection();
                              },
                            ),
                        ],
                      ),
                      if (role == 'parent')
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Choose a period to view school announcements and messages sent to parents.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
                if (isAdmin) DropdownButtonFormField<String>(
                  initialValue: messageAudienceFilter,
                  decoration: const InputDecoration(labelText: 'Filter messages by audience', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All message types')),
                    DropdownMenuItem(value: 'school_inbox', child: Text('Parent/staff inbox replies')),
                    DropdownMenuItem(value: 'direct', child: Text('Direct messages')),
                    DropdownMenuItem(value: 'all_parents', child: Text('Parents announcements')),
                    DropdownMenuItem(value: 'all_staff', child: Text('Staff announcements')),
                    DropdownMenuItem(value: 'all_school', child: Text('Whole school announcements')),
                  ],
                  onChanged: (value) {
                    setState(() { messageAudienceFilter = value ?? 'all'; recordPage = 1; });
                    loadSection();
                  },
                ),
                if (role == 'parent' || role == 'staff')
                  const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text(
                          'Messages are sent to this school workspace inbox. Chatify platform administrators are not selectable recipients.')),
                if (role == 'admin')
                  DropdownButtonFormField<String>(
                      initialValue: audience,
                      decoration: const InputDecoration(labelText: 'Send to'),
                      items: [
                        if (!scheduleSchoolEvent)
                          const DropdownMenuItem(
                              value: 'direct',
                              child: Text('One parent or staff member')),
                        const DropdownMenuItem(
                            value: 'all_parents', child: Text('All parents')),
                        const DropdownMenuItem(
                            value: 'all_staff', child: Text('All staff')),
                        const DropdownMenuItem(
                            value: 'all_school', child: Text('Whole school'))
                      ],
                      onChanged: (v) =>
                          setState(() => audience = v ?? 'all_parents')),
                if (role == 'admin' && audience == 'direct')
                  DropdownButtonFormField<String>(
                      initialValue: members.any((m) =>
                              m['userId']?.toString() ==
                              recipientIdController.text)
                          ? recipientIdController.text
                          : null,
                      decoration: const InputDecoration(
                          labelText: 'Message recipient',
                          border: OutlineInputBorder()),
                      items: members
                          .map((m) => DropdownMenuItem<String>(
                              value: m['userId'].toString(),
                              child: Text(
                                  '${m['name'] ?? m['email'] ?? 'School contact'} • ${m['role']}',
                                  overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => recipientIdController.text = v ?? '')),
                if (!scheduleSchoolEvent) ...[
                  field(messageSubject, 'Subject (optional)'),
                  field(messageBody, 'Message'),
                ],
                if (role == 'admin')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Schedule a school conference/event'),
                    subtitle: const Text('Publish it inside Messages with date, time and location.'),
                    value: scheduleSchoolEvent,
                    onChanged: (value) => setState(() {
                      scheduleSchoolEvent = value;
                      if (value && audience == 'direct') audience = 'all_parents';
                    }),
                  ),
                if (scheduleSchoolEvent && role == 'admin') ...[
                  field(conferenceTitle, 'Event / conference title'),
                  field(conferenceAgenda, 'Agenda / details'),
                  field(conferenceDate, 'Event date (YYYY-MM-DD)', hint: '2026-10-25'),
                  field(conferenceStartTime, 'Start time (24-hour HH:MM)', hint: '10:00'),
                  field(conferenceEndTime, 'End time (24-hour HH:MM)', hint: '11:00'),
                  field(conferenceLocation, 'Location (optional)'),
                ],
                actionButton(scheduleSchoolEvent ? 'Publish event in messages' : 'Send message / announcement', sendMessage,
                    icon: scheduleSchoolEvent ? Icons.event : Icons.send),
                ...messages.map((m) => _swipeSchoolRecord(
                    id: m['_id'].toString(),
                    label: 'message',
                    endpoint: 'messages/${m['_id']}',
                    child: Card(
                        child: ListTile(
                            leading:
                                const Icon(Icons.mark_chat_unread_outlined),
                            title: Text(
                                (m['subject'] ?? 'School message').toString()),
                            subtitle: Text([
                              '${m['sender'] is Map ? (m['sender']['name'] ?? 'School member') : 'School member'}',
                              if (m['messageType'] == 'conference') 'EVENT • ${m['startsAt'] ?? ''} – ${m['endsAt'] ?? ''}',
                              if ((m['location'] ?? '').toString().isNotEmpty) m['location'].toString(),
                              (m['body'] ?? '').toString(),
                            ].where((line) => line.isNotEmpty).join(' • ')),
                            isThreeLine: true,
                            trailing: (role == 'admin' || role == 'staff') && m['senderId'] != null && m['senderId'].toString() != app.user?['id']?.toString() ? IconButton(tooltip: 'Reply privately to sender', icon: const Icon(Icons.lock_outline), onPressed: () => _openPrivateParentChat(m['senderId'].toString())) : null)))),
                _schoolPager(),
              ],
              if (section == 2) ...[
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!isOwner) ...[
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: FilledButton.icon(
                                    onPressed: showSchoolSupportOptions,
                                    icon: const Icon(Icons.volunteer_activism_outlined),
                                    label: const Text('Donate / Support Us'),
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                              Text(
                                  (feePaymentOptions['schoolName'] ?? 'School')
                                          .toString() +
                                      ' payment options',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                              if ((feePaymentOptions['officialPhone'] ?? '')
                                  .toString()
                                  .isNotEmpty)
                                Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                        'School phone: ${feePaymentOptions['officialPhone']}')),
                              const SizedBox(height: 6),
                              if (feePaymentOptions['configured'] != true &&
                                  (feePaymentOptions['officialPhone']
                                          ?.toString()
                                          .isEmpty ??
                                      true))
                                const Text(
                                    'The school has not configured a fee payment method yet. Do not send money to an unverified number. Contact the school office.'),
                              if (feePaymentOptions['method'] ==
                                  'mpesa_paybill')
                                Text(
                                    'M-Pesa Paybill: ${feePaymentOptions['paybillNumber'] ?? 'Not provided'}'),
                              if (feePaymentOptions['method'] == 'mpesa_till')
                                Text(
                                    'M-Pesa Buy Goods Till: ${feePaymentOptions['tillNumber'] ?? 'Not provided'}'),
                              if (feePaymentOptions['method'] == 'bank')
                                Text(
                                    'Bank: ${feePaymentOptions['bankName'] ?? 'Not provided'} • Account: ${feePaymentOptions['accountNumber'] ?? 'Contact school office'}'),
                              if (feePaymentOptions['method'] != null &&
                                  feePaymentOptions['method'] != 'bank' &&
                                  feePaymentOptions['darajaConfigured'] != true)
                                const Text(
                                    'The school payment number is saved, but its Daraja STK Push credentials are not complete. No STK prompt can be sent yet.'),
                              if (fees.isNotEmpty)
                                Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                        'Records on this page: ${fees.length} • Confirmed/paid: ${fees.where((p) => p['status'] == 'CONFIRMED').length} • Pending: ${fees.where((p) => p['status'] != 'CONFIRMED' && p['status'] != 'FAILED' && p['status'] != 'CANCELLED' && p['status'] != 'REJECTED').length}')),
                            ]))),
                if (role == 'parent') ...[
                  if (feeStudents.isEmpty)
                    const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text(
                            'No attached students were found for this school. Ask the school administrator to link your registered student to your parent account.')),
                  if (feeStudents.isNotEmpty)
                    DropdownButtonFormField<String>(
                        key: ValueKey('fee-student-$feeStudentName'),
                        initialValue: feeStudents.any((student) =>
                                student['fullName']?.toString() ==
                                feeStudentName)
                            ? feeStudentName
                            : null,
                        decoration: const InputDecoration(
                            labelText: 'Student to pay fees for',
                            border: OutlineInputBorder()),
                        items: feeStudents
                            .map((student) => DropdownMenuItem<String>(
                                value: student['fullName'].toString(),
                                child: Text(
                                    '${student['fullName']} • ${student['className'] ?? ''}')))
                            .toList(),
                        onChanged: (value) => setState(() {
                              feeStudentName = value ?? '';
                              feeStudent.text = feeStudentName;
                            })),
                  field(amount, 'Amount in KSh',
                      keyboard: TextInputType.number),
                  field(feeTerm, 'Term / year'),
                  if (_parentFeePaymentOptions().isEmpty)
                    const Text(
                        'The school has not configured an M-Pesa destination or official phone number for fee payments.'),
                  if (_parentFeePaymentOptions().isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      key:
                          ValueKey('parent-fee-method-$parentFeePaymentMethod'),
                      initialValue: _selectedParentFeePaymentMethod(),
                      decoration: const InputDecoration(
                        labelText: 'How would you like to pay?',
                        border: OutlineInputBorder(),
                      ),
                      items: _parentFeePaymentOptions()
                          .map((option) => DropdownMenuItem<String>(
                                value: option['value'],
                                child: Text(option['label']!),
                              ))
                          .toList(),
                      onChanged: (value) => setState(() {
                        parentFeePaymentMethod = value ?? '';
                      }),
                    ),
                    if (_selectedParentFeePaymentMethod() == 'mpesa_till' ||
                        _selectedParentFeePaymentMethod() == 'mpesa_paybill')
                      field(payerPhone,
                          'Your M-Pesa phone receiving the STK prompt',
                          hint: '07XXXXXXXX or 2547XXXXXXXX',
                          keyboard: TextInputType.phone),
                    if (_selectedParentFeePaymentMethod() == 'mpesa_send_money')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Send Money to ${feePaymentOptions['officialPhone']}. The app will record this as pending until the school verifies your M-Pesa receipt.',
                        ),
                      ),
                  ],
                  actionButton(
                      _selectedParentFeePaymentMethod() == 'mpesa_send_money'
                          ? 'Continue with Send Money'
                          : _selectedParentFeePaymentMethod() == 'bank'
                              ? 'Record bank transfer'
                              : 'Pay Fees',
                      startFeePayment,
                      icon: Icons.payment)
                ],
                if (fees.isNotEmpty)
                  _responsiveSchoolTable(
                    columns: [
                      const DataColumn(label: Text('Student')),
                      const DataColumn(label: Text('Parent / guardian')),
                      const DataColumn(label: Text('Guardian phone')),
                      const DataColumn(label: Text('Term')),
                      const DataColumn(label: Text('Amount due')),
                      const DataColumn(label: Text('Payment method')),
                      const DataColumn(label: Text('Reference')),
                      const DataColumn(label: Text('Status')),
                      const DataColumn(label: Text('Actions')),
                    ],
                    rows: visibleFees.map((raw) {
                      final payment = Map<String, dynamic>.from(raw as Map);
                      final status = payment['status']?.toString() ?? 'PENDING';
                      return DataRow(cells: [
                        DataCell(Text(
                            (payment['studentName'] ?? 'Student').toString())),
                        DataCell(Text(
                            (payment['guardianName'] ?? 'Not recorded')
                                .toString())),
                        DataCell(
                            Text((payment['guardianPhone'] ?? '—').toString())),
                        DataCell(Text((payment['term'] ?? '').toString())),
                        DataCell(Text('KSh ${payment['amount'] ?? '—'}')),
                        DataCell(Text(schoolPaymentMethodForRecord(payment, configuredFallback: feePaymentOptions['method']))),
                        DataCell(Text(
                            (payment['paymentReference'] ?? '—').toString())),
                        DataCell(Text(status)),
                        DataCell(PopupMenuButton<String>(
                          tooltip: 'Payment actions',
                          onSelected: (action) {
                            switch (action) {
                              case 'status':
                                showFeePaymentStatus(payment);
                              case 'verify':
                                verifyFee(payment);
                              case 'download':
                                downloadSchoolFeeReceipt(payment);
                              case 'email':
                                resendSchoolReceipt(payment);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'status',
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.info_outline),
                                title: Text('View payment status'),
                              ),
                            ),
                            if (isAdmin && status == 'PENDING_VERIFICATION')
                              const PopupMenuItem(
                                value: 'verify',
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.verified_outlined),
                                  title: Text('Verify payment'),
                                ),
                              ),
                            if (status == 'CONFIRMED') ...[
                              const PopupMenuItem(
                                value: 'download',
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.download_outlined),
                                  title: Text('Download receipt'),
                                ),
                              ),
                              if (isAdmin)
                                const PopupMenuItem(
                                  value: 'email',
                                  child: ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.forward_to_inbox_outlined),
                                    title: Text('Retry receipt email'),
                                  ),
                                ),
                            ],
                          ],
                        )),
                      ]);
                    }).toList(),
                  ),
                if (isAdmin)
                  ...visibleReceipts.map((p) =>
                      actionButton(
                          'Retry receipt email • ${p['paymentReference']}',
                          () =>
                              resendSchoolReceipt(Map<String, dynamic>.from(p)),
                          icon: Icons.forward_to_inbox)),
              ],
              if (section == 2) ...[
                const SizedBox(height: 18),
                const Text('Issued student fee balances', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                if (visibleFeeBalances.isEmpty) Text(schoolSearchQuery.isNotEmpty || schoolClassFilter != 'all'
                    ? 'No fee balances match the current search / class filter.'
                    : 'No student charges have been issued yet. An administrator can configure fees in Fee setup and issue them to enrolled students.'),
                if (visibleFeeBalances.isNotEmpty)
                  _responsiveSchoolTable(
                    columns: const [
                      DataColumn(label: Text('Student')),
                      DataColumn(label: Text('Admission no.')),
                      DataColumn(label: Text('Class / grade')),
                      DataColumn(label: Text('Academic year')),
                      DataColumn(label: Text('Term')),
                      DataColumn(label: Text('Charges')),
                      DataColumn(label: Text('Confirmed paid')),
                      DataColumn(label: Text('Balance')),
                      DataColumn(label: Text('Status')),
                    ],
                    rows: visibleFeeBalances.map((raw) {
                      final balance = Map<String, dynamic>.from(raw as Map);
                      return DataRow(cells: [
                        DataCell(Text((balance['studentName'] ?? 'Student').toString())),
                        DataCell(Text((balance['admissionNumber'] ?? '—').toString())),
                        DataCell(Text((balance['className'] ?? '—').toString())),
                        DataCell(Text((balance['academicYear'] ?? '—').toString())),
                        DataCell(Text((balance['term'] ?? '—').toString())),
                        DataCell(Text('KSh ${balance['chargeAmount'] ?? balance['totalAmount'] ?? 0}')),
                        DataCell(Text('KSh ${balance['confirmedPaid'] ?? 0}')),
                        DataCell(Text('KSh ${balance['balance'] ?? 0}')),
                        DataCell(Text((balance['status'] ?? 'UNPAID').toString())),
                      ]);
                    }).toList(),
                  ),
              ],
              if (section == 8) ...[
                const Text('School fee receipts',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text(
                    'Receipts are available for confirmed payments only. Pending or failed payments cannot receive an official receipt.'),
                if (visibleReceipts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                        'No confirmed fee payments with receipts are available on this page yet. Check the Fees section or move to another page.'),
                  ),
                if (visibleReceipts.isNotEmpty)
                  _responsiveSchoolTable(
                    columns: [
                      const DataColumn(label: Text('Receipt no.')),
                      const DataColumn(label: Text('Payment reference')),
                      const DataColumn(label: Text('Student')),
                      const DataColumn(label: Text('Parent / guardian')),
                      const DataColumn(label: Text('Term')),
                      const DataColumn(label: Text('Paid on')),
                      const DataColumn(label: Text('Amount')),
                      const DataColumn(label: Text('Method')),
                      const DataColumn(label: Text('Status')),
                      const DataColumn(label: Text('Actions')),
                    ],
                    rows: visibleReceipts.map((raw) {
                      final payment = Map<String, dynamic>.from(raw as Map);
                      final confirmedAt = payment['verifiedAt'] ??
                          payment['updatedAt'] ??
                          payment['createdAt'];
                      return DataRow(cells: [
                        DataCell(
                            Text((payment['mpesaReceipt'] ?? '—').toString())),
                        DataCell(Text(
                            (payment['paymentReference'] ?? '—').toString())),
                        DataCell(Text(
                            (payment['studentName'] ?? 'Student').toString())),
                        DataCell(Text(
                            (payment['guardianName'] ?? 'Not recorded')
                                .toString())),
                        DataCell(Text((payment['term'] ?? '—').toString())),
                        DataCell(Text(
                            confirmedAt?.toString().split('T').first ?? '—')),
                        DataCell(Text('KSh ${payment['amount'] ?? '—'}')),
                        DataCell(Text(schoolPaymentMethodForRecord(payment, configuredFallback: feePaymentOptions['method']))),
                        DataCell(Text((payment['status'] ?? '').toString())),
                        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: 'Download printable receipt',
                            icon: const Icon(Icons.download),
                            onPressed: () => downloadSchoolFeeReceipt(payment),
                          ),
                          if (isAdmin)
                            IconButton(
                              tooltip: 'Resend receipt email',
                              icon: const Icon(Icons.forward_to_inbox),
                              onPressed: () => resendSchoolReceipt(payment),
                            ),
                        ])),
                      ]);
                    }).toList(),
                  ),
                _schoolPager(),
              ],
              if (section == 9) ...[
                const Text('Configure class fees', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Text('Enter one fee item per line as Description:Amount. Saving creates a new version; previously issued student charges are not overwritten.'),
                const Text('School classes / grades', style: TextStyle(fontWeight: FontWeight.w600)),
                const Text('Add the classes or grades used by your school. They will appear in this fee setup dropdown. Existing classes already used by students or fee records are also included.'),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: field(newSchoolClass, 'New class / grade', hint: 'e.g. PP1, Grade 4, Form 2')),
                  const SizedBox(width: 8),
                  Padding(padding: const EdgeInsets.only(top: 8), child: IconButton.filled(tooltip: 'Add class or grade', onPressed: saveSchoolClass, icon: const Icon(Icons.add))),
                ]),
                DropdownButtonFormField<String>(
                  value: schoolClasses.map((v) => v.toString()).contains(feeStructureClass.text.trim()) && feeStructureClass.text.trim().isNotEmpty ? feeStructureClass.text.trim() : null,
                  decoration: const InputDecoration(labelText: 'Class / grade for this fee structure'),
                  hint: const Text('Choose a configured class / grade'),
                  items: schoolClasses.map((raw) => DropdownMenuItem<String>(value: raw.toString(), child: Text(raw.toString()))).toList(),
                  onChanged: (value) => setState(() => feeStructureClass.text = value ?? ''),
                ),
                field(feeStructureYear, 'Academic year (for example 2027)'),
                field(feeStructureTerm, 'Term / fee period (for example Term 1)'),
                field(feeStructureItems, 'Fee items', hint: 'Tuition:12000\\nTransport:2500\\nActivities:1000'),
                actionButton('Save fee structure version', saveFeeStructure, icon: Icons.save_outlined),
                const SizedBox(height: 12),
                const Text('Existing fee structure versions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('Review each class fee plan, its academic period, total and status. Swipe a row to delete an unused structure, or use the delete action. Structures already issued to students are protected to preserve charges and payment history.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 10),
                if (feeStructures.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.receipt_long_outlined, size: 36, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            const SizedBox(height: 8),
                            const Text('No fee structures yet', style: TextStyle(fontWeight: FontWeight.bold)),
                            const Text('Create a class fee plan above to get started.'),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  LayoutBuilder(builder: (context, constraints) {
                    final compact = constraints.maxWidth < 680;
                    Widget cell(String label, String value, {double? width, bool strong = false, bool showLabel = true}) =>
                        SizedBox(
                          width: width ?? (compact ? constraints.maxWidth - 32 : 130),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                            child: showLabel
                                ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(label.toUpperCase(), style: TextStyle(fontSize: 10, letterSpacing: .6, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                      const SizedBox(height: 3),
                                      Text(value, style: TextStyle(fontSize: 13, fontWeight: strong ? FontWeight.w700 : FontWeight.w500), maxLines: compact ? 3 : 2, overflow: TextOverflow.ellipsis),
                                    ],
                                  )
                                : Text(value, style: TextStyle(fontSize: 13, fontWeight: strong ? FontWeight.w700 : FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
                          ),
                        );
                    return Column(
                      children: [
                        if (!compact)
                          Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                              border: Border.all(color: Theme.of(context).dividerColor),
                            ),
                            child: Row(children: [
                              cell('Class / grade', 'Class / grade', width: 150, strong: true, showLabel: false),
                              cell('Academic year', 'Academic year', width: 110, strong: true, showLabel: false),
                              cell('Term', 'Term', width: 100, strong: true, showLabel: false),
                              cell('Total fees', 'Total fees', width: 120, strong: true, showLabel: false),
                              cell('Version / status', 'Version / status', width: 140, strong: true, showLabel: false),
                              const Spacer(),
                              cell('Actions', 'Actions', width: 105, strong: true, showLabel: false),
                            ]),
                          ),
                        ...feeStructures.map((raw) {
                          final structure = Map<String, dynamic>.from(raw as Map);
                          final structureId = (structure['_id'] ?? '').toString();
                          final items = (structure['items'] as List? ?? const [])
                              .whereType<Map>()
                              .map((item) => '${item['description']}: KSh ${item['amount']}')
                              .join(' • ');
                          final active = structure['status'] == 'ACTIVE';
                          final row = Card(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            clipBehavior: Clip.antiAlias,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(color: Theme.of(context).dividerColor),
                            ),
                            child: compact
                                ? Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(children: [
                                          Expanded(child: Text('${structure['className'] ?? 'Class'} • ${structure['academicYear'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                            decoration: BoxDecoration(color: active ? Colors.green.withValues(alpha: .12) : Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
                                            child: Text((structure['status'] ?? 'UNKNOWN').toString(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: active ? Colors.green.shade800 : Theme.of(context).colorScheme.onSurfaceVariant)),
                                          ),
                                        ]),
                                        const SizedBox(height: 6),
                                        Wrap(spacing: 8, runSpacing: 2, children: [
                                          Text('Term: ${structure['term'] ?? '—'}'),
                                          Text('Version: ${structure['version'] ?? '—'}'),
                                          Text('Total: KSh ${structure['totalAmount'] ?? 0}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                        ]),
                                        if (items.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(items, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
                                        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                          if (active) TextButton.icon(
                                            onPressed: () => issueFeeStructure(structure),
                                            icon: const Icon(Icons.assignment_turned_in_outlined, size: 18),
                                            label: const Text('Issue charges'),
                                          ),
                                          IconButton(
                                            tooltip: 'Delete fee structure',
                                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                                            onPressed: () => _removeSchoolRecord(label: 'fee structure', endpoint: 'fee-structures/$structureId'),
                                          ),
                                        ]),
                                      ],
                                    ),
                                  )
                                : SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(children: [
                                      cell('Class / grade', (structure['className'] ?? '—').toString(), width: 150, strong: true, showLabel: false),
                                      cell('Year', (structure['academicYear'] ?? '—').toString(), width: 110, showLabel: false),
                                      cell('Term', (structure['term'] ?? '—').toString(), width: 100, showLabel: false),
                                      cell('KSh', 'KSh ${structure['totalAmount'] ?? 0}', width: 120, strong: true, showLabel: false),
                                      cell('Version', 'v${structure['version'] ?? 1} • ${structure['status'] ?? 'UNKNOWN'}', width: 140, showLabel: false),
                                      SizedBox(width: 105, child: Row(mainAxisSize: MainAxisSize.min, children: [
                                        if (active) IconButton(tooltip: 'Issue charges to students', icon: const Icon(Icons.assignment_turned_in_outlined), onPressed: () => issueFeeStructure(structure)),
                                        IconButton(tooltip: 'Delete fee structure', icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => _removeSchoolRecord(label: 'fee structure', endpoint: 'fee-structures/$structureId')),
                                      ])),
                                    ]),
                                  ),
                          );
                          return _swipeSchoolRecord(
                            id: structureId,
                            label: 'fee structure',
                            endpoint: 'fee-structures/$structureId',
                            showDeleteButton: false,
                            child: row,
                          );
                        }),
                      ],
                    );
                  }),
                _schoolPager(),
              ],
              if (section == 3 && (role == 'staff' || isAdmin)) ...[
                field(memberEmail, 'Existing Chatify account email'),
                DropdownButtonFormField<String>(
                    initialValue: memberRole,
                    decoration: const InputDecoration(labelText: 'Role'),
                    items: const [
                      DropdownMenuItem(value: 'parent', child: Text('Parent')),
                      DropdownMenuItem(value: 'staff', child: Text('Staff'))
                    ],
                    onChanged: (v) =>
                        setState(() => memberRole = v ?? 'parent')),
                field(studentNames, 'Linked student names',
                    hint: 'Exact names from the school register'),
                actionButton('Add school member', addMember,
                    icon: Icons.person_add),
                if (visibleMembers.isNotEmpty)
                  _responsiveSchoolTable(
                    columns: [
                      const DataColumn(label: Text('Member')),
                      const DataColumn(label: Text('Role')),
                      const DataColumn(label: Text('Email')),
                      const DataColumn(label: Text('Linked students')),
                      const DataColumn(label: Text('Status')),
                      if (isAdmin) const DataColumn(label: Text('Actions')),
                    ],
                    rows: visibleMembers.map((raw) {
                      final member = Map<String, dynamic>.from(raw as Map);
                      final id = member['id']?.toString() ?? '';
                      return DataRow(cells: [
                        DataCell(Text((member['name'] ?? 'Member').toString())),
                        DataCell(Text((member['role'] ?? '—').toString())),
                        DataCell(Text((member['email'] ?? '—').toString())),
                        DataCell(Text((member['studentNames'] is List
                            ? (member['studentNames'] as List).join(', ')
                            : '—'))),
                        const DataCell(Text('Active')),
                        if (isAdmin)
                          DataCell(
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            if (['parent', 'staff'].contains(member['role']))
                              IconButton(
                                tooltip: 'Edit linked pupil access',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => editParentPupilInfo(member),
                              ),
                            IconButton(
                              tooltip: 'Remove school member',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _removeSchoolRecord(
                                  label: 'member', endpoint: 'members/$id'),
                            ),
                          ])),
                      ]);
                    }).toList(),
                  ),
                if (schoolSearchQuery.isNotEmpty && visibleMembers.isEmpty)
                  const Padding(padding: EdgeInsets.all(12), child: Text('No members match your search.')),
                _schoolPager()
              ],
              if (section == 5) ...[
                if (role == 'admin') ...[
                  const Text('Year-end class promotion',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Text('Promote every active pupil in a class at once. Use the exact current class name shown in the register; promotion is recorded by academic year and cannot be repeated for the same class/year.'),
                  field(promotionFromClass, 'Current class / grade to promote'),
                  field(promotionToClass, 'Next class / grade'),
                  field(promotionYear, 'Academic year being completed'),
                  actionButton('Promote whole class', promoteSchoolClass,
                      icon: Icons.school_outlined),
                  const Divider(height: 28),
                ],
                if (role != 'parent') ...[
                  const Text('Student admission register',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  field(admissionNumber, 'Admission / student number'),
                  field(registeredStudentName, 'Student full name'),
                  field(studentClass, 'Class / grade'),
                  field(guardianName, 'Parent / guardian name'),
                  field(guardianPhone, 'Guardian phone',
                      keyboard: TextInputType.phone),
                  field(guardianEmail, 'Guardian email',
                      keyboard: TextInputType.emailAddress),
                  actionButton('Register student', registerStudent,
                      icon: Icons.person_add_alt_1),
                ],
                Text('Enrolled students: ${visibleStudents.length} of ${students.length} loaded',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                if (visibleStudents.isEmpty)
                  Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(schoolSearchQuery.isNotEmpty || schoolClassFilter != 'all'
                          ? 'No students match the current search / class filter.'
                          : 'No student records yet. School staff can register students above.')),
                if (visibleStudents.isNotEmpty)
                  _responsiveSchoolTable(
                    columns: [
                      const DataColumn(label: Text('Admission no.')),
                      const DataColumn(label: Text('Learner')),
                      const DataColumn(label: Text('Class / grade')),
                      const DataColumn(label: Text('Parent / guardian')),
                      const DataColumn(label: Text('Phone')),
                      const DataColumn(label: Text('Email')),
                      if (role != 'parent')
                        const DataColumn(label: Text('Actions')),
                    ],
                    rows: visibleStudents.map((raw) {
                      final student = Map<String, dynamic>.from(raw as Map);
                      return DataRow(cells: [
                        DataCell(Text(
                            (student['admissionNumber'] ?? '').toString())),
                        DataCell(Text(
                            (student['fullName'] ?? 'Student').toString())),
                        DataCell(Text((student['className'] ?? '').toString())),
                        DataCell(Text(
                            (student['guardianName'] ?? 'Not recorded')
                                .toString())),
                        DataCell(
                            Text((student['guardianPhone'] ?? '').toString())),
                        DataCell(
                            Text((student['guardianEmail'] ?? '').toString())),
                        if (role == 'admin')
                          DataCell(IconButton(
                            tooltip: 'Mark transferred and remove from active register',
                            icon: const Icon(Icons.person_remove_alt_1_outlined),
                            onPressed: () => _transferSchoolStudent(
                              student['_id'].toString(),
                              (student['fullName'] ?? 'Pupil').toString(),
                            ),
                          ))
                        else if (role == 'staff')
                          DataCell(IconButton(
                            tooltip: 'Archive student record',
                            icon: const Icon(Icons.archive_outlined),
                            onPressed: () => _removeSchoolRecord(
                              label: 'student',
                              endpoint: 'students/${student['_id']}',
                            ),
                          )),
                      ]);
                    }).toList(),
                  ),
                _schoolPager(),
              ],
              if (section == 6) ...[
                if (students.isNotEmpty) ...[
                  Text(
                      role == 'parent'
                          ? 'Your linked students'
                          : 'Daily attendance',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  DropdownButtonFormField<String>(
                      key: ValueKey('attendance-student-$attendanceStudentId'),
                      initialValue: students.any((s) =>
                              s['_id']?.toString() == attendanceStudentId)
                          ? attendanceStudentId
                          : students.first['_id']?.toString(),
                      decoration:
                          const InputDecoration(labelText: 'Select student'),
                      items: students
                          .map((s) => DropdownMenuItem<String>(
                              value: s['_id'].toString(),
                              child:
                                  Text('${s['fullName']} • ${s['className']}')))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => attendanceStudentId = v ?? '')),
                ],
                if (role != 'parent' && students.isNotEmpty) ...[
                  field(attendanceDate, 'Attendance date (YYYY-MM-DD)'),
                  DropdownButtonFormField<String>(
                      initialValue: attendanceStatus,
                      decoration:
                          const InputDecoration(labelText: 'Attendance status'),
                      items: const [
                        DropdownMenuItem(
                            value: 'present', child: Text('Present')),
                        DropdownMenuItem(
                            value: 'absent', child: Text('Absent')),
                        DropdownMenuItem(value: 'late', child: Text('Late')),
                        DropdownMenuItem(
                            value: 'excused', child: Text('Excused absence'))
                      ],
                      onChanged: (v) =>
                          setState(() => attendanceStatus = v ?? 'present')),
                  field(attendanceNote, 'Note (optional)'),
                  actionButton('Save attendance', saveAttendance,
                      icon: Icons.fact_check_outlined),
                ],
                Text('Attendance records: ${visibleAttendance.length}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                if (students.isEmpty && role == 'parent')
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'No students are linked to your parent account in this school. Ask the school office to update your student links.')),
                if (visibleAttendance.isEmpty &&
                    !(students.isEmpty && role == 'parent'))
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'No attendance records have been recorded yet.')),
                if (visibleAttendance.isNotEmpty)
                  _responsiveSchoolTable(
                    columns: [
                      const DataColumn(label: Text('Student')),
                      const DataColumn(label: Text('Admission no.')),
                      const DataColumn(label: Text('Class / grade')),
                      const DataColumn(label: Text('Date')),
                      const DataColumn(label: Text('Status')),
                      const DataColumn(label: Text('Note')),
                      if (role != 'parent')
                        const DataColumn(label: Text('Actions')),
                    ],
                    rows: visibleAttendance.whereType<Map>().map((raw) {
                      final record = Map<String, dynamic>.from(raw);
                      final date =
                          record['date']?.toString().split('T').first ?? '—';
                      return DataRow(cells: [
                        DataCell(Text(
                            (record['studentName'] ?? 'Student').toString())),
                        DataCell(Text(
                            (record['admissionNumber'] ?? '—').toString())),
                        DataCell(
                            Text((record['className'] ?? '—').toString())),
                        DataCell(Text(date)),
                        DataCell(Text(
                            (record['status'] ?? '—').toString().toUpperCase())),
                        DataCell(Text((record['note'] ?? '').toString())),
                        if (role != 'parent')
                          DataCell(IconButton(
                            tooltip: 'Delete attendance record',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _removeSchoolRecord(
                              label: 'attendance record',
                              endpoint: 'attendance/${record['_id']}',
                            ),
                          )),
                      ]);
                    }).toList(),
                  ),
                _schoolPager(),
              ],
              if (section == 7) ...[
                if (students.isNotEmpty) ...[
                  Text(
                      role == 'parent'
                          ? 'Your linked students'
                          : 'Academic results',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  DropdownButtonFormField<String>(
                      key: ValueKey('academic-student-$assessmentStudentId'),
                      initialValue: students.any((s) =>
                              s['_id']?.toString() == assessmentStudentId)
                          ? assessmentStudentId
                          : students.first['_id']?.toString(),
                      decoration:
                          const InputDecoration(labelText: 'Select student'),
                      items: students
                          .map((s) => DropdownMenuItem<String>(
                              value: s['_id'].toString(),
                              child:
                                  Text('${s['fullName']} • ${s['className']}')))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => assessmentStudentId = v ?? '')),
                ],
                if (role != 'parent' && students.isNotEmpty) ...[
                  field(subjectName, 'Subject'),
                  field(assessmentName, 'Assessment name (e.g. CAT 1)'),
                  field(assessmentTerm, 'Term / academic year'),
                  field(assessmentScore, 'Score',
                      keyboard: TextInputType.number),
                  field(assessmentOutOf, 'Total marks',
                      keyboard: TextInputType.number),
                  field(teacherNote, 'Teacher comment (optional)'),
                  actionButton('Save assessment result', saveAssessment,
                      icon: Icons.grading_outlined),
                ],
                Text('Assessment results: ${visibleAssessments.length}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                if (students.isEmpty && role == 'parent')
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'No students are linked to your parent account in this school. Ask the school office to update your student links.')),
                if (visibleAssessments.isEmpty &&
                    !(students.isEmpty && role == 'parent'))
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'No assessment results have been recorded yet.')),
                if (visibleAssessments.isNotEmpty)
                  _responsiveSchoolTable(
                    columns: [
                      const DataColumn(label: Text('Admission no.')),
                      const DataColumn(label: Text('Student')),
                      const DataColumn(label: Text('Class / grade')),
                      const DataColumn(label: Text('Subject')),
                      const DataColumn(label: Text('Term')),
                      const DataColumn(label: Text('Assessment')),
                      const DataColumn(label: Text('Score')),
                      const DataColumn(label: Text('Teacher note')),
                      if (role != 'parent')
                        const DataColumn(label: Text('Actions')),
                    ],
                    rows: visibleAssessments.map((raw) {
                      final record = Map<String, dynamic>.from(raw as Map);
                      return DataRow(cells: [
                        DataCell(
                            Text((record['admissionNumber'] ?? '').toString())),
                        DataCell(Text(
                            (record['studentName'] ?? 'Student').toString())),
                        DataCell(Text((record['className'] ?? '').toString())),
                        DataCell(Text((record['subject'] ?? '').toString())),
                        DataCell(Text((record['term'] ?? '').toString())),
                        DataCell(Text((record['assessment'] ?? '').toString())),
                        DataCell(Text(
                            '${record['score'] ?? '—'} / ${record['outOf'] ?? '—'}')),
                        DataCell(
                            Text((record['teacherNote'] ?? '').toString())),
                        if (role != 'parent')
                          DataCell(IconButton(
                            tooltip: 'Delete academic record',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _removeSchoolRecord(
                              label: 'academic record',
                              endpoint: 'academics/${record['_id']}',
                            ),
                          )),
                      ]);
                    }).toList(),
                  ),
                _schoolPager(),
              ],
              if (section == 4 && isAdmin) ...[
                DropdownButtonFormField<String>(
                    initialValue: paymentMethod,
                    decoration: const InputDecoration(
                        labelText: 'School payment method'),
                    items: const [
                      DropdownMenuItem(
                          value: 'mpesa_paybill',
                          child: Text('M-Pesa Paybill')),
                      DropdownMenuItem(
                          value: 'mpesa_till', child: Text('M-Pesa Till')),
                      DropdownMenuItem(
                          value: 'bank', child: Text('Bank transfer'))
                    ],
                    onChanged: (v) =>
                        setState(() => paymentMethod = v ?? 'mpesa_paybill')),
                if (paymentMethod == 'mpesa_paybill')
                  field(paybill, 'School Paybill number'),
                if (paymentMethod == 'mpesa_till')
                  field(till, 'School Till number'),
                if (paymentMethod == 'bank') ...[
                  field(bank, 'Bank name'),
                  field(account, 'Account number')
                ],
                if (paymentMethod != 'bank') ...[
                  DropdownButtonFormField<String>(
                      initialValue: darajaMode,
                      decoration: const InputDecoration(
                          labelText: 'Safaricom Daraja environment'),
                      items: const [
                        DropdownMenuItem(
                            value: 'production',
                            child: Text('Live production')),
                        DropdownMenuItem(
                            value: 'sandbox',
                            child: Text('Sandbox testing only'))
                      ],
                      onChanged: (v) =>
                          setState(() => darajaMode = v ?? 'production')),
                  secretField(darajaConsumerKey, 'School Daraja consumer key'),
                  secretField(
                      darajaConsumerSecret, 'School Daraja consumer secret'),
                  secretField(darajaPasskey, 'School shortcode passkey'),
                  const Text(
                      'Use the credentials issued for this school merchant and shortcode. Credentials are sent over HTTPS and encrypted on the API before storage; they are never displayed again.',
                      style: TextStyle(fontSize: 12)),
                ],
                actionButton('Save school payment setup', savePaymentProfile,
                    icon: Icons.save),
                const SizedBox(height: 18),
                const Divider(),
                const Text('Official school stamp', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text('Upload the school’s authorised rubber-stamp image. Use a clear JPEG image; the stamp is added to the official receipt and PDF. Maximum size: 700 KB.', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 10),
                if (receiptStampDataUrl.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFFF4F7FB), border: Border.all(color: const Color(0xFFD7E1ED)), borderRadius: BorderRadius.circular(12)),
                    child: Column(children: [
                      Image.memory(base64Decode(receiptStampDataUrl.substring(receiptStampDataUrl.indexOf(',') + 1)), height: 90, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Text('Saved stamp preview unavailable')),
                      const SizedBox(height: 6),
                      const Text('Saved school stamp', style: TextStyle(fontSize: 12, color: Color(0xFF53657D))),
                    ]),
                  )
                else
                  const Text('No official stamp uploaded yet.', style: TextStyle(color: Color(0xFF6B7C93))),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(onPressed: pickReceiptStamp, icon: const Icon(Icons.upload_file), label: Text(receiptStampDataUrl.isEmpty ? 'Upload school stamp' : 'Replace stamp')),
                  if (receiptStampDataUrl.isNotEmpty)
                    TextButton.icon(onPressed: removeReceiptStamp, icon: const Icon(Icons.delete_outline), label: const Text('Remove stamp')),
                ]),
                const Text(
                    'Live STK Push requires the API server to have SCHOOL_PAYMENT_ENCRYPTION_KEY and PUBLIC_API_URL (or API_URL) configured, plus SMTP_URL and SMTP_FROM for automatic receipt emails. Never paste Daraja secrets into chat or GitHub.',
                    style: TextStyle(color: Colors.deepOrange)),
              ],
            ],
          ])),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

// Coordinates the Home tabs and selections, and loads the data displayed in each section.
class _HomeState extends State<Home> {
  AppState? _observedAppState;
  int tab = 0;
  bool showMemoriesInChats = false;
  static const int _homePageSize = 20;
  int chatPage = 1,
      chatTotal = 0,
      memoryPage = 1,
      memoryTotal = 0,
      contactsPage = 1,
      contactsTotal = 0;
  final Map<int, String> chatCursors = {}, memoryCursors = {};
  List<dynamic> chats = [], users = [], memories = [];
  // Sparks are short-lived status updates that expire after 24 hours.
  List<dynamic> sparks = [];
  bool sparksLoading = false;
  bool loading = false;
  bool offlineDataMode = false;
  bool selectingChats = false;
  final Set<String> selectedConversationIds = {};
  bool memoriesLoading = false, usersLoading = false;
  String contactQuery = '';
  String phoneQuery = '';
  List<dynamic> savedContacts = [], phoneResults = [];
  bool contactsLoading = false, phoneSearching = false;
  Timer? _phoneSearchDebounce;
  String? chatsError, memoriesError, usersError;
  AppState get app => context.read<AppState>();
  int _lastMessageEventVersion = 0;

  void _onAppStateChanged() {
    final version = app.messageEventVersion;
    if (version == _lastMessageEventVersion) return;
    _lastMessageEventVersion = version;
    if (tab == 0) unawaited(loadChats());
  }

  @override
  void initState() {
    super.initState();
    _observedAppState = app;
    _lastMessageEventVersion = app.messageEventVersion;
    app.addListener(_onAppStateChanged);
    loadChats();
    loadSavedContacts();
    loadSparks();
  }

  void _toggleConversationSelection(String id) {
    setState(() {
      if (!selectedConversationIds.add(id)) selectedConversationIds.remove(id);
      if (selectedConversationIds.isEmpty) selectingChats = false;
    });
  }

  Future<void> _deleteSelectedConversations() async {
    final ids = selectedConversationIds.toList();
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
            'Delete ${ids.length} conversation${ids.length == 1 ? '' : 's'}?'),
        content: Text(
            'This removes the selected conversation${ids.length == 1 ? '' : 's'} from your chat list only. Other participants keep their copies. A new message can make a conversation appear again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete for me')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final deletedIds = <String>{};
    try {
      // The API caps each batch at 100 IDs. Chunk large selections so
      // Select all still works for accounts with hundreds of conversations.
      for (var offset = 0; offset < ids.length; offset += 100) {
        final batch = ids.skip(offset).take(100).toList();
        await app.api.call(
            'POST', '/api/conversations/delete', {'conversationIds': batch});
        deletedIds.addAll(batch);
      }
      if (mounted) {
        setState(() {
          chats.removeWhere(
              (c) => c is Map && deletedIds.contains(c['_id']?.toString()));
          selectedConversationIds.clear();
          selectingChats = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${deletedIds.length} conversation${deletedIds.length == 1 ? '' : 's'} deleted from your chat list.')));
      }
    } catch (error) {
      // Preserve the successful part of a large batch operation and leave only
      // the remaining conversations selected so the user can retry safely.
      if (mounted) {
        setState(() {
          chats.removeWhere(
              (c) => c is Map && deletedIds.contains(c['_id']?.toString()));
          selectedConversationIds.removeAll(deletedIds);
          if (selectedConversationIds.isEmpty) selectingChats = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(deletedIds.isEmpty
                ? error.toString()
                : 'Deleted ' +
                    deletedIds.length.toString() +
                    ' conversations. Some remaining items could not be deleted: ' +
                    error.toString())));
      }
    }
  }

  // Load the signed-in user's active Sparks and those shared by saved contacts.
  Future<void> loadSparks() async {
    if (!mounted) return;
    setState(() => sparksLoading = true);
    try {
      final result = await app.api.call('GET', '/api/sparks');
      if (!mounted) return;
      setState(() {
        sparks = List<dynamic>.from(result['sparks'] ?? const []);
        sparksLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => sparksLoading = false);
    }
  }

  // Create a 24-hour Spark as text, an image, or a short video.
  Future<void> _createSpark() async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
          child: Wrap(children: [
        ListTile(
            leading: const Icon(Icons.text_fields),
            title: const Text('Text Spark'),
            onTap: () => Navigator.pop(sheetContext, 'text')),
        ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Photo Spark'),
            onTap: () => Navigator.pop(sheetContext, 'image')),
        ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: const Text('Video Spark'),
            subtitle: const Text('Up to 8 MB'),
            onTap: () => Navigator.pop(sheetContext, 'video')),
      ])),
    );
    if (kind == null || !mounted) return;
    try {
      final Map<String, dynamic> payload = {'text': ''};
      if (kind == 'text') {
        final text = await showDialog<String>(
            context: context, builder: (_) => const _CreateSparkTextDialog());
        if (text == null || text.trim().isEmpty || !mounted) return;
        payload['text'] = text.trim();
      } else if (kind == 'image') {
        final file = await ImagePicker()
            .pickImage(source: ImageSource.gallery, imageQuality: 85);
        if (file == null) return;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024)
          throw const FormatException('Choose an image no larger than 8 MB.');
        final lower = file.name.toLowerCase();
        final mime = lower.endsWith('.png')
            ? 'image/png'
            : (lower.endsWith('.webp') ? 'image/webp' : 'image/jpeg');
        payload.addAll({
          'mediaData': base64Encode(bytes),
          'mimeType': mime,
          'mediaType': 'image'
        });
      } else {
        final selected = await FilePicker.platform.pickFiles(
            type: FileType.video, withData: true, allowMultiple: false);
        if (selected == null || selected.files.isEmpty) return;
        final file = selected.files.first;
        final bytes = file.bytes;
        if (bytes == null || bytes.isEmpty || bytes.length > 8 * 1024 * 1024)
          throw const FormatException('Choose a video no larger than 8 MB.');
        final ext = (file.extension ?? '').toLowerCase();
        final mime = switch (ext) {
          'mp4' => 'video/mp4',
          'mov' => 'video/quicktime',
          'webm' => 'video/webm',
          _ => throw const FormatException(
              'Supported video formats: MP4, MOV and WebM.'),
        };
        payload.addAll({
          'mediaData': base64Encode(bytes),
          'mimeType': mime,
          'mediaType': 'video'
        });
      }
      await app.api.call('POST', '/api/sparks', payload);
      await loadSparks();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Your Spark is live for 24 hours.')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not share Spark: $error')));
    }
  }

  void _viewSpark(Map<String, dynamic> spark) {
    final isMine = spark['isMine'] == true;
    final authorId = spark['authorId']?.toString();
    final selectedId = spark['_id']?.toString();
    final expiresAt = DateTime.tryParse(spark['expiresAt']?.toString() ?? '');
    if (expiresAt != null && !expiresAt.isAfter(DateTime.now())) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This Spark has expired.')),
        );
      }
      unawaited(loadSparks());
      return;
    }
    final sequence = sparks
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .where((item) {
      final expiry = DateTime.tryParse(item['expiresAt']?.toString() ?? '');
      if (expiry != null && !expiry.isAfter(DateTime.now())) return false;
      if (isMine) return item['isMine'] == true;
      return item['isMine'] != true &&
          (authorId == null || authorId.isEmpty
              ? item['_id']?.toString() == spark['_id']?.toString()
              : item['authorId']?.toString() == authorId);
    }).toList()
      ..sort((a, b) => _sparkCreatedAt(a).compareTo(_sparkCreatedAt(b)));
    if (!sequence.any((item) => item['_id']?.toString() == selectedId)) {
      sequence.add(spark);
      sequence.sort((a, b) => _sparkCreatedAt(a).compareTo(_sparkCreatedAt(b)));
    }
    final initialIndex = sequence.indexWhere(
      (item) => item['_id']?.toString() == selectedId,
    );
    if (sequence.isEmpty || initialIndex < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This Spark is unavailable.')),
      );
      unawaited(loadSparks());
      return;
    }
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, __) => _SparkStatusViewer(
        items: sequence,
        initialIndex: initialIndex,
        onViewed: (item) {
          final id = item['_id']?.toString();
          if (item['isMine'] == true ||
              item['hasViewed'] == true ||
              id == null ||
              id.isEmpty) return;
          unawaited(app.api
              .call('POST', '/api/sparks/$id/view', {})
              .then((_) => loadSparks())
              .catchError((_) {}));
        },
        onDelete: (item) async {
          try {
            await app.api.call('DELETE', '/api/sparks/${item['_id']}');
            await loadSparks();
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          } catch (error) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Could not delete Spark: $error')),
              );
            }
          }
        },
      ),
    );
  }

  DateTime _sparkCreatedAt(Map<String, dynamic> spark) =>
      DateTime.tryParse(spark['createdAt']?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  Widget _sparksStrip() {
    final theme = Theme.of(context);
    final mySparks =
        sparks.where((item) => item is Map && item['isMine'] == true).toList();
    final ownSpark = mySparks.isEmpty
        ? null
        : Map<String, dynamic>.from(mySparks.first as Map);
    final otherSparks =
        sparks.where((item) => item is Map && item['isMine'] != true).toList();
    return SizedBox(
      height: 112,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        children: [
          SizedBox(
            width: 76,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap:
                  ownSpark == null ? _createSpark : () => _viewSpark(ownSpark),
              child: Column(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: ownSpark == null
                              ? null
                              : LinearGradient(colors: [
                                  theme.colorScheme.primary,
                                  theme.colorScheme.tertiary,
                                ]),
                        ),
                        child: ClipOval(
                          child: SizedBox(
                            width: 50,
                            height: 50,
                            child: ColoredBox(
                              color: theme.colorScheme.primaryContainer,
                              child: ownSpark == null
                                  ? const Icon(Icons.auto_awesome_outlined,
                                      size: 28)
                                  : _sparkPreview(
                                      ownSpark,
                                      onTap: () => _viewSpark(ownSpark),
                                    ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: GestureDetector(
                          onTap: _createSpark,
                          child: CircleAvatar(
                            radius: 11,
                            backgroundColor: theme.colorScheme.primary,
                            child: const Icon(Icons.add,
                                size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text('Your Spark',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
          for (final item in otherSparks)
            Builder(builder: (context) {
              final spark = Map<String, dynamic>.from(item as Map);
              final name = spark['authorName']?.toString() ?? 'Chatify user';
              final mediaType = spark['mediaType']?.toString();
              final preview = _sparkPreview(
                spark,
                onTap: () => _viewSpark(spark),
              );
              return SizedBox(
                width: 76,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _viewSpark(spark),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [
                            theme.colorScheme.primary,
                            theme.colorScheme.tertiary,
                          ]),
                        ),
                        child: ClipOval(
                          child: SizedBox(
                            width: 50,
                            height: 50,
                            child: ColoredBox(
                              color: theme.colorScheme.surface,
                              child: Stack(fit: StackFit.expand, children: [
                                preview,
                                if (mediaType == 'video')
                                  const Center(
                                      child: Icon(Icons.play_circle_fill,
                                          color: Colors.white, size: 25)),
                              ]),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              );
            }),
          if (sparksLoading)
            const SizedBox(
                width: 60,
                child: Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)))),
        ],
      ),
    );
  }

  Widget _sparkPreview(Map<String, dynamic> spark, {VoidCallback? onTap}) {
    final mediaUrl = spark['mediaUrl']?.toString() ?? '';
    final mediaType = spark['mediaType']?.toString();
    final text = spark['text']?.toString().trim() ?? '';
    if (mediaType == 'image' && mediaUrl.startsWith('https://')) {
      return Image.network(
        mediaUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
      );
    }
    if (mediaType == 'image' && mediaUrl.startsWith('data:image/')) {
      return Image.memory(
        base64Decode(mediaUrl.split(',').last),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
      );
    }
    if (mediaType == 'video' && mediaUrl.startsWith('https://')) {
      return _SparkVideoThumbnail(url: mediaUrl, onTap: onTap);
    }
    if (mediaType == 'video') return const Icon(Icons.play_circle_outline);
    if (text.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(5),
        child: Center(
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      );
    }
    return const Icon(Icons.auto_awesome_outlined);
  }

  // Opens a chat avatar in a full-screen image viewer when the user taps it.
  void _showExpandedAvatar({required String name, required String imageUrl}) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(18),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            Center(
              child: imageUrl.startsWith('https://')
                  ? InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4,
                      child: Image.network(
                        imageUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            _largeAvatarFallback(name),
                      ),
                    )
                  : _largeAvatarFallback(name),
            ),
            IconButton(
              tooltip: 'Close profile picture',
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _largeAvatarFallback(String name) {
    final label = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return CircleAvatar(
      radius: 100,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(label,
          style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w700)),
    );
  }

  Future<void> loadChats() async {
    // Keep the current list visible while refreshing so a slow/waking API does
    // not replace usable content with a full-screen spinner.
    if (chats.isEmpty) setState(() => loading = true);
    try {
      if (chatPage == 1) chatCursors.clear();
      final cursor = chatCursors[chatPage];
      final path = cursor == null
          ? '/api/conversations?page=$chatPage&limit=$_homePageSize'
          : '/api/conversations?limit=$_homePageSize&cursor=${Uri.encodeQueryComponent(cursor)}';
      final result = await app.api.call('GET', path);
      final nextCursor = result['nextCursor'];
      if (nextCursor is String && nextCursor.isNotEmpty) {
        chatCursors[chatPage + 1] = nextCursor;
      } else {
        chatCursors.remove(chatPage + 1);
      }
      chats = List<dynamic>.from(result['conversations'] ?? []);
      chatTotal = (result['total'] as num?)?.toInt() ?? chats.length;
      chatsError = null;
      offlineDataMode = app.api.offlineDataMode;
    } catch (error) {
      chatsError = error.toString();
      offlineDataMode = app.api.offlineDataMode;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> search(String q) async {
    contactQuery = q;
    if (q.trim().length < 2) {
      setState(() {
        users = [];
        usersError = null;
        usersLoading = false;
      });
      return;
    }
    setState(() {
      usersLoading = true;
      usersError = null;
    });
    try {
      final found = List<dynamic>.from((await app.api.call('GET',
                  '/api/users/search?q=${Uri.encodeQueryComponent(q.trim())}'))[
              'users'] ??
          []);
      if (mounted && contactQuery == q) setState(() => users = found);
    } catch (error) {
      if (mounted && contactQuery == q) {
        setState(() => usersError = error.toString());
      }
    } finally {
      if (mounted && contactQuery == q) setState(() => usersLoading = false);
    }
  }

  Future<void> loadMemories() async {
    if (memories.isEmpty) setState(() => memoriesLoading = true);
    try {
      if (memoryPage == 1) memoryCursors.clear();
      final cursor = memoryCursors[memoryPage];
      final path = cursor == null
          ? '/api/memories?page=$memoryPage&limit=$_homePageSize'
          : '/api/memories?limit=$_homePageSize&cursor=${Uri.encodeQueryComponent(cursor)}';
      final result = await app.api.call('GET', path);
      final nextCursor = result['nextCursor'];
      if (nextCursor is String && nextCursor.isNotEmpty) {
        memoryCursors[memoryPage + 1] = nextCursor;
      } else {
        memoryCursors.remove(memoryPage + 1);
      }
      memories = List<dynamic>.from(result['memories'] ?? []);
      memoryTotal = (result['total'] as num?)?.toInt() ?? memories.length;
      memoriesError = null;
      offlineDataMode = app.api.offlineDataMode;
      if (mounted) setState(() {});
    } catch (error) {
      memoriesError = error.toString();
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => memoriesLoading = false);
    }
  }

  Future<void> _openMemoryConversation(Map<String, dynamic> memory) async {
    final conversationId = memory['conversationId']?.toString();
    if (conversationId == null || conversationId.isEmpty) return;
    try {
      final result = await app.api.call(
          'GET', '/api/conversations/${Uri.encodeComponent(conversationId)}');
      if (!mounted) return;
      await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Chat(
              conversation: Map<String, dynamic>.from(result['conversation']),
            ),
          ));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open the conversation: $error')));
      }
    }
  }

  Future<void> _deleteMemoryCard(Map<String, dynamic> memory) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete saved memory?'),
        content: Text(
            'Delete “${memory['title'] ?? 'Memory'}” from your saved memories?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await app.api.call('DELETE', '/api/memories/${memory['_id']}');
      if (!mounted) return;
      setState(() {
        memories.removeWhere((item) =>
            item is Map &&
            item['_id']?.toString() == memory['_id']?.toString());
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete memory: $error')),
      );
    }
  }

  Future<void> _toggleMemoryCompleted(Map<String, dynamic> memory) async {
    final completed = memory['completed'] != true;
    try {
      await app.api.call(
        'PATCH',
        '/api/memories/${memory['_id']}',
        {'completed': completed},
      );
      if (!mounted) return;
      setState(() {
        for (final item in memories.whereType<Map>()) {
          if (item['_id']?.toString() == memory['_id']?.toString()) {
            item['completed'] = completed;
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update memory: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AppState>().user?['role'] == 'admin';
    final titles = [
      'Chats',
      'Business',
      'Contacts',
      'Profile',
      'School',
      if (isAdmin) 'Admin'
    ];
    return Scaffold(
      // Keep Business discoverable from the primary chat screen as well as the
      // dedicated bottom-navigation tab. This is especially helpful on web,
      // where users may overlook the fifth navigation destination.
      floatingActionButton: tab == 0
          ? FloatingActionButton.extended(
              heroTag: 'open-business-workspace',
              onPressed: () => setState(() => tab = 1),
              icon: const Icon(Icons.business_center_outlined),
              label: const Text('Business'),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      appBar: AppBar(
        title: Text(tab == 0 && showMemoriesInChats ? 'Memories' : titles[tab]),
        actions: [
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: () => context.read<AppState>().logout(),
          ),
          if (tab != 1)
            IconButton(
              tooltip: 'Open Business workspace',
              icon: const Icon(Icons.business_center_outlined),
              onPressed: () => setState(() => tab = 1),
            ),
          IconButton(
              tooltip: 'Payment history',
              icon: const Icon(Icons.account_balance_wallet_outlined),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PaymentHistory()))),
          IconButton(
              tooltip: 'Pay a merchant by QR',
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const MerchantQrScannerPage()))),
          if (tab == 0 && !showMemoriesInChats && selectingChats) ...[
            IconButton(
                tooltip: 'Select all',
                icon: const Icon(Icons.select_all),
                onPressed: () => setState(() {
                      selectedConversationIds
                        ..clear()
                        ..addAll(chats
                            .whereType<Map>()
                            .map((c) => c['_id'].toString()));
                    })),
            IconButton(
                tooltip: 'Delete selected conversations',
                onPressed: selectedConversationIds.isEmpty
                    ? null
                    : _deleteSelectedConversations,
                icon: const Icon(Icons.delete_outline)),
            IconButton(
                tooltip: 'Cancel selection',
                onPressed: () => setState(() {
                      selectingChats = false;
                      selectedConversationIds.clear();
                    }),
                icon: const Icon(Icons.close)),
          ] else if (tab == 0 && !showMemoriesInChats) ...[
            IconButton(
                tooltip: 'Select conversations',
                onPressed: () => setState(() => selectingChats = true),
                icon: const Icon(Icons.checklist)),
            IconButton(onPressed: loadChats, icon: const Icon(Icons.refresh)),
          ],
          if (tab == 0 && showMemoriesInChats)
            IconButton(
                tooltip: 'Refresh memories',
                onPressed: loadMemories,
                icon: const Icon(Icons.refresh)),
          if (tab == 2)
            IconButton(onPressed: _newGroup, icon: const Icon(Icons.group_add)),
        ],
      ),
      body: Column(children: [
        if (offlineDataMode || app.api.offlineDataMode)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Row(children: [
              Icon(Icons.cloud_off_outlined, size: 18),
              SizedBox(width: 8),
              Expanded(
                  child: Text(
                'Offline mode — showing saved data. New changes need a connection to sync.',
                style: TextStyle(fontSize: 12),
              )),
            ]),
          ),
        Expanded(
          child: IndexedStack(index: tab, children: [
            _chatHub(),
            const BusinessHub(),
            _contacts(),
            const Profile(),
            const SchoolWorkspacePage(),
            if (isAdmin) const AdminDashboard()
          ]),
        ),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) {
          setState(() {
            tab = i;
            if (i == 0) showMemoriesInChats = false;
          });
          if (i == 0) loadChats();
        },
        destinations: [
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline), label: 'Chats'),
          NavigationDestination(
              icon: Icon(Icons.business_center_outlined), label: 'Business'),
          NavigationDestination(
              icon: Icon(Icons.people_outline), label: 'Contacts'),
          NavigationDestination(
              icon: Icon(Icons.person_outline), label: 'Profile'),
          const NavigationDestination(
              icon: Icon(Icons.school_outlined), label: 'School'),
          if (isAdmin)
            const NavigationDestination(
                icon: Icon(Icons.admin_panel_settings_outlined),
                label: 'Admin'),
        ],
      ),
    );
  }

  Widget _homePager(
      {required int page,
      required int total,
      required VoidCallback previous,
      required VoidCallback next}) {
    final pages = total == 0 ? 0 : (total / _homePageSize).ceil();
    if (pages <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Expanded(child: Text('Page $page of $pages · $total records')),
        IconButton(
            tooltip: 'Previous page',
            onPressed: page > 1 ? previous : null,
            icon: const Icon(Icons.chevron_left)),
        IconButton(
            tooltip: 'Next page',
            onPressed: page < pages ? next : null,
            icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }

  Future<void> _removeConversationFromDesktop(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Remove conversation?'),
        content: const Text(
            'This hides the conversation from your chat list only. Other participants keep their copies.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete for me')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => chats
        .removeWhere((item) => item is Map && item['_id']?.toString() == id));
    try {
      await app.api.call('POST', '/api/conversations/delete', {
        'conversationIds': [id]
      });
      await loadChats();
    } catch (error) {
      await loadChats();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not remove conversation: $error')));
    }
  }

  Widget _chatHub() {
    return Column(
      children: [
        _sparksStrip(),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: false,
                icon: Icon(Icons.chat_bubble_outline),
                label: Text('Chats'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: Icon(Icons.auto_awesome_outlined),
                label: Text('Memories'),
              ),
            ],
            selected: {showMemoriesInChats},
            onSelectionChanged: (selection) {
              final showMemories = selection.first;
              setState(() => showMemoriesInChats = showMemories);
              if (showMemories) {
                loadMemories();
              } else {
                loadChats();
              }
            },
          ),
        ),
        Expanded(
          child: showMemoriesInChats ? _memories() : _chats(),
        ),
      ],
    );
  }

  Widget _chats() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (chatsError != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(chatsError!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        AsyncActionButton(
            label: 'Retry chats', icon: Icons.refresh, onPressed: loadChats)
      ]));
    }
    if (chats.isEmpty) {
      return const Empty(
          icon: Icons.forum_outlined,
          title: 'No conversations',
          subtitle: 'Search Contacts to start a chat.');
    }
    return RefreshIndicator(
      onRefresh: loadChats,
      child: ListView.builder(
        itemCount: chats.length + 1,
        itemBuilder: (_, i) {
          if (i == chats.length) {
            return _homePager(
              page: chatPage,
              total: chatTotal,
              previous: () {
                setState(() => chatPage--);
                loadChats();
              },
              next: () {
                setState(() => chatPage++);
                loadChats();
              },
            );
          }
          final c = Map<String, dynamic>.from(chats[i]);
          // Use the same ID/email-aware peer resolver as the conversation header.
          // Older API payloads can expose participant IDs as either id or _id.
          final title = c['type'] == 'group'
              ? (c['title'] ?? 'Group').toString()
              : (conversationPeerName(c, app.user) ?? 'Unknown user')
                  .toString();
          final last = c['lastMessage'];
          final preview = last is Map
              ? (last['text'] ?? 'Start chatting').toString()
              : 'Start chatting';
          final id = c['_id']?.toString() ?? '';
          final selected = selectedConversationIds.contains(id);
          return Dismissible(
            key: ValueKey('conversation-swipe-$id'),
            direction: id.isEmpty || !_useSwipeToDelete(context)
                ? DismissDirection.none
                : DismissDirection.startToEnd,
            background: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.onErrorContainer),
            ),
            confirmDismiss: (_) async =>
                await showDialog<bool>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: const Text('Remove conversation?'),
                    content: const Text(
                        'This hides the conversation from your chat list only. Other participants keep their copies.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: const Text('Delete for me')),
                    ],
                  ),
                ) ??
                false,
            onDismissed: (_) async {
              setState(() => chats.removeWhere(
                  (item) => item is Map && item['_id']?.toString() == id));
              try {
                await app.api.call('POST', '/api/conversations/delete', {
                  'conversationIds': [id]
                });
                await loadChats();
              } catch (error) {
                await loadChats();
                if (context.mounted)
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Could not remove conversation: $error')));
              }
            },
            child: ListTile(
              leading: selectingChats
                  ? Checkbox(
                      value: selected,
                      onChanged: (_) => _toggleConversationSelection(id))
                  : Builder(builder: (context) {
                      // Group chats use their own image; direct chats use the other
                      // participant's profile image. Tapping opens an enlarged viewer.
                      final image = c['type'] == 'group'
                          ? _conversationGroupImage(c)
                          : _conversationProfileImage(c, app.user);
                      return GestureDetector(
                        onTap: () => _showExpandedAvatar(
                          name: title,
                          imageUrl: image ?? '',
                        ),
                        child: CircleAvatar(
                          foregroundImage:
                              image == null ? null : NetworkImage(image),
                          child: Text(
                              title.isEmpty ? '?' : title[0].toUpperCase()),
                        ),
                      );
                    }),
              title: Text(title),
              subtitle: Text(preview),
              trailing: !_useSwipeToDelete(context) && id.isNotEmpty
                  ? IconButton(
                      tooltip: 'Remove conversation',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _removeConversationFromDesktop(id),
                    )
                  : null,
              selected: selected,
              onLongPress: () {
                if (!selectingChats) setState(() => selectingChats = true);
                _toggleConversationSelection(id);
              },
              onTap: () {
                if (selectingChats) {
                  _toggleConversationSelection(id);
                  return;
                }
                Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => Chat(conversation: c)))
                    .then((_) => loadChats());
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _removeSavedContactFromDesktop(
      Map<String, dynamic> contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Remove saved contact?'),
        content: Text(
            'Remove ${contact['name'] ?? 'this contact'} from your saved contacts? Their account and messages will not be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await app.api.call('DELETE', '/api/contacts/${contact['id']}');
      if (mounted)
        setState(() => savedContacts.removeWhere((item) =>
            item is Map &&
            item['id']?.toString() == contact['id']?.toString()));
      await loadSavedContacts();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not remove contact: $error')));
    }
  }

  Future<void> loadSavedContacts() async {
    if (mounted) setState(() => contactsLoading = true);
    try {
      final result = await app.api
          .call('GET', '/api/contacts?page=$contactsPage&limit=$_homePageSize');
      if (mounted) {
        setState(() {
          savedContacts = List<dynamic>.from(result['contacts'] ?? []);
          contactsTotal =
              (result['total'] as num?)?.toInt() ?? savedContacts.length;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not load contacts: $error')));
      }
    } finally {
      if (mounted) setState(() => contactsLoading = false);
    }
  }

  @override
  void dispose() {
    _observedAppState?.removeListener(_onAppStateChanged);
    _phoneSearchDebounce?.cancel();
    super.dispose();
  }

  Future<void> searchPhone([String? query]) async {
    final value = (query ?? phoneQuery).trim();
    if (query != null) phoneQuery = query;
    if (value.replaceAll(RegExp(r'\D'), '').length < 3) {
      if (mounted) {
        setState(() {
          phoneResults = [];
          phoneSearching = false;
        });
      }
      return;
    }
    setState(() => phoneSearching = true);
    try {
      final result = await app.api.call(
          'GET', '/api/contacts/search?q=${Uri.encodeQueryComponent(value)}');
      if (mounted && phoneQuery.trim() == value) {
        setState(
            () => phoneResults = List<dynamic>.from(result['users'] ?? []));
      }
    } catch (error) {
      if (mounted && phoneQuery.trim() == value) {
        setState(() => phoneResults = []);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && phoneQuery.trim() == value) {
        setState(() => phoneSearching = false);
      }
    }
  }

  Future<void> savePhoneContact(String phone) async {
    try {
      await app.api.call('POST', '/api/contacts', {'phone': phone});
      await loadSavedContacts();
      if (mounted) {
        setState(() => phoneResults = []);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Contact saved.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _openUserChat(String userId) async {
    try {
      final result = await app.api.call(
        'POST',
        '/api/conversations/direct',
        {'userId': userId},
      );
      if (!mounted) return;
      final conversation = Map<String, dynamic>.from(result['conversation']);
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => Chat(conversation: conversation)),
      );
      if (mounted) loadChats();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    }
  }

  Future<void> saveUserContact(String userId) async {
    try {
      await app.api.call('POST', '/api/contacts', {'userId': userId});
      await loadSavedContacts();
      if (mounted) {
        // Keep live search results visible so another matching account can be
        // selected without retyping the query.
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Contact saved.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> removeSavedContact(Map<String, dynamic> contact) async {
    try {
      await app.api.call('DELETE', '/api/contacts/${contact['id']}');
      await loadSavedContacts();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Widget _contacts() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: TextField(
          keyboardType: TextInputType.phone,
          onChanged: (value) {
            phoneQuery = value;
            _phoneSearchDebounce?.cancel();
            _phoneSearchDebounce = Timer(
              const Duration(milliseconds: 300),
              () => searchPhone(value),
            );
          },
          onSubmitted: (_) => searchPhone(),
          decoration: InputDecoration(
            labelText: 'Find by phone number',
            hintText: 'Type a number, e.g. 0712 or +254712',
            prefixIcon: const Icon(Icons.phone),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Search phone number',
              onPressed: phoneSearching ? null : searchPhone,
              icon: phoneSearching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
            ),
          ),
        ),
      ),
      if (phoneQuery.trim().replaceAll(RegExp(r'\D'), '').length >= 3 &&
          phoneSearching)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: LinearProgressIndicator(),
        ),
      if (phoneQuery.trim().replaceAll(RegExp(r'\D'), '').length >= 3 &&
          !phoneSearching &&
          phoneResults.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
                'No accounts match that number yet. Keep typing or check the digits.'),
          ),
        ),
      if (phoneResults.isNotEmpty)
        SizedBox(
          height: phoneResults.length > 2 ? 144.0 : phoneResults.length * 68.0,
          child: ListView.builder(
            itemCount: phoneResults.length,
            itemBuilder: (_, i) {
              final person = Map<String, dynamic>.from(phoneResults[i]);
              final name = person['name']?.toString() ?? 'Chatify user';
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  foregroundImage: (person['profileImage'] is String &&
                          (person['profileImage'] as String)
                              .startsWith('https://'))
                      ? NetworkImage(person['profileImage'] as String)
                      : null,
                  child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
                ),
                title: Text(name),
                subtitle: Text(person['phone']?.toString() ?? ''),
                trailing: IconButton(
                  tooltip: 'Save contact',
                  icon: const Icon(Icons.person_add_alt_1),
                  onPressed: () => savePhoneContact(
                    person['phone']?.toString() ?? phoneQuery,
                  ),
                ),
              );
            },
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: TextField(
          onChanged: search,
          decoration: const InputDecoration(
            labelText: 'Search by user name or email',
            hintText: 'Type at least 2 letters',
            prefixIcon: Icon(Icons.person_search),
            border: OutlineInputBorder(),
          ),
        ),
      ),
      if (contactQuery.trim().length >= 2)
        SizedBox(
          height: 156,
          child: usersLoading
              ? const Center(child: CircularProgressIndicator())
              : usersError != null
                  ? Center(child: Text(usersError!))
                  : users.isEmpty
                      ? Center(
                          child: Text(
                            'No registered users match “${contactQuery.trim()}”.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          itemCount: users.length,
                          itemBuilder: (_, i) {
                            final user = Map<String, dynamic>.from(users[i]);
                            final name = user['name']?.toString() ?? 'User';
                            final userId = user['_id']?.toString() ??
                                user['id']?.toString() ??
                                '';
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.person_outline),
                              title: Text(name),
                              subtitle: Text(user['email']?.toString() ?? ''),
                              onTap: userId.isEmpty
                                  ? null
                                  : () => _openUserChat(userId),
                              trailing: Wrap(
                                spacing: 0,
                                children: [
                                  IconButton(
                                    tooltip: 'Save contact',
                                    icon: const Icon(Icons.person_add_alt_1),
                                    onPressed: userId.isEmpty
                                        ? null
                                        : () => saveUserContact(userId),
                                  ),
                                  IconButton(
                                    tooltip: 'Chat now',
                                    icon: const Icon(Icons.chat_bubble_outline),
                                    onPressed: userId.isEmpty
                                        ? null
                                        : () => _openUserChat(userId),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Saved contacts',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            IconButton(
              tooltip: 'Refresh contacts',
              onPressed: loadSavedContacts,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      Expanded(
        child: contactsLoading
            ? const Center(child: CircularProgressIndicator())
            : savedContacts.isEmpty
                ? const Empty(
                    icon: Icons.contacts_outlined,
                    title: 'No saved contacts',
                    subtitle:
                        'Search for a registered phone number or user name and save it here.',
                  )
                : ListView.builder(
                    itemCount: savedContacts.length + 1,
                    itemBuilder: (_, i) {
                      if (i == savedContacts.length) {
                        return _homePager(
                          page: contactsPage,
                          total: contactsTotal,
                          previous: () {
                            setState(() => contactsPage--);
                            loadSavedContacts();
                          },
                          next: () {
                            setState(() => contactsPage++);
                            loadSavedContacts();
                          },
                        );
                      }
                      final contact =
                          Map<String, dynamic>.from(savedContacts[i]);
                      final name = contact['name']?.toString() ?? 'Contact';
                      return Dismissible(
                        key: ValueKey('saved-contact-' +
                            (contact['id']?.toString() ?? 'unknown')),
                        direction: _useSwipeToDelete(context)
                            ? DismissDirection.startToEnd
                            : DismissDirection.none,
                        background: Container(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.only(left: 20),
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Icon(Icons.person_remove_outlined,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer),
                        ),
                        confirmDismiss: (_) async =>
                            await showDialog<bool>(
                              context: context,
                              builder: (dialog) => AlertDialog(
                                title: const Text('Remove saved contact?'),
                                content: Text(
                                    'Remove ${contact['name'] ?? 'this contact'} from your saved contacts? Their account and messages will not be deleted.'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialog, false),
                                      child: const Text('Cancel')),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(dialog, true),
                                      child: const Text('Remove')),
                                ],
                              ),
                            ) ??
                            false,
                        onDismissed: (_) async {
                          setState(() => savedContacts.removeWhere((item) =>
                              item is Map &&
                              item['id']?.toString() ==
                                  contact['id']?.toString()));
                          try {
                            await app.api.call(
                                'DELETE', '/api/contacts/${contact['id']}');
                            await loadSavedContacts();
                          } catch (error) {
                            await loadSavedContacts();
                            if (context.mounted)
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          'Could not remove contact: $error')));
                          }
                        },
                        child: ListTile(
                          leading: CircleAvatar(
                            foregroundImage:
                                (contact['profileImage'] is String &&
                                        (contact['profileImage'] as String)
                                            .startsWith('https://'))
                                    ? NetworkImage(
                                        contact['profileImage'] as String)
                                    : null,
                            child: Text(
                                name.isEmpty ? '?' : name[0].toUpperCase()),
                          ),
                          title: Text(name),
                          trailing: !_useSwipeToDelete(context)
                              ? IconButton(
                                  tooltip: 'Remove saved contact',
                                  icon:
                                      const Icon(Icons.person_remove_outlined),
                                  onPressed: () =>
                                      _removeSavedContactFromDesktop(contact),
                                )
                              : null,
                          subtitle: Text([
                            if ((contact['phone']?.toString() ?? '').isNotEmpty)
                              'Phone: ${contact['phone']}',
                            if ((contact['email']?.toString() ?? '').isNotEmpty)
                              'Email: ${contact['email']}',
                          ].join('\n')),
                          onTap: () async {
                            try {
                              final result = await app.api.call(
                                'POST',
                                '/api/conversations/direct',
                                {'userId': contact['userId']},
                              );
                              if (!mounted) return;
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => Chat(
                                    conversation: Map<String, dynamic>.from(
                                      result['conversation'],
                                    ),
                                  ),
                                ),
                              ).then((_) => loadChats());
                            } catch (error) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error.toString())),
                                );
                              }
                            }
                          },
                        ),
                      );
                    },
                  ),
      ),
    ]);
  }

  Widget _memories() {
    if (memoriesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (memoriesError != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(memoriesError!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        AsyncActionButton(
            label: 'Retry memories',
            icon: Icons.refresh,
            onPressed: loadMemories)
      ]));
    }
    if (memories.isEmpty) {
      return const Empty(
          icon: Icons.auto_awesome,
          title: 'No memories saved',
          subtitle: 'Save useful events, tasks, places and payments.');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: memories.length + 1,
      itemBuilder: (_, i) {
        if (i == memories.length) {
          return _homePager(
            page: memoryPage,
            total: memoryTotal,
            previous: () {
              setState(() => memoryPage--);
              loadMemories();
            },
            next: () {
              setState(() => memoryPage++);
              loadMemories();
            },
          );
        }
        final memory = Map<String, dynamic>.from(memories[i]);
        final memoryDate = DateTime.tryParse(memory['date']?.toString() ?? '');
        return Dismissible(
            key: ValueKey(memory['_id']),
            direction: _useSwipeToDelete(context)
                ? DismissDirection.startToEnd
                : DismissDirection.none,
            background: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 20),
                color: Theme.of(context).colorScheme.errorContainer,
                child: Icon(Icons.delete_outline,
                    color: Theme.of(context).colorScheme.onErrorContainer)),
            confirmDismiss: (_) async =>
                await showDialog<bool>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: const Text('Delete saved memory?'),
                    content: Text(
                        'Delete “${memory['title'] ?? 'Memory'}” from your saved memories?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: const Text('Delete')),
                    ],
                  ),
                ) ??
                false,
            onDismissed: (_) async {
              // Dismissible requires the item to leave the backing list immediately;
              // otherwise Flutter can report that a dismissed widget is still in the tree.
              if (mounted) {
                setState(() {
                  memories.removeWhere((item) =>
                      item is Map &&
                      item['_id']?.toString() == memory['_id']?.toString());
                });
              }
              try {
                await app.api.call('DELETE', '/api/memories/${memory['_id']}');
              } catch (error) {
                if (!mounted) return;
                await loadMemories();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not delete memory: $error')));
              }
            },
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      memory['title']?.toString() ?? 'Memory',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if ((memory['personName']?.toString() ?? '')
                        .trim()
                        .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('With ${memory['personName']}'),
                      ),
                    if ((memory['description']?.toString() ?? '')
                        .trim()
                        .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(memory['description'].toString()),
                      ),
                    if (memoryDate != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Date: ${DateFormat.yMMMd().format(memoryDate.toLocal())}',
                        ),
                      ),
                    if ((memory['time']?.toString() ?? '').trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('Time: ${memory['time']}'),
                      ),
                    if ((memory['location']?.toString() ?? '')
                        .trim()
                        .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('Place: ${memory['location']}'),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (memory['conversationId'] != null)
                          TextButton.icon(
                            onPressed: () => _openMemoryConversation(memory),
                            icon: const Icon(Icons.chat_bubble_outline),
                            label: const Text('Open conversation'),
                          ),
                        TextButton.icon(
                          onPressed: () => _toggleMemoryCompleted(memory),
                          icon: Icon(memory['completed'] == true
                              ? Icons.undo
                              : Icons.check_circle_outline),
                          label: Text(memory['completed'] == true
                              ? 'Restore'
                              : 'Mark complete'),
                        ),
                        IconButton(
                          tooltip: 'Delete saved memory',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteMemoryCard(memory),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ));
      },
    );
  }

  Future<void> _newGroup() async {
    final title = TextEditingController();
    final emails = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Create group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Group name')),
            TextField(
                controller: emails,
                keyboardType: TextInputType.emailAddress,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                    labelText: 'Member emails',
                    helperText: 'Separate addresses with commas or new lines')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                final memberEmails = emails.text
                    .split(RegExp(r'[,;\n]'))
                    .map((value) => value.trim().toLowerCase())
                    .where((value) => value.isNotEmpty)
                    .toSet();
                if (memberEmails.isEmpty) {
                  throw Exception('Enter at least one member email');
                }
                final memberIds = <String>[];
                for (final memberEmail in memberEmails) {
                  final result = await app.api.call('GET',
                      '/api/users/search?q=${Uri.encodeQueryComponent(memberEmail)}');
                  final found = List<dynamic>.from(result['users'] ?? []);
                  final match = found.where((user) =>
                      user is Map &&
                      user['email']?.toString().toLowerCase() == memberEmail);
                  if (match.isEmpty) {
                    throw Exception('No account found for $memberEmail');
                  }
                  memberIds.add(match.first['_id'].toString());
                }
                final created =
                    await app.api.call('POST', '/api/conversations/group', {
                  'title': title.text.trim(),
                  'memberIds': memberIds,
                });
                if (dialog.mounted) Navigator.pop(dialog);
                if (!mounted) return;
                Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Chat(
                          conversation: Map<String, dynamic>.from(
                              created['conversation'])),
                    ));
              } catch (error) {
                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(error.toString())));
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    title.dispose();
    emails.dispose();
  }
}

// Consistent empty-state message for screens that have no records to display yet.
class Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const Empty({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                height: 84,
                width: 84,
                decoration: BoxDecoration(
                  color: const Color(0xFFDDF5F2),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Icon(
                  icon,
                  size: 38,
                  color: const Color(0xFF087F8C),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: 21,
                      letterSpacing: -0.4,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF68788D),
                      height: 1.55,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Displays payment requests and their current statuses for the signed-in user.
class PaymentHistory extends StatefulWidget {
  const PaymentHistory({super.key});
  @override
  State<PaymentHistory> createState() => _PaymentHistoryState();
}

// Loads payment history and refreshes the list when payment data changes.
class _PaymentHistoryState extends State<PaymentHistory> {
  List<dynamic> payments = [];
  bool loading = true;
  String? error;
  Future<void> load() async {
    try {
      final result =
          await context.read<AppState>().api.call('GET', '/api/payments');
      if (mounted) {
        setState(() {
          payments = List<dynamic>.from(result['payments'] ?? []);
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Payment history'), actions: [
        IconButton(onPressed: load, icon: const Icon(Icons.refresh))
      ]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!))
              : payments.isEmpty
                  ? const Empty(
                      icon: Icons.payments_outlined,
                      title: 'No payments yet',
                      subtitle: 'Requests and payments will appear here.')
                  : RefreshIndicator(
                      onRefresh: load,
                      child: ListView.builder(
                          itemCount: payments.length,
                          itemBuilder: (_, i) {
                            final p = Map<String, dynamic>.from(payments[i]);
                            return PaymentCard(
                                payment: p,
                                currentUserId: app.user?['id']?.toString(),
                                onPay: () => payHistoryPayment(p),
                                onRetry: () => retryHistoryPayment(p),
                                onRefresh: () async {
                                  try {
                                    final result = await app.api.paymentStatus(
                                        p['paymentId'].toString());
                                    final index = payments.indexWhere((item) =>
                                        item is Map &&
                                        item['paymentId'] == p['paymentId']);
                                    if (mounted && index >= 0) {
                                      setState(() =>
                                          payments[index] = result['payment']);
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      messenger.showSnackBar(SnackBar(
                                          content: Text(e.toString())));
                                    }
                                  }
                                });
                          }),
                    ),
    );
  }

  Future<void> payHistoryPayment(Map<String, dynamic> payment) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final phone = TextEditingController(
      text: payment['payerPhone']?.toString() ??
          payment['phone']?.toString() ??
          app.user?['phone']?.toString() ??
          '',
    );
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Pay with M-Pesa'),
        content: Form(
          key: form,
          child: TextFormField(
            controller: phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Your M-Pesa phone number',
              hintText: '0712345678 or 254712345678',
              helperText: 'The STK prompt will be sent to this number.',
            ),
            validator: (value) => normalizeKenyanPhone(value ?? '') == null
                ? 'Enter a valid Kenyan M-Pesa number'
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(dialog, true);
              }
            },
            child: const Text('Send prompt'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) {
      phone.dispose();
      return;
    }
    try {
      final result = await app.api.call(
        'POST',
        '/api/payments/${payment['paymentId']}/initiate',
        {'phone': normalizeKenyanPhone(phone.text)!},
      );
      final updated = Map<String, dynamic>.from(result['payment']);
      final index = payments.indexWhere(
          (item) => item is Map && item['paymentId'] == updated['paymentId']);
      if (mounted && index >= 0) setState(() => payments[index] = updated);
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(result['mock'] == true
              ? 'Local demo only: no Safaricom prompt was sent. Configure live Daraja on the API service to send real prompts.'
              : 'STK request accepted. Check ${normalizeKenyanPhone(phone.text)} for the Safaricom prompt. Enter your PIN only in that prompt.'),
          duration: const Duration(seconds: 6),
        ));
        // After the STK prompt is requested, move to payment history so the
        // user can follow the server-confirmed payment status without guessing.
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => const PaymentHistory(),
        ));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      phone.dispose();
    }
  }

  Future<void> retryHistoryPayment(Map<String, dynamic> payment) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/retry', {});
      final created = Map<String, dynamic>.from(result['payment']);
      if (mounted) setState(() => payments.insert(0, created));
      if (mounted) await payHistoryPayment(created);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }
}

// Presents one payment request, its amount, participants and status in a compact card.
class PaymentCard extends StatelessWidget {
  final Map<String, dynamic> payment;
  final String? currentUserId;
  final VoidCallback? onPay;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;
  final VoidCallback? onReject;
  final VoidCallback? onReopen;
  final String? rejectLabel;
  final VoidCallback onRefresh;
  const PaymentCard({
    super.key,
    required this.payment,
    required this.currentUserId,
    required this.onRefresh,
    this.onPay,
    this.onRetry,
    this.onClose,
    this.onReject,
    this.onReopen,
    this.rejectLabel,
  });

  @override
  Widget build(BuildContext context) {
    final status = (payment['status'] ?? 'PENDING').toString();
    final isPayer = payment['payerId']?.toString() == currentUserId;
    final isMock = payment['provider']?.toString() == 'mock';
    final baseAmount = (payment['baseAmount'] as num?)?.toInt() ??
        (payment['amount'] as num?)?.toInt() ??
        0;
    final platformFee = (payment['platformFee'] as num?)?.toInt() ?? 0;
    final totalAmount =
        (payment['totalAmount'] as num?)?.toInt() ?? baseAmount + platformFee;
    final canReject = status == 'PENDING' &&
        payment['initiatedAt'] == null &&
        payment['initiating'] != true &&
        onReject != null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.payments_outlined),
              title:
                  Text(payment['description']?.toString() ?? 'M-Pesa payment'),
              subtitle: Text(
                platformFee > 0
                    ? 'Base KSh $baseAmount + platform fee KSh $platformFee = total KSh $totalAmount · $status · Fee ${payment['platformFeeStatus'] ?? 'PENDING_PAYMENT'}${isMock ? ' · Local demo' : ''}'
                    : 'KSh ${payment['amount'] ?? ''} · $status · To ${payment['recipientPhone'] ?? 'recipient'}${isMock ? ' · Local demo' : ''}',
              ),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 0,
              children: [
                if (onReopen != null)
                  TextButton.icon(
                    onPressed: onReopen,
                    icon: const Icon(Icons.unarchive_outlined, size: 18),
                    label: const Text('Reopen request'),
                  ),
                if (onReopen == null &&
                    status == 'PENDING' &&
                    isPayer &&
                    onPay != null)
                  TextButton(
                    onPressed: onPay,
                    child: const Text('Pay with M-Pesa'),
                  ),
                if (onReopen == null &&
                    (status == 'FAILED' || status == 'CANCELLED') &&
                    isPayer &&
                    onRetry != null)
                  TextButton(onPressed: onRetry, child: const Text('Retry')),
                if (onReopen == null && canReject)
                  TextButton.icon(
                    onPressed: onReject,
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    label: Text(rejectLabel ?? 'Reject request'),
                  ),
                if (onReopen == null && onClose != null)
                  TextButton.icon(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Close for me'),
                  ),
                TextButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Status'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Screen for one direct or group conversation, including messages and the composer.
class Chat extends StatefulWidget {
  final Map<String, dynamic> conversation;
  // Optional editable draft for a product enquiry; it is only sent after the user taps Send.
  final String? initialMessage;
  const Chat({super.key, required this.conversation, this.initialMessage});
  @override
  State<Chat> createState() => _ChatState();
}

// Owns the active conversation UI: loads messages, listens for real-time events, and sends message actions.
class _ChatState extends State<Chat> {
  final input = TextEditingController();
  final searchInput = TextEditingController();
  final ScrollController _messagesScrollController = ScrollController();
  Timer? _typingTimer;
  Timer? _remoteTypingTimer;
  bool _isTyping = false;
  List<dynamic> messages = [];
  List<dynamic> payments = [];
  // Suggestions remain in UI state until the user explicitly saves a Memory Card.
  List<Map<String, dynamic>> memorySuggestions = [];
  String? memorySuggestionSourceId;
  bool savingMemorySuggestion = false;
  final Set<String> _checkedMemoryMessageIds = {};
  final Set<String> _dismissedMemoryMessageIds = {};
  final Set<String> _savedMemoryMessageIds = {};
  final Set<String> mentionedUserIds = {};
  final Map<String, String> _mentionedNamesById = {};
  List<Map<String, dynamic>> _mentionSuggestions = [];
  int _mentionStart = -1;
  int _mentionCursor = -1;
  int _mentionActiveIndex = 0;
  bool _savedMemoryMessageIdsLoaded = false;
  bool showClosedPayments = false;
  String expiry = 'NONE';
  String? reply;
  String? typingUser;
  bool searching = false;
  bool sending = false;
  // Keep the mutation ID for a failed draft so retrying after a timeout cannot duplicate it.
  String? _pendingMutationId;
  String? _pendingMutationText;
  final Set<String> onlineIds = {};
  io.Socket? socket;
  bool loading = true;
  bool _socketConnectedOnce = false;
  bool _flushingOutbox = false;
  String? _socketToken;
  String? loadError;
  bool showingOfflineData = false;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    if (widget.initialMessage != null &&
        widget.initialMessage!.trim().isNotEmpty) {
      input.text = widget.initialMessage!.trim();
      input.selection = TextSelection.collapsed(offset: input.text.length);
    }
    app.addListener(_syncPresence);
    _syncPresence();
    load();
    connect();
  }

  // Resolve the other member from the conversation payload. The API normally
  // populates participants with user names, but support both id/_id and nested
  // user objects so the header still works across older conversation responses.
  String? _directPeerName() {
    if (widget.conversation['type'] != 'direct') return null;
    final participants = widget.conversation['participants'];
    if (participants is! List) return null;

    final currentUserIds = <String>{
      app.user?['id']?.toString() ?? '',
      app.user?['_id']?.toString() ?? '',
    }..remove('');
    Map<String, dynamic>? fallbackParticipant;

    for (final rawParticipant in participants) {
      if (rawParticipant is! Map) continue;
      final participant = Map<String, dynamic>.from(rawParticipant);
      final nestedUser = participant['user'] is Map
          ? Map<String, dynamic>.from(participant['user'] as Map)
          : <String, dynamic>{};
      final rawId = participant['_id'] ??
          participant['id'] ??
          nestedUser['_id'] ??
          nestedUser['id'];
      final participantId = rawId?.toString() ?? '';

      // Never accidentally show the signed-in user's own name as the chat peer.
      if (participantId.isNotEmpty && currentUserIds.contains(participantId)) {
        continue;
      }
      fallbackParticipant ??= participant;

      final name = (participant['name'] ??
              nestedUser['name'] ??
              participant['username'] ??
              nestedUser['username'] ??
              participant['displayName'] ??
              nestedUser['displayName'] ??
              '')
          .toString()
          .trim();
      if (name.isNotEmpty) return name;
    }

    final fallback = fallbackParticipant;
    if (fallback == null) return null;
    final nestedUser = fallback['user'] is Map
        ? Map<String, dynamic>.from(fallback['user'] as Map)
        : <String, dynamic>{};
    final fallbackName = (fallback['name'] ??
            nestedUser['name'] ??
            fallback['username'] ??
            nestedUser['username'] ??
            '')
        .toString()
        .trim();
    return fallbackName.isEmpty ? null : fallbackName;
  }

  String? _directPeerLastSeenLabel() {
    if (widget.conversation['type'] != 'direct') return null;
    final participants = widget.conversation['participants'];
    if (participants is! List) return null;
    final currentIds = {
      app.user?['id']?.toString() ?? '',
      app.user?['_id']?.toString() ?? '',
    };
    for (final raw in participants) {
      if (raw is! Map) continue;
      final participant = Map<String, dynamic>.from(raw);
      final id = (participant['_id'] ?? participant['id'])?.toString() ?? '';
      if (currentIds.contains(id)) continue;
      final privacy = participant['privacy'];
      if (privacy is Map && privacy['lastSeen'] == false) return null;
      final value =
          DateTime.tryParse(participant['lastSeen']?.toString() ?? '');
      if (value == null) return null;
      final elapsed = DateTime.now().difference(value.toLocal());
      if (elapsed.inMinutes < 1) return 'Last seen just now';
      if (elapsed.inHours < 1) return 'Last seen ${elapsed.inMinutes}m ago';
      if (elapsed.inDays < 1) return 'Last seen ${elapsed.inHours}h ago';
      return 'Last seen ${value.toLocal().day}/${value.toLocal().month}/${value.toLocal().year}';
    }
    return null;
  }

  void _recordPeerOffline(dynamic event) {
    if (event is! Map || event['lastSeen'] == null) return;
    final peerId = _directPeerId();
    if (peerId == null || event['userId']?.toString() != peerId) return;
    final participants = widget.conversation['participants'];
    if (participants is! List) return;
    final updated = participants.map((raw) {
      if (raw is! Map) return raw;
      final participant = Map<String, dynamic>.from(raw);
      if ((participant['_id'] ?? participant['id'])?.toString() == peerId) {
        participant['lastSeen'] = event['lastSeen'];
      }
      return participant;
    }).toList();
    widget.conversation['participants'] = updated;
  }

  String? _directPeerId() {
    if (widget.conversation['type'] != 'direct') return null;
    final participants = widget.conversation['participants'];
    if (participants is! List) return null;
    final currentUserIds = <String>{
      app.user?['id']?.toString() ?? '',
      app.user?['_id']?.toString() ?? '',
    }..remove('');
    for (final participant in participants) {
      if (participant is! Map) continue;
      final nestedUser =
          participant['user'] is Map ? participant['user'] as Map : null;
      final rawId = participant['_id'] ??
          participant['id'] ??
          nestedUser?['_id'] ??
          nestedUser?['id'];
      if (rawId == null) continue;
      final id = rawId.toString();
      if (id.isNotEmpty && !currentUserIds.contains(id)) return id;
    }
    return null;
  }

  void _syncPresence() {
    if (!mounted) return;
    // Password changes rotate JWTs. Rebuild an active chat socket before it retries
    // with the revoked token; initial connection is handled by initState below.
    final currentToken = app.api.token;
    if (_socketToken != null && currentToken != _socketToken) connect();
    final peerId = _directPeerId();
    final shouldBeOnline = peerId != null && app.onlineUserIds.contains(peerId);
    final isOnline = peerId != null && onlineIds.contains(peerId);
    if (shouldBeOnline == isOnline) return;
    setState(() {
      onlineIds.clear();
      if (peerId != null && app.onlineUserIds.contains(peerId)) {
        onlineIds.add(peerId);
      }
    });
  }

  void _scrollToLatestMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messagesScrollController.hasClients) return;
      final position = _messagesScrollController.position;
      if (!position.hasContentDimensions) return;
      _messagesScrollController.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    _typingTimer = null;
    if (_isTyping) {
      socket?.emit('typing:stop', widget.conversation['_id']);
      _isTyping = false;
    }
  }

  void _handleTyping(String value) {
    if (value.trim().isEmpty) {
      _stopTyping();
      return;
    }
    if (!_isTyping) {
      socket?.emit('typing:start', widget.conversation['_id']);
      _isTyping = true;
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(milliseconds: 1600), _stopTyping);
  }

  String _participantId(dynamic participant) {
    if (participant is Map) {
      return (participant['_id'] ?? participant['id'] ?? '').toString();
    }
    return participant?.toString() ?? '';
  }

  Future<Map<String, dynamic>> _encryptTextPayload(String plaintext) async {
    final senderId = app.user?['id']?.toString() ?? '';
    final ownPublicKey = await app.ensureEncryptionKey();
    final publicKeys = <String, String>{};
    for (final participant
        in List<dynamic>.from(widget.conversation['participants'] ?? [])) {
      if (participant is! Map) continue;
      final id = _participantId(participant);
      if (id.isEmpty) continue;
      if (id == senderId) {
        publicKeys[id] = ownPublicKey;
        continue;
      }
      final key = participant['encryptionPublicKey']?.toString();
      if (key == null || key.isEmpty) {
        throw StateError(
            'Every conversation member must open the latest Chatify version once to enable encrypted messaging.');
      }
      publicKeys[id] = key;
    }
    return ChatifyE2EE.instance.encryptText(
      senderId: senderId,
      conversationId: widget.conversation['_id'].toString(),
      plaintext: plaintext,
      participantPublicKeys: publicKeys,
      registeredSenderPublicKey: ownPublicKey,
    );
  }

  Future<Map<String, dynamic>> _decryptMessage(Map<String, dynamic> raw) async {
    if (raw['encryptionVersion'] != 1 ||
        raw['encryptedPayload'] is! String ||
        raw['deletedAt'] != null ||
        raw['expiredAt'] != null) {
      return raw;
    }
    final currentId = app.user?['id']?.toString() ?? '';
    final senderId = _participantId(raw['senderId']);
    String? senderPublicKey;
    if (senderId == currentId) {
      senderPublicKey = app.user?['encryptionPublicKey']?.toString();
      if (senderPublicKey == null || senderPublicKey.isEmpty) {
        senderPublicKey = await app.ensureEncryptionKey();
      }
    } else {
      for (final participant
          in List<dynamic>.from(widget.conversation['participants'] ?? [])) {
        if (participant is Map && _participantId(participant) == senderId) {
          senderPublicKey = participant['encryptionPublicKey']?.toString();
          break;
        }
      }
    }
    try {
      if (senderPublicKey == null || senderPublicKey.isEmpty) {
        throw StateError('The sender public key is unavailable.');
      }
      final clearText = await ChatifyE2EE.instance.decryptText(
        accountId: currentId,
        conversationId: widget.conversation['_id'].toString(),
        senderPublicKey: senderPublicKey,
        encryptedPayload: raw['encryptedPayload'].toString(),
        registeredAccountPublicKey:
            app.user?['encryptionPublicKey']?.toString(),
      );
      return <String, dynamic>{
        ...raw,
        'text': clearText,
        'decryptionFailed': false
      };
    } catch (_) {
      return <String, dynamic>{
        ...raw,
        'text': '🔒 Unable to decrypt this message on this device.',
        'decryptionFailed': true,
      };
    }
  }

  Future<void> _persistConversationMessages() async {
    final conversationId = widget.conversation['_id']?.toString();
    if (conversationId == null || conversationId.isEmpty || messages.isEmpty) {
      return;
    }
    // Keep the encrypted payload, not its decrypted plaintext, for E2EE messages.
    // The snapshot itself is written through FlutterSecureStorage.
    final snapshot = messages.whereType<Map>().map((message) {
      final copy = Map<String, dynamic>.from(message);
      if (copy['encryptionVersion'] == 1 &&
          copy['encryptedPayload'] is String) {
        copy.remove('text');
        copy.remove('decryptionFailed');
      }
      return copy;
    }).toList();
    await app.api.writeConversationSnapshot(conversationId, snapshot);
  }

  Future<void> load() async {
    final conversationId = widget.conversation['_id']?.toString() ?? '';
    // Hydrate the last saved history before attempting the network. This avoids
    // an empty chat or spinner when a previously opened conversation is offline.
    try {
      final cachedConversation =
          await app.api.readConversationMetadata(conversationId);
      if (cachedConversation != null) {
        widget.conversation.addAll(cachedConversation);
      }
      final cached = await app.api.readConversationSnapshot(conversationId);
      if (cached != null && cached.isNotEmpty && mounted && messages.isEmpty) {
        final hydrated = await Future.wait(cached.map((raw) async {
          if (raw is Map)
            return _decryptMessage(Map<String, dynamic>.from(raw));
          return raw;
        }));
        if (mounted) {
          setState(() {
            messages = mergeMessages(messages, hydrated);
            loading = false;
            loadError = null;
            showingOfflineData = true;
          });
          _scrollToLatestMessage();
        }
      }
    } catch (_) {
      // Fall through to API cache/network loading if local hydration fails.
    }
    try {
      // Fetch conversation metadata and messages together: these are independent
      // requests, and serialising them adds a full network round-trip to every
      // conversation open (especially noticeable on mobile connections).
      final results = await Future.wait([
        app.api.call('GET', '/api/conversations/${widget.conversation['_id']}'),
        app.api.call(
            'GET', '/api/conversations/${widget.conversation['_id']}/messages'),
      ]);
      final detail = results[0];
      widget.conversation
          .addAll(Map<String, dynamic>.from(detail['conversation']));
      unawaited(app.api
          .writeConversationMetadata(conversationId, widget.conversation));
      final fetched = List<dynamic>.from(results[1]['messages'] ?? []);
      final decryptedFetched = await Future.wait(fetched.map((raw) async {
        if (raw is Map) return _decryptMessage(Map<String, dynamic>.from(raw));
        return raw;
      }));
      if (mounted) {
        setState(() {
          messages = mergeMessages(messages, decryptedFetched);
          loading = false;
          loadError = null;
          showingOfflineData = app.api.offlineDataMode;
        });
        unawaited(_persistConversationMessages());
        _scrollToLatestMessage();
        // Inspect recent text messages automatically; users do not need the manual-save menu.
        _scanRecentMessagesForMemory(fetched);
        // A successful history refresh is also a recovery opportunity for any
        // securely queued messages whose previous retry was interrupted.
        unawaited(_flushOutgoingMessages());
      }

      // Payment history is supplementary. Do not keep the whole conversation
      // behind a spinner while an unrelated payments endpoint responds slowly.
      unawaited(() async {
        try {
          final paymentResult = await app.api.call('GET', '/api/payments');
          final conversationPayments =
              List<dynamic>.from(paymentResult['payments'] ?? [])
                  .where((item) =>
                      item is Map &&
                      item['conversationId']?.toString() ==
                          widget.conversation['_id']?.toString())
                  .toList();
          if (mounted) setState(() => payments = conversationPayments);
        } catch (_) {
          // Payment history is optional; the chat remains usable without it.
        }
      }());

      // Delivery receipts are also non-blocking; message content is already visible.
      for (final item in fetched) {
        if (item is Map &&
            item['senderId']?.toString() != app.user?['id']?.toString()) {
          unawaited(markReceived(item['_id'].toString()));
        }
      }
    } catch (error) {
      if (messages.isEmpty) {
        loadError = error.toString();
      } else {
        // Keep readable cached history visible if the refresh fails.
        loadError = null;
        showingOfflineData = true;
      }
    }
    if (mounted && loading) {
      setState(() => loading = false);
      _scrollToLatestMessage();
    }
  }

  Future<void> _flushOutgoingMessages() async {
    final conversationId = widget.conversation['_id']?.toString();
    final accountScope = app.api.accountScope;
    if (_flushingOutbox ||
        conversationId == null ||
        conversationId.isEmpty ||
        app.api.token == null ||
        app.api.token!.isEmpty) return;
    _flushingOutbox = true;
    var sentAny = false;
    try {
      final queued = await app.api.readOutgoingMessageOutbox(conversationId,
          accountScope: accountScope);
      for (final item in queued) {
        if (app.api.accountScope != accountScope) break;
        final mutationId = item['clientMutationId']?.toString();
        final rawBody = item['body'];
        if (mutationId == null || rawBody is! Map) continue;
        try {
          // Reusing the same mutation ID makes a retry safe even if the server
          // accepted the message but the original HTTP response was lost.
          final body = Map<String, dynamic>.from(rawBody);
          final result = await app.api.call(
              'POST', '/api/conversations/$conversationId/messages', body);
          await app.api.removeOutgoingMessageFromOutbox(
              conversationId, mutationId,
              accountScope: accountScope);
          messages.removeWhere((message) =>
              message is Map &&
              message['_id']?.toString() == 'local_$mutationId');
          if (result['message'] is Map) {
            final sent = await _decryptMessage(
                Map<String, dynamic>.from(result['message']));
            if (mounted)
              setState(() => messages = mergeMessages(messages, [sent]));
          }
          sentAny = true;
        } catch (_) {
          // Preserve the item and stop. The next connection/retry will resume
          // from the same idempotency key instead of losing or duplicating it.
          break;
        }
      }
      if (sentAny && mounted) {
        unawaited(_persistConversationMessages());
        unawaited(load());
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Queued messages sent successfully.')));
      }
    } catch (_) {
      // Secure storage errors never fall back to plaintext or discard queued data.
    } finally {
      _flushingOutbox = false;
    }
  }

  void connect() {
    socket?.dispose();
    final token = app.api.token;
    _socketToken = token;
    if (token == null || token.isEmpty) return;
    socket = io.io(
      app.api.base,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionAttempts(999999)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .disableAutoConnect()
          .build(),
    );
    socket!.onConnect((_) {
      socket!.emit('conversation:join', widget.conversation['_id']);
      unawaited(_flushOutgoingMessages());
      // A long-idle socket can reconnect after messages were sent on another
      // device. Fetch the durable server history after reconnect to fill gaps.
      // Also refresh on the first successful connection after starting offline;
      // that is when this device needs to catch up with messages sent elsewhere.
      if (_socketConnectedOnce ||
          showingOfflineData ||
          app.api.offlineDataMode) {
        unawaited(load());
      }
      _socketConnectedOnce = true;
    });
    socket!.on('typing:start', (data) {
      if (!mounted ||
          data is! Map ||
          data['userId']?.toString() == app.user?['id']?.toString()) {
        return;
      }
      final userId = data['userId']?.toString();
      if (userId == null || userId.isEmpty) return;
      _remoteTypingTimer?.cancel();
      setState(() => typingUser = userId);
      // Recover automatically if a stop event is lost during a reconnect.
      _remoteTypingTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && typingUser == userId) {
          setState(() => typingUser = null);
        }
      });
    });
    socket!.on('typing:stop', (data) {
      if (!mounted || data is! Map) return;
      if (typingUser == data['userId']?.toString()) {
        _remoteTypingTimer?.cancel();
        setState(() => typingUser = null);
      }
    });
    socket!.on('user:online', (data) {
      final peerId = _directPeerId();
      if (data is Map &&
          mounted &&
          peerId != null &&
          data['userId']?.toString() == peerId) {
        setState(() => onlineIds.add(peerId));
      }
    });
    socket!.on('user:offline', (data) {
      final peerId = _directPeerId();
      if (data is Map &&
          mounted &&
          peerId != null &&
          data['userId']?.toString() == peerId) {
        setState(() {
          onlineIds.remove(peerId);
          _recordPeerOffline(data);
        });
      }
    });
    socket!.on('message:new', (data) async {
      if (!mounted || data is! Map) return;
      if (data['conversationId']?.toString() ==
          widget.conversation['_id']?.toString()) {
        final incoming = await _decryptMessage(Map<String, dynamic>.from(data));
        if (!mounted) return;
        final id = incoming['_id']?.toString();
        if (id == null ||
            !messages
                .any((item) => item is Map && item['_id']?.toString() == id)) {
          setState(() => messages = mergeMessages(messages, [incoming]));
          unawaited(_persistConversationMessages());
          _scrollToLatestMessage();
          // Detect meaningful information in new live messages.
          _detectMemoryForMessage(incoming);
        }
        if (id != null &&
            incoming['senderId']?.toString() != app.user?['id']?.toString()) {
          markReceived(id);
        }
      }
    });
    socket!.on('payment:updated', (data) {
      if (!mounted ||
          data is! Map ||
          data['conversationId']?.toString() !=
              widget.conversation['_id']?.toString()) {
        return;
      }
      final incoming = Map<String, dynamic>.from(data);
      final id = incoming['paymentId']?.toString();
      if (id == null) return;
      setState(() => payments = mergePayment(payments, incoming));
    });
    socket!.on('message:deleted', (data) {
      if (!mounted ||
          data is! Map ||
          data['conversationId']?.toString() !=
              widget.conversation['_id']?.toString()) {
        return;
      }
      final index = messages.indexWhere((m) =>
          m is Map && m['_id']?.toString() == data['messageId']?.toString());
      if (index < 0) return;
      setState(() {
        final copy = Map<String, dynamic>.from(messages[index]);
        copy['deletedAt'] =
            data['deletedAt'] ?? DateTime.now().toIso8601String();
        copy['text'] = '';
        copy['encryptedPayload'] = null;
        copy['encryptionVersion'] = null;
        copy['mediaUrl'] = null;
        copy['messageType'] = 'text';
        copy['reactions'] = [];
        messages[index] = copy;
      });
      unawaited(_persistConversationMessages());
    });
    socket!.on('message:expired', (data) {
      if (!mounted || data is! Map) return;
      final index = messages.indexWhere((m) =>
          m is Map && m['_id']?.toString() == data['messageId']?.toString());
      if (index >= 0) {
        setState(() {
          final copy = Map<String, dynamic>.from(messages[index]);
          copy['expiredAt'] = DateTime.now().toIso8601String();
          copy['text'] = '';
          copy['encryptedPayload'] = null;
          copy['encryptionVersion'] = null;
          copy['mediaUrl'] = null;
          messages[index] = copy;
        });
        unawaited(_persistConversationMessages());
      }
    });
    socket!.on(
        'message:delivered', (data) => updateMessageState(data, 'deliveredTo'));
    socket!.on('message:read', (data) => updateMessageState(data, 'readBy'));
    // Register all listeners before opening the socket so the first incoming
    // event cannot race listener setup on fast connections.
    socket!.connect();
  }

  void updateMessageState(dynamic data, String field) {
    if (!mounted || data is! Map) return;
    final index = messages.indexWhere((item) =>
        item is Map &&
        item['_id']?.toString() == data['messageId']?.toString());
    if (index < 0) return;
    setState(() {
      final updated = Map<String, dynamic>.from(messages[index]);
      final ids = List<dynamic>.from(updated[field] ?? []);
      if (!ids.any((id) => id.toString() == data['userId']?.toString())) {
        ids.add(data['userId']);
      }
      updated[field] = ids;
      messages[index] = updated;
    });
    unawaited(_persistConversationMessages());
  }

  Future<void> markReceived(String id) async {
    try {
      await app.api.call('POST', '/api/messages/$id/delivered', {});
      await app.api.call('POST', '/api/messages/$id/read', {});
    } catch (_) {}
  }

  String _newClientMutationId() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
    final random = math.Random.secure();
    return List.generate(32, (_) => alphabet[random.nextInt(alphabet.length)])
        .join();
  }

  Future<void> _chooseMention() async {
    final participants = eligibleMentionParticipants(
      List<dynamic>.from(widget.conversation['participants'] ?? const []),
      currentUserId: _authenticatedUserId(app.user),
      limit: 50,
    );
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: participants
              .map((person) {
                final identifier = _mentionDisambiguator(
                  person,
                  List<dynamic>.from(
                      widget.conversation['participants'] ?? const []),
                );
                return ListTile(
                    leading: const Icon(Icons.alternate_email),
                    title: Text(person['name']?.toString() ?? 'Chat member'),
                    subtitle: identifier.isEmpty ? null : Text(identifier),
                    onTap: () => Navigator.pop(sheetContext, person),
                  );
              }).toList(),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final id = _conversationParticipantId(selected);
    final name = selected['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) return;
    final spacer = input.text.isEmpty || input.text.endsWith(' ') ? '' : ' ';
    final text = '${input.text}${spacer}@$name ';
    input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    mentionedUserIds.add(id);
    _mentionedNamesById[id] = name;
    _composerChanged(text);
    setState(() {});
  }

  void _composerChanged(String value) {
    _handleTyping(value);
    final staleMentions = mentionedUserIds.where((id) {
      final name = _mentionedNamesById[id];
      return name == null || !value.contains('@$name');
    }).toList();
    for (final id in staleMentions) {
      mentionedUserIds.remove(id);
      _mentionedNamesById.remove(id);
    }
    final cursor = input.selection.extentOffset.clamp(0, value.length);
    final at = value.lastIndexOf('@', math.max(0, cursor - 1));
    if (at < 0 ||
        (at > 0 && !RegExp(r'[\s([{!?,.;:]').hasMatch(value[at - 1]))) {
      if (_mentionSuggestions.isNotEmpty && mounted) {
        setState(() => _mentionSuggestions = []);
      }
      _mentionStart = -1;
      return;
    }
    final query = value.substring(at + 1, cursor);
    if (query.length > 80 || query.contains('\n') || query.contains('\r')) {
      _mentionSuggestions = [];
      _mentionStart = -1;
      return;
    }
    final participants = eligibleMentionParticipants(
      List<dynamic>.from(widget.conversation['participants'] ?? const []),
      currentUserId: _authenticatedUserId(app.user),
      query: query,
    );
    if (!listEquals(_mentionSuggestions, participants) ||
        _mentionStart != at ||
        _mentionCursor != cursor) {
      setState(() {
        _mentionSuggestions = participants;
        _mentionStart = at;
        _mentionCursor = cursor;
        _mentionActiveIndex = 0;
      });
    }
  }

  void _selectMention(Map<String, dynamic> selected) {
    final id = _conversationParticipantId(selected);
    final name = selected['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty || _mentionStart < 0) return;
    final currentId = _authenticatedUserId(app.user);
    final stillMember = eligibleMentionParticipants(
      List<dynamic>.from(widget.conversation['participants'] ?? const []),
      currentUserId: currentId,
      query: name,
      limit: 50,
    ).any((participant) => _conversationParticipantId(participant) == id);
    if (!stillMember) {
      setState(() => _mentionSuggestions = []);
      return;
    }
    final cursor = input.selection.extentOffset.clamp(0, input.text.length);
    final suffix = input.text.substring(cursor);
    final prefix = input.text.substring(0, _mentionStart);
    final insert = '@$name ';
    final text = '$prefix$insert$suffix';
    final nextCursor = prefix.length + insert.length;
    input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: nextCursor),
    );
    mentionedUserIds.add(id);
    _mentionedNamesById[id] = name;
    _mentionSuggestions = [];
    _mentionStart = -1;
    _composerChanged(text);
  }

  Widget _renderMessageText(String text, dynamic mentionIds) {
    if (mentionIds is! List || mentionIds.isEmpty) return Text(text);
    final participants = List<dynamic>.from(
      widget.conversation['participants'] ?? const [],
    ).whereType<Map>();
    final namesById = <String, String>{};
    for (final participant in participants) {
      final id = _conversationParticipantId(participant);
      final name = participant['name']?.toString();
      if (name != null && name.isNotEmpty) namesById[id] = name;
    }
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final rawId in mentionIds) {
      final name = namesById[rawId.toString()];
      if (name == null) continue;
      final token = '@$name';
      final start = text.indexOf(token, cursor);
      if (start < 0) continue;
      if (start > cursor)
        spans.add(TextSpan(text: text.substring(cursor, start)));
      final end = start + token.length;
      spans.add(TextSpan(
        text: token,
        style: TextStyle(
          color: Theme.of(context).colorScheme.tertiary,
          fontWeight: FontWeight.w700,
        ),
      ));
      cursor = end;
    }
    if (cursor == 0) return Text(text);
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(TextSpan(children: spans));
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    if (text.length > 5000) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Messages must be 5,000 characters or fewer.')));
      return;
    }
    _stopTyping();
    final clientMutationId =
        _pendingMutationText == text && _pendingMutationId != null
            ? _pendingMutationId!
            : _newClientMutationId();
    _pendingMutationText = text;
    _pendingMutationId = clientMutationId;
    Map<String, dynamic>? queuedBody;
    setState(() => sending = true);
    try {
      final encrypted = await _encryptTextPayload(text);
      final body = <String, dynamic>{
        ...encrypted,
        'mentions': mentionedUserIds.toList(),
        'clientMutationId': clientMutationId,
        'expiryType': expiry,
        'expiresInSeconds': expiry == 'AFTER_TIME' ? 3600 : null,
        'replyTo': reply,
      };
      queuedBody = body;
      final result = await app.api.call('POST',
          '/api/conversations/${widget.conversation['_id']}/messages', body);
      if (!mounted) return;
      final sent =
          await _decryptMessage(Map<String, dynamic>.from(result['message']));
      final sentId = sent['_id']?.toString();
      setState(() {
        if (sentId == null ||
            !messages.any(
                (item) => item is Map && item['_id']?.toString() == sentId)) {
          messages = mergeMessages(messages, [sent]);
        }
        reply = null;
        mentionedUserIds.clear();
        _mentionedNamesById.clear();
      });
      unawaited(_persistConversationMessages());
      input.clear();
      if (_pendingMutationId == clientMutationId) {
        _pendingMutationId = null;
        _pendingMutationText = null;
      }
      _scrollToLatestMessage();
      _detectMemoryForMessage(sent);
    } catch (error) {
      final shouldQueue = queuedBody != null &&
          (error is! ApiException || error.statusCode >= 500);
      if (shouldQueue) {
        try {
          final conversationId = widget.conversation['_id'].toString();
          final createdAt = DateTime.now().toUtc().toIso8601String();
          await app.api.enqueueOutgoingMessage(conversationId, {
            'clientMutationId': clientMutationId,
            'body': queuedBody,
            'createdAt': createdAt,
          });
          final pendingMessage = <String, dynamic>{
            ...queuedBody,
            '_id': 'local_$clientMutationId',
            'conversationId': conversationId,
            'senderId': app.user?['id']?.toString(),
            'createdAt': createdAt,
            'pending': true,
          };
          final decryptedPending = await _decryptMessage(pendingMessage);
          if (mounted) {
            setState(() {
              messages = mergeMessages(messages, [decryptedPending]);
              reply = null;
            });
            input.clear();
            _pendingMutationId = null;
            _pendingMutationText = null;
            unawaited(_persistConversationMessages());
            _scrollToLatestMessage();
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'No connection. Your encrypted message is saved securely and will send when you reconnect.')));
            if (socket?.connected == true) unawaited(_flushOutgoingMessages());
          }
        } catch (queueError) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(
                    'Message could not be sent or safely queued: $queueError')));
          }
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> requestMpesa() async {
    // This menu is for requesting money from the contact only.
    // Person-to-person "Send Money" is intentionally not offered here.
    final mode = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('M-Pesa'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: const Text('Lipa na Till'),
              subtitle:
                  const Text('Pay a shop using its Buy Goods Till number'),
              onTap: () => Navigator.pop(dialog, 'till'),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Lipa na Paybill'),
              subtitle: const Text(
                  'Pay a business using its Paybill and account number'),
              onTap: () => Navigator.pop(dialog, 'paybill'),
            ),
            ListTile(
              leading: const Icon(Icons.person_pin_circle_outlined),
              title: const Text('Lipa to this contact'),
              subtitle: const Text(
                  'Send an STK prompt using this contact’s merchant checkout'),
              onTap: () => Navigator.pop(dialog, 'contact'),
            ),
            ListTile(
              leading: const Icon(Icons.call_received),
              title: const Text('Receive Money'),
              subtitle: const Text('Request money from this contact'),
              onTap: () => Navigator.pop(dialog, 'receive'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!mounted || mode == null) return;

    // A personal contact is not a merchant checkout. Standard Daraja STK Push
    // only charges a payer against an authorized Till/Paybill shortcode; it cannot
    // transfer funds directly to an ordinary personal phone number. For contacts,
    // use the recipient's registered phone and hand off to the sender's M-Pesa USSD
    // menu instead of blocking on a merchant payment-profile configuration.
    if (mode == 'contact') {
      final me =
          app.user?['_id']?.toString() ?? app.user?['id']?.toString() ?? '';
      final participants =
          List<dynamic>.from(widget.conversation['participants'] ?? []);
      final other = participants.whereType<Map>().firstWhere((p) {
        final nested = p['user'] is Map ? p['user'] as Map : null;
        final id = (p['_id'] ??
                p['id'] ??
                p['userId'] ??
                nested?['_id'] ??
                nested?['id'])
            ?.toString();
        return id != null && id.isNotEmpty && id != me;
      }, orElse: () => <String, dynamic>{});
      final nested = other['user'] is Map ? other['user'] as Map : null;
      var recipientRaw = (other['mpesaPhone'] ??
              other['phone'] ??
              nested?['mpesaPhone'] ??
              nested?['phone'] ??
              '')
          .toString()
          .trim();
      final recipientId = (other['_id'] ??
                  other['id'] ??
                  other['userId'] ??
                  nested?['_id'] ??
                  nested?['id'])
              ?.toString() ??
          '';
      // Contacts endpoint exposes the registered phone for saved contacts if the
      // conversation projection did not include it.
      if (recipientRaw.isEmpty && recipientId.isNotEmpty) {
        try {
          final directory = await app.api.call('GET', '/api/contacts');
          final entries = List<dynamic>.from(directory['contacts'] ?? []);
          final contact = entries.whereType<Map>().firstWhere(
                (entry) => (entry['userId'] ?? '').toString() == recipientId,
                orElse: () => <String, dynamic>{},
              );
          recipientRaw = (contact['phone'] ?? '').toString().trim();
        } catch (_) {
          // Show an actionable message below; never substitute the sender's phone.
        }
      }
      final recipientPhone = normalizeKenyanPhone(recipientRaw);
      if (recipientPhone == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
              'This contact’s registered phone number is unavailable. Refresh the conversation or save the contact, then try again.',
            ),
            duration: Duration(seconds: 5),
          ));
        }
        return;
      }

      final amount = TextEditingController();
      final senderPhone = TextEditingController(
        text: app.user?['mpesaPhone']?.toString() ??
            app.user?['phone']?.toString() ??
            '',
      );
      final formKey = GlobalKey<FormState>();
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Lipa to this contact'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: recipientPhone,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Recipient’s registered M-Pesa number',
                      helperText: 'Loaded from this contact’s Chatify account.',
                    ),
                  ),
                  TextFormField(
                    controller: amount,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Amount (KSh)'),
                    validator: (value) {
                      final n = int.tryParse((value ?? '').trim());
                      return n == null || n < 1 || n > 150000
                          ? 'Enter KSh 1–150,000'
                          : null;
                    },
                  ),
                  TextFormField(
                    controller: senderPhone,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Your registered M-Pesa number',
                      helperText:
                          'Loaded from account creation. The M-Pesa menu uses the active SIM on this device.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Personal Send Money transfers go to the registered contact number. Safaricom does not support a direct-to-person STK prompt using a personal phone number; you will confirm the recipient and amount in M-Pesa. No payment is recorded as successful by Chatify.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(dialog, true);
                }
              },
              child: const Text('Open M-Pesa'),
            ),
          ],
        ),
      );
      if (accepted == true && context.mounted) {
        final normalizedSender = normalizeKenyanPhone(senderPhone.text);
        final amountValue = int.parse(amount.text.trim());
        await Clipboard.setData(ClipboardData(text: recipientPhone));
        try {
          final opened = await launchUrl(
            Uri(scheme: 'tel', path: '*334#'),
            mode: LaunchMode.externalApplication,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(opened
                  ? 'M-Pesa menu opened. Recipient $recipientPhone copied. Choose Send Money, enter KSh $amountValue, and confirm the recipient before entering your PIN.'
                  : 'Recipient $recipientPhone copied. Open M-Pesa on ${normalizedSender ?? senderPhone.text.trim()}, choose Send Money, and enter KSh $amountValue.'),
              duration: const Duration(seconds: 7),
            ));
          }
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                'Recipient $recipientPhone copied. Open M-Pesa, choose Send Money, and enter KSh $amountValue.',
              ),
              duration: const Duration(seconds: 7),
            ));
          }
        }
      }
      amount.dispose();
      senderPhone.dispose();
      return;
    }

    // Till and Paybill require merchant-authorized STK Push credentials and a
    // matching configured shortcode. Personal contacts do not use this path.
    if (mode == 'till' || mode == 'paybill') {
      final isTill = mode == 'till';
      final isPaybill = mode == 'paybill';
      final isContact = mode == 'contact';
      final storefrontSlug =
          widget.conversation['businessStorefrontSlug']?.toString();
      String sellerId = '';
      Map<String, dynamic>? merchantPaymentProfile;
      try {
        Map<String, dynamic>? profileResponse;
        if (storefrontSlug != null && storefrontSlug.isNotEmpty) {
          final result = await app.api.call(
            'GET',
            '/api/storefront/${Uri.encodeComponent(storefrontSlug)}',
          );
          final store = result['storefront'];
          if (store is Map && store['paymentProfile'] is Map) {
            profileResponse =
                Map<String, dynamic>.from(store['paymentProfile'] as Map);
          }
        } else {
          final participants =
              List<dynamic>.from(widget.conversation['participants'] ?? []);
          final currentIds = <String>{
            app.user?['_id']?.toString() ?? '',
            app.user?['id']?.toString() ?? '',
          }..remove('');
          for (final raw in participants) {
            if (raw is! Map) continue;
            final nested = raw['user'] is Map ? raw['user'] as Map : null;
            final id =
                (raw['_id'] ?? raw['id'] ?? raw['userId'])?.toString() ?? '';
            final candidateId = id.isNotEmpty
                ? id
                : (nested?['_id'] ?? nested?['id'])?.toString() ?? '';
            if (candidateId.isNotEmpty && !currentIds.contains(candidateId)) {
              sellerId = candidateId;
              break;
            }
          }
          if (sellerId.isNotEmpty) {
            final result = await app.api.call(
              'GET',
              '/api/storefront/by-seller/${Uri.encodeComponent(sellerId)}/payment-profile',
            );
            if (result['paymentProfile'] is Map) {
              profileResponse =
                  Map<String, dynamic>.from(result['paymentProfile'] as Map);
            }
          }
        }
        merchantPaymentProfile = profileResponse;
      } catch (_) {
        // Keep the failure actionable below; do not silently redirect payment to another shortcode.
      }

      final merchantMethod = merchantPaymentProfile?['method']?.toString();
      if (merchantPaymentProfile == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isContact
                ? 'No Till or Paybill is configured for this contact’s business. No STK prompt was sent. A saved phone number alone cannot receive an STK checkout; ask the contact to configure a merchant Till/Paybill or use the app’s supported manual Send Money flow.'
                : 'This business has no configured M-Pesa Till or Paybill. No STK prompt was sent. Ask the merchant to configure a payment method before trying again.'),
            duration: const Duration(seconds: 7),
          ));
        }
        return;
      }
      if ((isTill && merchantMethod != 'mpesa_till') ||
          (isPaybill && merchantMethod != 'mpesa_paybill')) {
        final configuredMethod = merchantMethod == 'mpesa_till'
            ? 'Till only'
            : merchantMethod == 'mpesa_paybill'
                ? 'Paybill only'
                : 'no supported checkout method';
        final nextStep = merchantMethod == 'mpesa_till'
            ? 'Choose Lipa na Till.'
            : merchantMethod == 'mpesa_paybill'
                ? 'Choose Lipa na Paybill.'
                : 'Ask the merchant to configure a Till or Paybill.';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('This merchant has $configuredMethod configured. $nextStep No STK prompt was sent.'),
            duration: const Duration(seconds: 6),
          ));
        }
        return;
      }

      final merchantNumber = TextEditingController(
        text: isTill
            ? (merchantPaymentProfile['tillNumber']?.toString() ?? '')
            : (merchantPaymentProfile['paybillNumber']?.toString() ?? ''),
      );
      final accountNumber = TextEditingController(
        text: merchantPaymentProfile['accountNumber']?.toString() ?? '',
      );
      final paymentAmount = TextEditingController();
      final payerPhone = TextEditingController(
        text: app.user?['mpesaPhone']?.toString() ??
            app.user?['phone']?.toString() ??
            '',
      );
      final description = TextEditingController(
        text: isContact
            ? 'Payment to contact'
            : (isTill ? 'Buy Goods payment' : 'Paybill payment'),
      );
      final formKey = GlobalKey<FormState>();
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(isContact
              ? 'Lipa to this contact'
              : (isTill ? 'Lipa na Till' : 'Lipa na Paybill')),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isContact)
                    TextFormField(
                      controller: merchantNumber,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: isTill
                            ? 'Buy Goods Till number'
                            : 'Paybill business number',
                        helperText:
                            'Prefilled from this business. STK requires this number to match the merchant-authorized shortcode.',
                      ),
                      validator: (value) {
                        final number = (value ?? '').trim();
                        return number.length >= 5 &&
                                number.length <= 10 &&
                                int.tryParse(number) != null
                            ? null
                            : 'Enter a valid 5–10 digit number';
                      },
                    ),
                  if (isPaybill)
                    TextFormField(
                      controller: accountNumber,
                      decoration: const InputDecoration(
                        labelText: 'Account/reference (optional)',
                        helperText:
                            'The merchant checkout generates a payment reference for reconciliation.',
                      ),
                    ),
                  TextFormField(
                    controller: paymentAmount,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Amount (KSh)'),
                    validator: (value) {
                      final amountValue = int.tryParse((value ?? '').trim());
                      return amountValue == null ||
                              amountValue < 1 ||
                              amountValue > 150000
                          ? 'Enter KSh 1–150,000'
                          : null;
                    },
                  ),
                  TextFormField(
                    controller: payerPhone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Your M-Pesa phone number',
                      helperText: 'The STK prompt will be sent to this number.',
                    ),
                    validator: (value) =>
                        normalizeKenyanPhone(value ?? '') == null
                            ? 'Enter a valid Kenyan M-Pesa number'
                            : null,
                  ),
                  TextFormField(
                    controller: description,
                    maxLength: 80,
                    decoration:
                        const InputDecoration(labelText: 'Payment description'),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Enter a payment description'
                        : null,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The STK prompt is sent to your saved default M-Pesa number (you can edit it above). The merchant receives payment through their configured Till/Paybill, not their personal phone number. A contact phone number alone cannot be used as an STK merchant destination. Check the amount and recipient before entering your PIN; a prompt is not proof of payment.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(dialog, true);
                }
              },
              child: const Text('Review STK payment'),
            ),
          ],
        ),
      );

      if (confirmed == true && mounted) {
        final baseAmount = int.parse(paymentAmount.text.trim());
        final acceptPayment = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('Confirm M-Pesa payment'),
            content: Text(
              'Merchant: ${isContact ? 'this contact' : (isTill ? 'Till' : 'Paybill')}\n'
              '${isContact ? '' : 'Number: ${merchantNumber.text.trim()}\n'}'
              'Total M-Pesa charge: KSh $baseAmount\n\n'
              'Chatify does not add a transaction commission. Safaricom charges, if applicable, are separate. Continue?',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Send STK Push')),
            ],
          ),
        );
        if (acceptPayment == true && mounted) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.showSnackBar(const SnackBar(
            content: Text('Requesting STK prompt…'),
            duration: Duration(seconds: 2),
          ));
          try {
            final endpoint = storefrontSlug != null && storefrontSlug.isNotEmpty
                ? '/api/storefront/${Uri.encodeComponent(storefrontSlug)}/stk-push'
                : '/api/storefront/by-seller/${Uri.encodeComponent(sellerId)}/stk-push';
            final result = await app.api.call('POST', endpoint, {
              'phone': payerPhone.text.trim(),
              'amount': baseAmount,
              'description': description.text.trim(),
              if (!isContact) 'merchantNumber': merchantNumber.text.trim(),
            });
            if (mounted) {
              final notice = result['notice']?.toString() ??
                  'STK request accepted. The payment remains pending until Safaricom confirms it.';
              messenger.showSnackBar(SnackBar(
                content: Text(
                    '$notice\nAmount: KSh ${result['totalAmount'] ?? baseAmount}'),
                duration: const Duration(seconds: 6),
              ));
            }
          } catch (error) {
            if (mounted) {
              messenger.showSnackBar(SnackBar(
                content: Text(error.toString()),
                duration: const Duration(seconds: 6),
              ));
            }
          }
        }
      }
      merchantNumber.dispose();
      accountNumber.dispose();
      paymentAmount.dispose();
      payerPhone.dispose();
      description.dispose();
      return;
    }

    final me =
        app.user?['_id']?.toString() ?? app.user?['id']?.toString() ?? '';
    final participants =
        List<dynamic>.from(widget.conversation['participants'] ?? []);
    final other = participants.whereType<Map>().firstWhere(
        (p) => p['_id']?.toString() != me,
        orElse: () => <String, dynamic>{});
    final payerId = other['_id']?.toString();
    if (payerId == null || payerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Conversation member details are unavailable.')));
      return;
    }
    final amount = TextEditingController();
    final payerPhone =
        TextEditingController(text: other['phone']?.toString() ?? '');
    final recipientPhone =
        TextEditingController(text: app.user?['phone']?.toString() ?? '');
    final description = TextEditingController();
    final form = GlobalKey<FormState>();
    final submit = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Request M-Pesa'),
              content: Form(
                  key: form,
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextFormField(
                          controller: amount,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Amount (KSh)'),
                          validator: (v) {
                            final value = int.tryParse(v ?? '');
                            return value == null || value < 1 || value > 150000
                                ? 'Enter KSh 1–150,000'
                                : null;
                          }),
                      TextFormField(
                          controller: payerPhone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                              labelText: 'Sender / Payer M-Pesa Number',
                              hintText: '0712345678 or 254712345678',
                              helperText:
                                  'Defaults to the other participant’s registered number. You can edit it for this request.'),
                          validator: (v) =>
                              normalizeKenyanPhone(v ?? '') == null
                                  ? 'Enter a valid Kenyan M-Pesa number'
                                  : null),
                      TextFormField(
                          controller: recipientPhone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                              labelText: 'Recipient M-Pesa Number',
                              hintText: '0712345678 or 254712345678',
                              helperText:
                                  'Defaults to your registered number. Editing affects this request only.'),
                          validator: (v) =>
                              normalizeKenyanPhone(v ?? '') == null
                                  ? 'Enter a valid Kenyan M-Pesa number'
                                  : null),
                      TextFormField(
                          controller: description,
                          maxLength: 80,
                          decoration:
                              const InputDecoration(labelText: 'Description'),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Enter a description'
                              : null),
                      const SizedBox(height: 8),
                      const Text(
                        'The selected payer number is the default for the STK prompt and can be changed before payment. STK Push payments settle to the configured business shortcode; this does not send money directly to a personal number.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ]),
                  )),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        Navigator.pop(dialog, true);
                      }
                    },
                    child: const Text('Request'))
              ],
            ));
    if (submit == true && mounted) {
      try {
        final response = await app.api.call('POST', '/api/payments', {
          'payerUserId': payerId,
          'conversationId': widget.conversation['_id'],
          'amount': int.parse(amount.text),
          'recipientPhone': normalizeKenyanPhone(recipientPhone.text)!,
          'payerPhone': normalizeKenyanPhone(payerPhone.text)!,
          'description': description.text.trim()
        });
        final payment = Map<String, dynamic>.from(response['payment']);
        if (mounted) setState(() => payments = mergePayment(payments, payment));
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }
    amount.dispose();
    payerPhone.dispose();
    recipientPhone.dispose();
    description.dispose();
  }

  Future<void> payPayment(Map<String, dynamic> payment) async {
    final payerPhone = TextEditingController(
        text: payment['payerPhone']?.toString() ??
            payment['phone']?.toString() ??
            app.user?['phone']?.toString() ??
            '');
    final form = GlobalKey<FormState>();
    final baseAmount = (payment['baseAmount'] as num?)?.toInt() ??
        (payment['amount'] as num?)?.toInt() ??
        0;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Review M-Pesa payment'),
              content: Form(
                key: form,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                      'Amount to pay: KSh $baseAmount\nNo Chatify transaction commission is added.',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 10),
                  const Text(
                      'This STK payment goes to the configured business shortcode, not directly to a personal recipient. Safaricom charges, if applicable, are separate.',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: payerPhone,
                    autofocus: true,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Your M-Pesa phone number',
                      hintText: '0712345678 or 254712345678',
                      helperText: 'The STK prompt will be sent to this number.',
                    ),
                    validator: (v) => normalizeKenyanPhone(v ?? '') == null
                        ? 'Enter a valid Kenyan M-Pesa number'
                        : null,
                  ),
                ]),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        Navigator.pop(dialog, true);
                      }
                    },
                    child: const Text('Continue')),
              ],
            ));
    if (accepted != true || !mounted) {
      payerPhone.dispose();
      return;
    }
    try {
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/initiate', {
        'phone': normalizeKenyanPhone(payerPhone.text)!,
      });
      final updated = Map<String, dynamic>.from(result['payment']);
      if (mounted) {
        final i = payments.indexWhere(
            (p) => p is Map && p['paymentId'] == updated['paymentId']);
        setState(() {
          if (i >= 0) payments[i] = updated;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['mock'] == true
                ? 'Local demo only: no Safaricom prompt was sent. Configure live Daraja on the API service to send real prompts.'
                : 'Check ${normalizeKenyanPhone(payerPhone.text)} for the M-Pesa prompt. Enter your PIN only in the Safaricom prompt.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      payerPhone.dispose();
    }
  }

  Future<void> refreshPayment(Map<String, dynamic> payment) async {
    try {
      final result =
          await app.api.paymentStatus(payment['paymentId'].toString());
      final updated = Map<String, dynamic>.from(result['payment']);
      final i = payments.indexWhere(
          (p) => p is Map && p['paymentId'] == updated['paymentId']);
      if (mounted && i >= 0) setState(() => payments[i] = updated);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> retryPayment(Map<String, dynamic> payment) async {
    try {
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/retry', {});
      if (mounted) {
        setState(() => payments = mergePayment(
            payments, Map<String, dynamic>.from(result['payment'])));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> closePayment(Map<String, dynamic> payment) async {
    try {
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/close', {});
      if (mounted) {
        setState(() => payments = mergePayment(
            payments, Map<String, dynamic>.from(result['payment'])));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Closed for you. The other person can still see this request.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> reopenPayment(Map<String, dynamic> payment) async {
    try {
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/reopen', {});
      if (mounted) {
        setState(() {
          payments = mergePayment(
              payments, Map<String, dynamic>.from(result['payment']));
          showClosedPayments = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Request reopened in this conversation.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> rejectPayment(Map<String, dynamic> payment) async {
    final isPayer =
        payment['payerId']?.toString() == app.user?['id']?.toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
            isPayer ? 'Reject M-Pesa request?' : 'Withdraw M-Pesa request?'),
        content: const Text(
          'This cancels the request for both people and is only available before an M-Pesa prompt has started. If a prompt was already sent, close it for yourself and cancel it on your phone if it is still open.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Keep request')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(isPayer ? 'Reject request' : 'Withdraw request')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await app.api
          .call('POST', '/api/payments/${payment['paymentId']}/reject', {});
      if (mounted) {
        setState(() => payments = mergePayment(
            payments, Map<String, dynamic>.from(result['payment'])));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isPayer
                ? 'Payment request rejected.'
                : 'Payment request withdrawn.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> searchMessages(String query) async {
    try {
      final result = await app.api.call('GET',
          '/api/conversations/${widget.conversation['_id']}/messages?q=${Uri.encodeQueryComponent(query)}');
      if (mounted) {
        setState(() => messages =
            mergeMessages([], List<dynamic>.from(result['messages'] ?? [])));
        _scrollToLatestMessage();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> sendImageLink() async {
    // Attachments are not covered by the current text-message E2EE protocol.
    // Warn explicitly rather than implying that images have the same protection.
    final acknowledgeRisk = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Image privacy notice'),
        content: const Text(
            'Images and shared image URLs are not end-to-end encrypted yet. The service may be able to access uploaded images or URLs. Do not send sensitive images until attachment encryption is available.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (!mounted || acknowledgeRisk != true) return;
    final source = await showModalBottomSheet<String>(
        context: context,
        builder: (sheet) => SafeArea(
              child: Wrap(children: [
                ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: const Text('Choose from device'),
                    onTap: () => Navigator.pop(sheet, 'device')),
                ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('Share secure image URL'),
                    onTap: () => Navigator.pop(sheet, 'url')),
              ]),
            ));
    if (!mounted || source == null) return;
    try {
      Map<String, dynamic> uploadRequest;
      if (source == 'url') {
        final url = TextEditingController();
        final accepted = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
                    title: const Text('Share an image'),
                    content: TextField(
                        controller: url,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                            labelText: 'Secure image URL',
                            hintText: 'https://…')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: const Text('Share'))
                    ]));
        if (accepted != true) {
          url.dispose();
          return;
        }
        uploadRequest = {'url': url.text.trim()};
        url.dispose();
      } else {
        final file = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (file == null) return;
        final bytes = await file.readAsBytes();
        if (bytes.length > 10 * 1024 * 1024) {
          throw Exception('Choose an image no larger than 10 MB');
        }
        final name = file.name.toLowerCase();
        final mimeType = name.endsWith('.png')
            ? 'image/png'
            : (name.endsWith('.webp') ? 'image/webp' : 'image/jpeg');
        uploadRequest = {'data': base64Encode(bytes), 'mimeType': mimeType};
      }
      final uploaded = await app.api.call('POST', '/api/media', uploadRequest);
      final sent = await app.api.call(
          'POST', '/api/conversations/${widget.conversation['_id']}/messages', {
        'messageType': 'image',
        'mediaUrl': uploaded['mediaUrl'],
        'expiryType': expiry
      });
      if (mounted) {
        final message = Map<String, dynamic>.from(sent['message']);
        final id = message['_id']?.toString();
        setState(() {
          if (id == null ||
              !messages.any(
                  (item) => item is Map && item['_id']?.toString() == id)) {
            messages.add(message);
          }
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> groupOptions() async {
    final members =
        List<dynamic>.from(widget.conversation['participants'] ?? []);
    final isAdmin = List<dynamic>.from(widget.conversation['admins'] ?? [])
        .any((id) => id.toString() == app.user?['id']?.toString());
    await showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => SafeArea(
                child: Wrap(children: [
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                      widget.conversation['description']
                                  ?.toString()
                                  .isNotEmpty ==
                              true
                          ? widget.conversation['description'].toString()
                          : '${members.length} members',
                      style: Theme.of(context).textTheme.titleMedium)),
              if (isAdmin)
                ListTile(
                    leading: const Icon(Icons.person_add_alt_1),
                    title: const Text('Add member'),
                    onTap: () async {
                      final email = TextEditingController();
                      try {
                        final chosen = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                                    title: const Text('Add group member'),
                                    content: TextField(
                                        controller: email,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        decoration: const InputDecoration(
                                            labelText: 'Member email')),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, false),
                                          child: const Text('Cancel')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(d, true),
                                          child: const Text('Add'))
                                    ]));
                        if (chosen != true) return;
                        final found = await app.api.call('GET',
                            '/api/users/search?q=${Uri.encodeQueryComponent(email.text.trim())}');
                        final users = List<dynamic>.from(found['users'] ?? []);
                        final emailValue = email.text.trim().toLowerCase();
                        final matches = users.where((user) =>
                            user is Map &&
                            user['email']?.toString().toLowerCase() ==
                                emailValue);
                        if (matches.isEmpty) {
                          throw Exception('No matching account found');
                        }
                        await app.api.call(
                            'POST',
                            '/api/conversations/${widget.conversation['_id']}/members',
                            {'userId': matches.first['_id']});
                        final d = await app.api.call('GET',
                            '/api/conversations/${widget.conversation['_id']}');
                        if (mounted) {
                          setState(() => widget.conversation.addAll(
                              Map<String, dynamic>.from(d['conversation'])));
                        }
                        if (sheet.mounted) Navigator.pop(sheet);
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())));
                        }
                      } finally {
                        email.dispose();
                      }
                    }),
              ...members.map((raw) {
                final person = Map<String, dynamic>.from(raw);
                final id = (person['_id'] ?? person['id']).toString();
                final admin =
                    List<dynamic>.from(widget.conversation['admins'] ?? [])
                        .any((item) => item.toString() == id);
                return ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(
                        '${person['name'] ?? 'Member'}${admin ? ' · admin' : ''}'),
                    subtitle: Text(person['email']?.toString() ?? ''),
                    trailing: isAdmin && id != app.user?['id']?.toString()
                        ? PopupMenuButton<String>(
                            onSelected: (action) async {
                              try {
                                if (action == 'remove') {
                                  await app.api.call('DELETE',
                                      '/api/conversations/${widget.conversation['_id']}/members/$id');
                                } else if (admin) {
                                  await app.api.call('DELETE',
                                      '/api/conversations/${widget.conversation['_id']}/admins/$id');
                                } else {
                                  await app.api.call(
                                      'POST',
                                      '/api/conversations/${widget.conversation['_id']}/admins/$id',
                                      {});
                                }
                                final d = await app.api.call('GET',
                                    '/api/conversations/${widget.conversation['_id']}');
                                if (mounted) {
                                  setState(() => widget.conversation.addAll(
                                      Map<String, dynamic>.from(
                                          d['conversation'])));
                                }
                              } catch (error) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(error.toString())));
                                }
                              }
                            },
                            itemBuilder: (_) => [
                                  PopupMenuItem(
                                      value: admin ? 'demote' : 'promote',
                                      child: Text(admin
                                          ? 'Remove admin'
                                          : 'Make admin')),
                                  const PopupMenuItem(
                                      value: 'remove',
                                      child: Text('Remove member'))
                                ])
                        : null);
              }),
              if (!isAdmin ||
                  List<dynamic>.from(widget.conversation['admins'] ?? [])
                          .length >
                      1)
                ListTile(
                    leading: const Icon(Icons.exit_to_app),
                    title: const Text('Leave group'),
                    onTap: () async {
                      try {
                        await app.api.call(
                            'POST',
                            '/api/conversations/${widget.conversation['_id']}/leave',
                            {});
                        if (mounted && sheet.mounted) {
                          Navigator.pop(sheet);
                          Navigator.pop(context);
                        }
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())));
                        }
                      }
                    })
            ])));
  }

  Future<void> downloadImage(String url) async {
    if (url.trim().isEmpty) return;
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      Uint8List? bytes;
      var mime = 'image/jpeg';

      if (url.startsWith('data:image/')) {
        final comma = url.indexOf(',');
        if (comma < 0) throw const FormatException('Invalid image data.');
        mime = url.substring(5, comma).split(';').first.toLowerCase();
        bytes = Uint8List.fromList(base64Decode(url.substring(comma + 1)));
      } else {
        final uri = Uri.parse(url);
        if (uri.scheme != 'https' && uri.scheme != 'http') {
          throw Exception('This image URL cannot be downloaded safely.');
        }

        final path = uri.path.toLowerCase();
        final guessedExtension = path.endsWith('.png')
            ? 'png'
            : path.endsWith('.webp')
                ? 'webp'
                : path.endsWith('.gif')
                    ? 'gif'
                    : path.endsWith('.heic')
                        ? 'heic'
                        : 'jpg';

        // Browsers ignore the download attribute for many cross-origin URLs.
        // Cloudinary supports fl_attachment, which makes the original asset
        // respond with Content-Disposition: attachment so the browser saves it.
        if (kIsWeb) {
          var downloadUri = uri;
          if (uri.host.toLowerCase() == 'res.cloudinary.com' &&
              uri.path.contains('/image/upload/') &&
              !uri.path.contains('/image/upload/fl_attachment/')) {
            downloadUri = uri.replace(
              path: uri.path.replaceFirst(
                '/image/upload/',
                '/image/upload/fl_attachment/',
              ),
            );
          }

          await FileSaver.instance.downloadLink(
            link: LinkDetails(link: downloadUri.toString()),
            name: 'chatify_image_$timestamp.$guessedExtension',
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Image download requested. Check your browser downloads.'),
            ));
          }
          return;
        }

        final response = await http.get(uri).timeout(
              const Duration(seconds: 45),
            );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception(
              'Image download failed (HTTP ${response.statusCode}).');
        }
        bytes = response.bodyBytes;
        mime = (response.headers['content-type'] ?? '')
            .split(';')
            .first
            .toLowerCase();
        if (!mime.startsWith('image/')) {
          mime = guessedExtension == 'png'
              ? 'image/png'
              : guessedExtension == 'webp'
                  ? 'image/webp'
                  : guessedExtension == 'gif'
                      ? 'image/gif'
                      : 'image/jpeg';
        }
      }

      final extension = mime.contains('png')
          ? 'png'
          : mime.contains('webp')
              ? 'webp'
              : mime.contains('gif')
                  ? 'gif'
                  : mime.contains('heic')
                      ? 'heic'
                      : mime.contains('svg')
                          ? 'svg'
                          : 'jpg';
      final saverMime = extension == 'png'
          ? MimeType.png
          : extension == 'webp'
              ? MimeType.webp
              : extension == 'gif'
                  ? MimeType.gif
                  : extension == 'heic'
                      ? MimeType.heic
                      : extension == 'svg'
                          ? MimeType.svg
                          : MimeType.jpeg;

      if (bytes.isEmpty) {
        throw Exception('The image file is empty.');
      }

      // Save the original response bytes directly. Never resize, recompress,
      // decode or re-encode the image during download.
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS) &&
          extension != 'svg') {
        await FileSaver.instance.saveToGallery(
          name: 'chatify_image_$timestamp',
          bytes: bytes,
          fileExtension: extension,
          mimeType: saverMime,
        );
      } else {
        await FileSaver.instance.saveFile(
          name: 'chatify_image_$timestamp',
          bytes: bytes,
          fileExtension: extension,
          mimeType: saverMime,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Image saved in its original quality.'),
        ));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not download image: $error')),
        );
      }
    }
  }

  Widget renderImage(String url) {
    Widget image;
    if (url.startsWith('data:image/')) {
      try {
        image = Image.memory(
          base64Decode(url.substring(url.indexOf(',') + 1)),
          width: 220,
          fit: BoxFit.contain,
        );
      } catch (_) {
        return const Text('Image unavailable');
      }
    } else {
      image = OfflineCachedImage(
        url,
        width: 220,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Text('Image unavailable'),
      );
    }

    return Stack(
      alignment: Alignment.topRight,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: image,
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: Material(
            color: const Color(0xE6172033),
            borderRadius: BorderRadius.circular(24),
            child: IconButton(
              tooltip: 'Download original image',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 38, height: 38),
              padding: EdgeInsets.zero,
              color: Colors.white,
              icon: const Icon(Icons.download_rounded, size: 20),
              onPressed: () => downloadImage(url),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    app.removeListener(_syncPresence);
    _typingTimer?.cancel();
    _remoteTypingTimer?.cancel();
    if (_isTyping) socket?.emit('typing:stop', widget.conversation['_id']);
    socket?.dispose();
    _messagesScrollController.dispose();
    input.dispose();
    searchInput.dispose();
    super.dispose();
  }

  // Scan newest-first and stop when a meaningful suggestion is found.
  Future<void> _scanRecentMessagesForMemory(
      List<dynamic> sourceMessages) async {
    final recent = sourceMessages.whereType<Map>().toList().reversed.take(12);
    for (final raw in recent) {
      if (await _detectMemoryForMessage(Map<String, dynamic>.from(raw))) return;
    }
  }

  String? _memoryPersonNameForMessage(Map<String, dynamic> message) {
    final senderId = _participantId(message['senderId']);
    final currentId = app.user?['id']?.toString() ?? '';
    if (senderId.isEmpty || senderId == currentId) return null;
    for (final participant
        in List<dynamic>.from(widget.conversation['participants'] ?? [])) {
      if (participant is Map && _participantId(participant) == senderId) {
        final name = participant['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) return name;
      }
    }
    return null;
  }

  Future<bool> _detectMemoryForMessage(Map<String, dynamic> message) async {
    // Encrypted text is decrypted on this device first; candidate extraction stays local.
    if (message['messageType'] != 'text' ||
        message['deletedAt'] != null ||
        message['expiredAt'] != null ||
        message['text'] is! String) {
      return false;
    }
    final text = (message['text'] as String).trim();
    final id = message['_id']?.toString();
    if (text.isEmpty ||
        id == null ||
        id.isEmpty ||
        _checkedMemoryMessageIds.contains(id) ||
        _dismissedMemoryMessageIds.contains(id) ||
        _savedMemoryMessageIds.contains(id)) {
      return false;
    }
    _checkedMemoryMessageIds.add(id);
    try {
      // Load the user's saved cards before suggesting anything from history.
      // This survives app restarts and prevents an already-saved source message
      // from repeatedly appearing as a new suggestion on another device.
      if (!_savedMemoryMessageIdsLoaded) {
        final saved = List<dynamic>.from(
            (await app.api.call('GET', '/api/memories'))['memories'] ?? []);
        for (final item in saved) {
          if (item is Map && item['sourceMessageId'] != null) {
            _savedMemoryMessageIds.add(item['sourceMessageId'].toString());
          }
        }
        _savedMemoryMessageIdsLoaded = true;
      }
      if (_savedMemoryMessageIds.contains(id)) return false;
      // Do not upload plaintext from an end-to-end encrypted message to the API.
      // Attribution is attached for display here and re-derived by the server when saved.
      final personName = _memoryPersonNameForMessage(message);
      final candidates = extractMemoryCandidatesLocally(text)
          .map((item) => <String, dynamic>{
                ...item,
                if (personName != null) 'personName': personName,
              })
          .toList();
      if (!mounted || candidates.isEmpty) return false;
      // Persist the one-time suggestion claim across app restarts and devices. A deleted card keeps its tombstone, so the source can never be suggested again.
      final seen = await app.api.call('POST', '/api/memories/seen', {
        'conversationId': widget.conversation['_id'],
        'sourceMessageId': id,
      });
      if (seen['alreadySeen'] == true || !mounted) return false;
      // The user must approve the suggestion; detection itself never saves data.
      setState(() {
        memorySuggestions = candidates;
        memorySuggestionSourceId = id;
      });
      return true;
    } catch (_) {
      // Memory detection is optional and must never interrupt normal messaging.
      return false;
    }
  }

  void _dismissMemorySuggestions() {
    final id = memorySuggestionSourceId;
    if (id != null) _dismissedMemoryMessageIds.add(id);
    if (!mounted) return;
    setState(() {
      memorySuggestions = [];
      memorySuggestionSourceId = null;
    });
  }

  Future<void> _saveMemorySuggestion(Map<String, dynamic> candidate) async {
    final sourceId = memorySuggestionSourceId;
    if (sourceId == null || savingMemorySuggestion) return;
    setState(() => savingMemorySuggestion = true);
    try {
      final savedResult = await app.api.call('POST', '/api/memories', {
        ...candidate,
        'conversationId': widget.conversation['_id'],
        'sourceMessageId': sourceId,
      });
      if (!mounted) return;
      _savedMemoryMessageIds.add(sourceId);
      setState(() {
        memorySuggestions.remove(candidate);
        if (memorySuggestions.isEmpty) memorySuggestionSourceId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(savedResult['alreadySaved'] == true
              ? 'This Memory Card was already saved.'
              : 'Memory saved to your Memory Cards.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save memory: $error')));
      }
    } finally {
      if (mounted) setState(() => savingMemorySuggestion = false);
    }
  }

  Future<void> extractMemory() async {
    try {
      final eligibleSources = messages
          .whereType<Map>()
          .where((item) =>
              item['expiredAt'] == null &&
              item['messageType'] == 'text' &&
              item['text'] is String &&
              (item['text'] as String).trim().isNotEmpty)
          .toList();
      final source = input.text.trim().isNotEmpty || eligibleSources.isEmpty
          ? null
          : eligibleSources.last;
      final sourceText = input.text.trim().isNotEmpty
          ? input.text.trim()
          : source?['text']?.toString() ?? '';
      if (sourceText.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Send a message before extracting a memory.')));
        return;
      }
      final result = await app.api
          .call('POST', '/api/memories/extract', {'text': sourceText});
      final candidates = List<dynamic>.from(result['candidates'] ?? []);
      if (!mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No memory candidate found.')));
        return;
      }
      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Save a memory'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: candidates.map((raw) {
                final item = Map<String, dynamic>.from(raw);
                return ListTile(
                  leading: const Icon(Icons.auto_awesome),
                  title: Text(item['title']?.toString() ?? 'Memory'),
                  subtitle: Text(item['description']?.toString() ?? ''),
                  onTap: () => Navigator.pop(dialog, item),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel'))
          ],
        ),
      );
      if (selected == null) return;
      await app.api.call('POST', '/api/memories', {
        ...selected,
        'conversationId': widget.conversation['_id'],
        if (source != null && source['_id'] != null)
          'sourceMessageId': source['_id'],
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Memory saved')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> reactTo(String messageId, String emoji) async {
    try {
      final result = await app.api
          .call('POST', '/api/messages/$messageId/reactions', {'emoji': emoji});
      final updated = Map<String, dynamic>.from(result['message']);
      final index = messages.indexWhere(
          (item) => item is Map && item['_id']?.toString() == messageId);
      if (index >= 0 && mounted) setState(() => messages[index] = updated);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> deleteMessage(Map<String, dynamic> message) async {
    final id = message['_id']?.toString();
    if (id == null || id.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete this message?'),
        content: const Text(
            'This removes the message for everyone in the conversation. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete for everyone')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await app.api.call('DELETE', '/api/messages/$id', {});
      final updated = Map<String, dynamic>.from(result['message']);
      final index = messages
          .indexWhere((item) => item is Map && item['_id']?.toString() == id);
      if (index >= 0 && mounted) setState(() => messages[index] = updated);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Message deleted for everyone.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> swipeDeleteMessage(Map<String, dynamic> message) async {
    final id = message['_id']?.toString();
    if (id == null || id.isEmpty) return;
    final mine = message['senderId']?.toString() == app.user?['id']?.toString();
    final pending = message['pending'] == true || id.startsWith('local_');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(pending
            ? 'Discard queued message?'
            : (mine
                ? 'Delete message for everyone?'
                : 'Remove message for you?')),
        content: Text(pending
            ? 'This encrypted message has not been sent yet. Discard it from the secure outgoing queue?'
            : mine
                ? 'This removes the message content for everyone in the conversation.'
                : 'This hides the message only from your own chat history. Other participants keep their copies.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (pending) {
      try {
        final conversationId = widget.conversation['_id'].toString();
        final mutationId = message['clientMutationId']?.toString() ??
            id.replaceFirst('local_', '');
        await app.api
            .removeOutgoingMessageFromOutbox(conversationId, mutationId);
        if (!mounted) return;
        setState(() => messages.removeWhere(
            (item) => item is Map && item['_id']?.toString() == id));
        unawaited(_persistConversationMessages());
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Queued message discarded.')));
      } catch (error) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Could not discard queued message: $error')));
      }
      return;
    }
    try {
      final result = await app.api
          .call('DELETE', '/api/messages/$id' + (mine ? '' : '?scope=me'), {});
      if (!mounted) return;
      setState(() {
        if (mine && result['message'] is Map) {
          final at = messages.indexWhere(
              (item) => item is Map && item['_id']?.toString() == id);
          if (at >= 0)
            messages[at] = Map<String, dynamic>.from(result['message']);
        } else {
          messages.removeWhere(
              (item) => item is Map && item['_id']?.toString() == id);
        }
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete message: $error')));
      await load();
    }
  }

  Future<void> showMessageActions(Map<String, dynamic> message) async {
    final mine = message['senderId']?.toString() == app.user?['id']?.toString();
    final deleted =
        message['deletedAt'] != null || message['expiredAt'] != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Wrap(
          children: [
            if (!deleted) ...[
              ListTile(
                  leading: const Icon(Icons.reply),
                  title: const Text('Reply'),
                  onTap: () => Navigator.pop(sheet, 'reply')),
              ListTile(
                  leading: const Text('❤️', style: TextStyle(fontSize: 22)),
                  title: const Text('React with ❤️'),
                  onTap: () => Navigator.pop(sheet, '❤️')),
              ListTile(
                  leading: const Text('👍', style: TextStyle(fontSize: 22)),
                  title: const Text('React with 👍'),
                  onTap: () => Navigator.pop(sheet, '👍')),
              ListTile(
                  leading: const Text('😂', style: TextStyle(fontSize: 22)),
                  title: const Text('React with 😂'),
                  onTap: () => Navigator.pop(sheet, '😂')),
            ],
            if (mine && !deleted)
              ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('Delete for everyone'),
                  onTap: () => Navigator.pop(sheet, 'delete')),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'reply') {
      setState(() => reply = message['_id']?.toString());
    } else if (action == 'delete') {
      await deleteMessage(message);
    } else if (message['_id'] != null) {
      await reactTo(message['_id'].toString(), action);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Direct chats show the other participant's real name above their presence status.
    // Group chats keep using the configured group title.
    final title = widget.conversation['type'] == 'group'
        ? (widget.conversation['title'] ?? 'Group').toString()
        : (_directPeerName() ?? 'Chat');
    final currentUserId = app.user?['id']?.toString();
    final closedPaymentCount = payments.where((item) {
      if (item is! Map) return false;
      return List<dynamic>.from(item['dismissedBy'] ?? [])
          .any((id) => id.toString() == currentUserId);
    }).length;
    final visiblePayments = payments.where((item) {
      if (item is! Map) return false;
      final dismissedBy = List<dynamic>.from(item['dismissedBy'] ?? []);
      final isClosedForMe =
          dismissedBy.any((id) => id.toString() == currentUserId);
      return showClosedPayments || !isClosedForMe;
    }).toList();
    return Scaffold(
      appBar: AppBar(
        title: searching
            ? TextField(
                controller: searchInput,
                autofocus: true,
                onChanged: searchMessages,
                decoration: const InputDecoration(
                    hintText: 'Search this chat', border: InputBorder.none))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                    Text(title),
                    if (widget.conversation['type'] == 'direct')
                      Text(
                          onlineIds.isNotEmpty
                              ? 'Online'
                              : (_directPeerLastSeenLabel() ?? 'Offline'),
                          style: Theme.of(context).textTheme.labelSmall)
                  ]),
        actions: [
          if (widget.conversation['type'] == 'direct')
            IconButton(
                onPressed: requestMpesa,
                tooltip: 'Request M-Pesa',
                icon: const Icon(Icons.payments_outlined)),
          IconButton(
              onPressed: () {
                setState(() {
                  searching = !searching;
                  if (!searching) {
                    searchInput.clear();
                    load();
                  }
                });
              },
              tooltip: 'Search messages',
              icon: Icon(searching ? Icons.close : Icons.search)),
          if (widget.conversation['type'] == 'group')
            IconButton(
                onPressed: groupOptions,
                tooltip: 'Group details',
                icon: const Icon(Icons.group_outlined)),
          IconButton(
              onPressed: extractMemory,
              tooltip: 'Save memory',
              icon: const Icon(Icons.auto_awesome)),
        ],
      ),
      body: Column(children: [
        if (showingOfflineData || app.api.offlineDataMode)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Row(children: [
              Icon(Icons.cloud_off_outlined, size: 18),
              SizedBox(width: 8),
              Expanded(
                  child: Text(
                'Offline mode — showing saved messages. Connect to send and sync new changes.',
                style: TextStyle(fontSize: 12),
              )),
            ]),
          ),
        if (closedPaymentCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => showClosedPayments = !showClosedPayments),
              icon: Icon(showClosedPayments
                  ? Icons.visibility_off_outlined
                  : Icons.history),
              label: Text(showClosedPayments
                  ? 'Hide closed requests'
                  : 'Show closed requests ($closedPaymentCount)'),
            ),
          ),
        if (visiblePayments.isNotEmpty)
          SizedBox(
              height: visiblePayments.length > 2 ? 220 : null,
              child: ListView.builder(
                  shrinkWrap: visiblePayments.length <= 2,
                  itemCount: visiblePayments.length,
                  itemBuilder: (_, index) {
                    final payment =
                        Map<String, dynamic>.from(visiblePayments[index]);
                    final isPayer =
                        payment['payerId']?.toString() == currentUserId;
                    final isClosedForMe =
                        List<dynamic>.from(payment['dismissedBy'] ?? [])
                            .any((id) => id.toString() == currentUserId);
                    return PaymentCard(
                        payment: payment,
                        currentUserId: currentUserId,
                        onPay: isClosedForMe ? null : () => payPayment(payment),
                        onRetry:
                            isClosedForMe ? null : () => retryPayment(payment),
                        onClose:
                            isClosedForMe ? null : () => closePayment(payment),
                        onReject:
                            isClosedForMe ? null : () => rejectPayment(payment),
                        onReopen:
                            isClosedForMe ? () => reopenPayment(payment) : null,
                        rejectLabel:
                            isPayer ? 'Reject request' : 'Withdraw request',
                        onRefresh: () => refreshPayment(payment));
                  })),
        if (widget.conversation['type'] == 'direct')
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: requestMpesa,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Request M-Pesa'),
              ),
            ),
          ),
        if (typingUser != null)
          const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Someone is typing…')),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : loadError != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      AsyncActionButton(
                          label: 'Retry', icon: Icons.refresh, onPressed: load)
                    ]))
                  : messages.isEmpty
                      ? const Empty(
                          icon: Icons.chat_bubble_outline,
                          title: 'Start the conversation',
                          subtitle: 'Send the first message.')
                      : ListView.builder(
                          controller: _messagesScrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: messages.length,
                          itemBuilder: (_, i) {
                            final message =
                                Map<String, dynamic>.from(messages[i]);
                            final mine = message['senderId']?.toString() ==
                                app.user?['id']?.toString();
                            final text = message['deletedAt'] != null
                                ? 'This message was deleted.'
                                : message['expiredAt'] != null
                                    ? 'This message has expired.'
                                    : (message['text'] ?? '[media]').toString();
                            return Dismissible(
                              key: ValueKey('message-swipe-${message['_id']}'),
                              direction: (message['deletedAt'] != null ||
                                      message['expiredAt'] != null ||
                                      !_useSwipeToDelete(context))
                                  ? DismissDirection.none
                                  : DismissDirection.startToEnd,
                              background: Container(
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.only(left: 20),
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .errorContainer,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(Icons.delete_outline,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer),
                              ),
                              confirmDismiss: (_) async =>
                                  await showDialog<bool>(
                                    context: context,
                                    builder: (dialog) => AlertDialog(
                                      title: Text(mine
                                          ? 'Delete message for everyone?'
                                          : 'Remove message for you?'),
                                      content: Text(mine
                                          ? 'The message content will be removed for everyone.'
                                          : 'The message will be hidden only from your own chat history.'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dialog, false),
                                            child: const Text('Cancel')),
                                        FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(dialog, true),
                                            child: const Text('Delete')),
                                      ],
                                    ),
                                  ) ??
                                  false,
                              onDismissed: (_) => swipeDeleteMessage(message),
                              child: GestureDetector(
                                onLongPress: () => showMessageActions(message),
                                child: Row(
                                  mainAxisAlignment: mine
                                      ? MainAxisAlignment.end
                                      : MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (!_useSwipeToDelete(context) &&
                                        !mine &&
                                        message['deletedAt'] == null &&
                                        message['expiredAt'] == null)
                                      IconButton(
                                        tooltip: 'Remove message for me',
                                        icon: const Icon(Icons.delete_outline,
                                            size: 19),
                                        onPressed: () =>
                                            swipeDeleteMessage(message),
                                      ),
                                    Flexible(
                                      child: Container(
                                        // Keep bubbles content-sized and aligned like a
                                        // modern messenger; long messages wrap instead of
                                        // stretching across the phone screen.
                                        constraints: BoxConstraints(
                                          maxWidth: (MediaQuery.sizeOf(context)
                                                      .width *
                                                  0.62)
                                              .clamp(180.0, 520.0)
                                              .toDouble(),
                                        ),
                                        margin:
                                            const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 13, vertical: 10),
                                        decoration: BoxDecoration(
                                          // Strongly distinct, high-contrast colors make
                                          // sent and received messages easy to scan.
                                          color: mine
                                              ? const Color(0xFF087F8C)
                                              : const Color(0xFFFFFFFF),
                                          borderRadius: BorderRadius.only(
                                            topLeft: const Radius.circular(18),
                                            topRight: const Radius.circular(18),
                                            bottomLeft:
                                                Radius.circular(mine ? 18 : 5),
                                            bottomRight:
                                                Radius.circular(mine ? 5 : 18),
                                          ),
                                          border: Border.all(
                                            color: mine
                                                ? const Color(0xFF065F68)
                                                : const Color(0xFFDCE4EE),
                                          ),
                                        ),
                                        child: DefaultTextStyle.merge(
                                          style: TextStyle(
                                            color: mine
                                                ? Colors.white
                                                : const Color(0xFF243B53),
                                          ),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                // A reply keeps only the original message ID in storage.
                                                // Resolve it against the current conversation so deleted,
                                                // expired, or unavailable originals never break rendering.
                                                if (message['replyTo'] != null)
                                                  Builder(builder: (context) {
                                                    final original =
                                                        findReplyTarget(
                                                            messages,
                                                            message['replyTo']);
                                                    // A non-null empty map keeps preview rendering null-safe
                                                    // while the unavailable flag preserves deleted-message semantics.
                                                    final originalMap =
                                                        original ??
                                                            <String, dynamic>{};
                                                    final unavailable =
                                                        original == null ||
                                                            originalMap[
                                                                    'deletedAt'] !=
                                                                null ||
                                                            originalMap[
                                                                    'expiredAt'] !=
                                                                null;
                                                    final originalSender =
                                                        originalMap['senderId']
                                                                    ?.toString() ==
                                                                app.user?['id']
                                                                    ?.toString()
                                                            ? 'You'
                                                            : 'Message';
                                                    final preview = unavailable
                                                        ? 'Original message unavailable'
                                                        : (originalMap[
                                                                    'text'] ??
                                                                '[media]')
                                                            .toString();
                                                    return Container(
                                                      width: double.infinity,
                                                      margin:
                                                          const EdgeInsets.only(
                                                              bottom: 7),
                                                      padding:
                                                          const EdgeInsets.all(
                                                              8),
                                                      decoration: BoxDecoration(
                                                        color: mine
                                                            ? const Color(
                                                                0x33404040)
                                                            : const Color(
                                                                0xFFDDF5F2),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(8),
                                                        border: Border(
                                                            left: BorderSide(
                                                          color: mine
                                                              ? Colors.white70
                                                              : const Color(
                                                                  0xFF087F8C),
                                                          width: 3,
                                                        )),
                                                      ),
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Text(
                                                              'Replying to $originalSender',
                                                              style: TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w700,
                                                                  fontSize: 11,
                                                                  color: mine
                                                                      ? Colors
                                                                          .white
                                                                      : const Color(
                                                                          0xFF087F8C))),
                                                          Text(preview,
                                                              maxLines: 2,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                  fontSize: 12,
                                                                  color: mine
                                                                      ? Colors
                                                                          .white
                                                                      : const Color(
                                                                          0xFF39445A))),
                                                        ],
                                                      ),
                                                    );
                                                  }),
                                                if (mine &&
                                                    message['deletedAt'] ==
                                                        null &&
                                                    message['expiredAt'] ==
                                                        null)
                                                  Align(
                                                    widthFactor: 1,
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child:
                                                        PopupMenuButton<String>(
                                                      tooltip:
                                                          'Message options',
                                                      padding: EdgeInsets.zero,
                                                      constraints:
                                                          const BoxConstraints(
                                                        minWidth: 44,
                                                        minHeight: 44,
                                                      ),
                                                      iconSize: 20,
                                                      icon: Icon(
                                                        Icons.more_horiz,
                                                        color: mine
                                                            ? Colors.white
                                                            : const Color(
                                                                0xFF52627A),
                                                      ),
                                                      onSelected: (action) {
                                                        if (action ==
                                                            'delete') {
                                                          deleteMessage(
                                                              message);
                                                        }
                                                      },
                                                      itemBuilder: (_) =>
                                                          const [
                                                        PopupMenuItem<String>(
                                                          value: 'delete',
                                                          child: Row(
                                                            children: [
                                                              Icon(
                                                                Icons
                                                                    .delete_outline,
                                                                color: Color(
                                                                    0xFFDC2626),
                                                                size: 20,
                                                              ),
                                                              SizedBox(
                                                                  width: 10),
                                                              Text(
                                                                  'Delete for everyone'),
                                                            ],
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                if (message['deletedAt'] == null &&
                                                    message['expiredAt'] ==
                                                        null &&
                                                    message['messageType'] ==
                                                        'image' &&
                                                    message['mediaUrl'] != null)
                                                  renderImage(
                                                      message['mediaUrl']
                                                          .toString())
                                                else
                                                  _renderMessageText(text,
                                                      message['mentions']),
                                                if (message['pending'] ==
                                                    true) ...[
                                                  const Text(
                                                      'Waiting to send · saved securely',
                                                      style: TextStyle(
                                                          fontSize: 11,
                                                          fontStyle: FontStyle
                                                              .italic)),
                                                  TextButton.icon(
                                                    onPressed:
                                                        _flushOutgoingMessages,
                                                    icon: const Icon(
                                                        Icons.refresh,
                                                        size: 14),
                                                    label:
                                                        const Text('Retry now'),
                                                    style: TextButton.styleFrom(
                                                        padding:
                                                            EdgeInsets.zero,
                                                        minimumSize:
                                                            const Size(0, 28),
                                                        tapTargetSize:
                                                            MaterialTapTargetSize
                                                                .shrinkWrap),
                                                  ),
                                                ],
                                                if (message[
                                                            'deletedAt'] ==
                                                        null &&
                                                    message['reactions']
                                                        is List &&
                                                    (message['reactions']
                                                            as List)
                                                        .isNotEmpty)
                                                  Text((message['reactions']
                                                          as List)
                                                      .map((r) => r['emoji'])
                                                      .join(' ')),
                                                if (mine &&
                                                    message['deliveredTo']
                                                        is List &&
                                                    (message['deliveredTo']
                                                                as List)
                                                            .length >
                                                        1)
                                                  Text(
                                                      message['readBy']
                                                                  is List &&
                                                              (message['readBy']
                                                                          as List)
                                                                      .length >
                                                                  1
                                                          ? 'Read'
                                                          : 'Delivered',
                                                      style: const TextStyle(
                                                          fontSize: 10))
                                              ]),
                                        ),
                                      ),
                                    ),
                                    if (!_useSwipeToDelete(context) &&
                                        mine &&
                                        message['deletedAt'] == null &&
                                        message['expiredAt'] == null)
                                      IconButton(
                                        tooltip: 'Delete message for everyone',
                                        icon: const Icon(Icons.delete_outline,
                                            size: 19),
                                        onPressed: () =>
                                            swipeDeleteMessage(message),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
        ),
        if (memorySuggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome, size: 18),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Chatify noticed something worth remembering',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Not now',
                          visualDensity: VisualDensity.compact,
                          onPressed: savingMemorySuggestion
                              ? null
                              : _dismissMemorySuggestions,
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    for (final suggestion in memorySuggestions)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      suggestion['title']?.toString() ??
                                          'Memory',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  if ((suggestion['personName']?.toString() ??
                                          '')
                                      .trim()
                                      .isNotEmpty)
                                    Text(
                                      'About ${suggestion['personName']}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  Text(suggestion['description']?.toString() ??
                                      ''),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: savingMemorySuggestion
                                  ? null
                                  : () => _saveMemorySuggestion(suggestion),
                              child: savingMemorySuggestion
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Text('Save'),
                            ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: savingMemorySuggestion
                            ? null
                            : _dismissMemorySuggestions,
                        child: const Text('Not now'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Keep the selected original visible while composing so users can verify
        // exactly which message their reply will reference, and allow cancellation.
        if (reply != null)
          Builder(builder: (context) {
            final original = findReplyTarget(messages, reply);
            // The fallback map lets the composer preview safely handle a missing or expired target.
            final originalMap = original ?? <String, dynamic>{};
            final originalDeleted = original == null ||
                originalMap['deletedAt'] != null ||
                originalMap['expiredAt'] != null;
            final originalSender = originalMap['senderId']?.toString() ==
                    app.user?['id']?.toString()
                ? 'You'
                : 'Message';
            final originalText = originalDeleted
                ? 'Original message unavailable'
                : (originalMap['text'] ?? '[media]').toString();
            return Container(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              decoration: BoxDecoration(
                color: const Color(0xFFDDF5F2),
                border: const Border(
                    left: BorderSide(color: Color(0xFF087F8C), width: 3)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.reply, color: Color(0xFF087F8C), size: 19),
                const SizedBox(width: 8),
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Replying to $originalSender',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: Color(0xFF087F8C))),
                    Text(originalText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF39445A))),
                  ],
                )),
                IconButton(
                  tooltip: 'Cancel reply',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => reply = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ]),
            );
          }),
        if (_mentionSuggestions.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.min(6, _mentionSuggestions.length) * 56.0,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _mentionSuggestions.length,
              itemBuilder: (context, index) {
                final person = _mentionSuggestions[index];
                final identifier = _mentionDisambiguator(
                  person,
                  List<dynamic>.from(
                      widget.conversation['participants'] ?? const []),
                );
                return ListTile(
                  dense: true,
                  selected: index == _mentionActiveIndex,
                  leading: const Icon(Icons.alternate_email, size: 18),
                  title: Text(person['name']?.toString() ?? 'Chat member'),
                  subtitle: identifier.isEmpty ? null : Text(identifier),
                  onTap: () => _selectMention(person),
                );
              },
            ),
          ),
        SafeArea(
            child: Row(children: [
          IconButton(
              onPressed: _chooseMention,
              tooltip: 'Mention a chat member',
              icon: const Icon(Icons.alternate_email)),
          IconButton(
              onPressed: sendImageLink,
              tooltip: 'Share image URL',
              icon: const Icon(Icons.image_outlined)),
          PopupMenuButton<String>(
            onSelected: (value) => setState(() => expiry = value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'NONE', child: Text('Permanent')),
              PopupMenuItem(value: 'AFTER_READ', child: Text('After read')),
              PopupMenuItem(value: 'AFTER_TIME', child: Text('After 1 hour')),
              PopupMenuItem(value: 'AFTER_REPLY', child: Text('After reply')),
            ],
          ),
          Expanded(
              child: Focus(
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;

              final key = event.logicalKey;
              if (_mentionSuggestions.isNotEmpty) {
                if (key == LogicalKeyboardKey.arrowDown ||
                    key == LogicalKeyboardKey.arrowUp) {
                  final direction =
                      key == LogicalKeyboardKey.arrowDown ? 1 : -1;
                  setState(() => _mentionActiveIndex = (_mentionActiveIndex +
                          direction +
                          _mentionSuggestions.length) %
                      _mentionSuggestions.length);
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.escape) {
                  setState(() => _mentionSuggestions = []);
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.enter) {
                  _selectMention(_mentionSuggestions[_mentionActiveIndex]);
                  return KeyEventResult.handled;
                }
              }
              if (key == LogicalKeyboardKey.enter &&
                  !HardwareKeyboard.instance.isShiftPressed) {
                if (!sending) send();
                return KeyEventResult.handled;
              }

              // When the composer is empty, use the arrow keys to browse
              // the conversation instead of moving an invisible caret.
              if (input.text.isEmpty &&
                  _messagesScrollController.hasClients &&
                  (key == LogicalKeyboardKey.arrowUp ||
                      key == LogicalKeyboardKey.arrowDown)) {
                final position = _messagesScrollController.position;
                final distance = position.viewportDimension * 0.7;
                final target = (position.pixels +
                        (key == LogicalKeyboardKey.arrowUp
                            ? -distance
                            : distance))
                    .clamp(
                      position.minScrollExtent,
                      position.maxScrollExtent,
                    )
                    .toDouble();
                _messagesScrollController.animateTo(
                  target,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                );
                return KeyEventResult.handled;
              }

              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: input,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) {
                if (_mentionSuggestions.isNotEmpty) {
                  _selectMention(_mentionSuggestions[_mentionActiveIndex]);
                } else if (!sending) {
                  send();
                }
              },
              onChanged: _composerChanged,
              decoration: const InputDecoration(
                hintText: 'Write a message…',
                border: InputBorder.none,
              ),
            ),
          )),
          IconButton(
              onPressed: sending ? null : send,
              icon: sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send)),
        ])),
      ]),
    );
  }
}

// Screen for viewing and editing the signed-in user's profile and preferences.
class Profile extends StatefulWidget {
  const Profile({super.key});
  @override
  State<Profile> createState() => _ProfileState();
}

// Loads profile data and submits profile/privacy/notification preference changes.
class _ProfileState extends State<Profile> {
  late TextEditingController name, phone;
  bool lastSeen = true,
      receipts = true,
      messages = true,
      mentions = true,
      memories = true;
  @override
  void initState() {
    super.initState();
    final u = context.read<AppState>().user ?? {};
    name = TextEditingController(text: u['name']?.toString() ?? '');
    phone = TextEditingController(text: u['phone']?.toString() ?? '');
    final p = Map<String, dynamic>.from(u['privacy'] ?? {}),
        n = Map<String, dynamic>.from(u['notificationPreferences'] ?? {});
    lastSeen = p['lastSeen'] ?? true;
    receipts = p['readReceipts'] ?? true;
    messages = n['messages'] ?? true;
    mentions = n['mentions'] ?? true;
    memories = n['memories'] ?? true;
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final api = context.read<AppState>().api;
    try {
      final d = await api.call('PATCH', '/api/users/me', {
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'privacy': {'lastSeen': lastSeen, 'readReceipts': receipts},
        'notificationPreferences': {
          'messages': messages,
          'mentions': mentions,
          'memories': memories
        },
      });
      if (!mounted) return;
      context.read<AppState>().user = Map<String, dynamic>.from(d['user']);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> chooseProfilePicture() async {
    final api = context.read<AppState>().api;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1200,
        maxHeight: 1200,
      );
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      if (bytes.length > 10 * 1024 * 1024) {
        throw Exception('Choose an image smaller than 10 MB.');
      }
      final path = picked.path.toLowerCase();
      final mimeType = path.endsWith('.png')
          ? 'image/png'
          : path.endsWith('.webp')
              ? 'image/webp'
              : 'image/jpeg';
      if (!mounted) return;
      final upload = await api.call('POST', '/api/media', {
        'data': base64Encode(bytes),
        'mimeType': mimeType,
      });
      final mediaUrl = upload['mediaUrl']?.toString();
      if (mediaUrl == null || !mediaUrl.startsWith('https://')) {
        throw Exception('Image upload did not return a secure image URL.');
      }
      final saved =
          await api.call('PATCH', '/api/users/me', {'profileImage': mediaUrl});
      if (!mounted) return;
      context.read<AppState>().updateCurrentUser(
            Map<String, dynamic>.from(saved['user']),
          );
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture updated.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not update picture: $error')));
      }
    }
  }

  Future<void> viewProfilePicture(String imageUrl) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: SizedBox(
          width: MediaQuery.sizeOf(dialogContext).width * .9,
          height: MediaQuery.sizeOf(dialogContext).height * .78,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: OfflineCachedImage(
                    imageUrl,
                    fit: BoxFit.contain,
                    width: double.infinity,
                    height: double.infinity,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined, size: 48),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  tooltip: 'Close enlarged profile picture',
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> saveDefaultPhone() async {
    final normalized = normalizeKenyanPhone(phone.text);
    if (normalized == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Enter a valid Kenyan M-Pesa number, e.g. 0712345678')));
      return;
    }
    try {
      final d = await context
          .read<AppState>()
          .api
          .call('PATCH', '/api/users/me', {'phone': normalized});
      if (!mounted) return;
      final app = context.read<AppState>();
      app.user = Map<String, dynamic>.from(d['user']);
      phone.text = normalized;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Default M-Pesa number saved. Payment requests will use it automatically.')));
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    try {
      await showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
                  title: const Text('Change password'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: current,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Current password')),
                    TextField(
                        controller: next,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'New password (8+ characters)'))
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            final appState = context.read<AppState>();
                            final passwordResult = await appState.api.call(
                                'POST', '/api/auth/change-password', {
                              'currentPassword': current.text,
                              'newPassword': next.text
                            });
                            if (passwordResult['token'] is String) {
                              await appState.api
                                  .saveToken(passwordResult['token'] as String);
                              appState.refreshRealtimeAuthentication();
                            }
                            if (d.mounted) Navigator.pop(d);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Password changed')));
                            }
                          } catch (error) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error.toString())));
                            }
                          }
                        },
                        child: const Text('Update'))
                  ]));
    } finally {
      current.dispose();
      next.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final profileImage = app.user?['profileImage']?.toString();
    return ListView(padding: const EdgeInsets.all(18), children: [
      Center(
        child: Column(children: [
          Semantics(
            button: profileImage != null && profileImage.startsWith('https://'),
            label: 'View profile picture full size',
            child: InkWell(
              key: const ValueKey('profile-picture-preview'),
              borderRadius: BorderRadius.circular(14),
              onTap: profileImage != null && profileImage.startsWith('https://')
                  ? () => viewProfilePicture(profileImage)
                  : null,
              child: Container(
                width: 180,
                height: 220,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                clipBehavior: Clip.antiAlias,
                child:
                    profileImage != null && profileImage.startsWith('https://')
                        ? OfflineCachedImage(
                            profileImage,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Icon(Icons.person_outline, size: 56),
                            ),
                          )
                        : const Center(
                            child: Icon(Icons.person_outline, size: 56),
                          ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: chooseProfilePicture,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Change profile picture'),
          ),
        ]),
      ),
      SwitchListTile(
        value: app.themeMode == ThemeMode.dark,
        onChanged: app.setDarkMode,
        secondary: Icon(app.themeMode == ThemeMode.dark
            ? Icons.dark_mode_outlined
            : Icons.light_mode_outlined),
        title: const Text('Dark mode'),
        subtitle: const Text('Use a darker, low-glare appearance'),
      ),
      TextField(
          controller: name,
          decoration: const InputDecoration(
              labelText: 'Name', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      const Text('Default M-Pesa number',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      const Text(
          'Set this for your existing account. Chatify will prefill it when you send or receive payment requests. You can still change either number on an individual request.'),
      const SizedBox(height: 10),
      TextField(
          controller: phone,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
              labelText: 'M-Pesa phone number',
              hintText: '0712345678 or 254712345678',
              helperText: (context
                          .watch<AppState>()
                          .user?['phone']
                          ?.toString()
                          .isNotEmpty ??
                      false)
                  ? 'Saved default: ${context.watch<AppState>().user?['phone']}'
                  : 'No default saved yet — add your number below.',
              border: const OutlineInputBorder())),
      const SizedBox(height: 8),
      OutlinedButton.icon(
          onPressed: saveDefaultPhone,
          icon: const Icon(Icons.account_balance_wallet_outlined),
          label: const Text('Save default M-Pesa number')),
      const SizedBox(height: 18),
      const Text('Privacy',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      SwitchListTile(
          value: lastSeen,
          onChanged: (v) => setState(() => lastSeen = v),
          title: const Text('Show last seen')),
      SwitchListTile(
          value: receipts,
          onChanged: (v) => setState(() => receipts = v),
          title: const Text('Read receipts')),
      const Text('Notifications',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      SwitchListTile(
          value: messages,
          onChanged: (v) => setState(() => messages = v),
          title: const Text('New messages')),
      SwitchListTile(
          value: mentions,
          onChanged: (v) => setState(() => mentions = v),
          title: const Text('Mentions')),
      SwitchListTile(
          value: memories,
          onChanged: (v) => setState(() => memories = v),
          title: const Text('Memory suggestions')),
      AsyncActionButton(label: 'Save changes', onPressed: save),
      TextButton(
          onPressed: changePassword, child: const Text('Change password')),
      TextButton(
          onPressed: () => context.read<AppState>().logout(),
          child: const Text('Sign out'))
    ]);
  }
}

/// Customer-facing public marketplace for discovering businesses and their published catalogue.
class StoreDirectoryPage extends StatefulWidget {
  const StoreDirectoryPage({super.key});
  @override
  State<StoreDirectoryPage> createState() => _StoreDirectoryPageState();
}

class _StoreDirectoryPageState extends State<StoreDirectoryPage> {
  final search = TextEditingController();
  final location = TextEditingController();
  final category = TextEditingController();
  List<dynamic> stores = [], products = [];
  bool loading = true, showingProducts = false;
  String country = 'KE';
  String? error;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    loadResults();
  }

  @override
  void dispose() {
    search.dispose();
    location.dispose();
    category.dispose();
    super.dispose();
  }

  Future<void> loadResults() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final parameters = <String, String>{
        if (search.text.trim().isNotEmpty) 'q': search.text.trim(),
        if (category.text.trim().isNotEmpty) 'category': category.text.trim(),
        if (country.isNotEmpty) 'country': country,
        if (location.text.trim().isNotEmpty) 'location': location.text.trim(),
        'page': '1',
        'pageSize': '50',
      };
      final endpoint =
          showingProducts ? '/api/marketplace/products' : '/api/marketplace';
      final result = await app.api
          .call('GET', '$endpoint?${Uri(queryParameters: parameters).query}');
      if (!mounted) return;
      setState(() {
        if (showingProducts) {
          products = List<dynamic>.from(result['products'] ?? []);
        } else {
          stores = List<dynamic>.from(result['businesses'] ?? []);
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = showingProducts ? products : stores;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore marketplace'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PaymentHistory()),
            ),
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: const Text('Payments'),
          ),
          IconButton(
              tooltip: 'Refresh marketplace',
              onPressed: loadResults,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                  value: false,
                  icon: Icon(Icons.storefront_outlined),
                  label: Text('Businesses')),
              ButtonSegment<bool>(
                  value: true,
                  icon: Icon(Icons.shopping_bag_outlined),
                  label: Text('Products')),
            ],
            selected: {showingProducts},
            onSelectionChanged: (selection) {
              setState(() => showingProducts = selection.first);
              loadResults();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => loadResults(),
            decoration: InputDecoration(
              hintText: showingProducts
                  ? 'Search products and services'
                  : 'Business name or @handle (e.g. @prime-cafe)',
              prefixIcon: const Icon(Icons.search),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: category,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => loadResults(),
                decoration: InputDecoration(
                  labelText: 'Category',
                  hintText: 'e.g. retail',
                  prefixIcon: const Icon(Icons.category_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 105,
              child: DropdownButtonFormField<String>(
                initialValue: country,
                decoration: InputDecoration(
                  labelText: 'Country',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                ),
                items: const [
                  DropdownMenuItem(value: 'KE', child: Text('Kenya')),
                  DropdownMenuItem(value: 'UG', child: Text('Uganda')),
                  DropdownMenuItem(value: 'TZ', child: Text('Tanzania')),
                  DropdownMenuItem(value: 'RW', child: Text('Rwanda')),
                  DropdownMenuItem(value: 'US', child: Text('USA')),
                  DropdownMenuItem(value: 'GB', child: Text('UK')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => country = value);
                  loadResults();
                },
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: location,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => loadResults(),
                decoration: InputDecoration(
                  labelText: 'Town or branch',
                  hintText: 'e.g. Nairobi',
                  prefixIcon: const Icon(Icons.location_on_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
                onPressed: loadResults,
                icon: const Icon(Icons.tune),
                label: const Text('Filter')),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: loadResults,
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                    ? ListView(children: [
                        const SizedBox(height: 90),
                        const Icon(Icons.cloud_off_outlined, size: 48),
                        Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(error!, textAlign: TextAlign.center)),
                        Center(
                            child: FilledButton(
                                onPressed: loadResults,
                                child: const Text('Try again'))),
                      ])
                    : entries.isEmpty
                        ? ListView(children: [
                            const SizedBox(height: 80),
                            const Icon(Icons.storefront_outlined,
                                size: 56, color: Color(0xFF77758B)),
                            const SizedBox(height: 12),
                            Center(
                                child: Text(
                              showingProducts
                                  ? 'No products match these filters.'
                                  : 'No businesses match these filters.',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            )),
                            const SizedBox(height: 6),
                            const Center(
                                child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 28),
                              child: Text(
                                  'Published businesses and active catalogue items appear here. Clear a filter or try another search.',
                                  textAlign: TextAlign.center),
                            )),
                          ])
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            itemCount: entries.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final entry = Map<String, dynamic>.from(
                                  entries[index] as Map);
                              if (showingProducts) {
                                final business = entry['business'] is Map
                                    ? Map<String, dynamic>.from(
                                        entry['business'] as Map)
                                    : <String, dynamic>{};
                                final images = entry['images'] is List
                                    ? List<dynamic>.from(entry['images'])
                                    : <dynamic>[];
                                final image = images.isNotEmpty
                                    ? images.first.toString()
                                    : '';
                                final currency =
                                    entry['currency']?.toString() ?? 'KES';
                                final price = entry['price']?.toString() ?? '—';
                                return Card(
                                  clipBehavior: Clip.antiAlias,
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.all(12),
                                    leading: CircleAvatar(
                                      radius: 28,
                                      backgroundColor: const Color(0xFFDDF5F2),
                                      backgroundImage:
                                          image.startsWith('https://')
                                              ? NetworkImage(image)
                                              : null,
                                      child: image.startsWith('https://')
                                          ? null
                                          : const Icon(
                                              Icons.inventory_2_outlined,
                                              color: Color(0xFF087F8C)),
                                    ),
                                    title: Text(
                                        entry['name']?.toString() ??
                                            'Product or service',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800)),
                                    subtitle: Text(
                                        '${business['name'] ?? 'Chatify business'} · ${entry['category'] ?? 'General'}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                    trailing: Text('$currency $price',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800)),
                                    onTap: business['slug'] == null
                                        ? null
                                        : () => Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      StorefrontPage(
                                                          slug: business['slug']
                                                              .toString())),
                                            ),
                                  ),
                                );
                              }
                              final name = entry['name']?.toString() ??
                                  'Chatify business';
                              final logo = entry['logo']?.toString() ?? '';
                              final count =
                                  entry['itemCount']?.toString() ?? '0';
                              final industry = entry['industry']
                                      ?.toString()
                                      .replaceAll('_', ' ') ??
                                  '';
                              return Card(
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                  contentPadding: const EdgeInsets.all(12),
                                  leading: CircleAvatar(
                                    radius: 28,
                                    backgroundColor: const Color(0xFFDDF5F2),
                                    backgroundImage: logo.startsWith('https://')
                                        ? NetworkImage(logo)
                                        : null,
                                    child: logo.startsWith('https://')
                                        ? null
                                        : const Icon(Icons.storefront_rounded,
                                            color: Color(0xFF087F8C)),
                                  ),
                                  title: Text(name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800)),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text(
                                        [
                                          if (industry.isNotEmpty)
                                            industry[0].toUpperCase() +
                                                industry.substring(1),
                                          '$count product/service(s)',
                                          if ((entry['country']?.toString() ??
                                                  '')
                                              .isNotEmpty)
                                            entry['country'].toString(),
                                          if ((entry['description']
                                                      ?.toString() ??
                                                  '')
                                              .isNotEmpty)
                                            entry['description'].toString(),
                                        ].join(' · '),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  trailing: const Icon(
                                      Icons.arrow_forward_ios_rounded,
                                      size: 16),
                                  onTap: () => Navigator.of(context)
                                      .push(MaterialPageRoute<void>(
                                    builder: (_) => StorefrontPage(
                                        slug: entry['slug'].toString()),
                                  )),
                                ),
                              );
                            },
                          ),
          ),
        ),
      ]),
    );
  }
}

/// Customer-facing storefront. Product prices are display-only until the server creates
/// an order from its own catalogue records; successful payment is confirmed by Daraja callback.
class StorefrontPage extends StatefulWidget {
  final String slug;
  const StorefrontPage({super.key, required this.slug});
  @override
  State<StorefrontPage> createState() => _StorefrontPageState();
}

class _StorefrontPageState extends State<StorefrontPage> {
  Map<String, dynamic> storefront = {};
  List<dynamic> products = [];
  final Map<String, int> cart = {};
  final phone = TextEditingController();
  bool loading = true, checkingOut = false;
  String? error, paymentId, notice;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    phone.text = app.user?['phone']?.toString() ?? '';
    loadStore();
  }

  @override
  void dispose() {
    phone.dispose();
    super.dispose();
  }

  Future<void> loadStore() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await app.api
          .call('GET', '/api/storefront/${Uri.encodeComponent(widget.slug)}');
      if (!mounted) return;
      setState(() {
        storefront = Map<String, dynamic>.from(result['storefront'] ?? {});
        products = List<dynamic>.from(result['items'] ?? []);
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  double get total => products.whereType<Map>().fold<double>(0, (sum, raw) {
        final item = Map<String, dynamic>.from(raw);
        return sum +
            (double.tryParse(item['price']?.toString() ?? '') ?? 0) *
                (cart[item['_id']?.toString()] ?? 0);
      });

  void addProduct(Map<String, dynamic> item) {
    final id = item['_id']?.toString();
    if (id == null) return;
    final current = cart[id] ?? 0;
    final stock = int.tryParse(item['stock']?.toString() ?? '') ?? 0;
    if (stock > 0 && current >= stock) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('You have selected all available stock for this product.')));
      return;
    }
    setState(() => cart[id] = current + 1);
  }

  // Open a private customer/seller conversation without exposing the seller's contact details.
  // The normal Chat screen retains end-to-end encryption and existing payment tools.
  Future<void> chatWithSeller({Map<String, dynamic>? item}) async {
    final sellerId = storefront['sellerUserId']?.toString() ?? '';
    if (sellerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'This seller has not enabled direct Chatify messaging yet.')));
      return;
    }
    if (app.user == null) {
      final shouldSignIn = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Chat with seller'),
          content: const Text(
              'Sign in to discuss products, delivery and payment securely with this seller.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Not now')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Sign in')),
          ],
        ),
      );
      if (shouldSignIn == true && mounted) app.openAuth();
      return;
    }
    final currentUserId =
        app.user?['_id']?.toString() ?? app.user?['id']?.toString() ?? '';
    if (sellerId == currentUserId) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Open this store using a customer account to contact the seller.')));
      return;
    }
    try {
      final result = await app.api
          .call('POST', '/api/conversations/direct', {'userId': sellerId});
      final conversation =
          Map<String, dynamic>.from(result['conversation'] ?? {});
      // Preserve the storefront context locally so chat payment forms can load this exact
      // merchant's public Till/Paybill instructions instead of guessing by seller name.
      final storefrontSlug = storefront['slug']?.toString();
      if (storefrontSlug != null && storefrontSlug.isNotEmpty) {
        conversation['businessStorefrontSlug'] = storefrontSlug;
      }
      if (!mounted || conversation.isEmpty) return;
      if (item != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Chat opened. Ask about ' +
              (item['name']?.toString() ?? 'this item') +
              '; secure M-Pesa checkout is available on this storefront.'),
        ));
      }
      final draft = item == null
          ? null
          : 'Hi, I am interested in ' +
              (item['name']?.toString() ?? 'this item') +
              ' from ' +
              (storefront['name']?.toString() ?? 'your store') +
              '. Could you share availability, delivery options and the best way to pay?';
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Chat(conversation: conversation, initialMessage: draft),
      ));
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to open seller chat: $e')),
        );
    }
  }

  Future<void> showProduct(Map<String, dynamic> item) async {
    final id = item['_id']?.toString() ?? '';
    final image =
        (item['images'] is List && (item['images'] as List).isNotEmpty)
            ? (item['images'] as List).first.toString()
            : '';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item['name']?.toString() ?? 'Product'),
        content: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (image.startsWith('https://'))
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: OfflineCachedImage(image,
                    height: 170,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
            const SizedBox(height: 8),
            Text('KSh ${item['price'] ?? '—'}',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(item['description']?.toString() ??
                'No product description yet.'),
            if ((item['category']?.toString() ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Chip(label: Text(item['category'].toString())),
              ),
          ],
        )),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close')),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              chatWithSeller(item: item);
            },
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Ask seller'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              addProduct(item);
            },
            icon: const Icon(Icons.add_shopping_cart),
            label: Text(cart[id] == null ? 'Add to cart' : 'Add another'),
          ),
        ],
      ),
    );
  }

  Future<void> checkout() async {
    if (cart.isEmpty || checkingOut) return;
    if (app.user == null) {
      final signIn = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Sign in to pay'),
          content: const Text(
              'You can browse products without an account. Sign in or create an account to place an order and receive the secure M-Pesa payment prompt.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Not now')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Continue')),
          ],
        ),
      );
      if (signIn == true && mounted) app.openAuth(register: true);
      return;
    }
    if (normalizeKenyanPhone(phone.text) == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a valid Kenyan M-Pesa phone number.')));
      return;
    }
    setState(() {
      checkingOut = true;
      notice = null;
      error = null;
    });
    try {
      final result = await app.api.call('POST',
          '/api/storefront/${Uri.encodeComponent(widget.slug)}/checkout', {
        'phone': phone.text.trim(),
        'items': cart.entries
            .map((entry) => {'itemId': entry.key, 'quantity': entry.value})
            .toList(),
      });
      final payment = Map<String, dynamic>.from(result['payment'] ?? {});
      final id = payment['paymentId']?.toString();
      if (id == null || id.isEmpty) {
        throw const FormatException(
            'Order was created but no payment reference was returned.');
      }
      final baseAmount = (payment['baseAmount'] as num?)?.toInt() ??
          (payment['amount'] as num?)?.toInt() ??
          0;
      if (!mounted) return;
      final consent = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                title: const Text('Confirm checkout total'),
                content: Text(
                    'Order total: KSh $baseAmount\nNo Chatify transaction commission is added. Safaricom charges, if applicable, are separate.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Continue to M-Pesa')),
                ],
              ));
      if (consent != true) {
        if (mounted)
          setState(() {
            paymentId = id;
            notice =
                'Order saved, but no M-Pesa prompt was sent. You can refresh this payment or contact the store.';
          });
        return;
      }
      if (mounted) {
        setState(() {
          paymentId = id;
          notice = 'Order created. Requesting M-Pesa payment prompt…';
        });
      }
      final initiated = await app.api.call(
          'POST',
          '/api/payments/${Uri.encodeComponent(id)}/initiate',
          {'phone': phone.text.trim()});
      if (!mounted) return;
      final isMock = initiated['mock'] == true;
      setState(() {
        notice = isMock
            ? 'Order created, but the server is in demo M-Pesa mode. No real Safaricom prompt was sent.'
            : 'Check your phone and enter your M-Pesa PIN to approve the payment. Then refresh payment status below.';
        cart.clear();
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => checkingOut = false);
    }
  }

  Future<void> refreshPayment() async {
    final id = paymentId;
    if (id == null) return;
    try {
      final result =
          await app.api.call('GET', '/api/payments/${Uri.encodeComponent(id)}');
      final payment = Map<String, dynamic>.from(result['payment'] ?? {});
      final status = payment['status']?.toString() ?? 'PENDING';
      if (mounted) {
        setState(() => notice = status == 'SUCCESS'
            ? 'Payment confirmed. Thank you for your order!'
            : status == 'PENDING'
                ? 'Payment is still pending. Complete the M-Pesa prompt on your phone, then refresh.'
                : 'Payment status: $status. You can contact the store if you need help.');
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (error != null && storefront.isEmpty) {
      return Scaffold(
          appBar: AppBar(title: const Text('Storefront')),
          body: Center(
              child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.storefront_outlined, size: 48),
              const SizedBox(height: 12),
              Text(error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              AsyncActionButton(
                  label: 'Retry store',
                  icon: Icons.refresh,
                  onPressed: loadStore),
            ]),
          )));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(storefront['name']?.toString() ?? 'Storefront'),
        actions: [
          TextButton.icon(
            onPressed: () => chatWithSeller(),
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Chat seller'),
          ),
          // Keep payment history visible from the customer storefront, not hidden behind an icon-only menu.
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PaymentHistory()),
            ),
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: const Text('Payments'),
          ),
          IconButton(
              tooltip: 'Refresh products',
              onPressed: loadStore,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: loadStore,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                    colors: [Color(0xFF082F49), Color(0xFF087F8C)]),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.storefront_rounded,
                        color: Colors.white, size: 30),
                    const SizedBox(height: 10),
                    Text(storefront['name']?.toString() ?? 'Shop',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 5),
                    Text(
                        storefront['description']?.toString() ??
                            'Browse products, add what you need to your cart, and pay securely with M-Pesa.',
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 10),
                    const Text('Secure checkout · M-Pesa',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700)),
                    if ((storefront['sellerMpesaPhone']?.toString() ?? '')
                        .isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Seller M-Pesa: ${storefront['sellerMpesaPhone']}',
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ]),
            ),
            const SizedBox(height: 16),
            Text('Products',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (products.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('This store has no active products yet.',
                    textAlign: TextAlign.center),
              ),
            ...products.whereType<Map>().map((raw) {
              final item = Map<String, dynamic>.from(raw);
              final id = item['_id']?.toString() ?? '';
              final image = (item['images'] is List &&
                      (item['images'] as List).isNotEmpty)
                  ? (item['images'] as List).first.toString()
                  : '';
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => showProduct(item),
                  child: Row(children: [
                    if (image.startsWith('https://'))
                      SizedBox(
                          width: 100,
                          height: 110,
                          child: OfflineCachedImage(image,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.inventory_2_outlined)))
                    else
                      Container(
                          width: 100,
                          height: 110,
                          color: const Color(0xFFF0F5FA),
                          child:
                              const Icon(Icons.inventory_2_outlined, size: 34)),
                    Expanded(
                        child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item['name']?.toString() ?? 'Product',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(item['description']?.toString() ?? '',
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 6),
                            Text('KSh ${item['price'] ?? '—'}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF087F8C))),
                            const SizedBox(height: 5),
                            Row(children: [
                              Expanded(
                                  child: Text(
                                      (cart[id] ?? 0) > 0
                                          ? 'In cart: ${cart[id]}'
                                          : 'Tap to view details',
                                      style: const TextStyle(fontSize: 11))),
                              IconButton(
                                  onPressed: () => addProduct(item),
                                  icon: const Icon(Icons.add_circle_outline),
                                  tooltip: 'Add to cart'),
                            ]),
                          ]),
                    )),
                  ]),
                ),
              );
            }),
            if (cart.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            'Your cart · ${cart.values.fold<int>(0, (sum, value) => sum + value)} item(s)',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        ...cart.entries.map((entry) {
                          final item = products.whereType<Map>().firstWhere(
                              (p) => p['_id']?.toString() == entry.key,
                              orElse: () => <String, dynamic>{});
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(item['name']?.toString() ?? 'Product'),
                            subtitle: Text(
                                '${entry.value} × KSh ${item['price'] ?? ''}'),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                  onPressed: () => setState(() {
                                        if (entry.value <= 1) {
                                          cart.remove(entry.key);
                                        } else {
                                          cart[entry.key] = entry.value - 1;
                                        }
                                      }),
                                  icon:
                                      const Icon(Icons.remove_circle_outline)),
                              IconButton(
                                  onPressed: () {
                                    final product = products
                                        .whereType<Map>()
                                        .firstWhere(
                                            (p) =>
                                                p['_id']?.toString() ==
                                                entry.key,
                                            orElse: () => <String, dynamic>{});
                                    if (product.isNotEmpty) {
                                      addProduct(
                                          Map<String, dynamic>.from(product));
                                    }
                                  },
                                  icon: const Icon(Icons.add_circle_outline)),
                            ]),
                          );
                        }),
                        const Divider(),
                        Row(children: [
                          const Expanded(
                              child: Text('Total',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w800))),
                          Text('KSh ${total.toStringAsFixed(0)}',
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w900)),
                        ]),
                        const SizedBox(height: 12),
                        TextField(
                          controller: phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'M-Pesa phone number',
                            hintText: '0712345678',
                            prefixIcon: Icon(Icons.phone_android),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: checkingOut ? null : checkout,
                              icon: checkingOut
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.lock_outline),
                              label: Text(checkingOut
                                  ? 'Starting secure checkout…'
                                  : 'Checkout with M-Pesa'),
                            )),
                      ]),
                ),
              ),
            if (notice != null)
              Card(
                  color: const Color(0xFFE9F8F2),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(notice!,
                              style: const TextStyle(color: Color(0xFF155E48))),
                          if (paymentId != null) ...[
                            const SizedBox(height: 8),
                            SelectableText('Payment reference: $paymentId'),
                            Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                    onPressed: refreshPayment,
                                    icon: const Icon(Icons.refresh),
                                    label:
                                        const Text('Refresh payment status'))),
                          ],
                        ]),
                  )),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
          ],
        ),
      ),
    );
  }
}

/// Business operations workspace: lightweight mobile entry points to the authenticated
/// organization, catalogue, customer CRM, sales documents and follow-up task APIs.
class BusinessHub extends StatefulWidget {
  const BusinessHub({super.key});
  @override
  State<BusinessHub> createState() => _BusinessHubState();
}

class _BusinessHubState extends State<BusinessHub> {
  Map<String, dynamic>? organization;
  Map<String, dynamic> dashboard = {};
  List<dynamic> organizations = [],
      catalog = [],
      customers = [],
      documents = [],
      tasks = [];
  bool loading = true, saving = false;
  int pendingOfflineCount = 0;
  List<String> syncConflicts = [];
  final Map<String, Future<int>> _offlineSyncs = {};
  String? error;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    loadOrganizations();
  }

  Future<void> loadOrganizations() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final result = await app.api.call('GET', '/api/business/organizations');
      organizations = List<dynamic>.from(result['organizations'] ?? []);
      if (organizations.isNotEmpty) {
        final currentId = organization?['_id']?.toString();
        organization = organizations.firstWhere(
          (item) => item is Map && item['_id']?.toString() == currentId,
          orElse: () => organizations.first,
        ) as Map<String, dynamic>;
        await loadWorkspaceData();
      } else {
        organization = null;
        dashboard = {};
        catalog = [];
        customers = [];
        documents = [];
        tasks = [];
      }
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> loadWorkspaceData({bool syncPending = true}) async {
    final id = organization?['_id']?.toString();
    if (id == null) return;
    try {
      final encoded = Uri.encodeComponent(id);
      final results = await Future.wait([
        app.api.call('GET', '/api/business/organizations/$encoded/dashboard'),
        app.api.call('GET', '/api/business/organizations/$encoded/catalog'),
        app.api.call('GET', '/api/business/organizations/$encoded/customers'),
        app.api.call('GET', '/api/business/organizations/$encoded/documents'),
        app.api.call('GET', '/api/business/organizations/$encoded/tasks'),
      ]);
      dashboard = Map<String, dynamic>.from(results[0]['metrics'] ?? {});
      catalog = List<dynamic>.from(results[1]['items'] ?? []);
      customers = List<dynamic>.from(results[2]['customers'] ?? []);
      documents = List<dynamic>.from(results[3]['documents'] ?? []);
      tasks = List<dynamic>.from(results[4]['tasks'] ?? []);
      await _overlayOfflineCreates(id);
      error = null;
    } catch (e) {
      error = e.toString();
    }
    if (syncPending && error == null) {
      final applied = await _flushOfflineQueue(id);
      if (applied > 0) {
        await loadWorkspaceData(syncPending: false);
        return;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> createOrganization() async {
    final name = TextEditingController();
    final industry = ValueNotifier<String>('retail');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create a business workspace'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Business name')),
          const SizedBox(height: 12),
          ValueListenableBuilder<String>(
            valueListenable: industry,
            builder: (_, value, __) => DropdownButtonFormField<String>(
              initialValue: value,
              decoration: const InputDecoration(labelText: 'Industry'),
              items: const [
                DropdownMenuItem(
                    value: 'retail', child: Text('Retail / wholesale')),
                DropdownMenuItem(
                    value: 'consulting', child: Text('Consultants / agencies')),
                DropdownMenuItem(
                    value: 'tourism', child: Text('Tourism / hospitality')),
                DropdownMenuItem(
                    value: 'logistics', child: Text('Transport / logistics')),
                DropdownMenuItem(
                    value: 'construction',
                    child: Text('Construction / trades')),
                DropdownMenuItem(
                    value: 'salon', child: Text('Salon / personal services')),
                DropdownMenuItem(
                    value: 'education', child: Text('Schools / training')),
                DropdownMenuItem(
                    value: 'agriculture', child: Text('Agriculture / produce')),
                DropdownMenuItem(
                    value: 'real_estate',
                    child: Text('Real estate / property')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (next) {
                if (next != null) industry.value = next;
              },
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (accepted != true || name.text.trim().isEmpty) return;
    try {
      await app.api.call('POST', '/api/business/organizations',
          {'name': name.text.trim(), 'industry': industry.value});
      await loadOrganizations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> createRecord(String kind) async {
    final name = TextEditingController();
    final detail = TextEditingController();
    final amount = TextEditingController();
    final quantity = TextEditingController(text: '1');
    final docType = ValueNotifier<String>('quote');
    final id = organization?['_id']?.toString();
    if (id == null) return;
    final title = kind == 'catalog'
        ? 'Add product or service'
        : kind == 'customer'
            ? 'Add customer'
            : kind == 'document'
                ? 'Create quotation'
                : 'Create follow-up task';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: kind == 'catalog'
                      ? 'Product / service name'
                      : kind == 'customer'
                          ? 'Customer name'
                          : kind == 'document'
                              ? 'Quotation title / item'
                              : 'Task title')),
          if (kind == 'catalog') ...[
            TextField(
                controller: detail,
                decoration: const InputDecoration(labelText: 'Description')),
            TextField(
                controller: amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Price')),
            TextField(
                controller: quantity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Stock quantity')),
          ] else if (kind == 'customer') ...[
            TextField(
                controller: detail,
                decoration: const InputDecoration(labelText: 'Email or phone')),
          ] else if (kind == 'document') ...[
            ValueListenableBuilder<String>(
                valueListenable: docType,
                builder: (_, value, __) => DropdownButtonFormField<String>(
                    initialValue: value,
                    decoration:
                        const InputDecoration(labelText: 'Document type'),
                    items: const [
                      DropdownMenuItem(
                          value: 'quote', child: Text('Quotation')),
                      DropdownMenuItem(
                          value: 'invoice', child: Text('Invoice')),
                      DropdownMenuItem(
                          value: 'order', child: Text('Sales order'))
                    ],
                    onChanged: (next) {
                      if (next != null) docType.value = next;
                    })),
            TextField(
                controller: amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Unit price')),
            TextField(
                controller: quantity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Quantity')),
          ] else ...[
            TextField(
                controller: detail,
                decoration:
                    const InputDecoration(labelText: 'Notes / description')),
          ],
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (accepted != true || name.text.trim().isEmpty) return;
    setState(() => saving = true);
    try {
      final base = '/api/business/organizations/${Uri.encodeComponent(id)}';
      if (kind == 'catalog') {
        final price = double.tryParse(amount.text) ?? -1;
        if (price < 0) {
          throw const FormatException('Enter a valid non-negative price.');
        }
        await _enqueueOfflineCreate(id, 'catalog', {
          'name': name.text.trim(),
          'description': detail.text.trim(),
          'price': price,
          'stock': int.tryParse(quantity.text) ?? 0
        });
      } else if (kind == 'customer') {
        final contact = detail.text.trim();
        await _enqueueOfflineCreate(id, 'customer', {
          'name': name.text.trim(),
          if (contact.contains('@')) 'email': contact else 'phone': contact
        });
      } else if (kind == 'document') {
        final price = double.tryParse(amount.text) ?? -1;
        final count = int.tryParse(quantity.text) ?? 0;
        if (price < 0 || count < 1) {
          throw const FormatException('Enter a valid price and quantity.');
        }
        await app.api.call('POST', '$base/documents', {
          'type': docType.value,
          'items': [
            {'name': name.text.trim(), 'quantity': count, 'unitPrice': price}
          ]
        });
      } else {
        await _enqueueOfflineCreate(id, 'task',
            {'title': name.text.trim(), 'description': detail.text.trim()});
      }
      if (kind == 'document') {
        await loadWorkspaceData();
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Business record saved.')));
      } else {
        final applied = await _flushOfflineQueue(id);
        if (applied > 0) {
          await loadWorkspaceData(syncPending: false);
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Business record saved.')));
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Saved on this device and waiting to sync.')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _offlineQueueKey(String id) =>
      'chatify_business_offline_${app.api.accountScope}_$id';
  String _offlineIssuesKey(String id) =>
      'chatify_business_sync_issues_${app.api.accountScope}_$id';

  List<dynamic>? _recordsForOfflineType(String type) => switch (type) {
        'catalog' => catalog,
        'customer' => customers,
        'task' => tasks,
        _ => null,
      };

  void _showOfflineCreate(Map<String, dynamic> mutation) {
    final records =
        _recordsForOfflineType(mutation['entityType']?.toString() ?? '');
    if (records == null) return;
    final mutationId = mutation['mutationId']?.toString();
    if (mutationId == null ||
        records.any(
            (item) => item is Map && item['_id']?.toString() == mutationId))
      return;
    final changes = mutation['changes'];
    if (changes is! Map) return;
    records.insert(0, <String, dynamic>{
      ...Map<String, dynamic>.from(changes),
      '_id': mutationId,
      'offlinePending': true,
      'createdAt': mutation['createdAt'],
    });
  }

  Future<void> _overlayOfflineCreates(String id) async {
    final prefs = await SharedPreferences.getInstance();
    for (final encoded
        in prefs.getStringList(_offlineQueueKey(id)) ?? <String>[]) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map)
          _showOfflineCreate(Map<String, dynamic>.from(decoded));
      } catch (_) {
        // A corrupt item stays in the queue for diagnosis; it is never replayed.
      }
    }
  }

  // Persist only offline record creates; each mutation ID makes retry safe if the response is lost.
  Future<void> _enqueueOfflineCreate(
      String id, String entityType, Map<String, dynamic> changes) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _offlineQueueKey(id);
    final queue = prefs.getStringList(key) ?? <String>[];
    final mutation = <String, dynamic>{
      'mutationId':
          'mobile:$entityType:${DateTime.now().microsecondsSinceEpoch}',
      'operation': 'create',
      'entityType': entityType,
      'changes': changes,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'status': 'pending'
    };
    queue.add(jsonEncode(mutation));
    await prefs.setStringList(key, queue);
    _showOfflineCreate(mutation);
    if (mounted) setState(() => pendingOfflineCount = queue.length);
  }

  Future<int> _flushOfflineQueue(String id) async {
    final syncKey = '${app.api.accountScope}:$id';
    final active = _offlineSyncs[syncKey];
    if (active != null) return active;
    final work = _flushOfflineQueueOnce(id);
    _offlineSyncs[syncKey] = work;
    try {
      return await work;
    } finally {
      if (identical(_offlineSyncs[syncKey], work))
        _offlineSyncs.remove(syncKey);
    }
  }

  Future<int> _flushOfflineQueueOnce(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _offlineQueueKey(id);
    final queue = prefs.getStringList(key) ?? <String>[];
    if (queue.isEmpty) {
      if (mounted) setState(() => pendingOfflineCount = 0);
      return 0;
    }
    try {
      final mutations = queue
          .take(50)
          .map((entry) => Map<String, dynamic>.from(jsonDecode(entry) as Map))
          .toList();
      final response = await app.api.call(
          'POST',
          '/api/business/organizations/${Uri.encodeComponent(id)}/sync',
          {'mutations': mutations});
      final results = List<dynamic>.from(response['results'] ?? []);
      final byId = <String, Map<String, dynamic>>{
        for (final result in results.whereType<Map>())
          result['mutationId'].toString(): Map<String, dynamic>.from(result)
      };
      final remaining = <String>[];
      final issues = prefs.getStringList(_offlineIssuesKey(id)) ?? <String>[];
      var applied = 0;
      for (final entry in queue) {
        final mutation = Map<String, dynamic>.from(jsonDecode(entry) as Map);
        final result = byId[mutation['mutationId'].toString()];
        if (result == null) {
          remaining.add(entry);
        } else if (result['status'] == 'applied') {
          applied++;
        } else {
          issues.add(jsonEncode({'mutation': mutation, 'result': result}));
        }
      }
      await prefs.setStringList(key, remaining);
      await prefs.setStringList(
          _offlineIssuesKey(id), issues.take(100).toList());
      if (mounted) {
        setState(() {
          pendingOfflineCount = remaining.length;
          syncConflicts = issues.take(100).toList();
        });
      }
      if (issues.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Some offline changes need review in Business Tools.')));
      }
      return applied;
    } catch (_) {
      if (mounted) setState(() => pendingOfflineCount = queue.length);
      return 0;
    }
  }

  // Publish or hide the customer-facing store without deleting the catalogue.
  // The server applies this flag to public discovery, storefront, enquiry and checkout routes.
  Future<void> _toggleStorefrontPublished() async {
    final id = organization?['_id']?.toString();
    if (id == null) return;
    final currentSettings = organization?['settings'] is Map
        ? Map<String, dynamic>.from(organization!['settings'] as Map)
        : <String, dynamic>{};
    final currentlyPublished = currentSettings['storefrontPublished'] != false;
    final next = !currentlyPublished;
    setState(() => saving = true);
    try {
      await app.api.call(
          'PATCH', '/api/business/organizations/${Uri.encodeComponent(id)}', {
        'settings': {'storefrontPublished': next},
      });
      await loadOrganizations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(next
              ? 'Storefront published. Customers can now discover your business.'
              : 'Storefront hidden from public discovery. Your business records are unchanged.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  // Seller M-Pesa settings start with the registered account phone, but owners can
  // save a different Kenyan number for customer-facing storefront payments.
  Future<void> _configureMpesaNumbers() async {
    var registeredPhone = app.user?['phone']?.toString() ?? '';
    final slug = organization?['slug']?.toString() ?? '';
    // The storefront API resolves the actual owner account default, even if a manager is editing settings.
    if (slug.isNotEmpty) {
      try {
        final storefrontResponse = await app.api
            .call('GET', '/api/storefront/${Uri.encodeComponent(slug)}');
        final sellerDefault =
            storefrontResponse['storefront']?['sellerMpesaPhone']?.toString() ??
                '';
        if (sellerDefault.isNotEmpty) registeredPhone = sellerDefault;
      } catch (_) {
        // Keep the signed-in user's registered number as a useful offline/fallback default.
      }
    }
    // The storefront lookup above may yield after this screen is disposed; do not open a dialog using a stale context.
    if (!mounted) return;
    final currentSettings = organization?['settings'] is Map
        ? Map<String, dynamic>.from(organization!['settings'] as Map)
        : <String, dynamic>{};
    final phone = TextEditingController(
      text:
          currentSettings['mpesaRecipientPhone']?.toString().isNotEmpty == true
              ? currentSettings['mpesaRecipientPhone'].toString()
              : registeredPhone,
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Seller M-Pesa number'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              'Registered account number: ${registeredPhone.isEmpty ? 'Not set' : registeredPhone}'),
          const SizedBox(height: 12),
          TextField(
            controller: phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Customer payment number',
              hintText: '0712345678',
              helperText:
                  'Starts with your registered number. Change it if you want customers to pay using another Kenyan M-Pesa number. Leave blank to use your registered account number.',
              prefixIcon: Icon(Icons.phone_android),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save number')),
        ],
      ),
    );
    if (accepted != true) return;
    final id = organization?['_id']?.toString();
    if (id == null) return;
    try {
      await app.api.call(
          'PATCH', '/api/business/organizations/${Uri.encodeComponent(id)}', {
        'settings': {'mpesaRecipientPhone': phone.text.trim()},
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Seller M-Pesa number saved.')));
      }
      await loadOrganizations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _configureGlobalTaxRates() async {
    final country = TextEditingController(text: 'KE');
    final currency = TextEditingController(text: 'KES');
    final rate = TextEditingController(text: '16');
    final label = TextEditingController(text: 'VAT');
    String mode = 'exclusive';
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                title: const Text('Platform-wide tax rate'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: country,
                      maxLength: 2,
                      decoration: const InputDecoration(
                          labelText: 'Country code (e.g. KE)')),
                  TextField(
                      controller: currency,
                      maxLength: 3,
                      decoration: const InputDecoration(
                          labelText: 'Currency (e.g. KES)')),
                  TextField(
                      controller: label,
                      decoration: const InputDecoration(
                          labelText: 'Tax label (e.g. VAT)')),
                  TextField(
                      controller: rate,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Rate (%)')),
                  DropdownButtonFormField<String>(
                      initialValue: mode,
                      decoration:
                          const InputDecoration(labelText: 'Tax treatment'),
                      items: const [
                        DropdownMenuItem(
                            value: 'exclusive', child: Text('Add tax on top')),
                        DropdownMenuItem(
                            value: 'inclusive',
                            child: Text('Tax included in price')),
                        DropdownMenuItem(value: 'none', child: Text('No tax')),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => mode = value);
                      }),
                  const Text(
                      'This rate applies to business documents for every workspace matching this country and currency. Verify the legally applicable rate before saving.',
                      style: TextStyle(fontSize: 12)),
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Apply globally')),
                ],
              ),
            ));
    if (accepted != true || !mounted) return;
    try {
      final countryCode = country.text.trim().toUpperCase();
      final currencyCode = currency.text.trim().toUpperCase();
      final value = double.tryParse(rate.text);
      if (countryCode.length != 2 ||
          currencyCode.length != 3 ||
          value == null ||
          value < 0 ||
          value > 100) {
        throw const FormatException(
            'Enter a valid country, currency and tax rate from 0 to 100.');
      }
      final response = await app.api.call(
          'PUT',
          '/api/admin/tax-rates/${Uri.encodeComponent(countryCode)}/${Uri.encodeComponent(currencyCode)}',
          {'mode': mode, 'rate': value, 'taxLabel': label.text.trim()});
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                response['notice']?.toString() ?? 'Global tax rate saved.')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save global tax rate: $error')));
    } finally {
      country.dispose();
      currency.dispose();
      rate.dispose();
      label.dispose();
    }
  }

  Future<void> _configureTaxProfile() async {
    final country = TextEditingController(
        text: organization?['country']?.toString() ?? 'KE');
    final currency = TextEditingController(
        text: organization?['currency']?.toString() ?? 'KES');
    final rate = TextEditingController(text: '0');
    String mode = 'exclusive';
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Tax and currency profile'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: country,
                        maxLength: 2,
                        decoration: const InputDecoration(
                            labelText: 'Country code (e.g. KE)')),
                    TextField(
                        controller: currency,
                        maxLength: 3,
                        decoration: const InputDecoration(
                            labelText: 'Currency (e.g. KES)')),
                    TextField(
                        controller: rate,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Tax rate (%)')),
                    DropdownButtonFormField<String>(
                        initialValue: mode,
                        decoration:
                            const InputDecoration(labelText: 'Tax treatment'),
                        items: const [
                          DropdownMenuItem(
                              value: 'exclusive',
                              child: Text('Tax added on top')),
                          DropdownMenuItem(
                              value: 'inclusive', child: Text('Tax included')),
                          DropdownMenuItem(value: 'none', child: Text('No tax'))
                        ],
                        onChanged: (value) {
                          if (value != null) setDialogState(() => mode = value);
                        }),
                    const Text(
                        'Confirm local rates with your accountant or tax authority.',
                        style: TextStyle(fontSize: 12)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Save'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call(
          'PATCH',
          '/api/business/organizations/${Uri.encodeComponent(id)}/tax-profile',
          {
            'country': country.text.trim().toUpperCase(),
            'currency': currency.text.trim().toUpperCase(),
            'rate': double.tryParse(rate.text) ?? -1,
            'mode': mode
          });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(response['notice']?.toString() ?? 'Tax profile saved.')));
      }
      await loadOrganizations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _translateBusinessText() async {
    final source = TextEditingController();
    final target = TextEditingController(text: 'Kiswahili');
    bool consent = false;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Translate business text'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: source,
                        minLines: 3,
                        maxLines: 6,
                        decoration: const InputDecoration(
                            labelText: 'Text to translate')),
                    TextField(
                        controller: target,
                        decoration: const InputDecoration(
                            labelText: 'Target language')),
                    CheckboxListTile(
                        value: consent,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                            'I consent to sending this text to the configured AI provider'),
                        onChanged: (value) =>
                            setDialogState(() => consent = value ?? false)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: consent
                            ? () => Navigator.pop(dialogContext, true)
                            : null,
                        child: const Text('Translate'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call('POST',
          '/api/business/organizations/${Uri.encodeComponent(id)}/translate', {
        'text': source.text,
        'targetLanguage': target.text.trim(),
        'consent': true
      });
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: const Text('Translation'),
                  content: SelectableText(response['translated']?.toString() ??
                      'No translation returned.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Close'))
                  ]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _translateVoice() async {
    final target = TextEditingController(text: 'Kiswahili');
    bool consent = false;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Voice message translation'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: target,
                        decoration: const InputDecoration(
                            labelText: 'Translate speech into')),
                    CheckboxListTile(
                        value: consent,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                            'I consent to sending this audio to the configured AI provider'),
                        onChanged: (value) =>
                            setDialogState(() => consent = value ?? false)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: consent
                            ? () => Navigator.pop(dialogContext, true)
                            : null,
                        child: const Text('Choose audio'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final selected = await FilePicker.platform.pickFiles(
          type: FileType.audio, withData: true, allowMultiple: false);
      if (selected == null || selected.files.isEmpty) return;
      final file = selected.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty || bytes.length > 11 * 1024 * 1024) {
        throw const FormatException('Choose an audio file smaller than 11 MB.');
      }
      final extension = (file.extension ?? '').toLowerCase();
      final mime = switch (extension) {
        'mp3' || 'mpeg' => 'audio/mpeg',
        'm4a' || 'mp4' => 'audio/mp4',
        'wav' => 'audio/wav',
        'ogg' => 'audio/ogg',
        'webm' => 'audio/webm',
        _ => throw const FormatException(
            'Supported audio formats: MP3, M4A, WAV, OGG and WebM.'),
      };
      final id = organization!['_id'].toString();
      final response = await app.api.call(
          'POST',
          '/api/business/organizations/${Uri.encodeComponent(id)}/voice-translate',
          {
            'audioBase64': base64Encode(bytes),
            'mimeType': mime,
            'targetLanguage': target.text.trim(),
            'consent': true
          });
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                title: const Text('Voice translation'),
                content: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Transcription',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SelectableText(
                          response['transcription']?.toString() ?? ''),
                      const SizedBox(height: 12),
                      const Text('Translation',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SelectableText(response['translated']?.toString() ?? ''),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Close'))
                ],
              ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _memorySuggestions() async {
    final source = TextEditingController();
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
                title: const Text('Business Memory suggestions'),
                content: TextField(
                    controller: source,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                        labelText: 'Paste a conversation or business note')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Find suggestions'))
                ]));
    if (accepted != true || source.text.trim().isEmpty) return;
    try {
      final id = organization!['_id'].toString();
      final response = await app.api.call(
          'POST',
          '/api/business/organizations/${Uri.encodeComponent(id)}/memory-candidates',
          {'text': source.text});
      final candidates = List<dynamic>.from(response['candidates'] ?? []);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: const Text('Review suggestions'),
                  content: SizedBox(
                      width: 420,
                      child: candidates.isEmpty
                          ? const Text('No clear candidates found.')
                          : ListView(
                              shrinkWrap: true,
                              children: candidates
                                  .whereType<Map>()
                                  .map((item) => ListTile(
                                      title: Text(item['title']?.toString() ??
                                          'Suggestion'),
                                      subtitle: Text(
                                          '${item['type']}: ${item['description']}')))
                                  .toList())),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Close'))
                  ]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _sendCustomerMessage() async {
    final eligible = customers.whereType<Map>().toList();
    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add a customer before sending a message.')));
      return;
    }
    String? customerId = eligible.first['_id']?.toString();
    String channel = 'whatsapp';
    bool confirmedOptIn = false;
    final message = TextEditingController();
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Message a customer'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    DropdownButtonFormField<String>(
                        initialValue: customerId,
                        decoration:
                            const InputDecoration(labelText: 'Customer'),
                        items: eligible
                            .map((item) => DropdownMenuItem<String>(
                                value: item['_id']?.toString(),
                                child: Text(
                                    item['name']?.toString() ?? 'Customer',
                                    overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: (value) =>
                            setDialogState(() => customerId = value)),
                    DropdownButtonFormField<String>(
                        initialValue: channel,
                        decoration: const InputDecoration(labelText: 'Channel'),
                        items: const [
                          DropdownMenuItem(
                              value: 'whatsapp', child: Text('WhatsApp')),
                          DropdownMenuItem(value: 'sms', child: Text('SMS'))
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => channel = value);
                          }
                        }),
                    TextField(
                        controller: message,
                        minLines: 2,
                        maxLines: 5,
                        decoration:
                            const InputDecoration(labelText: 'Message')),
                    CheckboxListTile(
                        value: confirmedOptIn,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Customer has explicitly opted in'),
                        onChanged: (value) => setDialogState(
                            () => confirmedOptIn = value ?? false)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed:
                            confirmedOptIn && message.text.trim().isNotEmpty
                                ? () => Navigator.pop(dialogContext, true)
                                : null,
                        child: const Text('Send'))
                  ],
                )));
    if (accepted != true || customerId == null) return;
    try {
      final base =
          '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}';
      await app.api.call(
          'PATCH',
          '$base/customers/${Uri.encodeComponent(customerId!)}/messaging-consent',
          {'consent': true});
      final response = await app.api.call('POST', '$base/communications/send', {
        'customerId': customerId,
        'channel': channel,
        'message': message.text.trim()
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(response['notice']?.toString() ?? 'Message submitted.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _createScheduledWorkflow() async {
    final name = TextEditingController(text: 'Daily follow-up reminder');
    final interval = TextEditingController(text: '60');
    final actionText =
        TextEditingController(text: 'Review open customer follow-ups');
    String action = 'create_task';
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: const Text('Scheduled workflow'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: name,
                        decoration:
                            const InputDecoration(labelText: 'Workflow name')),
                    TextField(
                        controller: interval,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Repeat every minutes (5–10080)')),
                    DropdownButtonFormField<String>(
                        initialValue: action,
                        decoration: const InputDecoration(labelText: 'Action'),
                        items: const [
                          DropdownMenuItem(
                              value: 'create_task',
                              child: Text('Create follow-up task')),
                          DropdownMenuItem(
                              value: 'notify_team',
                              child: Text('Notify team in Chatify'))
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => action = value);
                          }
                        }),
                    TextField(
                        controller: actionText,
                        decoration: InputDecoration(
                            labelText: action == 'create_task'
                                ? 'Task title'
                                : 'Notification')),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Create and enable'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final base =
          '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}';
      final created = await app.api.call('POST', '$base/workflows', {
        'name': name.text.trim(),
        'trigger': 'schedule',
        'scheduleEveryMinutes': int.tryParse(interval.text) ?? 60,
        'actions': [
          {
            'actionType': action,
            'config': action == 'create_task'
                ? {'title': actionText.text.trim()}
                : {'message': actionText.text.trim()}
          }
        ]
      });
      final workflowId = (created['workflow'] as Map?)?['_id']?.toString();
      if (workflowId == null) {
        throw const FormatException(
            'Workflow was created but its ID was missing.');
      }
      await app.api.call(
          'POST', '$base/workflows/${Uri.encodeComponent(workflowId)}/test', {
        'sample': {'source': 'mobile setup'}
      });
      await app.api.call(
          'PATCH',
          '$base/workflows/${Uri.encodeComponent(workflowId)}',
          {'enabled': true});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Workflow enabled. Keep the backend worker running.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _invoiceIntegration(String documentId, String action) async {
    try {
      final base =
          '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}/documents/${Uri.encodeComponent(documentId)}';
      Map<String, dynamic> response;
      if (action == 'stripe' || action == 'paypal') {
        final providerRoute =
            action == 'stripe' ? 'stripe-checkout' : 'paypal-checkout';
        response = await app.api.call('POST', '$base/$providerRoute', {});
        final checkoutUrl = response['payment'] is Map
            ? (response['payment'] as Map)['checkoutUrl']?.toString()
            : null;
        if (checkoutUrl == null ||
            !await launchUrl(Uri.parse(checkoutUrl),
                mode: LaunchMode.externalApplication)) {
          if (mounted && checkoutUrl != null) {
            await showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                        title: const Text('Hosted checkout'),
                        content: SelectableText(checkoutUrl),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'))
                        ]));
          }
        }
      } else if (action == 'mpesa') {
        final preview = await app.api.call('GET', '$base/mpesa-fee-preview');
        final baseAmount = (preview['baseAmount'] as num?)?.toInt() ?? 0;
        final phone = TextEditingController();
        if (!mounted) return;
        final accepted = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                    title: const Text('Review invoice M-Pesa total'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                          'Invoice balance: KSh $baseAmount\nNo Chatify transaction commission is added.'),
                      const SizedBox(height: 8),
                      const Text(
                          'Confirm the invoice balance with the customer before sending the M-Pesa prompt. Safaricom charges, if applicable, are separate.',
                          style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 8),
                      TextField(
                          controller: phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                              labelText: 'Customer M-Pesa phone')),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Confirm and send STK'))
                    ]));
        if (accepted != true) {
          phone.dispose();
          return;
        }
        response = await app.api
            .call('POST', '$base/mpesa-stk', {'phone': phone.text.trim()});
        phone.dispose();
      } else {
        response = await app.api.call('POST', '$base/etims-submit', {});
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(response['notice']?.toString() ?? 'Request submitted.')));
      }
      await loadWorkspaceData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _showPaymentMatching(String documentId) async {
    try {
      final orgId = Uri.encodeComponent(organization!['_id'].toString());
      final path =
          '/api/business/organizations/$orgId/documents/${Uri.encodeComponent(documentId)}/payment-matching';
      final result = await app.api.call('GET', path);
      final matches = List<dynamic>.from(result['matches'] ?? []);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Payment matching · ${result['number'] ?? 'Invoice'}'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      'Confirmed paid: ${result['currency'] ?? 'KES'} ${result['confirmedPaidAmount'] ?? 0}'),
                  Text(
                      'Outstanding: ${result['currency'] ?? 'KES'} ${result['outstandingAmount'] ?? 0}'),
                  const SizedBox(height: 8),
                  const Text(
                      'Confidence is a triage hint only. Unverified manual references are not proof of payment.'),
                  const Divider(),
                  if (matches.isEmpty)
                    const Text('No payment records attached to this document.'),
                  for (final match in matches.whereType<Map>())
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(match['verified'] == true
                          ? Icons.verified_outlined
                          : Icons.warning_amber_outlined),
                      title: Text(
                          '${match['status'] ?? 'unmatched'} · ${result['currency'] ?? 'KES'} ${match['amount'] ?? 0}'),
                      subtitle: Text(
                          'Confidence: ${match['confidence'] ?? 0}% · Reference: ${match['reference'] ?? 'none'}\n${match['notice'] ?? ''}'),
                    ),
                ])),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'))
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _shareBusinessDocument(String documentId) async {
    try {
      final orgId = Uri.encodeComponent(organization!['_id'].toString());
      final result = await app.api.call(
          'POST', '/api/business/organizations/$orgId/enterprise/shares', {
        'entityType': 'document',
        'entityId': documentId,
        'expiresInHours': 72,
      });
      final path = result['path']?.toString() ?? '';
      if (path.isEmpty || !mounted) return;
      final link = Uri.parse(app.api.base).resolve(path).toString();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Customer document link'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'The customer can view this document without seeing internal notes. The link expires in 72 hours.'),
                const SizedBox(height: 8),
                SelectableText(link),
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close')),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Customer document link copied.')));
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy link'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _manageDocumentDelivery(String documentId, Map item) async {
    final statuses = [
      'pending',
      'packed',
      'dispatched',
      'in_transit',
      'delivered',
      'failed',
      'returned',
      'not_required'
    ];
    String status = statuses.contains(item['deliveryStatus'])
        ? item['deliveryStatus'].toString()
        : 'pending';
    final address =
        TextEditingController(text: item['deliveryAddress']?.toString() ?? '');
    final provider =
        TextEditingController(text: item['deliveryProvider']?.toString() ?? '');
    final tracking =
        TextEditingController(text: item['trackingNumber']?.toString() ?? '');
    final notes =
        TextEditingController(text: item['deliveryNotes']?.toString() ?? '');
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                title: const Text('Product delivery'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  DropdownButtonFormField<String>(
                    initialValue: status,
                    decoration:
                        const InputDecoration(labelText: 'Delivery status'),
                    items: statuses
                        .map((value) => DropdownMenuItem(
                            value: value,
                            child: Text(value.replaceAll('_', ' '))))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => status = value);
                    },
                  ),
                  TextField(
                      controller: address,
                      decoration:
                          const InputDecoration(labelText: 'Delivery address')),
                  TextField(
                      controller: provider,
                      decoration: const InputDecoration(
                          labelText: 'Courier / delivery provider')),
                  TextField(
                      controller: tracking,
                      decoration:
                          const InputDecoration(labelText: 'Tracking number')),
                  TextField(
                      controller: notes,
                      maxLines: 2,
                      decoration: const InputDecoration(
                          labelText: 'Customer update / notes')),
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Save delivery')),
                ],
              ),
            ));
    if (accepted != true || !mounted) return;
    try {
      final orgId = organization!['_id'].toString();
      final response = await app.api.call(
          'PATCH',
          '/api/business/organizations/${Uri.encodeComponent(orgId)}/documents/${Uri.encodeComponent(documentId)}/delivery',
          {
            'deliveryStatus': status,
            'deliveryAddress': address.text.trim(),
            'deliveryProvider': provider.text.trim(),
            'trackingNumber': tracking.text.trim(),
            'deliveryNotes': notes.text.trim()
          });
      await loadWorkspaceData();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                response['notice']?.toString() ?? 'Delivery details saved.')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save delivery details: $error')));
    } finally {
      address.dispose();
      provider.dispose();
      tracking.dispose();
      notes.dispose();
    }
  }

  Future<void> _showDocumentActions(Map item) async {
    final type = item['type']?.toString() ?? '';
    final status = item['status']?.toString() ?? '';
    final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
                child: Wrap(children: [
              ListTile(
                  title: Text(item['number']?.toString() ?? 'Sales document'),
                  subtitle: Text('Status: $status')),
              if (!['draft', 'rejected', 'cancelled'].contains(status))
                ListTile(
                    leading: const Icon(Icons.link),
                    title:
                        const Text('Share customer link (expires in 72 hours)'),
                    onTap: () => Navigator.pop(context, 'share')),
              if (type == 'invoice' && status != 'draft')
                ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: const Text('Review payment matching'),
                    onTap: () => Navigator.pop(context, 'matching')),
              if (status == 'draft')
                ListTile(
                    leading: const Icon(Icons.send),
                    title: const Text('Issue / send document'),
                    onTap: () => Navigator.pop(context, 'issue')),
              if (type == 'invoice' &&
                  status != 'draft' &&
                  !['paid', 'cancelled', 'rejected', 'fulfilled']
                      .contains(status))
                ListTile(
                    leading: const Icon(Icons.credit_card),
                    title: const Text('Pay online (Stripe)'),
                    onTap: () => Navigator.pop(context, 'stripe')),
              if (type == 'invoice' &&
                  status != 'draft' &&
                  !['paid', 'cancelled', 'rejected', 'fulfilled']
                      .contains(status))
                ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: const Text('Pay with PayPal'),
                    onTap: () => Navigator.pop(context, 'paypal')),
              if (type == 'invoice' &&
                  status != 'draft' &&
                  !['paid', 'cancelled', 'rejected', 'fulfilled']
                      .contains(status))
                ListTile(
                    leading: const Icon(Icons.payments),
                    title: const Text('Request M-Pesa STK payment'),
                    onTap: () => Navigator.pop(context, 'mpesa')),
              if (type == 'invoice' &&
                  status != 'draft' &&
                  !['cancelled', 'rejected'].contains(status))
                ListTile(
                    leading: const Icon(Icons.receipt_long),
                    title:
                        const Text('Submit through configured eTIMS gateway'),
                    onTap: () => Navigator.pop(context, 'etims')),
              if (type == 'order' || type == 'invoice')
                ListTile(
                    leading: const Icon(Icons.local_shipping_outlined),
                    title: const Text('Manage product delivery'),
                    subtitle: Text(
                        'Delivery: ${item['deliveryStatus'] ?? 'not_required'}'),
                    onTap: () => Navigator.pop(context, 'delivery')),
            ])));
    if (action == null) return;
    final id = item['_id']?.toString();
    if (id == null) return;
    if (action == 'share') {
      await _shareBusinessDocument(id);
      return;
    }
    if (action == 'matching') {
      await _showPaymentMatching(id);
      return;
    }
    if (action == 'delivery') {
      await _manageDocumentDelivery(id, item);
      return;
    }
    try {
      if (action == 'issue') {
        final path =
            '/api/business/organizations/${Uri.encodeComponent(organization!['_id'].toString())}/documents/${Uri.encodeComponent(id)}/status';
        await app.api.call('PATCH', path, {'status': 'sent'});
        await loadWorkspaceData();
      } else {
        await _invoiceIntegration(id, action);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Widget toolsPanel() => ListView(padding: const EdgeInsets.all(12), children: [
        if (app.user?['role']?.toString() == 'admin')
          Card(
              child: ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Platform-wide tax rates'),
            subtitle: const Text(
                'Set the centrally managed tax rate for every matching workspace'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _configureGlobalTaxRates,
          )),
        // Keep the enterprise feature suite visible from the existing Business Tools panel.
        Card(
            child: ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: const Text('Enterprise workspace'),
          subtitle: const Text(
              'Handbook, approvals, customer promises, disputes, projects, incidents and global search'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => BusinessEnterprisePage(
              organizationId: organization!['_id'].toString(),
              organizationName: organization!['name']?.toString() ?? 'Business',
            ),
          )),
        )),
        Card(
            child: ListTile(
                leading: const Icon(Icons.public),
                title: const Text('Tax and currency profile'),
                subtitle:
                    const Text('Configure jurisdiction and tax treatment'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _configureTaxProfile)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.translate),
                title: const Text('Translate business text'),
                subtitle: const Text('Consent-gated AI translation'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _translateBusinessText)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.mic_none),
                title: const Text('Translate voice message'),
                subtitle: const Text(
                    'Transcribe and translate an audio file with consent'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _translateVoice)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.psychology_alt),
                title: const Text('Business Memory suggestions'),
                subtitle: const Text(
                    'Find possible tasks, dates and payment details'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _memorySuggestions)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.mark_chat_unread_outlined),
                title: const Text('Message a customer'),
                subtitle: const Text('WhatsApp / SMS; opt-in required'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _sendCustomerMessage)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text('Scheduled workflow'),
                subtitle:
                    const Text('Create, test and enable an allowed action'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _createScheduledWorkflow)),
        Card(
            child: ListTile(
                leading: const Icon(Icons.sync),
                title: Text('Sync offline records ($pendingOfflineCount)'),
                subtitle: Text(syncConflicts.isEmpty
                    ? 'Queued creates sync when connected'
                    : '${syncConflicts.length} changes need review'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final id = organization!['_id'].toString();
                  final applied = await _flushOfflineQueue(id);
                  if (applied > 0) await loadWorkspaceData(syncPending: false);
                  if (syncConflicts.isNotEmpty && mounted) {
                    await showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                                title: const Text('Sync conflicts'),
                                content: SizedBox(
                                    width: 420,
                                    child: ListView(
                                        shrinkWrap: true,
                                        children: syncConflicts.map((entry) {
                                          final item = jsonDecode(entry) as Map;
                                          final result =
                                              item['result'] as Map? ?? {};
                                          return ListTile(
                                              title: Text(result['status']
                                                      ?.toString() ??
                                                  'Needs review'),
                                              subtitle: Text(result['error']
                                                      ?.toString() ??
                                                  result['reason']
                                                      ?.toString() ??
                                                  'Server record changed; compare versions before retrying.'));
                                        }).toList())),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Close'))
                                ]));
                  }
                })),
      ]);

  Widget metric(String label, dynamic value, IconData icon) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(icon, size: 24),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(value?.toString() ?? '0',
                      style: Theme.of(context).textTheme.titleLarge),
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                ])),
          ]),
        ),
      );

  Widget recordList(List<dynamic> records, String kind, IconData icon) {
    if (records.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No $kind yet. Use Add to create your first record.',
                  textAlign: TextAlign.center)));
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: records.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, index) {
        final item = records[index];
        if (item is! Map) return const SizedBox.shrink();
        final title = item['name']?.toString() ??
            item['title']?.toString() ??
            item['number']?.toString() ??
            kind;
        final details = item['description']?.toString() ??
            item['company']?.toString() ??
            item['status']?.toString() ??
            '';
        final subtitle = item['offlinePending'] == true
            ? [details, 'Saved on this device · waiting to sync']
                .where((value) => value.isNotEmpty)
                .join(' · ')
            : details;
        final amount = item['price'] ?? item['total'];
        return ListTile(
          leading: CircleAvatar(child: Icon(icon)),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle:
              Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: kind == 'tasks' && item['_id'] != null
              ? IconButton(
                  tooltip: 'Delete saved task',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final taskId = item['_id'].toString();
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Delete saved task?'),
                        content: Text('Delete “$title” from this workspace?'),
                        actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('Delete')),
                        ],
                      ),
                    );
                    if (confirmed != true || !mounted) return;
                    try {
                      final orgId = organization?['_id']?.toString();
                      if (orgId == null) return;
                      await app.api.call('DELETE',
                          '/api/business/organizations/${Uri.encodeComponent(orgId)}/tasks/${Uri.encodeComponent(taskId)}');
                      await loadWorkspaceData();
                      if (mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Task deleted.')));
                    } catch (error) {
                      if (mounted)
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('Could not delete task: $error')));
                    }
                  },
                )
              : amount == null
                  ? null
                  : Text('${item['currency'] ?? 'KES'} $amount'),
          onTap: kind == 'sales documents'
              ? () => _showDocumentActions(Map<String, dynamic>.from(item))
              : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null && organizations.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.business_outlined, size: 48),
                const SizedBox(height: 12),
                Text(error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: loadOrganizations, child: const Text('Retry')),
              ])));
    }
    if (organization == null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.storefront_outlined, size: 56),
                const SizedBox(height: 12),
                Text('Turn conversations into business',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text(
                    'Create a workspace to manage customers, products, quotations and follow-ups alongside your conversations.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton.icon(
                    onPressed: createOrganization,
                    icon: const Icon(Icons.add_business),
                    label: const Text('Create business workspace')),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const StoreDirectoryPage())),
                    icon: const Icon(Icons.storefront_outlined),
                    label: const Text('Browse stores and products')),
              ])));
    }
    final metrics = dashboard;
    final compactLayout = MediaQuery.sizeOf(context).width < 600;
    return DefaultTabController(
      length: 5,
      child: Column(children: [
        // Keep the workspace controls compact so the catalogue and customer
        // lists receive most of the available height on mobile screens.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 38,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: organization!['_id']?.toString(),
                    items: organizations
                        .whereType<Map>()
                        .map((item) => DropdownMenuItem<String>(
                              value: item['_id'].toString(),
                              child: Text(
                                item['name']?.toString() ?? 'Business',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (id) async {
                      if (id == null) return;
                      setState(() {
                        organization = organizations
                            .whereType<Map>()
                            .firstWhere((item) => item['_id'].toString() == id)
                            .cast<String, dynamic>();
                        loading = true;
                      });
                      await loadWorkspaceData();
                      if (mounted) setState(() => loading = false);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 2),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const StoreDirectoryPage(),
                        ),
                      ),
                      icon: const Icon(Icons.storefront_outlined, size: 17),
                      label: const Text('Browse stores'),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () {
                        final slug = organization?['slug']?.toString() ?? '';
                        if (slug.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'This workspace has no storefront slug yet.'),
                            ),
                          );
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => StorefrontPage(slug: slug),
                          ),
                        );
                      },
                      icon: const Icon(Icons.storefront_outlined, size: 17),
                      label: const Text('Storefront'),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: saving ? null : _toggleStorefrontPublished,
                      icon: Icon(
                        (organization?['settings'] is Map &&
                                (organization!['settings']
                                        as Map)['storefrontPublished'] ==
                                    false)
                            ? Icons.publish_outlined
                            : Icons.visibility_off_outlined,
                        size: 17,
                      ),
                      label: Text(
                        (organization?['settings'] is Map &&
                                (organization!['settings']
                                        as Map)['storefrontPublished'] ==
                                    false)
                            ? 'Publish'
                            : 'Hide storefront',
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: _configureMpesaNumbers,
                      icon: const Icon(Icons.phone_android, size: 17),
                      label: const Text('M-Pesa'),
                    ),
                    const SizedBox(width: 6),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () {
                        final id = organization?['_id']?.toString();
                        if (id == null) return;
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => MerchantPosPage(
                              organizationId: id,
                              organizationName:
                                  organization?['name']?.toString() ??
                                      'Business',
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.point_of_sale_outlined, size: 17),
                      label: const Text('POS payments'),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: loadOrganizations,
                      icon: const Icon(Icons.refresh, size: 17),
                      label: const Text('Refresh'),
                    ),
                    const SizedBox(width: 6),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: createOrganization,
                      icon: const Icon(Icons.add_business, size: 17),
                      label: const Text('Add workspace'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!compactLayout)
          SizedBox(
            height: 76,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                SizedBox(
                  width: 142,
                  child: metric(
                      'Customers', metrics['customers'], Icons.people_outline),
                ),
                SizedBox(
                  width: 142,
                  child: metric(
                      'Products / services',
                      metrics['activeCatalogItems'],
                      Icons.inventory_2_outlined),
                ),
                SizedBox(
                  width: 142,
                  child: metric(
                      'Open tasks', metrics['openTasks'], Icons.task_alt),
                ),
                SizedBox(
                  width: 142,
                  child: metric('Open cases', metrics['openCases'],
                      Icons.support_agent_outlined),
                ),
              ],
            ),
          ),
        const TabBar(isScrollable: true, tabs: [
          Tab(text: 'Catalogue'),
          Tab(text: 'Customers'),
          Tab(text: 'Sales'),
          Tab(text: 'Tasks'),
          Tab(text: 'Tools'),
        ]),
        Expanded(
            child: TabBarView(children: [
          Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: saving ? null : () => createRecord('catalog'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add product / service'))),
            Expanded(
                child: recordList(catalog, 'products or services',
                    Icons.inventory_2_outlined))
          ]),
          Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: saving ? null : () => createRecord('customer'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add customer'))),
            Expanded(
                child: recordList(customers, 'customers', Icons.person_outline))
          ]),
          Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: saving ? null : () => createRecord('document'),
                    icon: const Icon(Icons.add),
                    label: const Text('Create quotation'))),
            Expanded(
                child: recordList(
                    documents, 'sales documents', Icons.receipt_long_outlined))
          ]),
          Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: saving ? null : () => createRecord('task'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add task / follow-up'))),
            Expanded(child: recordList(tasks, 'tasks', Icons.task_alt))
          ]),
          toolsPanel(),
        ])),
        if (saving) const LinearProgressIndicator(),
        if (error != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child: Text(error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
      ]),
    );
  }
}

// Merchant checkout for shops, supermarkets, malls, hotels and restaurants.
class MerchantPosPage extends StatefulWidget {
  const MerchantPosPage(
      {super.key,
      required this.organizationId,
      required this.organizationName});
  final String organizationId, organizationName;
  @override
  State<MerchantPosPage> createState() => _MerchantPosPageState();
}

class _MerchantPosPageState extends State<MerchantPosPage> {
  AppState get app => context.read<AppState>();
  final till = TextEditingController(),
      paybill = TextEditingController(),
      amount = TextEditingController(),
      description = TextEditingController(),
      reference = TextEditingController(),
      darajaConsumerKey = TextEditingController(),
      darajaConsumerSecret = TextEditingController(),
      darajaPasskey = TextEditingController();
  String method = 'mpesa_till', darajaMode = 'production';
  bool loading = true, saving = false, darajaConfigured = false;
  Map<String, dynamic>? profile;
  List<dynamic> charges = [];
  String? error;
  String get base =>
      '/api/business/organizations/${Uri.encodeComponent(widget.organizationId)}/pos';
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    till.dispose();
    paybill.dispose();
    amount.dispose();
    description.dispose();
    reference.dispose();
    darajaConsumerKey.dispose();
    darajaConsumerSecret.dispose();
    darajaPasskey.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (mounted)
      setState(() {
        loading = true;
        error = null;
      });
    try {
      final r = await Future.wait([
        app.api.call('GET', '$base/payment-profile'),
        app.api.call('GET', '$base/charges')
      ]);
      profile = r[0]['paymentProfile'] is Map
          ? Map<String, dynamic>.from(r[0]['paymentProfile'])
          : null;
      darajaConfigured = r[0]['darajaConfigured'] == true;
      charges = List<dynamic>.from(r[1]['charges'] ?? []);
      if (profile != null) {
        method = profile!['method']?.toString() ?? 'mpesa_till';
        till.text = profile!['tillNumber']?.toString() ?? '';
        paybill.text = profile!['paybillNumber']?.toString() ?? '';
      }
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> saveProfile() async {
    setState(() => saving = true);
    try {
      final body = <String, dynamic>{'method': method};
      if (method == 'mpesa_till') {
        body['tillNumber'] = till.text.trim();
      } else {
        body['paybillNumber'] = paybill.text.trim();
      }
      final hasAnyCredential = darajaConsumerKey.text.trim().isNotEmpty ||
          darajaConsumerSecret.text.trim().isNotEmpty ||
          darajaPasskey.text.trim().isNotEmpty;
      if (hasAnyCredential) {
        if (darajaConsumerKey.text.trim().isEmpty ||
            darajaConsumerSecret.text.trim().isEmpty ||
            darajaPasskey.text.trim().isEmpty) {
          throw Exception(
              'Enter the merchant consumer key, consumer secret and passkey together, or leave all three blank.');
        }
        body.addAll({
          'mode': darajaMode,
          'shortcode':
              method == 'mpesa_till' ? till.text.trim() : paybill.text.trim(),
          'consumerKey': darajaConsumerKey.text.trim(),
          'consumerSecret': darajaConsumerSecret.text.trim(),
          'passkey': darajaPasskey.text.trim()
        });
      }
      final r = await app.api.call('PUT', '$base/payment-profile', body);
      profile = Map<String, dynamic>.from(r['paymentProfile'] ?? body);
      darajaConfigured = r['darajaConfigured'] == true;
      darajaConsumerKey.clear();
      darajaConsumerSecret.clear();
      darajaPasskey.clear();
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Merchant payment instructions saved.')));
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> createCharge() async {
    final n = int.tryParse(amount.text.trim());
    if (n == null || n < 1 || n > 150000 || description.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Enter a description and whole-number amount from KSh 1 to KSh 150,000.')));
      return;
    }
    final accepted = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
              title: const Text('Confirm POS sale amount'),
              content: Text(
                  'Sale amount and customer total: KSh $n\nNo Chatify transaction commission is added. Safaricom charges, if applicable, are separate.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(d, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(d, true),
                    child: const Text('Create payment QR')),
              ],
            ));
    if (accepted != true) return;
    setState(() => saving = true);
    try {
      final r = await app.api.call('POST', '$base/charges', {
        'amount': n,
        'description': description.text.trim(),
        if (reference.text.trim().isNotEmpty)
          'reference': reference.text.trim(),
      });
      amount.clear();
      description.clear();
      reference.clear();
      if (mounted)
        await showCharge(Map<String, dynamic>.from(r['charge'] ?? {}));
      await load();
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> initiateStk(Map<String, dynamic> item, String phone) async {
    if (phone.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter the customer M-Pesa phone number first.')));
      return;
    }
    final baseAmount = (item['baseAmount'] as num?)?.toInt() ??
        (item['amount'] as num?)?.toInt() ??
        0;
    final feeConsent = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
              title: const Text('Confirm customer payment'),
              content: Text(
                  'Sale amount and customer total: KSh $baseAmount\nNo Chatify transaction commission is added. Confirm the customer has reviewed the amount.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(d, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(d, true),
                    child: const Text('Confirm and send STK')),
              ],
            ));
    if (feeConsent != true) return;
    try {
      await app.api.call(
          'POST',
          '$base/charges/${Uri.encodeComponent(item['paymentId'].toString())}/stk',
          {'phone': phone.trim()});
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'STK prompt sent. The sale remains pending until Safaricom confirms payment.')));
      }
      await load();
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> reconcileCharge(Map<String, dynamic> item) async {
    final receipt = TextEditingController();
    bool verified = false;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (d) => StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                title: const Text('Verify M-Pesa receipt'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                      'Sale reference: ${item['reference'] ?? ''} · KSh ${item['amount'] ?? ''}'),
                  TextField(
                      controller: receipt,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                          labelText: 'M-Pesa receipt number')),
                  CheckboxListTile(
                      value: verified,
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                          'I checked the receipt in the official merchant M-Pesa account or statement'),
                      onChanged: (value) =>
                          setDialogState(() => verified = value ?? false)),
                  const Text(
                      'This records a manual finance reconciliation; it does not verify the receipt with Safaricom.',
                      style: TextStyle(fontSize: 12)),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(d, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: verified && receipt.text.trim().isNotEmpty
                          ? () => Navigator.pop(d, true)
                          : null,
                      child: const Text('Record as verified')),
                ],
              ),
            ));
    if (accepted == true) {
      try {
        await app.api.call(
            'POST',
            '$base/charges/${Uri.encodeComponent(item['paymentId'].toString())}/reconcile',
            {
              'receipt': receipt.text.trim().toUpperCase(),
              'verified': verified,
            });
        await load();
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Receipt recorded as manually reconciled.')));
      } catch (e) {
        if (context.mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
    receipt.dispose();
  }

  Future<void> showCharge(Map<String, dynamic> item) async {
    if (item['qrPayload'] == null && item['paymentId'] != null) {
      try {
        final details = await app.api.call('GET',
            '$base/charges/${Uri.encodeComponent(item['paymentId'].toString())}');
        item = Map<String, dynamic>.from(details['charge'] ?? item);
      } catch (e) {
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not load payment QR: $e')));
        return;
      }
    }
    if (!mounted) return;
    final payload = item['qrPayload']?.toString() ?? '';
    final dynamicQrImage = item['dynamicQrImage']?.toString() ?? '';
    final stkPhone = TextEditingController();
    final isSafaricomQr = item['qrProvider'] == 'safaricom_dynamic_qr' &&
        dynamicQrImage.isNotEmpty;
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
              title: const Text('Customer checkout'),
              content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (isSafaricomQr)
                  Image.memory(base64Decode(dynamicQrImage),
                      width: 220,
                      height: 220,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Text(
                          'Could not display the M-Pesa QR image. Refresh and try again.'))
                else if (payload.isNotEmpty)
                  QrImageView(
                      data: payload,
                      version: QrVersions.auto,
                      size: 220,
                      backgroundColor: Colors.white),
                Text(widget.organizationName,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
                Text('Customer total: KSh ${item['amount'] ?? ''}',
                    style: Theme.of(context).textTheme.headlineSmall),
                Text('Sale amount: KSh ${item['amount'] ?? ''}',
                    textAlign: TextAlign.center),
                const Text(
                    'No Chatify transaction commission is added. Safaricom charges, if applicable, are separate.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12)),
                Text(item['description']?.toString() ?? ''),
                SelectableText('Reference: ${item['reference'] ?? ''}'),
                Text('Status: ${item['status'] ?? 'PENDING'}'),
                const SizedBox(height: 8),
                Text(
                    isSafaricomQr
                        ? 'Scan this Safaricom Dynamic QR with the M-Pesa app to pay the merchant. The sale remains pending until the provider callback confirms the matching transaction.'
                        : 'Demo/instruction QR only. Customer scans with Chatify to view the merchant details, then pays in M-Pesa. This does not confirm payment.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12)),
                if (!isSafaricomQr)
                  TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: payload));
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy QR payload')),
                const Divider(height: 24),
                TextField(
                    controller: stkPhone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: 'Customer M-Pesa phone',
                        hintText: '0712345678 or 254712345678')),
                const SizedBox(height: 6),
                Text(
                    darajaConfigured
                        ? 'STK uses this merchant\'s own authorized Daraja shortcode.'
                        : 'Configure authorized merchant Daraja credentials to enable direct STK Push.',
                    style: const TextStyle(fontSize: 12)),
              ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(d),
                    child: const Text('Close')),
                FilledButton.icon(
                    onPressed: saving || !darajaConfigured
                        ? null
                        : () => initiateStk(item, stkPhone.text),
                    icon: const Icon(Icons.phone_android),
                    label: const Text('Send STK Push')),
              ],
            ));
    stkPhone.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
        appBar: AppBar(title: const Text('In-person POS payments'), actions: [
          IconButton(onPressed: load, icon: const Icon(Icons.refresh))
        ]),
        body: RefreshIndicator(
            onRefresh: load,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text(widget.organizationName,
                  style: Theme.of(context).textTheme.headlineSmall),
              const Text(
                  'Create cashier checkout requests for retail purchases, restaurant bills, hotel stays and other sales.'),
              if (error != null)
                Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Merchant payment destination',
                                style: Theme.of(context).textTheme.titleLarge),
                            DropdownButtonFormField<String>(
                                initialValue: method,
                                decoration:
                                    const InputDecoration(labelText: 'Method'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'mpesa_till',
                                      child: Text('M-Pesa Buy Goods / Till')),
                                  DropdownMenuItem(
                                      value: 'mpesa_paybill',
                                      child: Text('M-Pesa Paybill')),
                                ],
                                onChanged: saving
                                    ? null
                                    : (v) {
                                        if (v != null)
                                          setState(() => method = v);
                                      }),
                            if (method == 'mpesa_till')
                              TextField(
                                  controller: till,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: 'Merchant Till number')),
                            if (method == 'mpesa_paybill') ...[
                              TextField(
                                  controller: paybill,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: 'Merchant Paybill number')),
                            ],
                            const SizedBox(height: 8),
                            const SizedBox(height: 12),
                            Text('Merchant Daraja authorization',
                                style: Theme.of(context).textTheme.titleMedium),
                            DropdownButtonFormField<String>(
                                initialValue: darajaMode,
                                decoration: const InputDecoration(
                                    labelText: 'Daraja environment'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'sandbox',
                                      child: Text('Sandbox / testing')),
                                  DropdownMenuItem(
                                      value: 'production',
                                      child:
                                          Text('Production / live payments')),
                                ],
                                onChanged: saving
                                    ? null
                                    : (v) {
                                        if (v != null)
                                          setState(() => darajaMode = v);
                                      }),
                            TextField(
                                controller: darajaConsumerKey,
                                obscureText: true,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: const InputDecoration(
                                    labelText:
                                        'Merchant Daraja consumer key (optional)')),
                            TextField(
                                controller: darajaConsumerSecret,
                                obscureText: true,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: const InputDecoration(
                                    labelText:
                                        'Merchant Daraja consumer secret (optional)')),
                            TextField(
                                controller: darajaPasskey,
                                obscureText: true,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: const InputDecoration(
                                    labelText:
                                        'Merchant STK passkey (optional)')),
                            const SizedBox(height: 6),
                            Text(
                                darajaConfigured
                                    ? 'Authorized merchant credentials are stored encrypted. Leave secret fields blank to keep the existing credentials.'
                                    : 'Enter all three secrets from the merchant\'s authorized Daraja app. The shortcode must match the Till or Paybill above.',
                                style: const TextStyle(fontSize: 12)),
                            FilledButton.icon(
                                onPressed: saving ? null : saveProfile,
                                icon: const Icon(Icons.lock_outline),
                                label: const Text(
                                    'Save destination and secure credentials')),
                          ]))),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Create checkout',
                                style: Theme.of(context).textTheme.titleLarge),
                            TextField(
                                controller: description,
                                decoration: const InputDecoration(
                                    labelText: 'Purchase / bill description',
                                    hintText:
                                        'Groceries, dinner, room deposit…')),
                            TextField(
                                controller: amount,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                    labelText: 'Amount (KES)',
                                    prefixText: 'KSh ')),
                            TextField(
                                controller: reference,
                                decoration: const InputDecoration(
                                    labelText:
                                        'Optional order / table / room reference')),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                                onPressed: saving || profile == null
                                    ? null
                                    : createCharge,
                                icon: const Icon(Icons.qr_code_2),
                                label: const Text('Create payment QR')),
                            if (profile == null)
                              const Text(
                                  'Save your payment destination before creating a checkout.',
                                  style: TextStyle(fontSize: 12)),
                          ]))),
              Text('Recent payment requests',
                  style: Theme.of(context).textTheme.titleLarge),
              if (charges.isEmpty) const Text('No POS payment requests yet.'),
              ...charges.map((raw) {
                final item = Map<String, dynamic>.from(raw as Map);
                final st =
                    (item['status']?.toString() ?? 'PENDING').toUpperCase();
                final source = item['confirmationSource']?.toString() ?? '';
                final receipt = item['providerReceipt']?.toString() ?? '';
                final subtitle =
                    '${item['reference'] ?? ''} · $st\n${item['createdAt'] ?? ''}'
                    '${receipt.isNotEmpty ? '\nReceipt: $receipt' : ''}'
                    '${source == 'manual_merchant_reconciliation' ? '\nManually verified by merchant' : source == 'safaricom_c2b' ? '\nConfirmed by Safaricom C2B' : ''}';
                return Card(
                    child: ListTile(
                  leading: Icon(st == 'SUCCESS'
                      ? Icons.check_circle
                      : st == 'FAILED'
                          ? Icons.error_outline
                          : Icons.hourglass_top),
                  title: Text(
                      'KSh ${item['amount'] ?? ''} · ${item['description'] ?? 'Sale'}'),
                  subtitle: Text(subtitle),
                  isThreeLine: true,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                        tooltip: 'Show payment QR',
                        icon: const Icon(Icons.qr_code_2),
                        onPressed: () => showCharge(item)),
                    if (st == 'PENDING')
                      IconButton(
                          tooltip: 'Record receipt after official verification',
                          icon: const Icon(Icons.fact_check_outlined),
                          onPressed: () => reconcileCharge(item)),
                  ]),
                ));
              }),
              const Text(
                  'Do not release goods or close a bill based on a QR scan or screenshot. Wait for independently verified payment confirmation.',
                  style: TextStyle(fontSize: 12)),
            ])));
  }
}

// Customer scans the Chatify checkout QR and reads the payment destination.
class MerchantQrScannerPage extends StatefulWidget {
  const MerchantQrScannerPage({super.key});
  @override
  State<MerchantQrScannerPage> createState() => _MerchantQrScannerPageState();
}

class _MerchantQrScannerPageState extends State<MerchantQrScannerPage> {
  Map<String, dynamic>? charge;
  String? error;
  bool handled = false;
  void onDetect(BarcodeCapture capture) {
    if (handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final d = jsonDecode(raw);
        if (d is! Map ||
            d['type'] != 'chatify_pos_payment' ||
            d['currency'] != 'KES' ||
            d['paymentId'] == null ||
            d['reference'] == null ||
            d['amount'] is! num ||
            d['amount'] < 1 ||
            d['amount'] > 150000) {
          throw const FormatException('Invalid Chatify merchant payment QR.');
        }
        handled = true;
        if (mounted)
          setState(() {
            charge = Map<String, dynamic>.from(d);
            error = null;
          });
        return;
      } catch (_) {
        handled = true;
        if (mounted)
          setState(() => error =
              'This may be a Safaricom Dynamic QR. Scan that QR with the M-Pesa app; Chatify reads its own checkout-instruction QR only.');
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = charge;
    final dest = c == null
        ? ''
        : c['method'] == 'mpesa_till'
            ? 'M-Pesa Till: ${c['tillNumber'] ?? ''}'
            : 'M-Pesa Paybill: ${c['paybillNumber'] ?? ''}\nAccount/reference: ${c['accountNumber'] ?? ''}';
    return Scaffold(
        appBar: AppBar(title: const Text('Pay a merchant')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (c == null) ...[
            const Text(
                'Scan the cashier’s Chatify QR and verify the merchant and amount.'),
            SizedBox(
                height: 320,
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: MobileScanner(onDetect: onDetect))),
            if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            OutlinedButton.icon(
                onPressed: () => setState(() {
                      handled = false;
                      error = null;
                    }),
                icon: const Icon(Icons.refresh),
                label: const Text('Scan again')),
          ] else
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Icon(Icons.storefront, size: 48),
                          Text(c['merchantName']?.toString() ?? 'Merchant',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.headlineSmall),
                          Text('KSh ${c['amount']}',
                              textAlign: TextAlign.center,
                              style:
                                  Theme.of(context).textTheme.headlineMedium),
                          Text(c['description']?.toString() ?? 'Purchase',
                              textAlign: TextAlign.center),
                          const Divider(height: 24),
                          SelectableText(dest),
                          SelectableText('Reference: ${c['reference']}'),
                          const SizedBox(height: 12),
                          const Text(
                              'Open M-Pesa and use Buy Goods or Paybill. Enter the exact merchant details and verify the amount before confirming. Scanning this QR does not transfer money or prove payment.',
                              style: TextStyle(fontSize: 13)),
                          FilledButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(
                                    ClipboardData(text: dest));
                              },
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy payment details')),
                          OutlinedButton.icon(
                              onPressed: () => setState(() {
                                    charge = null;
                                    handled = false;
                                    error = null;
                                  }),
                              icon: const Icon(Icons.qr_code_scanner),
                              label: const Text('Scan another payment')),
                        ]))),
        ]));
  }
}

// A single, permission-aware screen exposes the enterprise APIs without duplicating business data.
// Every operation is scoped by the selected organization ID and re-authorized by the server.
class BusinessEnterprisePage extends StatefulWidget {
  const BusinessEnterprisePage(
      {super.key,
      required this.organizationId,
      required this.organizationName});
  final String organizationId;
  final String organizationName;

  @override
  State<BusinessEnterprisePage> createState() => _BusinessEnterprisePageState();
}

class _BusinessEnterprisePageState extends State<BusinessEnterprisePage> {
  Map<String, dynamic> overview = {}, readiness = {}, usage = {}, settings = {};
  List<dynamic> records = [], searchResults = [];
  bool loading = true, saving = false, searching = false;
  String typeFilter = 'all';
  String query = '';
  String? error;
  AppState get app => context.read<AppState>();
  String get base =>
      '/api/business/organizations/${Uri.encodeComponent(widget.organizationId)}/enterprise';

  static const recordTypes = <String, String>{
    'handbook': 'Company handbook / procedure',
    'notification': 'Team notification',
    'approval': 'Approval request',
    'refund_case': 'Refund case',
    'credit_profile': 'Customer credit profile',
    'project_room': 'Customer project room',
    'supplier_quote': 'Supplier quotation',
    'service_policy': 'Service guarantee / policy',
    'delivery_proof': 'Delivery / collection proof',
    'dispute': 'Dispute resolution',
    'consent_record': 'Consent record',
    'support_case': 'Support / complaint case',
    'incident': 'Incident report',
    'integration': 'Integration record',
    'migration_job': 'Data import / migration',
    'recovery_plan': 'Recovery plan',
    'promise': 'Customer / supplier promise',
    'response_target': 'Response-time target',
    'subscription_note': 'Subscription / billing note',
    'financial_close': 'Financial period close',
    'supplier_comparison': 'Supplier comparison',
    'customer_portal': 'Customer self-service portal',
    'reputation_review': 'Transaction-linked review',
    'service_recovery': 'Service recovery plan',
  };

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final results = await Future.wait([
        app.api.call('GET', '$base/overview'),
        app.api.call('GET', '$base/records?limit=100'),
        app.api.call('GET', '$base/readiness'),
        app.api.call('GET', '$base/usage'),
        app.api.call('GET', '$base/settings'),
      ]);
      overview = Map<String, dynamic>.from(results[0]);
      records = List<dynamic>.from(results[1]['records'] ?? []);
      readiness = Map<String, dynamic>.from(results[2]);
      usage = Map<String, dynamic>.from(results[3]);
      settings = Map<String, dynamic>.from(results[4]);
      if (mounted) setState(() {});
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  List<dynamic> get visibleRecords {
    final q = query.trim().toLowerCase();
    return records.where((item) {
      if (item is! Map) return false;
      if (typeFilter != 'all' && item['type'] != typeFilter) return false;
      if (q.isEmpty) return true;
      return '${item['title'] ?? ''} ${item['description'] ?? ''} ${item['status'] ?? ''}'
          .toLowerCase()
          .contains(q);
    }).toList();
  }

  Future<void> searchAll() async {
    final q = query.trim();
    if (q.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Enter at least two characters to search all business records.')));
      }
      return;
    }
    setState(() => searching = true);
    try {
      final response = await app.api.call('GET',
          '/api/business/organizations/${Uri.encodeComponent(widget.organizationId)}/search?q=${Uri.encodeQueryComponent(q)}');
      searchResults = List<dynamic>.from(response['results'] ?? []);
      if (mounted) setState(() {});
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Search results for "$q"'),
          content: SizedBox(
            width: 480,
            child: searchResults.isEmpty
                ? const Text(
                    'No matching customers, products, invoices, tasks or enterprise records found in this workspace.')
                : ListView(
                    shrinkWrap: true,
                    children: searchResults
                        .map((item) => ListTile(
                              leading: const Icon(Icons.search),
                              title: Text(item['title']?.toString() ??
                                  'Business record'),
                              subtitle: Text(
                                  '${item['type'] ?? 'record'} · ${item['status'] ?? item['subtitle'] ?? ''}'),
                            ))
                        .toList(),
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'))
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> configureEnterpriseSettings() async {
    final targets = settings['serviceTargets'] is Map
        ? Map<String, dynamic>.from(settings['serviceTargets'])
        : <String, dynamic>{};
    final credit = settings['creditPolicy'] is Map
        ? Map<String, dynamic>.from(settings['creditPolicy'])
        : <String, dynamic>{};
    final firstResponse = TextEditingController(
        text: (targets['firstResponseMinutes'] ?? 15).toString());
    final escalation = TextEditingController(
        text: (targets['escalationMinutes'] ?? 60).toString());
    final terms = TextEditingController(
        text: (credit['defaultTermsDays'] ?? 0).toString());
    final threshold = TextEditingController(
        text: (credit['approvalRequiredAbove'] ?? 0).toString());
    final creditEnabled = ValueNotifier<bool>(credit['enabled'] == true);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Service and credit controls'),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: firstResponse,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'First response target (minutes)')),
          TextField(
              controller: escalation,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Escalation target (minutes)')),
          const Divider(height: 24),
          ValueListenableBuilder<bool>(
              valueListenable: creditEnabled,
              builder: (_, value, __) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable customer credit policy'),
                    value: value,
                    onChanged: (next) => creditEnabled.value = next,
                  )),
          TextField(
              controller: terms,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Default payment terms (days, 0–365)')),
          TextField(
              controller: threshold,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText:
                      'Require approval above (amount, 0 disables threshold)')),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save controls')),
        ],
      ),
    );
    if (accepted != true) return;
    final first = int.tryParse(firstResponse.text) ?? 0;
    final escalate = int.tryParse(escalation.text) ?? 0;
    final termsDays = int.tryParse(terms.text) ?? -1;
    final approvalAmount = double.tryParse(threshold.text) ?? -1;
    if (first < 1 ||
        escalate < first ||
        termsDays < 0 ||
        termsDays > 365 ||
        approvalAmount < 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Check the response targets, credit terms and approval threshold.')));
      }
      return;
    }
    setState(() => saving = true);
    try {
      await app.api.call('PATCH', '$base/settings', {
        'serviceTargets': {
          'firstResponseMinutes': first,
          'escalationMinutes': escalate
        },
        'creditPolicy': {
          'enabled': creditEnabled.value,
          'defaultTermsDays': termsDays,
          'approvalRequiredAbove': approvalAmount
        },
      });
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Service and credit settings saved.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> downloadBusinessArchive() async {
    setState(() => saving = true);
    try {
      final token = app.api.token;
      if (token == null || token.isEmpty) {
        throw Exception('Sign in again before exporting business records.');
      }
      final orgId = Uri.encodeComponent(widget.organizationId);
      final uri =
          Uri.parse('${app.api.base}/api/business/organizations/$orgId/export');
      final response = await app.api.client.get(uri, headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json'
      });
      if (response.statusCode != 200) {
        throw Exception(
            'Business archive export failed with status ${response.statusCode}. Manager permissions may be required.');
      }
      await FileSaver.instance.saveFile(
        name: 'chatify-business-archive',
        bytes: response.bodyBytes,
        fileExtension: 'json',
        mimeType: MimeType.json,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Full business archive exported. Keep it in a secure location.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> downloadEnterpriseExport() async {
    setState(() => saving = true);
    try {
      final token = app.api.token;
      if (token == null || token.isEmpty) {
        throw Exception('Sign in again before exporting business records.');
      }
      final uri = Uri.parse('${app.api.base}$base/export');
      final response = await app.api.client.get(uri,
          headers: {'Authorization': 'Bearer $token', 'Accept': 'text/csv'});
      if (response.statusCode != 200) {
        throw Exception(
            'Export failed with status ${response.statusCode}. Check your finance or manager permissions.');
      }
      await FileSaver.instance.saveFile(
        name: 'chatify-business-records',
        bytes: response.bodyBytes,
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Business records CSV exported.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> closeFinancialPeriod() async {
    final now = DateTime.now();
    final startDate = TextEditingController(
        text: DateTime(now.year, now.month, 1)
            .toIso8601String()
            .substring(0, 10));
    final endDate = TextEditingController(
        text: now
            .add(const Duration(days: 1))
            .toIso8601String()
            .substring(0, 10));
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Close financial period'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'Creates an immutable snapshot of invoices created between the start date and the exclusive end date.'),
          TextField(
              controller: startDate,
              decoration:
                  const InputDecoration(labelText: 'Start date (YYYY-MM-DD)')),
          TextField(
              controller: endDate,
              decoration: const InputDecoration(
                  labelText: 'End date, exclusive (YYYY-MM-DD)')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Close period')),
        ],
      ),
    );
    if (accepted != true) return;
    final start = DateTime.tryParse(startDate.text.trim());
    final end = DateTime.tryParse(endDate.text.trim());
    if (start == null || end == null || !start.isBefore(end)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Enter valid dates; the end date must be after the start date.')));
      }
      return;
    }
    setState(() => saving = true);
    try {
      final result =
          await app.api.call('POST', '$base/financial-periods/close', {
        'periodStart': '${startDate.text.trim()}T00:00:00.000Z',
        'periodEnd': '${endDate.text.trim()}T00:00:00.000Z',
      });
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['notice']?.toString() ??
                'Financial period snapshot created.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> createRecord() async {
    final title = TextEditingController();
    final description = TextEditingController();
    final type = ValueNotifier<String>('handbook');
    final priority = ValueNotifier<String>('normal');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create enterprise record'),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          ValueListenableBuilder<String>(
              valueListenable: type,
              builder: (_, value, __) => DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: value,
                    decoration: const InputDecoration(labelText: 'Record type'),
                    items: recordTypes.entries
                        .where((entry) => entry.key != 'financial_close')
                        .map((entry) => DropdownMenuItem(
                            value: entry.key, child: Text(entry.value)))
                        .toList(),
                    onChanged: (next) {
                      if (next != null) type.value = next;
                    },
                  )),
          const SizedBox(height: 8),
          TextField(
              controller: title,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Title')),
          TextField(
              controller: description,
              maxLines: 3,
              maxLength: 6000,
              decoration: const InputDecoration(labelText: 'Details / reason')),
          ValueListenableBuilder<String>(
              valueListenable: priority,
              builder: (_, value, __) => DropdownButtonFormField<String>(
                    initialValue: value,
                    decoration: const InputDecoration(labelText: 'Priority'),
                    items: const [
                      DropdownMenuItem(value: 'low', child: Text('Low')),
                      DropdownMenuItem(value: 'normal', child: Text('Normal')),
                      DropdownMenuItem(value: 'high', child: Text('High')),
                      DropdownMenuItem(value: 'urgent', child: Text('Urgent')),
                    ],
                    onChanged: (next) {
                      if (next != null) priority.value = next;
                    },
                  )),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (accepted != true || title.text.trim().isEmpty) return;
    setState(() => saving = true);
    try {
      await app.api.call('POST', '$base/records', {
        'type': type.value,
        'title': title.text.trim(),
        'description': description.text.trim(),
        'priority': priority.value,
      });
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enterprise record created.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> createCustomerShare(Map<String, dynamic> item) async {
    try {
      final result = await app.api.call('POST', '$base/shares', {
        'entityType': 'enterprise_record',
        'entityId': item['_id']?.toString() ?? '',
        'expiresInHours': 72,
      });
      final path = result['path']?.toString() ?? '';
      if (path.isEmpty || !mounted) return;
      final link = Uri.parse(app.api.base).resolve(path).toString();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Secure customer link'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'This link expires in 72 hours. Share it only with the intended customer.'),
                const SizedBox(height: 8),
                SelectableText(link),
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close')),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Customer link copied.')));
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy link'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> runAction(Map<String, dynamic> item, String action) async {
    final id = Uri.encodeComponent(item['_id']?.toString() ?? '');
    if (id.isEmpty) return;
    try {
      if (action == 'acknowledge') {
        await app.api.call('POST', '$base/records/$id/acknowledge', {});
      } else if (action == 'approve' || action == 'reject') {
        final reason = TextEditingController();
        if (action == 'reject') {
          final accepted = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                    title: const Text('Reason for rejection'),
                    content: TextField(
                        controller: reason,
                        maxLines: 3,
                        decoration: const InputDecoration(
                            labelText: 'Required reason')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Reject request')),
                    ],
                  ));
          if (accepted != true || reason.text.trim().isEmpty) return;
        }
        await app.api.call('POST', '$base/records/$id/decision', {
          'decision': action == 'approve' ? 'approved' : 'rejected',
          'reason': reason.text.trim()
        });
      } else {
        await app.api.call('POST', '$base/records/$id/resolve',
            {'resolution': 'Resolved from Chatify Business'});
      }
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = overview['counts'] is Map
        ? Map<String, dynamic>.from(overview['counts'])
        : <String, dynamic>{};
    final business = overview['business'] is Map
        ? Map<String, dynamic>.from(overview['business'])
        : <String, dynamic>{};
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.organizationName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              tooltip: 'Refresh enterprise workspace',
              onPressed: load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: saving ? null : createRecord,
        icon: const Icon(Icons.add),
        label: const Text('Add record'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: load, child: const Text('Retry')),
                      ])))
              : RefreshIndicator(
                  onRefresh: load,
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                      children: [
                        Text('Business command centre',
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(
                            'Overview, accountability and follow-up records for this workspace. Sensitive actions are checked by the server.'),
                        const SizedBox(height: 12),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          _enterpriseMetric('Customers',
                              business['customers'] ?? 0, Icons.people_outline),
                          _enterpriseMetric(
                              'Active products',
                              business['activeCatalogItems'] ?? 0,
                              Icons.inventory_2_outlined),
                          _enterpriseMetric('Open tasks',
                              business['openTasks'] ?? 0, Icons.task_alt),
                          _enterpriseMetric(
                              'Open cases',
                              business['openCases'] ?? 0,
                              Icons.support_agent_outlined),
                          _enterpriseMetric(
                              'Overdue records',
                              overview['overdueEnterpriseRecords'] ?? 0,
                              Icons.warning_amber_outlined),
                        ]),
                        const SizedBox(height: 16),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      'Setup readiness: ${readiness['complete'] ?? 0}/${readiness['total'] ?? 0}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const SizedBox(height: 8),
                                  for (final check
                                      in (readiness['checks'] as List? ??
                                              const [])
                                          .whereType<Map>())
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(check['complete'] == true
                                          ? Icons.check_circle_outline
                                          : Icons.radio_button_unchecked),
                                      title: Text(check['label']?.toString() ??
                                          'Setup step'),
                                      trailing: Text(check['complete'] == true
                                          ? 'Ready'
                                          : 'Incomplete'),
                                    ),
                                ]),
                          ),
                        ),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Plan and usage',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  Text(
                                      'Plan: ${usage['plan'] ?? settings['plan'] ?? 'free'}'),
                                  Text(
                                      'Staff: ${(usage['usage'] as Map?)?['members'] ?? 1} · Customers: ${(usage['usage'] as Map?)?['customers'] ?? 0} · Catalogue items: ${(usage['usage'] as Map?)?['catalogItems'] ?? 0}'),
                                  Text(
                                      'Response target: ${(settings['serviceTargets'] as Map?)?['firstResponseMinutes'] ?? 15} minutes · Escalation: ${(settings['serviceTargets'] as Map?)?['escalationMinutes'] ?? 60} minutes'),
                                  Text(
                                      'Credit policy: ${(settings['creditPolicy'] as Map?)?['enabled'] == true ? 'Enabled' : 'Disabled'}'),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: saving
                                          ? null
                                          : configureEnterpriseSettings,
                                      icon: const Icon(Icons.tune),
                                      label: const Text(
                                          'Configure response and credit controls'),
                                    ),
                                  ),
                                ]),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text('Enterprise modules',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final entry in recordTypes.entries)
                            Chip(
                                avatar: const Icon(Icons.checklist, size: 16),
                                label: Text(
                                    '${entry.value}: ${counts[entry.key] ?? 0}')),
                        ]),
                        const SizedBox(height: 16),
                        TextField(
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            labelText: 'Search business records',
                            helperText:
                                'Type to filter this list, or use the search icon for customers, products, invoices, tasks and cases.',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: 'Search all business data',
                              onPressed: searching ? null : searchAll,
                              icon: searching
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.manage_search),
                            ),
                          ),
                          onChanged: (value) => setState(() => query = value),
                          onSubmitted: (_) => searchAll(),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: typeFilter,
                          decoration: const InputDecoration(
                              labelText: 'Filter by module',
                              border: OutlineInputBorder()),
                          items: [
                            const DropdownMenuItem(
                                value: 'all',
                                child: Text('All enterprise records')),
                            ...recordTypes.entries.map((entry) =>
                                DropdownMenuItem(
                                    value: entry.key,
                                    child: Text(entry.value))),
                          ],
                          onChanged: (value) =>
                              setState(() => typeFilter = value ?? 'all'),
                        ),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(
                              child: Text('Records (${visibleRecords.length})',
                                  style:
                                      Theme.of(context).textTheme.titleMedium)),
                          TextButton.icon(
                            onPressed: saving ? null : downloadEnterpriseExport,
                            icon: const Icon(Icons.file_download_outlined),
                            label: const Text('Export CSV'),
                          ),
                        ]),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: saving ? null : closeFinancialPeriod,
                            icon: const Icon(Icons.lock_clock_outlined),
                            label: const Text('Close financial period'),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: saving ? null : downloadBusinessArchive,
                            icon: const Icon(Icons.backup_outlined),
                            label: const Text(
                                'Export full business archive (JSON)'),
                          ),
                        ),
                        if (visibleRecords.isEmpty)
                          const Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                  'No matching records yet. Add a handbook, approval request, project room, promise, support case or other enterprise record.',
                                  textAlign: TextAlign.center)),
                        for (final item in visibleRecords.whereType<Map>())
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: CircleAvatar(
                                          child: Icon(item['priority'] ==
                                                  'urgent'
                                              ? Icons.priority_high
                                              : Icons
                                                  .business_center_outlined)),
                                      title: Text(item['title']?.toString() ??
                                          'Business record'),
                                      subtitle: Text(
                                          _enterpriseRecordSubtitle(
                                              Map<String, dynamic>.from(item)),
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis),
                                    ),
                                    Wrap(spacing: 8, children: [
                                      if (item['type'] == 'handbook' ||
                                          item['type'] == 'service_policy')
                                        OutlinedButton.icon(
                                            onPressed: () => runAction(
                                                Map<String, dynamic>.from(item),
                                                'acknowledge'),
                                            icon: const Icon(
                                                Icons.fact_check_outlined),
                                            label: const Text('Acknowledge')),
                                      if ([
                                        'project_room',
                                        'customer_portal',
                                        'service_policy',
                                        'delivery_proof'
                                      ].contains(item['type']))
                                        OutlinedButton.icon(
                                          onPressed: () => createCustomerShare(
                                              Map<String, dynamic>.from(item)),
                                          icon: const Icon(Icons.link),
                                          label:
                                              const Text('Share with customer'),
                                        ),
                                      if (item['status'] == 'pending' &&
                                          [
                                            'approval',
                                            'refund_case',
                                            'credit_profile',
                                            'dispute'
                                          ].contains(item['type'])) ...[
                                        OutlinedButton.icon(
                                            onPressed: () => runAction(
                                                Map<String, dynamic>.from(item),
                                                'reject'),
                                            icon: const Icon(Icons.close),
                                            label: const Text('Reject')),
                                        FilledButton.tonalIcon(
                                            onPressed: () => runAction(
                                                Map<String, dynamic>.from(item),
                                                'approve'),
                                            icon: const Icon(Icons.check),
                                            label: const Text('Approve')),
                                      ],
                                      if (![
                                        'closed',
                                        'cancelled',
                                        'resolved',
                                        'approved',
                                        'rejected'
                                      ].contains(item['status']))
                                        TextButton.icon(
                                            onPressed: () => runAction(
                                                Map<String, dynamic>.from(item),
                                                'resolve'),
                                            icon: const Icon(Icons.done_all),
                                            label: const Text('Resolve')),
                                    ]),
                                  ]),
                            ),
                          ),
                        const SizedBox(height: 16),
                        Text('Payment and security reminder',
                            style: Theme.of(context).textTheme.titleMedium),
                        const Text(
                            'A payment screenshot, manually typed reference or accepted checkout request is not proof of receipt. Only verified provider callbacks or authorized reconciliation can confirm money received.'),
                      ]),
                ),
    );
  }

  String _enterpriseRecordSubtitle(Map<String, dynamic> item) {
    final type = item['type']?.toString() ?? '';
    final status = item['status']?.toString() ?? 'open';
    final priority = item['priority']?.toString() ?? 'normal';
    final description = item['description']?.toString() ?? '';
    if (type == 'financial_close' && item['payload'] is Map) {
      final payload = Map<String, dynamic>.from(item['payload'] as Map);
      final org = overview['organization'] is Map
          ? Map<String, dynamic>.from(overview['organization'])
          : <String, dynamic>{};
      final currency = org['currency']?.toString() ?? 'KES';
      return 'Closed snapshot · ${payload['invoiceCount'] ?? 0} invoices\n'
          'Invoiced: $currency ${payload['invoicedTotal'] ?? 0} · Verified receipts in period: $currency ${payload['confirmedPaidTotal'] ?? 0}\n'
          'Outstanding at period end: $currency ${payload['outstandingTotal'] ?? 0}';
    }
    return '${recordTypes[type] ?? type} · $status · $priority\n$description';
  }

  Widget _enterpriseMetric(String label, dynamic value, IconData icon) =>
      SizedBox(
        width: 150,
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Icon(icon, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(value.toString(),
                            style: Theme.of(context).textTheme.titleLarge),
                        Text(label,
                            style: Theme.of(context).textTheme.bodySmall),
                      ])),
                ]))),
      );
}
