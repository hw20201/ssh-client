import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/glass_morph_overlay.dart';
import 'package:ssh_client/glass_styles.dart';
import 'package:ssh_client/ip_geo_database.dart';
import 'package:ssh_client/main.dart';

/// v13 同款假会话（v14 直接复用，v15/v16 沿用）。
class _FakeSessionHandle implements SessionHandle {
  _FakeSessionHandle();

  final StreamController<Uint8List> _stdout = StreamController<Uint8List>();
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>();
  final List<Uint8List> written = <Uint8List>[];
  bool closed = false;

  @override
  Stream<Uint8List> get stdoutStream => _stdout.stream;
  @override
  Stream<Uint8List> get stderrStream => _stderr.stream;

  @override
  void write(Uint8List data) {
    written.add(data);
    _stdout.add(data);
    _stdout.add(utf8.encode('hi\n'));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _stdout.close();
    await _stderr.close();
  }
}

/// 颜色的有效亮度（亮度 × alpha）：表面色盖在背景上，肉眼看到的
/// 亮度是 tint 本身的亮度乘上它的不透明度。
double effectiveBrightness(Color c) =>
    (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) * c.a;

/// 阴影的有效透明度：渲染时 paint 颜色是 shadow.color，包在
/// alpha 字段的 saveLayer 里，所以有效透明度 = 颜色 alpha × alpha 字段。
double effectiveShadowAlpha(fluid.GlassShadow s) => s.color.a * s.alpha;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// v11 同款：记账式假 vault + path_provider mock + geo 预热。
  final fakeVault = <String, String>{};
  late final Directory supportDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    supportDir = await Directory.systemTemp.createTemp('ipgeo-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async {
        final args = (call.arguments as Map?) ?? <String, Object?>{};
        switch (call.method) {
          case 'read':
            return fakeVault[args['key'] as String?];
          case 'write':
            final key = args['key'] as String?;
            if (key != null) {
              fakeVault[key] = args['value'] as String? ?? '';
            }
            return null;
          case 'delete':
            fakeVault.remove(args['key'] as String?);
            return null;
          case 'deleteAll':
            fakeVault.clear();
            return null;
          case 'readAll':
            return Map<String, String>.from(fakeVault);
          case 'containsKey':
            return fakeVault.containsKey(args['key'] as String?);
          default:
            return null;
        }
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return supportDir.path;
        }
        return null;
      },
    );
    await fluid.FluidGlass.ensureInitialized();
    final geoDb = await IpGeoDatabase.open();
    await geoDb.lookup('8.8.8.8');
  });

  setUp(() async {
    fakeVault.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  // v11 同款小步推进（地球一直在转，pumpAndSettle 永远等不到）。
  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    final int steps = (ms / 100).ceil();
    for (int i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
  }

  /// 等一段文字出现（保存提示、地球仪卡片都靠它）。光 pump 假时间不够：
  /// 保存要做真实 I/O，真实 I/O 只在真实时间里推进，假时间里会永远
  /// 挂起（实测）；所以每轮先 runAsync 跳出假时间、真实等 500ms，
  /// 再 pump 一帧。预算 30 秒真实时间。
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

  /// 等一个条件成立（异步断开这类要几个微任务才落定的事）。
  /// 预算 5 秒真实时间，到点还没成立就返回 false。
  Future<bool> waitForCondition(
    WidgetTester tester,
    bool Function() condition, {
    int timeoutMs = 5000,
  }) async {
    final int rounds = (timeoutMs / 100).ceil();
    for (int i = 0; i < rounds; i++) {
      if (condition()) return true;
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 100));
    }
    return condition();
  }

  /// 起主页（带假连接器），地球转起来。
  Future<void> pumpHome(
    WidgetTester tester, {
    SessionConnector? connector,
  }) async {
    await tester.pumpWidget(SshApp(sessionConnector: connector));
    await settle(tester, 2000);
  }

  /// 密码方式保存一个服务器（端口/用户名留空走默认值），返回它的 id。
  Future<String> savePasswordServer(
    WidgetTester tester, {
    required String name,
    required String host,
    String password = 'pw123',
  }) async {
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('add_name_field')),
      name,
    );
    await tester.enterText(
      find.byKey(const ValueKey('add_host_field')),
      host,
    );
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester, 300);
    await tester.enterText(
      find.byKey(const ValueKey('add_password_field')),
      password,
    );
    await tester.tap(find.byKey(const ValueKey('glass_form_save')));
    await settle(tester, 300);
    expect(await waitForText(tester, '已保存'), isTrue);
    await settle(tester, 1000);
    await tester.pump(const Duration(seconds: 6));
    final profiles = await loadProfiles();
    expect(profiles, hasLength(1));
    return profiles.first.id;
  }

  /// 点地球仪卡片，等会话面板的弹簧走完（输入框可点）。
  Future<void> openSessionPanel(WidgetTester tester, String name) async {
    await tester.tap(find.textContaining(name));
    await settle(tester, 1200);
    expect(find.byKey(const ValueKey('session_input_field')), findsOneWidget);
  }

  test('session anchor glass equals the card at open=0 (flash deleted)',
      () {
    // v17 主修：会话 morph 的锚点玻璃就是卡片本身——表面色、阴影、
    // 折射在 open=0 时和卡片同值，overlay 一卸没有任何亮度台阶。
    // 表面色：直接对 GlassStyles.card() 的 tint（单点来源），
    // 不是手抄的第二个常量。
    expect(
      surfaceColorForOpen(0, sessionAnchorSurfaceColor),
      GlassStyles.card().tint,
      reason: '会话锚面 open=0 的表面色必须就是卡片 tint',
    );
    // 阴影：半径 11、offset (0,4)、有效透明度 .13（卡片的 BoxShadow），
    // 颜色是纯黑——没有青色（删掉的辉光是 0x5500cde5，绿 205 蓝 229）。
    final shadow = shadowForOpen(0, sessionAnchorShadow);
    expect(shadow.radius, 11);
    expect(shadow.offset, const Offset(0, 4));
    expect(effectiveShadowAlpha(shadow), closeTo(0.13, 0.002));
    expect(shadow.color.r, 0);
    expect(shadow.color.g, 0);
    expect(shadow.color.b, 0);
    // 对照：默认锚点（按钮那套）在 open=0 时就是青色辉光——闪的来源。
    // 会话锚点把它删掉了，上面三条断言守的就是这个删除。
    final defaultShadow = shadowForOpen(0);
    expect(defaultShadow.color, const Color(0x5500cde5));
    expect(defaultShadow.color.g, greaterThan(0.5));
    expect(defaultShadow.color.b, greaterThan(0.5));
    // 表面色也是：默认锚点（按钮亮蓝 tint）比会话锚点（卡片深 slate）
    // 亮得多，删掉的就是这道亮度台阶。
    expect(
      effectiveBrightness(surfaceColorForOpen(0)),
      greaterThan(effectiveBrightness(sessionAnchorSurfaceColor)),
    );
    // 折射：会话锚点 open=0 是高 12、量 18、色散关；默认锚点是
    // 高 16、量 28、色散开——小矩形上强折射 + 七波长分光会把亮背景
    // 聚到边缘，收尾那一下就是“高亮”。
    final sessionLens = lensForOpen(
      0,
      anchorHeight: sessionAnchorLensHeight,
      anchorAmount: sessionAnchorLensAmount,
      anchorChromatic: sessionAnchorChromaticAberration,
    );
    expect(sessionLens.height, 12);
    expect(sessionLens.amount, 18);
    expect(sessionLens.chromaticAberration, isFalse);
    final defaultLens = lensForOpen(0);
    expect(defaultLens.height, 16);
    expect(defaultLens.amount, 28);
    expect(defaultLens.chromaticAberration, isTrue);
    // open=1 的大面板端两边完全一样——打开方向不受影响。
    expect(
      surfaceColorForOpen(1, sessionAnchorSurfaceColor),
      surfaceColorForOpen(1),
    );
    expect(
      shadowForOpen(1, sessionAnchorShadow),
      fluid.GlassShadow.standard,
    );
    expect(
      lensForOpen(
        1,
        anchorHeight: sessionAnchorLensHeight,
        anchorAmount: sessionAnchorLensAmount,
        anchorChromatic: sessionAnchorChromaticAberration,
      ),
      lensForOpen(1),
    );
  });

  test('face brightness darkens monotonically as it closes (no jump)', () {
    // 暗下去：关闭时（open 减小）亮度驱动只暗不亮，没有跳变。
    // 采 open = 0 / .25 / .5 / .75 / 1 五个点，会话锚点：
    const opens = <double>[0, 0.25, 0.5, 0.75, 1.0];
    double prevAmount = -1;
    double prevHeight = -1;
    double prevShadowAlpha = double.infinity;
    for (final open in opens) {
      final lens = lensForOpen(
        open,
        anchorHeight: sessionAnchorLensHeight,
        anchorAmount: sessionAnchorLensAmount,
        anchorChromatic: sessionAnchorChromaticAberration,
      );
      // 折射量与高度随 open 单调增——关闭时单调减，暗下去。
      expect(lens.amount, greaterThan(prevAmount));
      expect(lens.height, greaterThan(prevHeight));
      prevAmount = lens.amount;
      prevHeight = lens.height;
      // 阴影有效透明度随 open 单调减——关闭时单调增（阴影变深），
      // 不会中间鼓一包再落回去。
      final alpha = effectiveShadowAlpha(
        shadowForOpen(open, sessionAnchorShadow),
      );
      expect(alpha, lessThan(prevShadowAlpha));
      prevShadowAlpha = alpha;
      // 色散：收尾段（open < 0.5）关，open ≥ 0.5 才开——开关发生在
      // 脸还比较大的时候，不留突然的亮闪。
      expect(lens.chromaticAberration, open >= 0.5);
    }
    // 表面色在 open=0 时就是卡片（见上一个测试），收尾交接零台阶；
    // open=1 时就是面板深色——两端钉死，中间是 lerp，没有跳变。
    expect(
      surfaceColorForOpen(0, sessionAnchorSurfaceColor),
      GlassStyles.card().tint,
    );
  });

  testWidgets('session morph uses the card-matched anchor glass',
      (tester) async {
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    final overlay =
        tester.widget<GlassMorphOverlay>(find.byType(GlassMorphOverlay));
    expect(overlay.anchorSurfaceColor, sessionAnchorSurfaceColor);
    expect(overlay.anchorShadow, sessionAnchorShadow);
    expect(overlay.anchorLensHeight, sessionAnchorLensHeight);
    expect(overlay.anchorLensAmount, sessionAnchorLensAmount);
    expect(overlay.anchorChromaticAberration, isFalse);
    // 关到底：卡片回来，能重新打开（v13 同款流程）。
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    await settle(tester, 1200);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(find.textContaining('测试机'), findsWidgets);
    await openSessionPanel(tester, '测试机');
    expect(tester.takeException(), isNull);
  });

  testWidgets('add morph still uses the button anchor glass (unchanged)',
      (tester) async {
    // 添加 morph 的锚点是右下角胶囊按钮（本来就带着青色辉光），
    // v17 只改了会话 morph——这里守住添加面板仍用按钮那套默认值。
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);
    final overlay =
        tester.widget<GlassMorphOverlay>(find.byType(GlassMorphOverlay));
    expect(overlay.anchorSurfaceColor, isNull);
    expect(overlay.anchorShadow, isNull);
    expect(overlay.anchorLensHeight, 16);
    expect(overlay.anchorLensAmount, 28);
    expect(overlay.anchorChromaticAberration, isTrue);
    expect(tester.takeException(), isNull);
  });
}
