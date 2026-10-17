import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/shell/sub_window_blocked_page.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';

class _TaggedPage extends StatelessWidget {
  const _TaggedPage({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text(text));
}

void main() {
  tearDown(() => MultiWindowRole.isSubWindow = false);

  testWidgets('子窗：显示拦截文案与返回键，不构建子页', (tester) async {
    MultiWindowRole.isSubWindow = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: SubWindowBlockedPage(child: _TaggedPage(text: 'SECRET_CHILD')),
      ),
    );
    expect(find.text('该功能仅可在主窗口使用'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('SECRET_CHILD'), findsNothing,
        reason: '子页在子窗模式不得构建');
  });

  testWidgets('主窗：透传子页', (tester) async {
    MultiWindowRole.isSubWindow = false;
    await tester.pumpWidget(
      const MaterialApp(
        home: SubWindowBlockedPage(child: _TaggedPage(text: 'SECRET_CHILD')),
      ),
    );
    expect(find.text('该功能仅可在主窗口使用'), findsNothing);
    expect(find.text('SECRET_CHILD'), findsOneWidget);
  });
}
