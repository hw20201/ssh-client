import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/glass_morph_overlay.dart';
import 'package:ssh_client/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => null,
    );
    await fluid.FluidGlass.ensureInitialized();
  });

  // The globe has a continuously running rotation ticker, so
  // pumpAndSettle() never settles. Advance the fake clock with explicit
  // pumps instead, in small 100ms steps.
  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    final int steps = (ms / 100).ceil();
    for (int i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
  }

  testWidgets('tap + opens the add morph capsules', (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);

    expect(find.byType(GlassMorphOverlay), findsNothing);
    // v8：没有外框、没有标题栏，“添加服务器”标题已删；
    // 两个胶囊按钮直接摆在右下角，不用先展开 SpeedDial。
    expect(find.text('添加服务器'), findsNothing);
    expect(find.byKey(const ValueKey('glass_add_action')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('glass_settings_action')),
      findsOneWidget,
    );
    // 大 × 主按钮已删（没有 SpeedDial、没有收纳）。
    expect(find.byKey(const ValueKey('glass_main_action')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester, 800);

    expect(
      find.byType(GlassMorphOverlay),
      findsOneWidget,
      reason: 'tapped + but the morph overlay never entered the tree',
    );
    // v11：六个可见胶囊——名称 + 地址/IP + 端口 + 用户名 + 认证方式 + 保存；
    // 密码/口令收在认证方式里（默认收起），但 TextField 在树上是 6 个。
    expect(find.byType(TextField), findsNWidgets(6));
    expect(find.text('认证方式'), findsOneWidget);
    expect(find.text('保存服务器'), findsOneWidget);
  });

  testWidgets('tap gear opens the settings morph capsules', (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);

    expect(find.byType(GlassMorphOverlay), findsNothing);

    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester, 800);

    expect(
      find.byType(GlassMorphOverlay),
      findsOneWidget,
      reason: 'tapped gear but the morph overlay never entered the tree',
    );
    // v9：设置四个胶囊——标题“设置” + 提示 + 高级设置 + 高级提示
    // （高级提示收起时高 0；深色模式等旧设置项已拿掉）。
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('设置内容正在整理，敬请期待。'), findsOneWidget);
  });
}
