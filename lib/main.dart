import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const TinodeTestPage(),
    );
  }
}

class TinodeTestPage extends StatefulWidget {
  const TinodeTestPage({super.key});

  @override
  State<TinodeTestPage> createState() => _TinodeTestPageState();
}

class _TinodeTestPageState extends State<TinodeTestPage> {

  static const MethodChannel _channel = MethodChannel('tinode');

  String status = '尚未连接';

  Future<void> connect() async {
    setState(() {
      status = '连接中...';
    });

    try {
      final result = await _channel.invokeMethod('connect');

      setState(() {
        status = '连接结果：$result';
      });
    } on PlatformException catch (e) {
      setState(() {
        status = '连接失败：${e.code}\n${e.message}';
      });
    } catch (e) {
      setState(() {
        status = '连接失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tinode Flutter Test'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              status,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: connect,
              child: const Text('连接 Tinode'),
            ),
          ],
        ),
      ),
    );
  }
}

