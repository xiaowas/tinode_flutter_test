import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'media.dart';

/// Shared by the chat list and toolbar; unavailable images retain the initial.
class ChatAvatar extends StatefulWidget {
  const ChatAvatar({super.key, required this.name, required this.avatar,
    required this.media, required this.radius, required this.color});
  final String name;
  final Map<String, dynamic>? avatar;
  final ChatMedia media;
  final double radius;
  final Color color;

  @override
  State<ChatAvatar> createState() => _ChatAvatarState();
}

class _ChatAvatarState extends State<ChatAvatar> {
  Future<String>? _remote;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ChatAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatar?['ref'] != widget.avatar?['ref'] ||
        oldWidget.avatar?['val'] != widget.avatar?['val']) _load();
  }

  void _load() {
    _remote = null;
    _bytes = null;
    final avatar = widget.avatar;
    if (avatar == null) return;
    if ((avatar['ref'] as String?)?.isNotEmpty == true) {
      _remote = widget.media.resolve(avatar);
    } else {
      try {
        final value = avatar['val'];
        _bytes = value is Uint8List ? value : value is String ? base64Decode(value) : null;
      } on FormatException {
        // Invalid avatar data must not prevent the conversation from rendering.
      }
    }
  }

  Widget _fallback() => ColoredBox(color: widget.color, child: Center(child: Text(
    widget.name.isEmpty ? '?' : widget.name.characters.first.toUpperCase(),
    style: TextStyle(color: Colors.white, fontSize: widget.radius * .8),
  )));

  @override
  Widget build(BuildContext context) => ClipOval(child: SizedBox.square(
    dimension: widget.radius * 2,
    child: _remote != null
      ? FutureBuilder<String>(future: _remote, builder: (context, snapshot) {
          if (!snapshot.hasData) return _fallback();
          return Image.file(File(snapshot.data!), fit: BoxFit.cover, cacheWidth: 192,
            errorBuilder: (_, _, _) => _fallback());
        })
      : _bytes != null
        ? Image.memory(_bytes!, fit: BoxFit.cover, cacheWidth: 192,
            errorBuilder: (_, _, _) => _fallback())
        : _fallback(),
  ));
}
