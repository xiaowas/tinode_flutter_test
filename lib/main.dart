import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: const TinodePage(),
      );
}

class TinodePage extends StatefulWidget {
  const TinodePage({super.key});

  @override
  State<TinodePage> createState() => _TinodePageState();
}

class _TinodePageState extends State<TinodePage> {
  static const _channel = MethodChannel('tinode');
  static const _events = EventChannel('tinode/events');

  final _username = TextEditingController();
  final _password = TextEditingController();
  final _message = TextEditingController();
  StreamSubscription<dynamic>? _eventSubscription;

  bool _loggedIn = false;
  bool _busy = false;
  String _status = '请输入 Tinode 账号';
  String? _selectedTopic;
  List<Map<String, dynamic>> _chats = [];
  final Map<String, List<Map<String, dynamic>>> _messages = {};

  @override
  void initState() {
    super.initState();
    _eventSubscription = _events.receiveBroadcastStream().listen(_onEvent);
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    try {
      final session = await _channel.invokeMethod<Map<Object?, Object?>>('getSession');
      if (session?['authenticated'] == true && mounted) {
        setState(() {
          _loggedIn = true;
          _status = '已登录：${session?['uid'] ?? ''}';
        });
        await _loadChats();
      }
    } on PlatformException {
      // Native session is optional; the login form remains available.
    }
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _username.dispose();
    _password.dispose();
    _message.dispose();
    super.dispose();
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    if (raw['type'] != 'message') return;
    final topic = raw['topic']?.toString() ?? '';
    if (topic.isEmpty) return;
    final item = <String, dynamic>{
      'from': raw['from']?.toString() ?? '',
      'content': raw['content']?.toString() ?? '',
      'seq': raw['seq'] ?? 0,
    };
    setState(() {
      final topicMessages = _messages[topic] ??= [];
      final optimistic = raw['self'] == true
          ? topicMessages.lastIndexWhere(
              (message) => message['seq'] == 0 && message['content'] == item['content'],
            )
          : -1;
      if (optimistic >= 0) {
        topicMessages[optimistic] = item;
      } else {
        topicMessages.add(item);
      }
      for (final chat in _chats) {
        if (chat['topic'] == topic) {
          chat['last'] = item['content'];
          if (_selectedTopic != topic) {
            chat['unread'] = ((chat['unread'] as num?)?.toInt() ?? 0) + 1;
          }
          break;
        }
      }
    });
    if (_selectedTopic == topic) {
      _channel.invokeMethod<void>('markRead', {'topic': topic});
    }
  }

  Future<void> _login() async {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _status = '请输入用户名和密码');
      return;
    }
    setState(() {
      _busy = true;
      _status = '登录中...';
    });
    try {
      final response = await _channel.invokeMethod<Map<Object?, Object?>>(
        'login',
        {'username': username, 'password': password},
      );
      if (response?['success'] != true) throw PlatformException(code: 'LOGIN_FAILED');
      setState(() {
        _loggedIn = true;
        _status = '已登录：${response?['uid'] ?? ''}';
      });
      await _loadChats();
    } on PlatformException catch (error) {
      setState(() => _status = '登录失败：${error.message ?? error.code}');
    } catch (error) {
      setState(() => _status = '登录失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadChats() async {
    try {
      final response = await _channel.invokeMethod<List<dynamic>>('listChats');
      final chats = (response ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      setState(() => _chats = chats);
      await Future.wait(chats.map(_loadPreview));
    } on PlatformException catch (error) {
      setState(() => _status = '加载会话失败：${error.message ?? error.code}');
    }
  }

  Future<void> _loadPreview(Map<String, dynamic> chat) async {
    final topic = chat['topic']?.toString();
    if (topic == null || topic.isEmpty) return;
    try {
      final response = await _channel.invokeMethod<List<dynamic>>('getMessages', {'topic': topic});
      final messages = (response ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (!mounted) return;
      setState(() {
        _messages[topic] = messages;
        if (messages.isNotEmpty) chat['last'] = messages.last['content']?.toString() ?? '';
      });
    } on PlatformException {
      // Keep the conversation visible even when history is temporarily unavailable.
    }
  }

  Future<void> _openChat(String topic) async {
    setState(() => _selectedTopic = topic);
    if (!_messages.containsKey(topic)) {
      final chat = _chats.firstWhere((item) => item['topic'] == topic, orElse: () => {'topic': topic});
      await _loadPreview(chat);
    }
    await _channel.invokeMethod<void>('markRead', {'topic': topic});
    if (!mounted) return;
    setState(() {
      for (final chat in _chats) {
        if (chat['topic'] == topic) chat['unread'] = 0;
      }
    });
  }

  Future<void> _sendMessage() async {
    final topic = _selectedTopic;
    final content = _message.text.trim();
    if (topic == null || content.isEmpty) return;
    _message.clear();
    try {
      await _channel.invokeMethod('sendMessage', {'topic': topic, 'content': content});
      setState(() {
        final optimistic = <String, dynamic>{
          'from': '',
          'self': true,
          'content': content,
          'seq': 0,
          'time': DateTime.now().toUtc().toIso8601String(),
        };
        final current = _messages[topic] ??= [];
        if (!current.any((item) => item['seq'] == 0 && item['content'] == content)) {
          current.add(optimistic);
        }
        for (final chat in _chats) {
          if (chat['topic'] == topic) chat['last'] = content;
        }
      });
    } on PlatformException catch (error) {
      setState(() => _status = '发送失败：${error.message ?? error.code}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loggedIn) return _buildLogin();
    if (_selectedTopic != null) return _buildConversationPage();
    return Scaffold(
      backgroundColor: const Color(0xff303030),
      appBar: AppBar(
        backgroundColor: const Color(0xff212121),
        foregroundColor: Colors.white,
        title: const Text('Tinode', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [IconButton(onPressed: _loadChats, icon: const Icon(Icons.more_vert))],
      ),
      body: _buildChatList(),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xff009688),
        foregroundColor: Colors.white,
        onPressed: () {},
        child: const Icon(Icons.chat),
      ),
    );
  }

  Widget _buildConversationPage() => Scaffold(
        backgroundColor: const Color(0xff303030),
        appBar: AppBar(
          backgroundColor: const Color(0xff212121),
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _selectedTopic = null),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              _avatarForTopic(_selectedTopic!, radius: 26),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_chatName(_selectedTopic!), style: const TextStyle(fontSize: 19)),
                  const Text('在线', style: TextStyle(fontSize: 14, color: Colors.white60)),
                ],
              ),
            ],
          ),
          actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert))],
        ),
        body: _buildConversation(),
      );

  Widget _buildLogin() => Scaffold(
        appBar: AppBar(title: const Text('Tinode 登录')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _username,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '用户名'),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密码'),
                    onSubmitted: (_) => _login(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _login,
                      child: Text(_busy ? '登录中...' : '登录'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(_status, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      );

  String _chatName(String topic) {
    for (final chat in _chats) {
      if (chat['topic'] == topic) return chat['name']?.toString() ?? topic;
    }
    return topic;
  }

  Widget _buildChatList() {
    if (_chats.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadChats,
        child: ListView(
          children: const [
            SizedBox(height: 260),
            Center(child: Text('暂无会话', style: TextStyle(color: Colors.white70, fontSize: 16))),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _chats.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 92, color: Color(0xff555555)),
      itemBuilder: (context, index) {
        final chat = _chats[index];
        final topic = chat['topic']?.toString() ?? '';
        final name = chat['name']?.toString() ?? topic;
        final unread = (chat['unread'] as num?)?.toInt() ?? 0;
        final online = chat['online'] == true;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 38,
                backgroundColor: _avatarColor(index),
                child: Text(
                  (chat['initial']?.toString().isNotEmpty == true
                          ? chat['initial']
                          : (name.isEmpty ? '?' : name.substring(0, 1)))
                      .toString(),
                  style: const TextStyle(color: Colors.white, fontSize: 30),
                ),
              ),
              Positioned(
                right: -1,
                bottom: 1,
                child: Container(
                  width: 21,
                  height: 21,
                  decoration: BoxDecoration(
                    color: online ? const Color(0xff35c759) : const Color(0xff666666),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xff303030), width: 2),
                  ),
                ),
              ),
            ],
          ),
          title: Row(
            children: [
              Expanded(child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 22))),
              if (unread > 0)
                CircleAvatar(
                  radius: 16,
                  backgroundColor: const Color(0xff9bb5ce),
                  child: Text('$unread', style: const TextStyle(color: Colors.white)),
                ),
            ],
          ),
          subtitle: Text(
            (chat['last']?.toString().isNotEmpty == true ? chat['last'] : topic).toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 18),
          ),
          onTap: () => _openChat(topic),
        );
      },
    );
  }

  Color _avatarColor(int index) {
    const colors = [Color(0xffb9db93), Color(0xffed4b16), Color(0xff667caa), Color(0xff8c5aa8)];
    return colors[index % colors.length];
  }

  Widget _buildConversation() {
    final topic = _selectedTopic;
    if (topic == null) return const Center(child: Text('请选择一个会话'));
    final messages = _messages[topic] ?? [];
    return Column(children: [
      Expanded(
        child: CustomPaint(
          painter: _ChatWallpaperPainter(),
          child: ListView.builder(
            reverse: false,
            padding: const EdgeInsets.fromLTRB(8, 22, 8, 12),
            itemCount: messages.length,
            itemBuilder: (context, index) => _messageBubble(messages[index]),
          ),
        ),
      ),
      Container(
        color: const Color(0xff333333),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(children: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.image, color: Color(0xff80cbc4))),
          IconButton(onPressed: () {}, icon: const Icon(Icons.attach_file, color: Color(0xff80cbc4))),
          Expanded(
            child: TextField(
              controller: _message,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: const InputDecoration(
                hintText: '新消息',
                hintStyle: TextStyle(color: Colors.white54, fontSize: 18),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white54)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xff80cbc4))),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          IconButton(onPressed: _sendMessage, icon: const Icon(Icons.mic, color: Color(0xff80cbc4))),
        ]),
      ),
    ]);
  }

  Widget _messageBubble(Map<String, dynamic> item) {
    final self = item['self'] == true;
    final text = item['content']?.toString() ?? '';
    final time = _formatTime(item['time']?.toString());
    return Align(
      alignment: self ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        margin: EdgeInsets.only(left: self ? 70 : 56, right: self ? 8 : 70, bottom: 5),
        padding: const EdgeInsets.fromLTRB(14, 9, 12, 6),
        decoration: BoxDecoration(
          color: self ? const Color(0xff005b16) : const Color(0xff252525),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 20)),
            ),
            const SizedBox(height: 3),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(time, style: const TextStyle(color: Colors.white60, fontSize: 14)),
              if (self) ...[
                const SizedBox(width: 7),
                const Icon(Icons.done_all, size: 16, color: Color(0xff00a9a0)),
              ],
            ]),
          ],
        ),
      ),
    );
  }

  String _formatTime(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _avatarForTopic(String topic, {double radius = 38}) {
    final index = _chats.indexWhere((item) => item['topic'] == topic);
    final chat = index >= 0 ? _chats[index] : <String, dynamic>{};
    final name = chat['name']?.toString() ?? topic;
    return Stack(clipBehavior: Clip.none, children: [
      CircleAvatar(
        radius: radius,
        backgroundColor: _avatarColor(index < 0 ? 0 : index),
        child: Text(name.isEmpty ? '?' : name.substring(0, 1), style: TextStyle(color: Colors.white, fontSize: radius * .7)),
      ),
      Positioned(
        right: -1,
        bottom: 0,
        child: Container(
          width: radius * .48,
          height: radius * .48,
          decoration: BoxDecoration(color: const Color(0xff35c759), shape: BoxShape.circle, border: Border.all(color: const Color(0xff212121), width: 2)),
        ),
      ),
    ]);
  }
}

class _ChatWallpaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xff171717), BlendMode.src);
    final paint = Paint()..color = const Color(0xff292929)..strokeWidth = 2;
    for (var y = -size.width; y < size.height + size.width; y += 13) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - size.width), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChatWallpaperPainter oldDelegate) => false;
}
