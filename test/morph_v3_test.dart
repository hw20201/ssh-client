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
  // pumps instead, in small 100ms steps: a single big pump() jump leaves
  // AnimatedSize / Scaffold layout one frame behind (the dial button is
  // still 0-sized or 32px off at tap time, so the tap misses).
  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    final int steps = (ms / 100).ceil();
    for (int i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
  }

  // v8：没有 SpeedDial、没有大 × 主按钮，两个胶囊按钮直接点。
  Future<void> openAdd(WidgetTester tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester);
  }

  double globeSpeed(WidgetTester tester) =>
      tester.widget<SshGlobe>(find.byType(SshGlobe)).rotationSpeed;

  bool globeAutoRotate(WidgetTester tester) =>
      tester.widget<SshGlobe>(find.byType(SshGlobe)).autoRotate;

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

  // 800x600 test surface, v11 capsules (group centered at screen
  // height/2 = 300, each 240x48, radius 18; gap follows the visible
  // count: 6 visible -> 4, group height 6*48 + 5*4 = 308, top 146):
  // add (collapsed): name (280, 146), host (280, 198),
  // port (280, 250), username (280, 302), auth (280, 354),
  // save (280, 406); group 146-454,
  // buttons top 470 (gear 470-518, + 536-584).
  // settings (collapsed): title (280, 218), hint (280, 276),
  // advanced (280, 334); group 218-382.
  const addNameRect = Rect.fromLTWH(280, 146, 240, 48);
  const addHostRect = Rect.fromLTWH(280, 198, 240, 48);
  const addPortRect = Rect.fromLTWH(280, 250, 240, 48);
  const addUsernameRect = Rect.fromLTWH(280, 302, 240, 48);
  const addAuthRect = Rect.fromLTWH(280, 354, 240, 48);
  const addSaveRect = Rect.fromLTWH(280, 406, 240, 48);
  const settingsTitleRect = Rect.fromLTWH(280, 218, 240, 48);
  const settingsHintRect = Rect.fromLTWH(280, 276, 240, 48);
  const settingsAdvancedRect = Rect.fromLTWH(280, 334, 240, 48);

  testWidgets('tap + morphs into six floating capsules above the buttons',
      (tester) async {
    await openAdd(tester);

    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    // v8：没有外框、没有标题栏，“添加服务器”标题已删。
    expect(find.text('添加服务器'), findsNothing);
    // v11：胶囊内容是名称 + 地址/IP + 端口 + 用户名 + 认证方式 + 保存
    // （密码/口令收在认证方式里，默认收起，但 TextField 在树上是 6 个）。
    expect(find.byType(TextField), findsNWidgets(6));
    // 六个可见胶囊，各自落在目标矩形上（240x48，间距 4）。
    expect(
      hasGlassRect(tester, addNameRect),
      isTrue,
      reason: 'name capsule did not land on its target rect',
    );
    expect(
      hasGlassRect(tester, addHostRect),
      isTrue,
      reason: 'host capsule did not land on its target rect',
    );
    expect(
      hasGlassRect(tester, addPortRect),
      isTrue,
      reason: 'port capsule did not land on its target rect',
    );
    expect(
      hasGlassRect(tester, addUsernameRect),
      isTrue,
      reason: 'username capsule did not land on its target rect',
    );
    expect(
      hasGlassRect(tester, addAuthRect),
      isTrue,
      reason: 'auth capsule did not land on its target rect',
    );
    expect(
      hasGlassRect(tester, addSaveRect),
      isTrue,
      reason: 'save capsule did not land on its target rect',
    );
    // Overlay root Stack is full-screen (0x0 regression).
    expect(
      tester.getSize(find.byType(GlassMorphOverlay)),
      const Size(800, 600),
    );
    // 整组底边（454）不盖右下角的按钮（齿轮顶 470）；
    // 大 × 主按钮根本不存在（v8 已删 SpeedDial 和收纳）。
    const groupBottom = 454.0;
    expect(
      tester.getRect(find.byKey(const ValueKey('glass_settings_action'))).top,
      greaterThan(groupBottom),
    );
    expect(
      find.byKey(const ValueKey('glass_main_action')),
      findsNothing,
    );
  });

  testWidgets('earth slows to 3 deg/s while a panel is open, not stopped',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    expect(globeSpeed(tester), 12);
    expect(globeAutoRotate(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);
    expect(globeAutoRotate(tester), isTrue);
    expect(globeSpeed(tester), 3);

    // Close via scrim tap (no title bar / header X in v8), earth back to 12.
    await tester.tapAt(const Offset(400, 500));
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeSpeed(tester), 12);
  });

  testWidgets('add form has 6 fields and no No Material exception',
      (tester) async {
    await openAdd(tester);

    // v11：名称 + 地址/IP + 端口 + 用户名 + 密码 + 口令
    // （密码/口令收在认证方式里，默认收起，但 TextField 在树上；
    // 端口/用户名是 v11 新加的胶囊）。
    expect(find.byType(TextField), findsNWidgets(6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrim tap mid-flight reverses the morph and closes it',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    // Mid-flight: tap at 100ms, not 400ms. The v11 capsules interpolate
    // from the bottom-right button (y~536) toward the group (y 146-454);
    // at 100ms the faces are still around y~400, so (400, 100) is scrim.
    await settle(tester, 100);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    await tester.tapAt(const Offset(400, 100));
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeSpeed(tester), 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings morph opens three capsules, scrim closes it',
      (tester) async {
    await openSettings(tester);

    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    // v9：设置三个可见胶囊——标题 + 提示 + 高级设置
    // （高级提示收起时高 0；深色模式等旧设置项已拿掉）。
    expect(find.text('设置内容正在整理，敬请期待。'), findsOneWidget);
    expect(globeSpeed(tester), 3);
    expect(
      hasGlassRect(tester, settingsTitleRect),
      isTrue,
      reason: 'settings title capsule did not land on its target rect',
    );
    expect(
      hasGlassRect(tester, settingsHintRect),
      isTrue,
      reason: 'settings hint capsule did not land on its target rect',
    );
    expect(
      hasGlassRect(tester, settingsAdvancedRect),
      isTrue,
      reason: 'settings advanced capsule did not land on its target rect',
    );

    // v8：没有标题栏拖回，关闭只走 scrim 点按。
    await tester.tapAt(const Offset(400, 500));
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeSpeed(tester), 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no slow-mode control anywhere in the app', (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);

    // 慢速是演示用的工具，v3 已删干净（全树 grep 也验过）。
    expect(find.textContaining('慢速'), findsNothing);
    expect(find.textContaining('×6'), findsNothing);
  });

  testWidgets(
      'no main button at all; both capsule buttons stay, hidden one passes taps to the scrim',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    // v8：大 × 主按钮根本不存在（SpeedDial 已拿掉），两个胶囊按钮
    // 直接摆在右下角。先记下 + 的中心（面板打开后它藏起来，
    // 但位置不变，点那里要透到 scrim 去关面板——v5 的死区在 v8 修了）。
    final addCenter =
        tester.getCenter(find.byKey(const ValueKey('glass_add_action')));
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    expect(find.byKey(const ValueKey('glass_main_action')), findsNothing);
    expect(find.byKey(const ValueKey('glass_add_action')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('glass_settings_action')),
      findsOneWidget,
    );
    const groupBottom = 454.0;
    expect(
      tester.getRect(find.byKey(const ValueKey('glass_add_action'))).top,
      greaterThan(groupBottom),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('glass_settings_action'))).top,
      greaterThan(groupBottom),
    );

    // Tapping the other child reaches the button (not the scrim):
    // the add panel stays open instead of closing.
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester, 300);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(find.text('保存服务器'), findsOneWidget);

    // Tapping where the hidden + button is falls through to the
    // full-screen scrim and closes the panel (v8: IgnorePointer wraps
    // the whole _DialButton, so the hidden spot is no longer a dead zone).
    await tester.tapAt(addCenter);
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeSpeed(tester), 12);

    // Both buttons come back as soon as the panel is gone.
    expect(find.byKey(const ValueKey('glass_add_action')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('glass_settings_action')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
