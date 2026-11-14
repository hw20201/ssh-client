import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/glass_morph_overlay.dart';
import 'package:ssh_client/globe.dart';
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

  // v8：没有 SpeedDial、没有大 × 主按钮，+ 直接点。
  Future<void> openAdd(WidgetTester tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);
  }

  double globeSpeed(WidgetTester tester) =>
      tester.widget<SshGlobe>(find.byType(SshGlobe)).rotationSpeed;

  // The morph glass is one of several DrawBackdrops in the tree
  // (form sections have their own); find the one that landed on [expected].
  bool hasGlassRect(WidgetTester tester, Rect expected) {
    for (final e in find.byType(fluid.DrawBackdrop).evaluate()) {
      final box = e.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if ((rect.left - expected.left).abs() < 1 &&
          (rect.top - expected.top).abs() < 1 &&
          (rect.width - expected.width).abs() < 1 &&
          (rect.height - expected.height).abs() < 1) {
        return true;
      }
    }
    return false;
  }

  // 800x600 test surface, v11: add group is six 240x48 capsules
  // (name 146, host 198, port 250, username 302, auth 354, save 406;
  // group 146-454), buttons top 470.

  testWidgets('scrim below the panel closes it (v3 dead zone)',
      (tester) async {
    await openAdd(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    // v3 的 scrim 只盖到面板底边，面板下面那块根本点不动；
    // v4 恢复全屏 scrim，点面板下方空白就关（v11 整组底边 454，
    // (400, 500) 在整组之下、按钮柱之外，是 scrim）。
    await tester.tapAt(const Offset(400, 500));
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeSpeed(tester), 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrim at the side margin closes it', (tester) async {
    await openAdd(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    // 面板左侧 16px 边条（x < 16）也是 scrim：点 (8, 300) 就关。
    await tester.tapAt(const Offset(8, 300));
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeSpeed(tester), 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets('child button tap reaches through the full-screen scrim',
      (tester) async {
    await openAdd(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    // 两个胶囊按钮是主页 Stack 里的 Positioned（在 overlay 和全屏
    // scrim 之上），点按不会被 scrim 吞掉：点齿轮，添加面板还开着
    // （_openMorph 挡掉第二个面板）。
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester, 300);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(find.text('保存服务器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a device-like surface the add capsules fit without scrolling',
      (tester) async {
    // 真机逻辑屏约 375x822dp。v11 整组竖着居中（屏高一半 411）：
    // 六个可见 240x48 胶囊（左 67.5，间距 4，组高 6*48 + 5*4 = 308），
    // 名称 257、地址 309、端口 361、用户名 413、认证方式 465、
    // 保存 517，整组 257-565，按钮柱顶 692——
    // 下面还剩约 127dp 空位。v4 的 830.6
    // 完整表单已不存在（内容掏空到 6 字段 + 认证 + 保存），
    // 胶囊在真机上整个放得下，不用滚动。
    tester.view.physicalSize = const Size(750, 1644);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);

    const deviceNameRect = Rect.fromLTWH(67.5, 257, 240, 48);
    const deviceHostRect = Rect.fromLTWH(67.5, 309, 240, 48);
    const devicePortRect = Rect.fromLTWH(67.5, 361, 240, 48);
    const deviceUsernameRect = Rect.fromLTWH(67.5, 413, 240, 48);
    const deviceAuthRect = Rect.fromLTWH(67.5, 465, 240, 48);
    const deviceSaveRect = Rect.fromLTWH(67.5, 517, 240, 48);
    expect(
      hasGlassRect(tester, deviceNameRect),
      isTrue,
      reason: 'name capsule did not land on the device target rect',
    );
    expect(
      hasGlassRect(tester, deviceHostRect),
      isTrue,
      reason: 'host capsule did not land on the device target rect',
    );
    expect(
      hasGlassRect(tester, devicePortRect),
      isTrue,
      reason: 'port capsule did not land on the device target rect',
    );
    expect(
      hasGlassRect(tester, deviceUsernameRect),
      isTrue,
      reason: 'username capsule did not land on the device target rect',
    );
    expect(
      hasGlassRect(tester, deviceAuthRect),
      isTrue,
      reason: 'auth capsule did not land on the device target rect',
    );
    expect(
      hasGlassRect(tester, deviceSaveRect),
      isTrue,
      reason: 'save capsule did not land on the device target rect',
    );
    // 六个字段 + 认证 + 保存按钮打开就都在各自胶囊里，不用滚动。
    final saveRect =
        tester.getRect(find.byKey(const ValueKey('glass_form_save')));
    expect(saveRect.top, greaterThanOrEqualTo(deviceSaveRect.top));
    expect(saveRect.bottom, lessThanOrEqualTo(deviceSaveRect.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a tall screen the capsules keep their content height',
      (tester) async {
    // 800x1100 逻辑屏：v11 整组按内容算高（308），不随屏高变——
    // 宽 240 居中（左 280），整组竖着居中（屏高一半 550）：
    // 名称 396、地址 448、端口 500、用户名 552、认证方式 604、
    // 保存 656，整组 396-704。
    tester.view.physicalSize = const Size(2400, 3300);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);

    const tallNameRect = Rect.fromLTWH(280, 396, 240, 48);
    const tallHostRect = Rect.fromLTWH(280, 448, 240, 48);
    const tallPortRect = Rect.fromLTWH(280, 500, 240, 48);
    const tallUsernameRect = Rect.fromLTWH(280, 552, 240, 48);
    const tallAuthRect = Rect.fromLTWH(280, 604, 240, 48);
    const tallSaveRect = Rect.fromLTWH(280, 656, 240, 48);
    expect(
      hasGlassRect(tester, tallNameRect),
      isTrue,
      reason: 'name capsule did not keep its height on a tall screen',
    );
    expect(
      hasGlassRect(tester, tallHostRect),
      isTrue,
      reason: 'host capsule did not keep its height on a tall screen',
    );
    expect(
      hasGlassRect(tester, tallPortRect),
      isTrue,
      reason: 'port capsule did not keep its height on a tall screen',
    );
    expect(
      hasGlassRect(tester, tallUsernameRect),
      isTrue,
      reason: 'username capsule did not keep its height on a tall screen',
    );
    expect(
      hasGlassRect(tester, tallAuthRect),
      isTrue,
      reason: 'auth capsule did not keep its height on a tall screen',
    );
    expect(
      hasGlassRect(tester, tallSaveRect),
      isTrue,
      reason: 'save capsule did not keep its height on a tall screen',
    );
    final saveRect =
        tester.getRect(find.byKey(const ValueKey('glass_form_save')));
    expect(saveRect.top, greaterThanOrEqualTo(tallSaveRect.top));
    expect(saveRect.bottom, lessThanOrEqualTo(tallSaveRect.bottom));
    expect(tester.takeException(), isNull);
  });

  // v7 已删：展开/收起开关不存在了（胶囊高度按内容固定 262，
  // 不再展开/收起）。这个测试随功能一起删掉，特此留注。
}
