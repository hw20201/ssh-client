import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
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

  /// 等一段文字出现（保存提示靠它）。光 pump 假时间不够：
  /// 保存要做真实 I/O（vault mock + prefs mock + geo 查库），
  /// 真实 I/O 只在真实时间里推进，假时间里会永远挂起；
  /// 所以每轮先 runAsync 跳出假时间、真实等 500ms，再 pump 一帧。
  /// 预算 30 秒真实时间。
  Future<bool> waitForText(
    WidgetTester tester,
    String text, {
    int timeoutMs = 30000,
  }) async {
    final int rounds = (timeoutMs / 500).ceil();
    for (int i = 0; i < rounds; i++) {
      if (find.textContaining(text).evaluate().isNotEmpty) return true;
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump(const Duration(milliseconds: 100));
    }
    return find.textContaining(text).evaluate().isNotEmpty;
  }

  // ==========================================================================
  // Step A: capsule buttons, no dial, no main button (v8)
  // ==========================================================================

  testWidgets('two capsule buttons sit at bottom-right, no dial (v8)',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);

    // v8：大 × 主按钮已删（没有 SpeedDial、没有收纳），两个胶囊按钮
    // 直接摆在右下角、不用先展开。
    expect(find.byKey(const ValueKey('glass_main_action')), findsNothing);
    // 两个按钮 88x48 胶囊（圆角 24 = 48/2），齿轮在上、+ 在下，
    // 间距 18（比原来稍大一点点）。
    expect(
      tester.getSize(find.byKey(const ValueKey('glass_add_action'))),
      const Size(88, 48),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('glass_settings_action'))),
      const Size(88, 48),
    );
    final addTop =
        tester.getRect(find.byKey(const ValueKey('glass_add_action'))).top;
    final gearBottom = tester
        .getRect(find.byKey(const ValueKey('glass_settings_action')))
        .bottom;
    expect(addTop - gearBottom, 18);
    expect(tester.takeException(), isNull);
  });

  testWidgets('morph starts from the capsule button rect, targets are 6 capsules',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);

    // 点按前量一下 + 胶囊的全局矩形。
    final Rect origin =
        tester.getRect(find.byKey(const ValueKey('glass_add_action')));
    expect(origin.width, 88);
    expect(origin.height, 48);

    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    // 打开第一帧（弹簧刚起步）：overlay 的 origin 就是这个矩形、
    // originRadius 是高/2 = 24，不再是写死的 29。
    await tester.pump(const Duration(milliseconds: 16));
    final overlay =
        tester.widget<GlassMorphOverlay>(find.byType(GlassMorphOverlay));
    expect((overlay.origin.left - origin.left).abs(), lessThan(1.0));
    expect((overlay.origin.top - origin.top).abs(), lessThan(1.0));
    expect((overlay.origin.width - origin.width).abs(), lessThan(1.0));
    expect((overlay.origin.height - origin.height).abs(), lessThan(1.0));
    expect(overlay.originRadius, 24);
    // v11：目标是六个分开的胶囊矩形（240 宽、间距 4、整组居中 146-454），
    // 圆角 18（ServerBox 行，不是全圆药丸 24）；
    // 认证方式收起时 48 高，密码/私钥/口令在胶囊里面（不占单独的目标矩形）。
    expect(overlay.targetRadius, 18);
    expect(overlay.targets.length, 6);
    expect(overlay.targets[0], const Rect.fromLTWH(280, 146, 240, 48));
    expect(overlay.targets[1], const Rect.fromLTWH(280, 198, 240, 48));
    expect(overlay.targets[2], const Rect.fromLTWH(280, 250, 240, 48));
    expect(overlay.targets[3], const Rect.fromLTWH(280, 302, 240, 48));
    expect(overlay.targets[4], const Rect.fromLTWH(280, 354, 240, 48));
    expect(overlay.targets[5], const Rect.fromLTWH(280, 406, 240, 48));

    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // Step B: capsule panel + emptied content (v7)
  // ==========================================================================

  /// 三个胶囊的玻璃脸矩形（上→下排好）：树上只有 morph 的脸是
  /// fluid.DrawBackdrop（字段是裸 TextField、保存按钮是 prism 玻璃、
  /// 预热的 1x1 早拿掉了），按 top 排序就是胶囊顺序。
  /// 宽 < 10 的是预热残影（如果还在），跳过。
  List<Rect> capsuleRects(WidgetTester tester) {
    final rects = <Rect>[];
    for (final e in find.byType(fluid.DrawBackdrop).evaluate()) {
      final box = e.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.width < 10) continue;
      rects.add(rect);
    }
    rects.sort((a, b) => a.top.compareTo(b.top));
    return rects;
  }

  /// 整组的外包矩形（胶囊们的并集）：关尾平滑测试用它量高度。
  Rect groupRect(WidgetTester tester) {
    final rects = capsuleRects(tester);
    double top = rects.first.top;
    double bottom = rects.first.bottom;
    for (final r in rects) {
      if (r.top < top) top = r.top;
      if (r.bottom > bottom) bottom = r.bottom;
    }
    return Rect.fromLTRB(rects.first.left, top, rects.first.right, bottom);
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

  testWidgets('add is six visible capsules, floating, no outer frame',
      (tester) async {
    await openAdd(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    // 800x600 表面：六个可见胶囊，各自 240x48、圆角 18，
    // 间距 4，整组竖着居中（146-454），四边留空，不贴底、不满宽；
    // 认证方式收起时 48 高，密码/私钥/口令在胶囊里面（不在外面占目标矩形）。
    final rects = capsuleRects(tester);
    // ignore: avoid_print
    print('ADD CAPSULE RECTS: $rects');
    expect(rects.length, 6);
    expect(rects[0], const Rect.fromLTWH(280, 146, 240, 48));
    expect(rects[1], const Rect.fromLTWH(280, 198, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 250, 240, 48));
    expect(rects[3], const Rect.fromLTWH(280, 302, 240, 48));
    expect(rects[4], const Rect.fromLTWH(280, 354, 240, 48));
    expect(rects[5], const Rect.fromLTWH(280, 406, 240, 48));
    // 胶囊之间是地球（空隙里没有容器背景）：没有包着胶囊们的
    // 大框子——最大的脸就是一个胶囊（240x48），不是 240x308。
    expect(rects[0].height, 48);
    // 整组底边 454 在按钮柱顶（470）之上，留着 16dp 空位在下面。
    final group = groupRect(tester);
    expect(group.top, 146);
    expect(group.bottom, 454);
    expect(group.top, greaterThan(16));
    expect(group.left, greaterThan(16));
    expect(group.right, lessThan(800 - 16));
    final overlay =
        tester.widget<GlassMorphOverlay>(find.byType(GlassMorphOverlay));
    expect(overlay.targetRadius, 18);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings is three visible capsules: title + hint + advanced (v9)',
      (tester) async {
    await openSettings(tester);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('设置内容正在整理，敬请期待。'), findsOneWidget);

    // 三个可见胶囊：标题（218）+ 提示（276）+ 高级设置（334），
    // 各 240x48、间距 10（3 个可见）；高级设置收起时 48 高，
    // 提示在胶囊里面（不占单独的目标矩形）。
    final rects = capsuleRects(tester);
    // ignore: avoid_print
    print('SETTINGS CAPSULE RECTS: $rects');
    expect(rects.length, 3);
    expect(rects[0], const Rect.fromLTWH(280, 218, 240, 48));
    expect(rects[1], const Rect.fromLTWH(280, 276, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 334, 240, 48));
    // v9 的“高级设置”胶囊（可向下展开）已加。
    expect(find.text('高级设置'), findsOneWidget);

    // 旧设置项全拿掉。
    expect(find.text('深色模式'), findsNothing);
    expect(find.text('主题风格'), findsNothing);
    expect(find.text('终端字号'), findsNothing);
    expect(find.text('默认 SSH 端口'), findsNothing);
    expect(find.text('主机指纹校验'), findsNothing);
    expect(find.text('离线 IP 地理定位'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add keeps name + host + port + username + auth + password + key + save (v11)',
      (tester) async {
    await openAdd(tester);
    // v8：没有标题栏，“添加服务器”标题已删。
    expect(find.text('添加服务器'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(6));
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('地址 / IP'), findsOneWidget);
    expect(find.text('端口'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('认证方式'), findsOneWidget);
    // 密码/私钥收在认证方式里（默认收起）：密码是第 5 个 TextField，
    // 口令是第 6 个，私钥是“未选择，点一下选择文件”那一行。
    expect(find.text('私钥'), findsOneWidget);
    expect(find.text('未选择，点一下选择文件'), findsOneWidget);
    expect(find.text('保存服务器'), findsOneWidget);

    // 旧字段全拿掉。
    expect(find.text('城市定位（可选）'), findsNothing);
    expect(find.text('连接信息'), findsNothing);
    expect(find.text('SSH 密码'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save validates, including auth, then really persists and says 已保存 (v11)',
      (tester) async {
    await openAdd(tester);

    // 空着点保存：没有 Form/validator 报错行（会撑高 48 的胶囊），
    // 只弹一句提示，面板不关、不闪退。
    await tester.tap(find.text('保存服务器'));
    await settle(tester, 300);
    expect(find.text('请填写名称和地址。'), findsOneWidget);
    expect(find.text('请输入名称'), findsNothing);
    expect(find.text('请输入主机地址'), findsNothing);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    // 等第一条提示自己消失（SnackBar 默认 4 秒，新的会排队等它），
    // 再填表、点保存，否则成功提示排在后面、测不到。
    await settle(tester, 4500);
    expect(find.text('请填写名称和地址。'), findsNothing);

    // 填好名称+地址再点：默认方式是密码，密码空着会先提示填密码。
    // 端口/用户名空着走默认值（22/root），不拦保存。
    await tester.enterText(find.byType(TextField).at(0), 'srv-main');
    await tester.enterText(find.byType(TextField).at(1), '1.2.3.4');
    await tester.ensureVisible(find.text('保存服务器'));
    await tester.pump();
    await tester.tap(find.text('保存服务器'));
    await settle(tester, 300);
    expect(find.text('请填写密码。'), findsOneWidget);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    // 等这条提示消失，展开认证方式填上密码再点：v11 是真保存——
    // 写 SharedPreferences（ssh.profiles.v1）+ vault，关面板、
    // 弹“已保存”。这个文件没有 path_provider mock，geo 库打不开，
    // 解析走默认落点，文案是“已保存，城市解析不到，已放在德国。”。
    await settle(tester, 4500);
    expect(find.text('请填写密码。'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(4), 'hunter2');
    await tester.ensureVisible(find.text('保存服务器'));
    await tester.pump();
    await tester.tap(find.text('保存服务器'));
    expect(await waitForText(tester, '已保存'), isTrue);
    // 面板关了（弹簧走完才卸载），档案真的落盘了。
    await settle(tester, 1000);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    final profiles = await loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.first.name, 'srv-main');
    expect(profiles.first.host, '1.2.3.4');
    expect(profiles.first.port, 22);
    expect(profiles.first.username, 'root');
    // 查库排队链上可能挂一个 5 秒超时 Timer，推 6 秒把它烧掉，
    // 免得测试结束时框架报“还有 Timer 挂起”。
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // Step C: #5 GlassTextField style fields (v7)
  // ==========================================================================

  testWidgets('fields are ServerBox-style rows: 48 tall, radius 18, hint text',
      (tester) async {
    await openAdd(tester);

    // v11：字段不再包 _GlassField（overlay 的 fluid 脸就是胶囊玻璃，
    // 再包一层 prism 是双层玻璃）；字段是裸 TextField，只留边框+文字，
    // 玻璃由 overlay 的脸给。六个字段都是 48 高，边框圆角 18
    // （ServerBox 行，不是全圆药丸 24）。
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(6));
    for (int i = 0; i < 6; i++) {
      expect(
        tester.getSize(fields.at(i)).height,
        48,
        reason: 'field $i is not 48 tall',
      );
    }
    // v11：密码收在认证方式胶囊里面（默认收起）：在树上，48 高，
    // 但在脸外面（顶贴着脸的底边，被裁剪盖住、点不到）。
    // 口令行同理（密钥方式才出现）：在密码行下面一格、
    // 私钥行下面一格，顶贴着“脸底边 + 96”。
    final authFace = capsuleRects(tester)[4];
    expect(tester.getRect(fields.at(4)).top, authFace.bottom);
    expect(tester.getRect(fields.at(5)).top, authFace.bottom + 96);

    // 占位式（#5 做法），不再是 floating label；decoration 直接在
    // TextField 上（没有 Form、没有 Theme 包）。
    InputDecoration? decoration(int i) =>
        tester.widget<TextField>(fields.at(i)).decoration;
    expect(decoration(0)?.hintText, '名称');
    expect(decoration(1)?.hintText, '地址 / IP');
    expect(decoration(2)?.hintText, '端口');
    expect(decoration(3)?.hintText, '用户名');
    expect(decoration(4)?.hintText, '密码');
    expect(decoration(5)?.hintText, '私钥口令（可选）');
    // 密码和口令默认密文（眼睛切换在 morph_v9_test 里测）。
    expect(tester.widget<TextField>(fields.at(4)).obscureText, isTrue);
    expect(tester.widget<TextField>(fields.at(5)).obscureText, isTrue);
    expect(decoration(0)?.labelText, isNull);
    final enabledBorder = decoration(0)?.enabledBorder as OutlineInputBorder;
    expect(enabledBorder.borderRadius, BorderRadius.circular(18));
    expect(
      decoration(0)?.contentPadding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('save button is a row: 48 tall, radius 18', (tester) async {
    await openAdd(tester);

    final save = find.byKey(const ValueKey('glass_form_save'));
    expect(tester.getSize(save).height, 48);
    // 注：key 在最外层 SizedBox 上，LiquidGlass 是它的子孙，不是祖先。
    final glass = find.descendant(
      of: save,
      matching: find.byType(prism.LiquidGlass),
    );
    expect(
      tester.widget<prism.LiquidGlass>(glass.first).borderRadius,
      BorderRadius.circular(18),
    );
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // Step D: one-to-many staggered fade-in (v7)
  // ==========================================================================

  /// 读一个 _CapsuleStagger 的当前透明度（key 定位；Opacity 是它
  /// ValueListenableBuilder 里的第一层）。
  double staggerOpacity(WidgetTester tester, String key) {
    final opacity = find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(Opacity),
    );
    return tester.widget<Opacity>(opacity.first).opacity;
  }

  testWidgets('capsules fade in top-down, staggered (v7 step D)',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));

    // 打开动画逐帧 16ms 推进，记录三个小胶囊的透明度。
    bool sawNameAheadOfHost = false;
    bool sawHostAheadOfSave = false;
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final name = staggerOpacity(tester, 'stagger_name');
      final host = staggerOpacity(tester, 'stagger_host');
      final save = staggerOpacity(tester, 'stagger_save');
      // 自上而下：名称永远不比地址晚，地址永远不比保存晚。
      expect(name, greaterThanOrEqualTo(host - 1e-9));
      expect(host, greaterThanOrEqualTo(save - 1e-9));
      if (name > host + 1e-9) sawNameAheadOfHost = true;
      if (host > save + 1e-9) sawHostAheadOfSave = true;
    }
    // 不是一起蹦出来：打开中途确实出现过先后（名称先于地址、
    // 地址先于保存）。
    expect(sawNameAheadOfHost, isTrue);
    expect(sawHostAheadOfSave, isTrue);
    // 全开后三个都完全可见。
    expect(staggerOpacity(tester, 'stagger_name'), 1.0);
    expect(staggerOpacity(tester, 'stagger_host'), 1.0);
    expect(staggerOpacity(tester, 'stagger_save'), 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings capsules fade in top-down (v8 step D)',
      (tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    // 打开第一帧：标题和提示都还没进（open < 0.55）。
    await tester.pump(const Duration(milliseconds: 16));
    expect(staggerOpacity(tester, 'stagger_settings_title'), 0.0);
    expect(staggerOpacity(tester, 'stagger_settings_hint'), 0.0);
    await settle(tester);
    // 全开后两个都完全可见。
    expect(staggerOpacity(tester, 'stagger_settings_title'), 1.0);
    expect(staggerOpacity(tester, 'stagger_settings_hint'), 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capsules fade out bottom-up on close (v7 step D)',
      (tester) async {
    await openAdd(tester);
    expect(staggerOpacity(tester, 'stagger_name'), 1.0);
    expect(staggerOpacity(tester, 'stagger_save'), 1.0);

    // 点面板外的 scrim 收回（400,500 在面板底边 392 之下、按钮柱之外）。
    await tester.tapAt(const Offset(400, 500));

    // 收回动画逐帧推进：顺序不变（名称 ≥ 地址 ≥ 保存），
    // 保存先淡（窗口最高），名称最后淡。
    bool sawSaveFadeFirst = false;
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(GlassMorphOverlay).evaluate().isEmpty) break;
      final name = staggerOpacity(tester, 'stagger_name');
      final host = staggerOpacity(tester, 'stagger_host');
      final save = staggerOpacity(tester, 'stagger_save');
      expect(name, greaterThanOrEqualTo(host - 1e-9));
      expect(host, greaterThanOrEqualTo(save - 1e-9));
      if (save < 1.0 - 1e-9 && name == 1.0) sawSaveFadeFirst = true;
    }
    expect(sawSaveFadeFirst, isTrue);
    // 收完面板卸载。
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // Step E: flash re-fix (v7)
  // ==========================================================================

  /// morph 脸的亮度端点和真按钮一致（纯函数，直接断言）。
  test('morph face brightness matches the real button at open=0 (v7 step E)',
      () {
    // 阴影：open=0 是按钮辉光，open=1 是面板黑阴影；中间插值。
    expect(shadowForOpen(0), buttonGlowShadow);
    expect(shadowForOpen(1), fluid.GlassShadow.standard);
    expect(shadowForOpen(0.5).radius, 19);
    expect(shadowForOpen(0.5).offset, const Offset(0, 2));
    // 表面色：open=0 是按钮 tint，open=1 是胶囊深色（v8 没有外框，
    // 胶囊本身就是 #5 深色玻璃，不再是 v7 面板的表面白）。
    // v10：两端 alpha 各降一档（.58→.45、.55→.38），和新 dialGlyph/
    // field tint 对齐，关到底交接仍没有亮度台阶。
    expect(
      surfaceColorForOpen(0),
      const Color(0xff315b73).withValues(alpha: .45),
    );
    expect(
      surfaceColorForOpen(1),
      const Color(0xff0e2233).withValues(alpha: .38),
    );
  });

  /// 读一个按钮的当前不透明度（最近的 Opacity 祖先——子按钮是
  /// ValueListenableBuilder 的 Opacity，主按钮是 dialRoot 的淡入 Opacity）。
  double buttonOpacity(WidgetTester tester, String key) {
    final opacity = find.ancestor(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(Opacity),
    );
    return tester.widget<Opacity>(opacity.first).opacity;
  }

  testWidgets(
      'no overlap on close: child returns only after overlay unmounts (v7 step E)',
      (tester) async {
    await openAdd(tester);
    // 打开时被点的 + 是藏着的（0），没被点的齿轮是 1。
    expect(buttonOpacity(tester, 'glass_add_action'), 0.0);
    expect(buttonOpacity(tester, 'glass_settings_action'), 1.0);

    await tester.tapAt(const Offset(400, 500)); // scrim -> close

    // 收回全程：只要 overlay 还在树上，被点的子按钮就必须是 0
    // （v6 在这里会失败：150ms 交叉淡入期间 overlay 还在、
    // 子按钮已经淡到 >0，两层同时可见、叠加变亮）。
    bool sawUnmount = false;
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(GlassMorphOverlay).evaluate().isEmpty) {
        sawUnmount = true;
        break;
      }
      expect(buttonOpacity(tester, 'glass_add_action'), 0.0);
    }
    expect(sawUnmount, isTrue);
    // 卸载的同一帧，被点的子按钮已经满亮度回来（不是淡入）。
    expect(buttonOpacity(tester, 'glass_add_action'), 1.0);
    // v8 没有主按钮（根本不存在），不用淡入。
    expect(find.byKey(const ValueKey('glass_main_action')), findsNothing);
    await settle(tester, 300);
    expect(buttonOpacity(tester, 'glass_add_action'), 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('close tail is smooth: group rect shrinks monotonically, no jump',
      (tester) async {
    await openAdd(tester);
    expect(groupRect(tester).height, 308);

    await tester.tapAt(const Offset(400, 500)); // scrim -> close

    // 收回逐帧 16ms 推进：整组高度单调递减（弹簧减速趋近 0，
    // 没有突变）；单步最大跌幅 < 120dp（弹簧物理上限约 78dp/16ms，
    // 超过就是硬切/跳变）。欠阻尼弹簧尾段有约 0.1dp 的过冲，
    // 单调断言留 1dp 容差。
    double prevHeight = 308;
    double minHeight = 308;
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(GlassMorphOverlay).evaluate().isEmpty) break;
      final double height = groupRect(tester).height;
      expect(height, lessThanOrEqualTo(prevHeight + 1.0));
      expect(prevHeight - height, lessThan(120));
      prevHeight = height;
      if (height < minHeight) minHeight = height;
    }
    // 整组确实收回去了（从 308 收到接近按钮的 48）。
    expect(minHeight, lessThan(60));
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
