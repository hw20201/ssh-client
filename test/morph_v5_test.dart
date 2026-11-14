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

  /// 子按钮是不是藏着：v5 的 ValueListenableBuilder+Opacity 是 glyph
  /// 祖先链里的一个 Opacity。链里还可能有别的 Opacity（prism
  /// LiquidGlass 内部），morph 脸的 Opacity 不在这条链上，所以不
  /// 断言“最近一个”，只断言：藏着时链里有 0.0，露着时链里没有 0.0。
  bool childHidden(WidgetTester tester, String actionKey) {
    final opacities = tester.widgetList<Opacity>(
      find.ancestor(
        of: find.byKey(ValueKey(actionKey)),
        matching: find.byType(Opacity),
      ),
    );
    return opacities.any((o) => o.opacity == 0.0);
  }

  testWidgets('open settings hides the gear, keeps + visible and tappable',
      (tester) async {
    await openSettings(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    // v5：被点的齿轮藏起来（它变成了设置胶囊），没被点的 + 留在原地。
    expect(childHidden(tester, 'glass_settings_action'), isTrue);
    expect(childHidden(tester, 'glass_add_action'), isFalse);

    // 点另一个子按钮（+）：面板不关（_openMorph 挡掉第二个面板）。
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester, 300);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('open add hides +, keeps gear visible and tappable',
      (tester) async {
    await openAdd(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(find.text('保存服务器'), findsOneWidget);

    // v5：被点的 + 藏起来（它变成了添加胶囊），没被点的齿轮留在原地。
    expect(childHidden(tester, 'glass_add_action'), isTrue);
    expect(childHidden(tester, 'glass_settings_action'), isFalse);

    // 点另一个子按钮（齿轮）：面板不关。
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester, 300);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(find.text('保存服务器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'tapped child stays hidden mid-close and returns when fully closed',
      (tester) async {
    await openSettings(tester);
    expect(childHidden(tester, 'glass_settings_action'), isTrue);

    // 点 scrim 关面板：弹簧正在往回走（只 pump 100ms，还没关到底），
    // 被点的齿轮必须还藏着——变形脸 + 真按钮不能同时出现（虚影根因）。
    await tester.tapAt(const Offset(400, 500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(childHidden(tester, 'glass_settings_action'), isTrue);
    expect(childHidden(tester, 'glass_add_action'), isFalse);

    // 关到底：overlay 卸载，被点的齿轮回来（v8 没有大 × 主按钮）。
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeSpeed(tester), 12);
    expect(childHidden(tester, 'glass_settings_action'), isFalse);
    expect(childHidden(tester, 'glass_add_action'), isFalse);
    expect(find.byKey(const ValueKey('glass_main_action')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap on the hidden gear passes through to the scrim (v8 fix)',
      (tester) async {
    await openSettings(tester);
    expect(childHidden(tester, 'glass_settings_action'), isTrue);

    // v8：被藏的按钮不再是死区——IgnorePointer 包在整个 _DialButton
    // 外面（v5 是 SpeedDialChild 自己的 FAB 在 IgnorePointer 外面
    // 吞点按），藏起来的齿轮那个位置点按会透到全屏 scrim 去关面板。
    // （v5 的行为是“点按无反应、面板还开着”，v8 修了它。）
    await tester.tap(
      find.byKey(const ValueKey('glass_settings_action')),
      warnIfMissed: false,
    );
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeSpeed(tester), 12);
    expect(childHidden(tester, 'glass_settings_action'), isFalse);
    expect(tester.takeException(), isNull);
  });

}
