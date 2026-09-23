import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'media.dart';
import 'chat_avatar.dart';

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
  final _media = ChatMedia();
  StreamSubscription<dynamic>? _eventSubscription;

  bool _loggedIn = false;
  bool _busy = false;
  String _status = '请输入 Tinode 账号';
  String? _selectedTopic;
  List<Map<String, dynamic>> _chats = [];
  final Map<String, List<Map<String, dynamic>>> _messages = {};
  final Map<String, Future<bool>> _messageLoads = {};
  final Map<String, bool> _presence = {};
  final Map<String, Map<String, dynamic>> _profiles = {};
  final Set<String> _mutedTopics = {};
  final Set<String> _pinnedTopics = {};
  bool _showGroupDetails = false;

  @override
  void initState() {
    super.initState();
    _eventSubscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) => _showReceiveError('消息接收异常：$error'),
    );
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
    _media.dispose();
    super.dispose();
  }

  void _onEvent(dynamic raw) {
    if (!mounted || raw is! Map) return;
    if (_media.handleEvent(raw)) return;
    final topic = raw['topic']?.toString() ?? '';
    if (topic.isEmpty) return;
    if (raw['type'] == 'profile') {
      if (raw['name'] is! String) return;
      final name = raw['name'] as String;
      setState(() {
        final profile = _profiles[topic] ??= {};
        profile['name'] = name;
        for (final key in ['avatar', 'isGroup']) {
          if (raw.containsKey(key)) profile[key] = raw[key];
        }
        for (final chat in _chats) {
          if (chat['topic'] == topic) _applyProfile(chat, profile);
        }
      });
      return;
    }
    if (raw['type'] == 'presence') {
      if (raw['online'] is! bool) return;
      setState(() {
        _presence[topic] = raw['online'] as bool;
        for (final chat in _chats) {
          if (chat['topic'] == topic) chat['online'] = raw['online'];
        }
      });
      return;
    }
    if (raw['type'] != 'message') return;
    final item = <String, dynamic>{
      'from': raw['from']?.toString() ?? '',
      'sender': raw['sender']?.toString() ?? '',
      'self': raw['self'] == true,
      'time': raw['time']?.toString() ?? '',
      'attachments': raw['attachments'] ?? [],
      'content': raw['content']?.toString() ?? '',
      'seq': raw['seq'] ?? 0,
    };
    setState(() {
      final topicMessages = _messages[topic] ??= [];
      final existing = topicMessages.indexWhere(
        (message) => item['seq'] != 0 && message['seq'] == item['seq'],
      );
      final optimistic = raw['self'] == true
          ? topicMessages.lastIndexWhere(
              (message) => message['seq'] == 0 && message['content'] == item['content'],
            )
          : -1;
      if (existing >= 0) {
        topicMessages[existing] = item;
      } else if (optimistic >= 0) {
        topicMessages[optimistic] = item;
      } else {
        topicMessages.add(item);
      }
      for (final chat in _chats) {
        if (chat['topic'] == topic) {
          chat['last'] = _messagePreview(item);
          if (_selectedTopic != topic && item['self'] != true && existing < 0) {
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
      if (!mounted) return;
      setState(() {
        // Live updates can arrive before the list response. Do not let the
        // older snapshot overwrite them.
        for (final chat in chats) {
          final online = _presence[chat['topic']];
          if (online != null) chat['online'] = online;
          final profile = _profiles[chat['topic']];
          if (profile != null) _applyProfile(chat, profile);
        }
        _chats = chats;
      });
      await Future.wait(chats.map(_loadPreview));
    } on PlatformException catch (error) {
      setState(() => _status = '加载会话失败：${error.message ?? error.code}');
    }
  }

  void _showReceiveError(String message) {
    if (!mounted) return;
    debugPrint(message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _loadPreview(Map<String, dynamic> chat) {
    final topic = chat['topic']?.toString();
    if (topic == null || topic.isEmpty) return Future.value(false);
    return _messageLoads.putIfAbsent(topic, () {
      return _fetchMessages(chat, topic).whenComplete(() {
        _messageLoads.remove(topic);
      });
    });
  }

  Future<bool> _fetchMessages(Map<String, dynamic> chat, String topic) async {
    try {
      final response = await _channel.invokeMethod<List<dynamic>>('getMessages', {'topic': topic});
      final messages = (response ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (!mounted) return false;
      setState(() {
        // History can finish after a live event. Preserve those messages and
        // merge by server sequence number instead of replacing the whole list.
        final bySeq = <int, Map<String, dynamic>>{};
        final pending = <Map<String, dynamic>>[];
        for (final message in [...messages, ...?_messages[topic]]) {
          final seq = (message['seq'] as num?)?.toInt() ?? 0;
          if (seq > 0) {
            bySeq[seq] = message;
          } else {
            pending.add(message);
          }
        }
        final merged = bySeq.values.toList()
          ..sort((a, b) => (a['seq'] as num).compareTo(b['seq'] as num));
        merged.addAll(pending);
        _messages[topic] = merged;
        if (merged.isNotEmpty) chat['last'] = _messagePreview(merged.last);
      });
      return true;
    } on PlatformException catch (error) {
      _showReceiveError('无法接收此会话的消息：${error.message ?? error.code}');
      return false;
    }
  }

  Future<void> _openChat(String topic) async {
    setState(() => _selectedTopic = topic);
    // Cached messages do not imply that the server subscription is still active.
    final chat = _chats.firstWhere((item) => item['topic'] == topic, orElse: () => {'topic': topic});
    final ready = await _loadPreview(chat);
    if (!ready || !mounted || _selectedTopic != topic) return;
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
        backgroundColor: const Color(0xfffaf5ea),
        appBar: AppBar(
          backgroundColor: const Color(0xfffff4df),
          foregroundColor: const Color(0xff202124),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              if (_showGroupDetails) {
                _showGroupDetails = false;
              } else {
                _selectedTopic = null;
              }
            }),
          ),
          titleSpacing: 0,
          title: Text(_chatName(_selectedTopic!), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: Color(0xff202124))),
          actions: [if (_isGroup(_selectedTopic!)) IconButton(tooltip: '群聊信息', onPressed: () => setState(() => _showGroupDetails = true), icon: const Icon(Icons.menu))],
        ),
        body: _showGroupDetails ? _buildGroupDetails() : _buildConversation(),
      );

  Widget _buildGroupDetails() {
    final topic = _selectedTopic!;
    final chat = _chats.firstWhere((item) => item['topic'] == topic, orElse: () => {'topic': topic});
    final name = _chatName(topic);
    final members = (chat['members'] as List? ?? const []).whereType<Map>().map((member) => Map<String, dynamic>.from(member)).toList();
    return ColoredBox(
      color: const Color(0xfff1f2f6),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          _detailsSection(child: InkWell(
            onTap: () => _editGroupName(topic, name),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                _avatarForTopic(topic, radius: 34),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, color: Color(0xff202124))),
                  const SizedBox(height: 6),
                  Text('ID：$topic', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: Color(0xff858991))),
                ])),
                const Icon(Icons.chevron_right, color: Color(0xffb7bac1)),
              ]),
            ),
          )),
          const SizedBox(height: 12),
          _detailsSection(child: InkWell(
            onTap: () => _editGroupAnnouncement(topic, chat['announcement']?.toString() ?? ''),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 86,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(colors: [Color(0xffef4e3e), Color(0xffff985c)]),
              ),
              child: Row(children: [
                const Icon(Icons.mail, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(child: Text(chat['announcement']?.toString().isNotEmpty == true ? '群公告  ${chat['announcement']}' : '群公告  暂无群公告',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16))),
                const Icon(Icons.chevron_right, color: Colors.white70),
              ]),
            ),
          )),
          const SizedBox(height: 12),
          _detailsSection(child: ListTile(
            title: const Text('我的群昵称'),
            subtitle: Text(chat['myAlias']?.toString().isNotEmpty == true ? chat['myAlias'].toString() : '设置我在群内的昵称', style: const TextStyle(color: Color(0xff858991))),
            trailing: const Icon(Icons.chevron_right, color: Color(0xffb7bac1)),
            onTap: () => _editGroupAlias(topic, chat['myAlias']?.toString() ?? ''),
          )),
          const SizedBox(height: 12),
          _detailsSection(child: Column(children: [
            SwitchListTile(
              title: const Text('消息免打扰'),
              value: _mutedTopics.contains(topic),
              activeColor: const Color(0xffed9b37),
              onChanged: (value) => setState(() => value ? _mutedTopics.add(topic) : _mutedTopics.remove(topic)),
            ),
            SwitchListTile(
              title: const Text('置顶聊天'),
              value: _pinnedTopics.contains(topic),
              activeColor: const Color(0xffed9b37),
              onChanged: (value) => setState(() => value ? _pinnedTopics.add(topic) : _pinnedTopics.remove(topic)),
            ),
          ])),
          const SizedBox(height: 12),
          _detailsSection(child: Column(children: [
            _detailsAction('清除聊天记录', onTap: () => _confirmClearMessages(topic)),
            const Divider(height: 1, indent: 18, endIndent: 18),
            _detailsAction('退出群聊', color: const Color(0xffed9b37), onTap: () => _confirmLeaveGroup(topic)),
          ])),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(children: [
              Expanded(child: Text('群组成员', style: const TextStyle(color: Color(0xff858991), fontSize: 15))),
              Text('${members.isNotEmpty ? members.length : (chat['memberCount'] ?? 0)} 人', style: const TextStyle(color: Color(0xff858991), fontSize: 14)),
            ]),
          ),
          const SizedBox(height: 8),
          _detailsSection(child: Column(children: [
            ListTile(
              leading: const Icon(Icons.person_add_alt_1, color: Color(0xff858991)),
              title: const Text('添加成员', style: TextStyle(fontSize: 15)),
              onTap: () => _showReceiveError('添加成员功能暂不可用'),
            ),
            for (final member in members)
              ListTile(
                leading: CircleAvatar(backgroundColor: const Color(0xffb7df91), child: Text((member['name']?.toString() ?? '?').characters.first)),
                title: Text(member['name']?.toString() ?? member['uid']?.toString() ?? '群成员'),
                subtitle: Text(member['uid']?.toString() ?? '', style: const TextStyle(color: Color(0xff858991))),
                trailing: member['owner'] == true ? const Chip(label: Text('群主'), visualDensity: VisualDensity.compact) : null,
              ),
          ])),
        ],
      ),
    );
  }

  Widget _detailsSection({required Widget child}) => Container(
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _detailsAction(String title, {required VoidCallback onTap, Color color = const Color(0xff202124)}) => ListTile(
    title: Center(child: Text(title, style: TextStyle(color: color, fontSize: 16))),
    onTap: onTap,
  );

  Future<void> _editGroupName(String topic, String current) async {
    final value = await _textPrompt('群聊名称', current);
    if (value == null || value.trim().isEmpty) return;
    try {
      await _channel.invokeMethod<void>('updateGroup', {'topic': topic, 'name': value.trim()});
      if (!mounted) return;
      final chat = _chats.firstWhere((item) => item['topic'] == topic);
      setState(() => _updateChatName(chat, value.trim()));
    } on PlatformException catch (error) {
      _showReceiveError('修改群名称失败：${error.message ?? error.code}');
    }
  }

  Future<void> _editGroupAnnouncement(String topic, String current) async {
    final value = await _textPrompt('群公告', current, multiline: true);
    if (value == null) return;
    try {
      await _channel.invokeMethod<void>('updateGroup', {'topic': topic, 'announcement': value.trim()});
      if (!mounted) return;
      setState(() => _chats.firstWhere((item) => item['topic'] == topic)['announcement'] = value.trim());
    } on PlatformException catch (error) {
      _showReceiveError('更新群公告失败：${error.message ?? error.code}');
    }
  }

  Future<void> _editGroupAlias(String topic, String current) async {
    final value = await _textPrompt('我的群昵称', current);
    if (value == null) return;
    try {
      await _channel.invokeMethod<void>('updateGroup', {'topic': topic, 'alias': value.trim()});
      if (!mounted) return;
      setState(() => _chats.firstWhere((item) => item['topic'] == topic)['myAlias'] = value.trim());
    } on PlatformException catch (error) {
      _showReceiveError('修改群昵称失败：${error.message ?? error.code}');
    }
  }

  Future<String?> _textPrompt(String title, String value, {bool multiline = false}) async {
    final controller = TextEditingController(text: value);
    return showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, maxLines: multiline ? 4 : 1),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('保存')),
      ],
    ));
  }

  Future<void> _confirmClearMessages(String topic) async {
    final clear = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('清除聊天记录'),
      content: const Text('清除本设备上此群聊的消息记录？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('清除')),
      ],
    ));
    if (clear == true && mounted) setState(() => _messages[topic]?.clear());
  }

  Future<void> _confirmLeaveGroup(String topic) async {
    final leave = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('退出群聊'),
      content: const Text('确定退出此群聊吗？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
      ],
    ));
    if (leave != true) return;
    try {
      await _channel.invokeMethod<void>('leaveGroup', {'topic': topic});
      if (!mounted) return;
      setState(() {
        _chats.removeWhere((chat) => chat['topic'] == topic);
        _selectedTopic = null;
        _showGroupDetails = false;
      });
    } on PlatformException catch (error) {
      _showReceiveError('退出群聊失败：${error.message ?? error.code}');
    }
  }

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

  void _applyProfile(Map<String, dynamic> chat, Map<String, dynamic> profile) {
    if (profile['name'] is String) _updateChatName(chat, profile['name'] as String);
    for (final key in ['avatar', 'isGroup']) {
      if (profile.containsKey(key)) chat[key] = profile[key];
    }
  }

  bool _isGroup(String topic) => _chats.any((chat) => chat['topic'] == topic && chat['isGroup'] == true);

  void _updateChatName(Map<String, dynamic> chat, String name) {
    chat['name'] = name;
    chat['initial'] = name.isEmpty ? '?' : name.characters.first.toUpperCase();
  }

  bool _isOnline(String topic) {
    if (_presence.containsKey(topic)) return _presence[topic]!;
    return _chats.any((chat) => chat['topic'] == topic && chat['online'] == true);
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
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          leading: _avatarForTopic(topic, radius: 28),
          title: Row(
            children: [
              if (chat['isGroup'] == true) ...[
                const Tooltip(message: '群聊', child: Icon(Icons.group, size: 20, color: Color(0xff80cbc4))),
                const SizedBox(width: 6),
              ],
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
        child: ColoredBox(
          color: const Color(0xfffaf5ea),
          child: ListView.builder(
            // Anchor the conversation at its newest message. Otherwise incoming
            // messages can be appended below the visible history with no cue.
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
            itemCount: messages.length,
            itemBuilder: (context, index) => _messageBubble(messages[messages.length - 1 - index]),
          ),
        ),
      ),
      MessageComposer(
        key: ValueKey(topic),
        topic: topic,
        controller: _message,
        media: _media,
        onSendText: _sendMessage,
        onSent: (message) {
          if (!mounted) return;
          _onEvent({'type': 'message', ...message});
        },
      ),
    ]);
  }

  Widget _messageBubble(Map<String, dynamic> item) {
    final self = item['self'] == true;
    final text = item['content']?.toString() ?? '';
    final time = _formatTime(item['time']?.toString());
    final attachments = (item['attachments'] as List? ?? []).whereType<Map>().map((a) => Map<String, dynamic>.from(a)).toList();
    final sender = item['sender']?.toString().trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 17),
      child: Row(
        mainAxisAlignment: self ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!self) ...[
            _messageAvatar(item, radius: 22),
            const SizedBox(width: 9),
          ],
          Flexible(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: self ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!self && _isGroup(_selectedTopic!) && sender != null && sender.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(left: 4, bottom: 5),
                    child: Text(sender, style: const TextStyle(color: Color(0xff999a9c), fontSize: 12))),
                Container(
                  padding: const EdgeInsets.fromLTRB(13, 10, 12, 7),
                  decoration: BoxDecoration(
                    color: self ? const Color(0xffd9f6ca) : Colors.white,
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: const [BoxShadow(color: Color(0x0c000000), blurRadius: 2, offset: Offset(0, 1))],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final attachment in attachments)
                        AttachmentView(key: ValueKey('${item['seq']}-${attachments.indexOf(attachment)}-${attachment['ref']}'), attachment: attachment, media: _media),
                      if (text.trim().isNotEmpty)
                        Align(alignment: Alignment.centerLeft, child: Text(text,
                          style: const TextStyle(color: Color(0xff202124), fontSize: 17, height: 1.45))),
                      if (time.isNotEmpty || self)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          if (time.isNotEmpty) Text(time, style: const TextStyle(color: Color(0xff9b9da1), fontSize: 11)),
                          if (self) ...[
                            if (time.isNotEmpty) const SizedBox(width: 5),
                            const Icon(Icons.done_all, size: 14, color: Color(0xff54b5aa)),
                          ],
                        ]),
                    ],
                  ),
                ),
              ],
            ),
          )),
          if (self) const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _messageAvatar(Map<String, dynamic> message, {double radius = 22}) {
    final topic = _selectedTopic!;
    if (_isGroup(topic)) {
      final uid = message['from']?.toString();
      final sender = uid == null ? null : _chats.where((chat) => chat['topic'] == uid).firstOrNull;
      final senderName = message['sender']?.toString() ?? uid ?? '?';
      return ChatAvatar(name: senderName,
        avatar: sender?['avatar'] is Map ? Map<String, dynamic>.from(sender!['avatar']) : null,
        media: _media, radius: radius, color: _avatarColor(uid?.hashCode ?? 0));
    }
    return _avatarForTopic(topic, radius: radius);
  }

  String _messagePreview(Map<String, dynamic> message) {
    final text = message['content']?.toString() ?? '';
    if (text.trim().isNotEmpty) return text;
    final attachments = message['attachments'];
    if (attachments is List && attachments.isNotEmpty && attachments.first is Map) {
      return switch (attachments.first['kind']) {
        'IM' => '[图片]', 'AU' => '[语音]', 'VD' => '[视频]', _ => '[文件]',
      };
    }
    return '';
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
      ChatAvatar(name: name, avatar: chat['avatar'] is Map ? Map<String, dynamic>.from(chat['avatar']) : null,
        media: _media, radius: radius, color: _avatarColor(index < 0 ? 0 : index)),
      if (chat['isGroup'] != true)
      Positioned(
        right: -1,
        bottom: 0,
        child: Container(
          width: radius * .48,
          height: radius * .48,
          decoration: BoxDecoration(color: _isOnline(topic) ? const Color(0xff35c759) : const Color(0xff666666), shape: BoxShape.circle, border: Border.all(color: const Color(0xff212121), width: 2)),
        ),
      ),
    ]);
  }
}
