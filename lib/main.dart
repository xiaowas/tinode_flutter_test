import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: const TinodeLoginPage(),
      );
}

class TinodeLoginPage extends StatefulWidget {
  const TinodeLoginPage({super.key});

  @override
  State<TinodeLoginPage> createState() => _TinodeLoginPageState();
}

class _TinodeLoginPageState extends State<TinodeLoginPage> {
  static const MethodChannel _channel = MethodChannel('tinode');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String _status = '请输入 Tinode 账号';
  bool _loggingIn = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _status = '请输入用户名和密码');
      return;
    }
    setState(() {
      _loggingIn = true;
      _status = '登录中...';
    });
    try {
      final response = await _channel.invokeMethod<Map<Object?, Object?>>(
        'login',
        {'username': username, 'password': password},
      );
      setState(() => _status = '登录成功\n用户 ID：${response?['uid'] ?? ''}');
    } on PlatformException catch (error) {
      setState(() => _status = '登录失败：${error.message ?? error.code}');
    } catch (error) {
      setState(() => _status = '登录失败：$error');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
                    controller: _usernameController,
                    enabled: !_loggingIn,
                    decoration: const InputDecoration(labelText: '用户名'),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    enabled: !_loggingIn,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密码'),
                    onSubmitted: (_) => _login(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loggingIn ? null : _login,
                      child: Text(_loggingIn ? '登录中...' : '登录'),
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
}
