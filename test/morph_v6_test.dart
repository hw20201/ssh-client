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

  // v8：没有 SpeedDial、没有大 × 主按钮，齿轮直接点。
  Future<void> openSettings(WidgetTester tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester);
  }

  bool globeAutoRotate(WidgetTester tester) =>
      tester.widget<SshGlobe>(find.byType(SshGlobe)).autoRotate;

  double globeSpeed(WidgetTester tester) =>
      tester.widget<SshGlobe>(find.byType(SshGlobe)).rotationSpeed;

  /// 一个控件祖先链里的所有 Opacity 值（v5 的 childHidden 同款做法：
  /// 链里还可能有别的 Opacity）。prism 的 LiquidGlass 在 widget 层
  /// 没有 Opacity（只有 render 层的 OpacityLayer），所以链里会变的
  /// 只有我们自己加的淡入 Opacity。
  List<double> ancestorOpacities(WidgetTester tester, String actionKey) =>
      tester
          .widgetList<Opacity>(
            find.ancestor(
              of: find.byKey(ValueKey(actionKey)),
              matching: find.byType(Opacity),
            ),
          )
          .map((o) => o.opacity)
          .toList();

  /// Morph 玻璃那块 DrawBackdrop 的阴影（v7：辉光↔黑阴影插值，
  /// 见 shadowForOpen；v6 是 alpha 淡出）。它是“设置”标题胶囊的
  /// DrawBackdrop 祖先（标题胶囊的脸就是这块玻璃；提示胶囊的脸是
  /// 它的兄弟、不是祖先）。中途矩形一直在变，按矩形找会找不到，
  /// 按祖先找才稳。找不到就返回 null。
  fluid.GlassShadow? morphShadow(WidgetTester tester) {
    final found = find.ancestor(
      of: find.text('设置'),
      matching: find.byType(fluid.DrawBackdrop),
    );
    if (found.evaluate().isEmpty) return null;
    final widget = found.evaluate().first.widget as fluid.DrawBackdrop;
    return widget.shadow?.call();
  }

  /// 关面板后、以 16ms 步进 pump，直到 overlay 卸载（v7：弹簧关到底
  /// 就立刻卸载，没有 v6 的 150ms 交叉淡入阶段）。最多 60 步（960ms），
  /// 弹簧关闭本身约 350ms，超时就是 bug。
  Future<void> pumpUntilUnmount(WidgetTester tester) async {
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(GlassMorphOverlay).evaluate().isEmpty) return;
    }
    fail('overlay did not unmount within 960ms after closing');
  }

  testWidgets('shadow lerps from button glow to panel black (flash, v7 step E)',
      (tester) async {
    await openSettings(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    // 打开稳态：阴影是面板黑阴影（标准）。
    expect(morphShadow(tester), fluid.GlassShadow.standard);

    // 点 scrim 关：关到一半（约 100ms）阴影已在往辉光走——
    // 半径 < 24（往 14 走）、颜色不再是纯黑（往青走）。
    // v6 的阴影是 alpha 淡出（1→0），v7 是辉光↔黑阴影插值。
    // 注意：必须用小步 pump（2×50ms），单次大 pump 推不动弹簧
    // ticker（v2 踩过的坑），open 会停在 1.0。
    await tester.tapAt(const Offset(400, 500));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final shadow = morphShadow(tester);
    expect(shadow, isNotNull);
    expect(shadow!.radius, lessThan(24));
    expect(shadow.radius, greaterThan(14));
    expect(shadow.color, isNot(fluid.GlassShadow.standard.color));

    // 关到底：overlay 直接卸载（v7 没有交叉淡入阶段）。
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'close unmounts at once: tapped child returns full-bright, no main button (flash, v7 step E)',
      (tester) async {
    await openSettings(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    // 打开稳态：被点的齿轮藏着（链里最小是 0.0）；v8 没有主按钮。
    expect(
      ancestorOpacities(tester, 'glass_settings_action').reduce(
        (a, b) => a < b ? a : b,
      ),
      0.0,
    );
    expect(find.byKey(const ValueKey('glass_main_action')), findsNothing);

    // 点 scrim 关：v7 没有交叉淡入——弹簧关到底就直接卸载。
    // 卸载那一刻：齿轮已满亮度回来（链里最小是 1.0，没有 0.0、
    // 没有中间值）。v6 在这一刻 overlay 还在、齿轮还在淡入
    // （两层同时可见、叠加变亮——就是闪光的凶手）。
    // v8 也没有主按钮要淡入（它根本不存在）。
    await tester.tapAt(const Offset(400, 500));
    await pumpUntilUnmount(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(
      ancestorOpacities(tester, 'glass_settings_action').reduce(
        (a, b) => a < b ? a : b,
      ),
      1.0,
      reason: 'tapped child must return at full brightness, not fade in',
    );
    expect(find.byKey(const ValueKey('glass_main_action')), findsNothing);
    await settle(tester);
    expect(
      ancestorOpacities(tester, 'glass_settings_action')
          .any((o) => o == 1.0),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('globe freezes only while the springs animate (smoothness A)',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    expect(globeAutoRotate(tester), isTrue);
    expect(globeSpeed(tester), 12);

    // 打开中途（200ms，弹簧在走）：ticker 停掉，背景不再重抓。
    // 冻地球的通知是 post-frame 推迟一帧写的（见 _syncAnimating），
    // 所以要 pump 两帧才看得到 autoRotate 翻 false；200ms 时弹簧
    // 还在走（打开约 450ms），仍是中途。
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(globeAutoRotate(tester), isFalse);

    // 打开稳态：恢复慢转 3°/秒（面板开着不停转，主人已定）。
    await settle(tester);
    expect(globeAutoRotate(tester), isTrue);
    expect(globeSpeed(tester), 3);

    // 关闭中途（200ms，弹簧往回走）：ticker 再次停掉。
    // 同样 pump 两帧（post-frame 推迟一帧）；200ms 时关闭弹簧
    // 还在走（关闭约 350ms），仍是中途。
    await tester.tapAt(const Offset(400, 500));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(globeAutoRotate(tester), isFalse);

    // 关到底：v7 直接卸载、_onMorphSettledClosed 里把
    // _morphAnimating 置 false，地球恢复正常 12°/秒（v7 修复：
    // 立刻卸载会让 overlay 的 post-frame 回调因 mounted=false
    // 直接返回，_morphAnimating 卡在 true、地球一直冻着——
    // 这个测试抓的就是它）。
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(globeAutoRotate(tester), isTrue);
    expect(globeSpeed(tester), 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets('children stay anchored during the fade (no LayerLink break)',
      (tester) async {
    await openSettings(tester);
    final Offset addCenter =
        tester.getCenter(find.byKey(const ValueKey('glass_add_action')));
    final Offset gearCenter = tester.getCenter(
      find.byKey(const ValueKey('glass_settings_action')),
    );

    // 关面板、卸载：v8 的两个按钮是主页 Stack 里的普通 Positioned，
    // 没有 LeaderLayer/OverlayEntry，位置不该动。断言卸载后和
    // 稳态后两个时刻（v4 的教训：dialRoot 断 LeaderLayer 时子按钮
    // 会掉到左上角去，当时实测 y=5/63）。
    await tester.tapAt(const Offset(400, 500));
    await pumpUntilUnmount(tester);
    expect(
      tester.getCenter(find.byKey(const ValueKey('glass_add_action'))),
      addCenter,
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('glass_settings_action'))),
      gearCenter,
    );

    // 稳态后：位置仍不变。
    await settle(tester);
    expect(
      tester.getCenter(find.byKey(const ValueKey('glass_add_action'))),
      addCenter,
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('glass_settings_action'))),
      gearCenter,
    );
    expect(tester.takeException(), isNull);
  });
}
