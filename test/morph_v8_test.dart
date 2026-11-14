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

  /// 有没有一块玻璃盖住这个点（空隙里应该没有玻璃——看得到地球）。
  bool glassCovers(WidgetTester tester, Offset point) {
    for (final rect in capsuleRects(tester)) {
      if (rect.contains(point)) return true;
    }
    return false;
  }

  // ==========================================================================
  // v8: three separate capsules, no outer frame, normal size
  // ==========================================================================

  testWidgets('add capsules: 48 high, 240 wide, gap 4, no outer frame',
      (tester) async {
    await openAdd(tester);
    final rects = capsuleRects(tester);
    // 6 张脸：6 个可见胶囊（48 高）；认证方式收起时 48 高，
    // 密码/私钥/口令在胶囊里面（不占单独的脸）。
    expect(rects.length, 6);
    final visible = rects.where((r) => r.height > 0).toList();
    expect(visible.length, 6);
    for (final rect in visible) {
      expect(rect.width, 240);
      expect(rect.height, 48);
    }
    // 间距 4（6 个可见胶囊；3 个及以下才 10，见 _capsuleGapForCount）。
    expect(visible[1].top - visible[0].bottom, 4);
    expect(visible[2].top - visible[1].bottom, 4);
    expect(visible[3].top - visible[2].bottom, 4);
    expect(visible[4].top - visible[3].bottom, 4);
    expect(visible[5].top - visible[4].bottom, 4);
    // 没有 0 高的脸了（v10：没有子胶囊，展开的胶囊自己变高）。
    expect(rects.where((r) => r.height == 0), isEmpty);
    // 没有外框：没有一块玻璃包着整组（最大的脸就是一个胶囊）。
    final biggest = rects
        .map((r) => r.width * r.height)
        .reduce((a, b) => a > b ? a : b);
    expect(biggest, 240 * 48);
    // 圆角 18（ServerBox 行），不是全圆药丸 24。
    final overlay =
        tester.widget<GlassMorphOverlay>(find.byType(GlassMorphOverlay));
    expect(overlay.targetRadius, 18);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gaps between capsules show the globe (no glass in the gaps)',
      (tester) async {
    await openAdd(tester);
    // 胶囊里有玻璃（名称 146-194、地址 198-246、保存 406-454）。
    expect(glassCovers(tester, const Offset(400, 170)), isTrue);
    expect(glassCovers(tester, const Offset(400, 222)), isTrue);
    expect(glassCovers(tester, const Offset(400, 430)), isTrue);
    // 空隙里没有玻璃——看得到地球，不是装进一个大框子里
    // （空隙 194-198、246-250、298-302、350-354、402-406）。
    expect(glassCovers(tester, const Offset(400, 196)), isFalse);
    expect(glassCovers(tester, const Offset(400, 248)), isFalse);
    expect(glassCovers(tester, const Offset(400, 300)), isFalse);
    expect(glassCovers(tester, const Offset(400, 352)), isFalse);
    expect(glassCovers(tester, const Offset(400, 404)), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('room below the group for future fields', (tester) async {
    await openAdd(tester);
    // 800x600：整组 146-454，按钮柱顶 470，下面留着 16dp 空位。
    final rects = capsuleRects(tester);
    final groupBottom = rects.last.bottom;
    final gearTop =
        tester.getRect(find.byKey(const ValueKey('glass_settings_action'))).top;
    expect(groupBottom, 454);
    expect(gearTop, 470);
    expect(gearTop - groupBottom, 16);
    // 一个胶囊占 52（48 + 间距 4），16dp 不够再放 1 个；
    // 真机（375x822）上整组 257-565、按钮柱顶 692，留着约 127dp，
    // 够再放 2 个胶囊。胶囊不撑满屏幕。
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v8: big X deleted, no SpeedDial
  // ==========================================================================

  testWidgets('big X deleted: only gear and +, gap 18, no dial',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);

    // 大 × 主按钮根本不存在（SpeedDial 整个拿掉了）。
    expect(find.byKey(const ValueKey('glass_main_action')), findsNothing);
    // 只有添加和设置两个按钮，直接摆在右下角。
    expect(find.byKey(const ValueKey('glass_add_action')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('glass_settings_action')),
      findsOneWidget,
    );
    // 设置和添加之间的间隔比原来稍大一点点（v7 的 SpeedDial 间距是 12，
    // v8 是 18）。
    final addTop =
        tester.getRect(find.byKey(const ValueKey('glass_add_action'))).top;
    final gearBottom = tester
        .getRect(find.byKey(const ValueKey('glass_settings_action')))
        .bottom;
    expect(addTop - gearBottom, 18);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v8: capsule count follows the field list (not hardcoded 3)
  // ==========================================================================

  /// 第 i 张脸的当前透明度（脸的 Opacity 祖先；没有 Opacity 就是 1.0）。
  double faceOpacity(WidgetTester tester, int i) {
    final backdrop = find.byType(fluid.DrawBackdrop).at(i);
    final opacities = find.ancestor(
      of: backdrop,
      matching: find.byType(Opacity),
    );
    if (opacities.evaluate().isEmpty) return 1.0;
    return tester.widget<Opacity>(opacities.first).opacity;
  }

  /// 直接建一个 GlassMorphOverlay（不走 SshApp）：targets 有几个，
  /// 脸就有几个。用来验证“加一个字段就多一个胶囊”。
  /// 4 个目标：名称、地址、密钥（临时加的）、保存——密钥是第 4 个，
  /// 窗口 0.79→0.94（_capsuleWindow(3)）。
  Widget fourCapsuleOverlay({
    required fluid.LayerBackdrop backdrop,
    required ValueNotifier<double> openNotifier,
    required List<Rect> targets,
    required List<({double begin, double end})> faceWindows,
    required List<String> labels,
  }) {
    return MaterialApp(
      home: Stack(
        children: [
          Positioned.fill(
            child: fluid.BackdropLayer(
              backdrop: backdrop,
              child: Container(color: Colors.teal),
            ),
          ),
          GlassMorphOverlay(
            backdrop: backdrop,
            origin: const Rect.fromLTWH(696, 536, 88, 48),
            originRadius: 24,
            targets: targets,
            targetRadius: 18,
            anchor: const Icon(
              Icons.add_rounded,
              color: Color(0xffdaf9ff),
              size: 22,
            ),
            faceWindows: faceWindows,
            openNotifier: openNotifier,
            onSettledClosed: () {},
            panelBuilder: (context, close) => <Widget>[
              for (final label in labels)
                SizedBox(
                  width: 240,
                  height: 48,
                  child: Center(child: Text(label)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  testWidgets(
      'adding a key capsule adds one capsule (layout + stagger follow the list)',
      (tester) async {
    // 4 个胶囊：整组高 4*48 + 3*10 = 222，竖着居中（屏高一半 300），
    // 顶 189：名称 189、地址 247、密钥 305、保存 363。
    const fourTargets = <Rect>[
      Rect.fromLTWH(280, 189, 240, 48),
      Rect.fromLTWH(280, 247, 240, 48),
      Rect.fromLTWH(280, 305, 240, 48),
      Rect.fromLTWH(280, 363, 240, 48),
    ];
    const fourWindows = <({double begin, double end})>[
      (begin: 0, end: 0),
      (begin: 0.63, end: 0.78),
      (begin: 0.71, end: 0.86),
      (begin: 0.79, end: 0.94),
    ];
    final backdrop = fluid.LayerBackdrop();
    final openNotifier = ValueNotifier<double>(0);

    await tester.pumpWidget(
      fourCapsuleOverlay(
        backdrop: backdrop,
        openNotifier: openNotifier,
        targets: fourTargets,
        faceWindows: fourWindows,
        labels: const ['名称', '地址 / IP', '密钥', '保存服务器'],
      ),
    );

    // 打开动画逐帧推进：第 4 个胶囊（密钥）按自己的窗口淡入，
    // 不比前面的早、不和前面的同时蹦出来。
    bool sawKeyFadeIn = false;
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final open = openNotifier.value;
      final key = faceOpacity(tester, 3);
      final save = faceOpacity(tester, 2);
      final host = faceOpacity(tester, 1);
      final name = faceOpacity(tester, 0);
      // 自上而下：名称 ≥ 地址 ≥ 保存 ≥ 密钥（窗口一个比一个晚）。
      expect(name, greaterThanOrEqualTo(host - 1e-9));
      expect(host, greaterThanOrEqualTo(save - 1e-9));
      expect(save, greaterThanOrEqualTo(key - 1e-9));
      // open 还没到 0.79 时密钥脸一定是 0（窗口还没开）。
      if (open < 0.79) expect(key, 0.0);
      if (key > 0.0 && key < 1.0) sawKeyFadeIn = true;
    }
    // 密钥脸确实是淡入的（中途出现过 0 到 1 之间的值），不是蹦出来的。
    expect(sawKeyFadeIn, isTrue);

    // 全开后：4 张脸都在目标矩形上，4 个内容都在。
    await settle(tester);
    final rects = capsuleRects(tester);
    expect(rects.length, 4);
    expect(rects[0], fourTargets[0]);
    expect(rects[1], fourTargets[1]);
    expect(rects[2], fourTargets[2]);
    expect(rects[3], fourTargets[3]);
    expect(find.text('密钥'), findsOneWidget);
    expect(find.text('保存服务器'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 再把它拿掉：3 个目标 → 3 张脸，密钥没了。
    const threeTargets = <Rect>[
      Rect.fromLTWH(280, 218, 240, 48),
      Rect.fromLTWH(280, 276, 240, 48),
      Rect.fromLTWH(280, 334, 240, 48),
    ];
    const threeWindows = <({double begin, double end})>[
      (begin: 0, end: 0),
      (begin: 0.63, end: 0.78),
      (begin: 0.71, end: 0.86),
    ];
    await tester.pumpWidget(
      fourCapsuleOverlay(
        backdrop: backdrop,
        openNotifier: openNotifier,
        targets: threeTargets,
        faceWindows: threeWindows,
        labels: const ['名称', '地址 / IP', '保存服务器'],
      ),
    );
    await settle(tester);
    expect(capsuleRects(tester).length, 3);
    expect(find.text('密钥'), findsNothing);
    expect(find.text('保存服务器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v8: settings is two capsules; advanced settings is v9, not v8
  // ==========================================================================

  testWidgets('settings has title + hint + advanced capsules (v9)',
      (tester) async {
    await openSettings(tester);
    final rects = capsuleRects(tester);
    // 3 张脸：3 个可见胶囊（间距 10）；高级设置收起时 48 高，
    // 提示在胶囊里面（不占单独的脸）。
    expect(rects.length, 3);
    expect(rects[0], const Rect.fromLTWH(280, 218, 240, 48));
    expect(rects[1], const Rect.fromLTWH(280, 276, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 334, 240, 48));
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('设置内容正在整理，敬请期待。'), findsOneWidget);
    // v9 的“高级设置”胶囊（可向下展开）已加。
    expect(find.text('高级设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v8: flash regression — at open=0 only the primary face is visible
  // ==========================================================================

  testWidgets('at open=0 only the primary face is visible (no triple layer)',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    // 打开第一帧：open 还是 0，主脸恒为 1，其余五张脸是 0——
    // 不会多层叠加变亮（v6 的教训）。
    await tester.pump(const Duration(milliseconds: 16));
    expect(faceOpacity(tester, 0), 1.0);
    for (int i = 1; i < 6; i++) {
      expect(faceOpacity(tester, i), 0.0);
    }
    await settle(tester);
    for (int i = 0; i < 6; i++) {
      expect(faceOpacity(tester, i), 1.0);
    }
    expect(tester.takeException(), isNull);
  });
}
