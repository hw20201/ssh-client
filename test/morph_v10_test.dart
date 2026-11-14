import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/glass_morph_overlay.dart';
import 'package:ssh_client/glass_styles.dart';
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

  /// 胶囊的玻璃脸矩形（上→下排好）：树上只有 morph 的脸是
  /// fluid.DrawBackdrop，按 top 排序就是胶囊顺序。
  List<Rect> capsuleRects(WidgetTester tester) {
    final rects = <Rect>[];
    for (final e in find.byType(fluid.DrawBackdrop).evaluate()) {
      final box = e.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.width < 10) continue; // 预热的 1x1（如果还在）
      rects.add(rect);
    }
    rects.sort((a, b) => a.top.compareTo(b.top));
    return rects;
  }

  /// 一行是不是完整落在某张脸里面（上下左右都用 <= 比，
  /// 底边贴着脸的底边也算在里面——Rect.contains 的底边是开区间，
  /// 行底正好贴着脸底会被它判成外面）。
  bool rectInsideFace(Rect inner, Rect face) =>
      inner.top >= face.top &&
      inner.bottom <= face.bottom &&
      inner.left >= face.left &&
      inner.right <= face.right;

  // ==========================================================================
  // v10: glass retune — more transparent, stronger refraction
  // ==========================================================================

  test('morph face surface colors are more transparent (v10)', () {
    // open=0（按钮）：0xff315b73 alpha .45，和新 dialGlyph tint 对齐；
    // open=1（胶囊）：0xff0e2233 alpha .38，和新 field tint 对齐。
    expect(surfaceColorForOpen(0).a, closeTo(0.45, 0.001));
    expect(surfaceColorForOpen(1).a, closeTo(0.38, 0.001));
    // 两端色相不同（按钮青 0x31 vs 胶囊深青 0x0e），不是同一色硬改 alpha。
    expect(surfaceColorForOpen(0).r, isNot(closeTo(surfaceColorForOpen(1).r, 0.001)));
  });

  test('fluid sheet surface is more transparent (v10)', () {
    expect(GlassStyles.fluidSheetSurface.a, closeTo(0.20, 0.001));
    expect(GlassStyles.fluidColors.container.a, closeTo(0.20, 0.001));
  });

  test('capsule text carries its own shadow (v10, readability without opacity)',
      () {
    // 玻璃更透以后，字靠自己站稳：每级文字都有淡黑阴影，
    // 不靠把玻璃改不透明（主人的铁规矩）。
    for (final style in <TextStyle>[
      GlassText.valueStyle,
      GlassText.labelStyle,
      GlassText.bodyStyle,
      GlassText.hintStyle,
      GlassText.captionStyle,
    ]) {
      expect(style.shadows, isNotNull);
      expect(style.shadows, isNotEmpty);
    }
  });

  testWidgets('glass still renders after the retune: faces + text present',
      (tester) async {
    await openAdd(tester);
    expect(capsuleRects(tester).length, 6);
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('地址 / IP'), findsOneWidget);
    expect(find.text('端口'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('认证方式'), findsOneWidget);
    expect(find.text('保存服务器'), findsOneWidget);
    await tester.tapAt(const Offset(400, 100)); // scrim 关掉添加
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester);
    expect(capsuleRects(tester).length, 3);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('高级设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v10: advanced hint lives inside the capsule when expanded
  // ==========================================================================

  testWidgets('advanced hint is inside the face when expanded',
      (tester) async {
    await openSettings(tester);

    // 收起：提示在脸外面（胶囊 48 高，提示在 48 下面，被裁剪盖住）。
    Rect face = capsuleRects(tester)[2];
    Rect hint = tester.getRect(find.text('高级设置内容待定。'));
    expect(face, const Rect.fromLTWH(280, 334, 240, 48));
    expect(rectInsideFace(hint, face), isFalse);

    // 展开：提示在脸里面（胶囊 88 高）。
    await tester.tap(find.byKey(const ValueKey('advanced_expand_area')));
    await settle(tester);
    face = capsuleRects(tester)[2];
    hint = tester.getRect(find.text('高级设置内容待定。'));
    expect(face, const Rect.fromLTWH(280, 314, 240, 88));
    expect(rectInsideFace(hint, face), isTrue);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v10: expanded groups stay clear of the buttons
  // ==========================================================================

  testWidgets('expanded groups do not cover the bottom-right buttons',
      (tester) async {
    // 添加展开：整组 142-454，按钮柱顶 470，留着 16dp。
    await openAdd(tester);
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester);
    final addRects = capsuleRects(tester);
    expect(addRects.last.bottom, 454);
    expect(addRects.last.bottom, lessThan(470));

    // 设置展开：整组 198-402，离按钮柱远着。
    await tester.tapAt(const Offset(400, 100)); // scrim 关掉添加
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('advanced_expand_area')));
    await settle(tester);
    final settingsRects = capsuleRects(tester);
    expect(settingsRects.last.bottom, 402);
    expect(settingsRects.last.bottom, lessThan(470));
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v10: expansion slides, it does not jump
  // ==========================================================================

  testWidgets('auth expansion slides: face height passes through the middle',
      (tester) async {
    await openAdd(tester);
    // v11：认证方式是 6 个胶囊里的第 5 个（下标 4），不再是下标 2
    //（下标 2 现在是端口胶囊，恒 48 高，旧代码量它永远是 48）。
    expect(capsuleRects(tester)[4].height, 48);

    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    // 先 pump 一帧，让 overlay 的 didUpdateWidget 看到新目标、
    // 260ms 的 RectTween 开始走；再推进 130ms（一半），
    // 脸高在 48 和 144 之间，不是一下子蹦到 144。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final double midHeight = capsuleRects(tester)[4].height;
    expect(midHeight, greaterThan(48));
    expect(midHeight, lessThan(144));

    await settle(tester);
    expect(capsuleRects(tester)[4].height, 144);
    expect(tester.takeException(), isNull);
  });
}
