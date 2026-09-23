import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinode_flutter_test/main.dart';
import 'package:tinode_flutter_test/chat_avatar.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('tinode');
  const events = MethodChannel('tinode/events');
  var authenticated = false;
  var messageRequests = 0;
  var failMessages = false;
  Completer<List<Map<String, dynamic>>>? history;
  Completer<List<Map<String, dynamic>>>? chatList;

  setUp(() {
    authenticated = false;
    messageRequests = 0;
    failMessages = false;
    history = null;
    chatList = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, (_) async => null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'getSession':
          return {'authenticated': authenticated, 'uid': 'usrMe'};
        case 'listChats':
          if (chatList != null) return await chatList!.future;
          return [{'topic': 'usrPeer', 'name': '测试好友'}];
        case 'getMessages':
          messageRequests++;
          if (failMessages) {
            throw PlatformException(code: 'TINODE_MESSAGES_ERROR', message: '订阅被拒绝');
          }
          return history == null ? <Map<String, dynamic>>[] : await history!.future;
        case 'markRead':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  Future<void> receive(WidgetTester tester, Map<String, dynamic> message) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'tinode/events',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'message',
        'topic': 'usrPeer',
        'from': 'usrPeer',
        'self': false,
        ...message,
      }),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('renders Tinode login form', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Tinode 登录'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });

  Finder statusDot(Color color) => find.byWidgetPredicate((widget) {
    if (widget is! Container || widget.decoration is! BoxDecoration) return false;
    final decoration = widget.decoration! as BoxDecoration;
    return decoration.shape == BoxShape.circle && decoration.color == color;
  });

  testWidgets('group uses photo and marker in list and group label in toolbar', (tester) async {
    authenticated = true;
    final photo = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=');
    chatList = Completer<List<Map<String, dynamic>>>()..complete([
      {'topic': 'grpTest', 'name': '测试群', 'isGroup': true, 'avatar': {'val': photo}},
    ]);
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.byTooltip('群聊'), findsOneWidget);
    expect(find.byIcon(Icons.group), findsOneWidget);
    expect(tester.widget<ChatAvatar>(find.byType(ChatAvatar)).avatar?['val'], photo);
    expect(statusDot(const Color(0xff666666)), findsNothing);
    await tester.tap(find.text('测试群'));
    await tester.pumpAndSettle();
    expect(find.text('群聊'), findsOneWidget);
    expect(find.text('离线'), findsNothing);
    expect(tester.widget<ChatAvatar>(find.byType(ChatAvatar)).avatar?['val'], photo);
    await receive(tester, {'type': 'profile', 'topic': 'grpTest', 'name': '新群名', 'isGroup': true, 'avatar': null});
    await tester.pumpAndSettle();
    expect(tester.widget<ChatAvatar>(find.byType(ChatAvatar)).avatar, isNull);
    expect(find.text('新'), findsOneWidget);
  });

  testWidgets('profile update refreshes list name and initial without reloading history', (tester) async {
    authenticated = true;
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await receive(tester, {'seq': 1, 'content': '保留消息预览'});
    await receive(tester, {'type': 'presence', 'online': true});
    final requests = messageRequests;
    await receive(tester, {'type': 'profile', 'name': 'Alice'});
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('测试好友'), findsNothing);
    expect(find.text('保留消息预览'), findsOneWidget);
    expect(statusDot(const Color(0xff35c759)), findsOneWidget);
    expect(messageRequests, requests);
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    final openRequests = messageRequests;
    await receive(tester, {'type': 'profile', 'name': 'Bob'});
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
    expect(find.text('保留消息预览'), findsOneWidget);
    expect(messageRequests, openRequests);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('profile update before list response overrides stale name', (tester) async {
    authenticated = true;
    chatList = Completer<List<Map<String, dynamic>>>();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await receive(tester, {'type': 'profile', 'name': '新昵称'});
    chatList!.complete([{'topic': 'usrPeer', 'name': '旧昵称', 'initial': '旧'}]);
    await tester.pumpAndSettle();
    expect(find.text('新昵称'), findsOneWidget);
    expect(find.text('新'), findsOneWidget);
    expect(find.text('旧昵称'), findsNothing);
  });

  testWidgets('presence updates list and open conversation in both directions', (tester) async {
    authenticated = true;
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(statusDot(const Color(0xff666666)), findsOneWidget);
    await receive(tester, {'type': 'presence', 'online': true});
    expect(statusDot(const Color(0xff35c759)), findsOneWidget);
    await tester.tap(find.text('测试好友'));
    await tester.pumpAndSettle();
    expect(find.text('在线'), findsOneWidget);
    await receive(tester, {'type': 'presence', 'online': false});
    expect(find.text('离线'), findsOneWidget);
    expect(statusDot(const Color(0xff666666)), findsOneWidget);
    await receive(tester, {'type': 'presence', 'online': true});
    expect(find.text('在线'), findsOneWidget);
    expect(statusDot(const Color(0xff35c759)), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await receive(tester, {'type': 'presence', 'online': false});
    expect(statusDot(const Color(0xff666666)), findsOneWidget);
  });

  testWidgets('presence arriving before chat list overrides stale snapshot', (tester) async {
    authenticated = true;
    chatList = Completer<List<Map<String, dynamic>>>();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await receive(tester, {'type': 'presence', 'online': true});
    chatList!.complete([{'topic': 'usrPeer', 'name': '测试好友', 'online': false}]);
    await tester.pumpAndSettle();
    expect(statusDot(const Color(0xff35c759)), findsOneWidget);
  });

  testWidgets('shows live messages once and preserves sender and time', (tester) async {
    authenticated = true;
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试好友'));
    await tester.pumpAndSettle();

    final timestamp = DateTime(2026, 9, 23, 12, 34);
    final message = {
      'seq': 7,
      'content': '实时收到的消息',
      'self': true,
      'time': timestamp.toIso8601String(),
    };
    await receive(tester, message);
    await receive(tester, message);
    expect(find.text('实时收到的消息'), findsOneWidget);
    expect(find.text('12:34'), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsOneWidget);

    await receive(tester, {'seq': 8, 'content': '好友的回复'});
    expect(find.text('好友的回复'), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsOneWidget);
  });

  testWidgets('late history does not overwrite live messages', (tester) async {
    authenticated = true;
    history = Completer<List<Map<String, dynamic>>>();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await receive(tester, {'seq': 8, 'content': '最新回复'});
    history!.complete([
      {'seq': 7, 'content': '历史消息', 'self': false},
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试好友'));
    await tester.pumpAndSettle();
    expect(find.text('历史消息'), findsOneWidget);
    expect(find.text('最新回复'), findsOneWidget);
  });

  testWidgets('opening cached chat checks subscription again', (tester) async {
    authenticated = true;
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(messageRequests, 1);
    await tester.tap(find.text('测试好友'));
    await tester.pumpAndSettle();
    expect(messageRequests, 2);
  });

  testWidgets('new replies stay visible below a long history', (tester) async {
    authenticated = true;
    history = Completer<List<Map<String, dynamic>>>()
      ..complete(List.generate(50, (index) => {
        'seq': index + 1,
        'content': '旧消息 $index',
        'self': false,
      }));
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试好友'));
    await tester.pumpAndSettle();
    expect(find.text('旧消息 49').hitTestable(), findsOneWidget);
    await receive(tester, {'seq': 51, 'content': '刚刚发来的回复'});
    await tester.pumpAndSettle();
    expect(find.text('刚刚发来的回复').hitTestable(), findsOneWidget);
  });

  testWidgets('subscription failure is visible and opening chat retries', (tester) async {
    authenticated = true;
    failMessages = true;
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('无法接收此会话的消息：订阅被拒绝'), findsOneWidget);
    failMessages = false;
    await tester.tap(find.text('测试好友'));
    await tester.pumpAndSettle();
    expect(messageRequests, 2);
    await receive(tester, {'seq': 9, 'content': '重试后收到'});
    expect(find.text('重试后收到'), findsOneWidget);
  });

  testWidgets('opening chat during history load shares the subscription request', (tester) async {
    authenticated = true;
    history = Completer<List<Map<String, dynamic>>>();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试好友'));
    await tester.pumpAndSettle();
    expect(messageRequests, 1);
    history!.complete([]);
    await tester.pumpAndSettle();
  });
}
