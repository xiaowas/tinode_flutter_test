import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinode_flutter_test/media.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late ChatMedia media;
  late TextEditingController text;
  late List<MethodCall> calls;
  late List<Map<String, dynamic>> sent;
  var failSend = false;
  var textSends = 0;
  Completer<void>? recordingPermission;
  const file = {'path': '/cache/test.pdf', 'name': 'test.pdf', 'mime': 'application/pdf', 'size': 1024, 'kind': 'EX'};

  setUp(() {
    media = ChatMedia();
    text = TextEditingController();
    calls = []; sent = []; failSend = false; textSends = 0; recordingPermission = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(ChatMedia.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'pick': return file;
        case 'send':
          if (failSend) throw PlatformException(code: 'UPLOAD', message: '上传失败');
          return {'seq': 12, 'topic': 'usrPeer', 'self': true, 'attachments': [file]};
        case 'startRecording': await recordingPermission?.future; return null;
        case 'stopRecording':
          if (call.arguments['cancel'] == true) return null;
          return {'path': '/cache/voice.m4a', 'name': 'voice.m4a', 'mime': 'audio/mp4', 'kind': 'AU', 'duration': 2000, 'size': 512};
        case 'resolve': return '/cache/download';
        default: return null;
      }
    });
  });
  tearDown(() {
    media.dispose(); text.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(ChatMedia.channel, null);
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter,
      child: MessageComposer(topic: 'usrPeer', controller: text, media: media,
        onSendText: () async { textSends++; }, onSent: sent.add),
    ))));
    await tester.pumpAndSettle();
  }

  testWidgets('typing switches microphone to send and back', (tester) async {
    await mount(tester);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.byTooltip('发送消息'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing);
    await tester.tap(find.byTooltip('发送消息'));
    expect(textSends, 1);
    text.clear(); await tester.pump();
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });

  testWidgets('file selection previews before sending and supports retry', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('选择文件')); await tester.pumpAndSettle();
    expect(find.text('test.pdf'), findsOneWidget);
    expect(calls.where((c) => c.method == 'send'), isEmpty);
    failSend = true;
    await tester.tap(find.byTooltip('发送附件')); await tester.pumpAndSettle();
    expect(find.textContaining('点击发送重试'), findsOneWidget);
    expect(sent, isEmpty);
    failSend = false;
    await tester.tap(find.byTooltip('发送附件')); await tester.pumpAndSettle();
    expect(sent.single['seq'], 12);
    expect(calls.lastWhere((c) => c.method == 'send').arguments['topic'], 'usrPeer');
    expect(find.text('test.pdf'), findsNothing);
  });

  testWidgets('discarding attachment never publishes', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('选择文件')); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('取消附件')); await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'send'), isEmpty);
    expect(calls.where((c) => c.method == 'delete'), hasLength(1));
  });

  testWidgets('tap recording can stop, preview, play and send', (tester) async {
    await mount(tester);
    await tester.tap(find.byIcon(Icons.mic)); await tester.pump();
    expect(find.byTooltip('停止录音'), findsOneWidget);
    await tester.tap(find.byTooltip('停止录音')); await tester.pumpAndSettle();
    expect(find.text('语音 0:02'), findsOneWidget);
    expect(calls.where((c) => c.method == 'send'), isEmpty);
    await tester.tap(find.text('语音 0:02')); await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'play'), hasLength(1));
    await tester.tap(find.byTooltip('发送附件')); await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    expect(calls.lastWhere((c) => c.method == 'send').arguments['attachment']['kind'], 'AU');
  });

  testWidgets('release long press sends recording', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 600)); await tester.pump();
    await gesture.up(); await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'startRecording'), hasLength(1));
    expect(sent, hasLength(1));
  });

  testWidgets('left slide cancels without sending', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 600)); await tester.pump();
    await gesture.moveBy(const Offset(-90, 0)); await tester.pump();
    await gesture.up(); await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c.method == 'stopRecording').arguments['cancel'], true);
    expect(sent, isEmpty);
  });

  testWidgets('up slide locks recording until explicitly stopped', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 600)); await tester.pump();
    await gesture.moveBy(const Offset(0, -90)); await tester.pump();
    await gesture.up(); await tester.pump();
    expect(find.byTooltip('停止录音'), findsOneWidget);
    expect(calls.where((c) => c.method == 'stopRecording'), isEmpty);
    await tester.tap(find.byTooltip('取消录音')); await tester.pumpAndSettle();
  });

  testWidgets('release while permission is pending cancels late recording', (tester) async {
    recordingPermission = Completer<void>();
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 600)); await tester.pump();
    await gesture.up(); await tester.pump();
    recordingPermission!.complete(); await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c.method == 'stopRecording').arguments['cancel'], true);
    expect(sent, isEmpty);
  });

  test('playback completion clears playing state', () async {
    await media.play(Map<String, dynamic>.from(file), 'voice');
    expect(media.playing, 'voice');
    media.handleEvent({'type': 'playback', 'id': 'voice'});
    expect(media.playing, isNull);
  });
}
