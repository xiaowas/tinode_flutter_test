import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Media bytes stay in Android's private cache; only metadata crosses the channel.
class ChatMedia extends ChangeNotifier {
  static const channel = MethodChannel('tinode/media');
  final events = StreamController<Map<dynamic, dynamic>>.broadcast();
  final Map<String, double> progress = {};
  final Map<String, Future<String>> _files = {};
  String? playing;
  bool _disposed = false;

  bool handleEvent(Map<dynamic, dynamic> event) {
    final type = event['type'];
    if (!['upload', 'playback', 'recordingLimit', 'recordingCancelled'].contains(type)) return false;
    if (type == 'upload') {
      final size = (event['size'] as num?)?.toDouble() ?? 0;
      progress[event['id'].toString()] = size > 0 ? ((event['sent'] as num) / size).clamp(0, 1).toDouble() : 0;
    } else if (type == 'playback' && event['id'] == playing) {
      playing = null;
    }
    events.add(event);
    notifyListeners();
    return true;
  }

  Future<String> resolve(Map<String, dynamic> attachment) {
    final local = attachment['path'];
    if (local is String) return Future.value(local);
    final key = '${attachment['ref'] ?? attachment['val']}';
    return _files.putIfAbsent(key, () async {
      try {
        return (await channel.invokeMethod<String>('resolve', {'attachment': attachment}))!;
      } catch (_) {
        _files.remove(key);
        rethrow;
      }
    });
  }

  Future<void> play(Map<String, dynamic> attachment, String id) async {
    if (playing == id) {
      await channel.invokeMethod<void>('stopPlayback');
      playing = null;
    } else {
      final path = await resolve(attachment);
      if (_disposed) return;
      await channel.invokeMethod<void>('play', {'path': path, 'id': id});
      playing = id;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> open(Map<String, dynamic> attachment) async {
    final path = await resolve(attachment);
    await channel.invokeMethod<void>('open', {'path': path, 'mime': attachment['mime']});
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(channel.invokeMethod<void>('stopPlayback').catchError((Object _) {}));
    events.close();
    super.dispose();
  }
}

String mediaSize(dynamic bytes) {
  final n = (bytes as num?)?.toDouble() ?? 0;
  return n >= 1024 * 1024 ? '${(n / 1024 / 1024).toStringAsFixed(1)} MB' : '${(n / 1024).toStringAsFixed(1)} KB';
}
String mediaDuration(dynamic millis) {
  final seconds = ((millis as num?)?.toInt() ?? 0) ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
String mediaError(Object error) => error is PlatformException ? (error.message ?? error.code) : '附件操作失败，请重试';

class AttachmentView extends StatefulWidget {
  const AttachmentView({super.key, required this.attachment, required this.media});
  final Map<String, dynamic> attachment;
  final ChatMedia media;
  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  Future<String>? _image;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    if (widget.attachment['kind'] == 'IM') _image = widget.media.resolve(widget.attachment);
  }
  @override
  void didUpdateWidget(covariant AttachmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment['ref'] != widget.attachment['ref'] || oldWidget.attachment['val'] != widget.attachment['val']) {
      _image = widget.attachment['kind'] == 'IM' ? widget.media.resolve(widget.attachment) : null;
    }
  }
  Future<void> _action() async {
    setState(() => _busy = true);
    try {
      if (widget.attachment['kind'] == 'AU') {
        await widget.media.play(widget.attachment, '${widget.attachment['ref'] ?? widget.attachment['path'] ?? widget.attachment['val']}');
      } else {
        await widget.media.open(widget.attachment);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mediaError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    if (a['kind'] == 'IM') {
      return FutureBuilder<String>(
        future: _image,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return TextButton.icon(onPressed: () => setState(() => _image = widget.media.resolve(a)),
                icon: const Icon(Icons.refresh), label: const Text('图片加载失败，点击重试'));
          }
          if (!snapshot.hasData) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
          final path = snapshot.data!;
          return InkWell(
            onTap: () => showDialog<void>(context: context, builder: (context) => Dialog(
              child: Stack(children: [
                InteractiveViewer(child: Image.file(File(path), fit: BoxFit.contain)),
                Positioned(right: 0, top: 0, child: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
              ]),
            )),
            child: Image.file(File(path), width: 240, height: 180, fit: BoxFit.contain, cacheWidth: 720,
              errorBuilder: (_, _, _) => const Text('无法显示图片', style: TextStyle(color: Colors.white))),
          );
        },
      );
    }
    return ListenableBuilder(listenable: widget.media, builder: (context, _) {
      final isAudio = a['kind'] == 'AU';
      final id = '${a['ref'] ?? a['path'] ?? a['val']}';
      return InkWell(onTap: _busy ? null : _action, child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (_busy) const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          else Icon(isAudio ? (widget.media.playing == id ? Icons.stop : Icons.play_arrow)
              : a['kind'] == 'VD' ? Icons.video_file : Icons.insert_drive_file, color: Colors.white),
          const SizedBox(width: 8),
          Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isAudio ? '语音 ${mediaDuration(a['duration'])}' : '${a['name'] ?? '附件'}',
                style: const TextStyle(color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(isAudio ? '点击播放 / 停止' : '${mediaSize(a['size'])} · 点击打开', style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ])),
        ]),
      ));
    });
  }
}

class MessageComposer extends StatefulWidget {
  const MessageComposer({super.key, required this.topic, required this.controller,
    required this.media, required this.onSendText, required this.onSent});
  final String topic;
  final TextEditingController controller;
  final ChatMedia media;
  final Future<void> Function() onSendText;
  final void Function(Map<String, dynamic>) onSent;
  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  static const tint = Color(0xff80cbc4);
  Map<String, dynamic>? _attachment;
  bool _uploading = false, _selecting = false, _recording = false, _starting = false, _locked = false, _holding = false, _showAttachments = false;
  String? _error, _uploadId;
  int _seconds = 0;
  Timer? _timer;
  late final StreamSubscription<Map<dynamic, dynamic>> _events;
  @override
  void initState() {
    super.initState();
    _events = widget.media.events.stream.listen((event) {
      if (event['type'] == 'recordingLimit' && _recording) _finishRecording();
      if (event['type'] == 'recordingCancelled' && mounted) {
        _timer?.cancel();
        setState(() { _recording = false; _locked = false; _error = '录音已取消'; });
      }
      if (event['type'] == 'playback' && event['error'] != null && mounted) {
        setState(() => _error = event['error'].toString());
      }
    });
  }
  @override
  void dispose() {
    _events.cancel(); _timer?.cancel();
    unawaited(ChatMedia.channel.invokeMethod<void>('stopPlayback').catchError((Object _) {}));
    if (_recording || _starting) unawaited(ChatMedia.channel.invokeMethod<void>('stopRecording', {'cancel': true}).catchError((Object _) {}));
    super.dispose();
  }
  Future<void> _pick(String source) async {
    setState(() { _selecting = true; _error = null; });
    try {
      final result = await ChatMedia.channel.invokeMapMethod<String, dynamic>('pick', {'source': source});
      if (mounted && result != null) setState(() => _attachment = result);
    } catch (e) {
      if (mounted) setState(() => _error = mediaError(e));
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }
  Future<void> _mediaMenu() async {
    final source = await showModalBottomSheet<String>(context: context, builder: (context) => SafeArea(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(leading: const Icon(Icons.photo_library), title: const Text('相册'), onTap: () => Navigator.pop(context, 'gallery')),
        ListTile(leading: const Icon(Icons.camera_alt), title: const Text('拍照'), onTap: () => Navigator.pop(context, 'camera')),
        ListTile(leading: const Icon(Icons.videocam), title: const Text('录视频'), onTap: () => Navigator.pop(context, 'video')),
      ],
    )));
    if (source != null && mounted) await _pick(source);
  }
  Future<void> _pickVideo() async {
    final source = await showModalBottomSheet<String>(context: context, builder: (context) => SafeArea(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [ListTile(leading: const Icon(Icons.videocam), title: const Text('录视频'), onTap: () => Navigator.pop(context, 'video'))],
    )));
    if (source != null && mounted) await _pick(source);
  }
  Future<void> _startRecording({bool locked = false}) async {
    if (_starting || _recording) return;
    setState(() { _starting = true; _locked = locked; _error = null; });
    try {
      await ChatMedia.channel.invokeMethod<void>('startRecording');
      if (!mounted || (!locked && !_holding)) {
        await ChatMedia.channel.invokeMethod<void>('stopRecording', {'cancel': true});
        return;
      }
      setState(() { _recording = true; _seconds = 0; });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() => _seconds++); });
    } catch (e) {
      if (mounted) setState(() => _error = mediaError(e));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
  Future<void> _finishRecording({bool cancel = false, bool send = false}) async {
    if (!_recording) return;
    _timer?.cancel();
    setState(() { _recording = false; _locked = false; _selecting = true; });
    try {
      final result = await ChatMedia.channel.invokeMapMethod<String, dynamic>('stopRecording', {'cancel': cancel});
      if (!mounted) return;
      setState(() => _attachment = result);
      if (send && result != null) await _sendAttachment();
    } catch (e) {
      if (mounted) setState(() => _error = mediaError(e));
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }
  Future<void> _discard() async {
    final attachment = _attachment;
    setState(() { _attachment = null; _error = null; });
    try {
      await ChatMedia.channel.invokeMethod<void>('stopPlayback');
      if (attachment != null) await ChatMedia.channel.invokeMethod<void>('delete', {'path': attachment['path']});
    } catch (_) { /* Cache cleanup may already have occurred. */ }
  }
  Future<void> _sendAttachment() async {
    if (_uploading || _attachment == null) return;
    final attachment = _attachment!;
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    setState(() { _uploading = true; _uploadId = id; _error = null; });
    try {
      final result = await ChatMedia.channel.invokeMapMethod<String, dynamic>('send', {
        'topic': widget.topic, 'attachment': attachment, 'id': id,
      });
      if (result != null) widget.onSent(result);
      if (mounted) setState(() => _attachment = null);
      // Cache cleanup must not turn a successfully published message into a
      // retry action, which would send the attachment a second time.
      try {
        await ChatMedia.channel.invokeMethod<void>('stopPlayback');
        await ChatMedia.channel.invokeMethod<void>('delete', {'path': attachment['path']});
      } catch (_) {}
    } catch (e) {
      if (mounted) setState(() => _error = '${mediaError(e)}，点击发送重试');
    } finally {
      widget.media.progress.remove(id);
      if (mounted) setState(() => _uploading = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    final busy = _uploading || _selecting || _starting;
    return PopScope(
      canPop: !_recording && !_starting && !_uploading,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _recording) _finishRecording(cancel: true);
      },
      child: SafeArea(top: false, child: Container(
      color: const Color(0xfff0f1f5), padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xffa3412b))),
        if (_selecting || _starting) const LinearProgressIndicator(),
        if (_uploading) ListenableBuilder(listenable: widget.media, builder: (_, _) {
          final progress = widget.media.progress[_uploadId] ?? 0;
          return Column(children: [
            LinearProgressIndicator(value: progress),
            Text(progress >= 1 ? '上传完成，正在发送…' : '上传中 ${(progress * 100).round()}%', style: const TextStyle(color: Color(0xff555861))),
          ]);
        }),
        if (_attachment != null) Row(children: [
          Expanded(child: AttachmentView(key: ValueKey(_attachment!['path']), attachment: _attachment!, media: widget.media)),
          IconButton(tooltip: '取消附件', onPressed: busy ? null : _discard, icon: const Icon(Icons.close, color: tint)),
          IconButton(tooltip: '发送附件', onPressed: busy ? null : _sendAttachment, icon: const Icon(Icons.send, color: tint)),
        ])
        else ...[
          if (_recording) Row(children: [
            const Icon(Icons.fiber_manual_record, color: Color(0xffd7473e)),
            Text(mediaDuration(_seconds * 1000), style: const TextStyle(color: Color(0xff34363a))),
            Expanded(child: Text(_locked ? '已锁定 · 停止后可试听' : '松开发送 · 左滑取消 · 上滑锁定', style: const TextStyle(color: Color(0xff777a82), fontSize: 12))),
            if (_locked) ...[
              IconButton(tooltip: '取消录音', onPressed: () => _finishRecording(cancel: true), icon: const Icon(Icons.delete, color: tint)),
              IconButton(tooltip: '停止录音', onPressed: _finishRecording, icon: const Icon(Icons.stop, color: tint)),
            ],
          ]),
          Row(children: [
            _composerButton(tooltip: '按住说话', onPressed: null, child: Semantics(label: '录音，按住说话或点击开始', button: true,
              child: GestureDetector(
                onTap: busy || _recording ? null : () => _startRecording(locked: true),
                onLongPressStart: busy || _recording ? null : (_) { _holding = true; _startRecording(); },
                onLongPressMoveUpdate: (details) {
                  if (!_recording || _locked) return;
                  if (details.offsetFromOrigin.dx < -70) { _holding = false; _finishRecording(cancel: true); }
                  else if (details.offsetFromOrigin.dy < -70) setState(() => _locked = true);
                },
                onLongPressEnd: (_) { _holding = false; if (!_locked) _finishRecording(send: true); },
                onLongPressCancel: () { _holding = false; if (!_locked) _finishRecording(cancel: true); },
                child: Icon(_locked && _recording ? Icons.lock : Icons.mic, color: const Color(0xff30343a), size: 25),
              ))),
            const SizedBox(width: 8),
            Expanded(child: TextField(
              controller: widget.controller, enabled: !busy && !_recording,
              style: const TextStyle(color: Color(0xff202124), fontSize: 17),
              decoration: InputDecoration(hintText: '', hintStyle: const TextStyle(color: Color(0xff9a9ca2)),
                filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none)),
              onSubmitted: (_) => widget.onSendText(),
            )),
            ValueListenableBuilder<TextEditingValue>(valueListenable: widget.controller, builder: (_, value, _) {
              if (value.text.trim().isNotEmpty) return _composerButton(tooltip: '发送消息', onPressed: busy ? null : widget.onSendText,
                  child: const Icon(Icons.send, color: Color(0xff30343a), size: 21));
              return _composerButton(tooltip: '表情', onPressed: () {},
                  child: const Icon(Icons.sentiment_satisfied_alt, color: Color(0xff30343a), size: 25));
            }),
            const SizedBox(width: 8),
            _composerButton(tooltip: _showAttachments ? '收起附件' : '更多功能',
              onPressed: () => setState(() => _showAttachments = !_showAttachments),
              child: Icon(_showAttachments ? Icons.close : Icons.add, color: const Color(0xff30343a), size: 27)),
          ]),
          if (_showAttachments) ...[
            const Divider(height: 1, color: Color(0xffdfe1e7)),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 18, 8, 2),
              child: Wrap(spacing: 0, runSpacing: 18, children: [
                _attachmentAction(Icons.image, '图片', busy || _recording ? null : _mediaMenu),
                _attachmentAction(Icons.photo_camera, '拍照', busy || _recording ? null : () => _pick('camera')),
                _attachmentAction(Icons.videocam, '摄像', busy || _recording ? null : _pickVideo),
                _attachmentAction(Icons.folder, '文件', busy || _recording ? null : () => _pick('file')),
                _attachmentAction(Icons.mail, '红包', null),
              ]),
            ),
          ],
        ],
      ]),
    )));
  }

  Widget _composerButton({required String tooltip, required VoidCallback? onPressed, required Widget child}) => SizedBox(
    width: 48,
    height: 48,
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: IconButton(tooltip: tooltip, onPressed: onPressed, icon: child, padding: EdgeInsets.zero),
    ),
  );

  Widget _attachmentAction(IconData icon, String label, VoidCallback? onPressed) => SizedBox(
    width: (MediaQuery.sizeOf(context).width - 36) / 4,
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, size: 38, color: const Color(0xff5e626b)),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 14, color: Color(0xff777a82))),
      ]),
    ),
  );
}
