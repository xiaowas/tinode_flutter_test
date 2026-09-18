import 'package:flutter_test/flutter_test.dart';
import 'package:tinode_flutter_test/main.dart';

void main() {
  testWidgets('renders Tinode login form', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Tinode 登录'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });
}
