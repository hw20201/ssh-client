import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/glass_morph_overlay.dart';
import 'package:ssh_client/globe.dart';
import 'package:ssh_client/ip_geo_database.dart';
import 'package:ssh_client/main.dart';

/// v13 同款假会话（v14 直接复用，v15 沿用）。
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

  /// v14：锚点卡片是不是藏着。卡片的玻璃在 Opacity 祖先链里（fade 那层）；
  /// 藏着时链里有 0.0，露着时没有（v5 同款断言法）。
  /// 卡片文字是“名字\n位置标签”（内网机解析不到，标签是“德国”），
  /// 面板标题只有名字、没有换行，所以这个 finder 只命中卡片。
  bool cardHidden(WidgetTester tester) {
    final opacities = tester.widgetList<Opacity>(
      find.ancestor(
        of: find.text('测试机\n德国'),
        matching: find.byType(Opacity),
      ),
    );
    return opacities.any((o) => o.opacity == 0.0);
  }

  /// 面板脸的当前矩形：面积最大的 DrawBackdrop（面板脸最大，
  /// 卡片 136×46、按钮 88×48 都小得多）。收回时脸从 0.62 屏高
  /// 缩到锚点 136×46，面积一直最大，直到落点。
  Rect faceRect(WidgetTester tester) {
    final rects = <Rect>[];
    for (final e in find.byType(fluid.DrawBackdrop).evaluate()) {
      final box = e.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.width < 10) continue;
      rects.add(rect);
    }
    rects.sort((a, b) =>
        (b.width * b.height).compareTo(a.width * a.height));
    return rects.first;
  }

  /// v15：地球仪上那张卡片的文字。会话面板的锚面也在树上（overlay 里，
  /// 同名同标签的文字），所以不能直接 find.text——用 SshGlobe 的后代
  /// 限定，只命中卡片。卡片藏着（Opacity 0）时仍有布局，getCenter
  /// 照样能读到它的实时位置。
  Finder cardFinder(WidgetTester tester) {
    return find.descendant(
      of: find.byType(SshGlobe),
      matching: find.text('测试机\n德国'),
    );
  }

  /// v15：卡片的实时中心（见 cardFinder 的说明）。
  Offset cardCenter(WidgetTester tester) {
    return tester.getCenter(cardFinder(tester));
  }

  /// v15：会话面板锚面的 finder（key 在 _SessionAnchorFace 上）。
  Finder anchorFaceFinder() {
    return find.byKey(const ValueKey('session_anchor_face'));
  }

  testWidgets('globe rotates while no panel is open (control)',
      (tester) async {
    // 对照：没开面板时地球在转，卡片 3 秒内横向漂移 > 5dp。
    // 这个对照证明下面的“冻住”测试不是空转——卡片本来是会动的。
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    double? minX, maxX;
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final f = cardFinder(tester);
      if (f.evaluate().isEmpty) continue;
      final double x = tester.getCenter(f).dx;
      minX = minX == null ? x : math.min(minX, x);
      maxX = maxX == null ? x : math.max(maxX, x);
    }
    expect(minX, isNotNull, reason: '3 秒内卡片一次都没出现');
    expect(maxX! - minX!, greaterThan(5),
        reason: '地球没转，卡片 3 秒横向漂移 <= 5dp');
    expect(tester.takeException(), isNull);
  });

  testWidgets('globe stays frozen while the session panel is open',
      (tester) async {
    // v15 主修：会话面板打开全程地球彻底定住，卡片钉在点开的位置。
    // v14 的行为是面板开着时地球还以 3°/秒慢转，5 秒漂约 15°，
    // 卡片在屏幕上漂出一大截，关闭时落点就对不上了。
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    final Offset before = cardCenter(tester);
    // 面板开着等 5 秒（主人输指令的时间），地球要是有在转，
    // 卡片 5 秒能漂几十 dp。
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Offset after = cardCenter(tester);
    expect(after.dx, closeTo(before.dx, 0.5));
    expect(after.dy, closeTo(before.dy, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('close lands exactly on the card after waiting',
      (tester) async {
    // v15 主修：面板开着几秒后再关闭，关闭落点和卡片实时位置重合。
    // 面板开着时地球冻住了，卡片没漂（下面 5 秒那段断言的就是这个）。
    // v19：关闭那一刻地球开始转，卡片在过渡里漂约 2°，所以落点
    // 对的是卡片在 unmount 那一帧的实时位置（活锚点），不是点开
    // 那一刻记的旧锚点。
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    final overlay = tester.widget<GlassMorphOverlay>(
      find.byType(GlassMorphOverlay),
    );
    final Rect anchor = overlay.origin;
    // 锚点就是点按位置（卡片文字中心），和卡片中心只差约 1.5dp。
    final Offset cardAtOpen = cardCenter(tester);
    expect(cardAtOpen.dx, closeTo(anchor.center.dx, 5));
    expect(cardAtOpen.dy, closeTo(anchor.center.dy, 5));
    // 面板开着等 5 秒。
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Offset cardWhileOpen = cardCenter(tester);
    expect(cardWhileOpen.dx, closeTo(anchor.center.dx, 5));
    expect(cardWhileOpen.dy, closeTo(anchor.center.dy, 5));

    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    // 收回逐帧 16ms 推进，抓最后采到的脸矩形（v14 同款）。
    Rect lastFace = faceRect(tester);
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(GlassMorphOverlay).evaluate().isEmpty) break;
      lastFace = faceRect(tester);
    }
    // 落点和卡片实时位置重合（中心 ±30dp 以内）。
    expect(lastFace.center.dx, closeTo(cardWhileOpen.dx, 30));
    expect(lastFace.center.dy, closeTo(cardWhileOpen.dy, 30));
    expect(lastFace.height, closeTo(anchor.height, 20));
    // v19：overlay 刚卸载时地球已经在转了（点关闭那一刻开始加速，
    // 过渡里约转 2°），卡片不在打开时的锚点位置了——它在 unmount
    // 那一帧的实时位置。落点断言对的是那个实时位置（脸的最后一帧
    // vs 关完立刻量的卡片，±2dp），不是打开时的旧锚点；卡片相对
    // 旧锚点的漂移有界（±10dp，约 2° 的转动量）。
    await tester.pump();
    expect(find.byType(GlassMorphOverlay), findsNothing);
    final Offset cardAfterClose = cardCenter(tester);
    expect(lastFace.center.dx, closeTo(cardAfterClose.dx, 2));
    expect(lastFace.center.dy, closeTo(cardAfterClose.dy, 2));
    expect(cardAfterClose.dx, closeTo(anchor.center.dx, 10));
    expect(cardAfterClose.dy, closeTo(anchor.center.dy, 10));
    await settle(tester);
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchor face is a card replica, not a terminal icon',
      (tester) async {
    // v15 主修之二：会话面板的变形锚面（open=0 那一端）必须和卡片
    // 画得一模一样——小蓝点 + 名字 + 位置标签 + 右边 `>`，不要终端图标。
    // 打开前和关到底后，锚面/卡片的内容一致；打开中途面板内容正常。
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    // 锚面只在 open < 0.3 时在树上（overlay 里 anchorAlpha > 0 才画，
    // 见 glass_morph_overlay 359 行；开到底 open=1 时 anchorAlpha=0、
    // 锚面已卸载）。所以点开后只推一帧（open=0，anchorAlpha=1），
    // 在锚面还在的时候查它；不能等 settle 再查。
    await tester.tap(find.textContaining('测试机'));
    await tester.pump();
    // 锚面在树上，内容就是卡片原样。
    expect(anchorFaceFinder(), findsOneWidget);
    expect(
      find.descendant(
        of: anchorFaceFinder(),
        matching: find.text('测试机\n德国'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: anchorFaceFinder(),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
    // 锚面里没有终端图标（面板标题行里那个不算，只查锚面子树）。
    expect(
      find.descendant(
        of: anchorFaceFinder(),
        matching: find.byIcon(Icons.terminal_rounded),
      ),
      findsNothing,
    );
    // 再等弹簧走完，面板内容正常（输入框在，标题是服务器名）。
    await settle(tester, 1200);
    expect(find.byKey(const ValueKey('session_input_field')), findsOneWidget);
    expect(find.text('测试机'), findsWidgets);
    // 关到底：锚面跟着 overlay 一起卸载，卡片回来，内容还是那张卡片。
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    await settle(tester, 1200);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(anchorFaceFinder(), findsNothing);
    expect(cardHidden(tester), isFalse);
    expect(cardFinder(tester), findsOneWidget);
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchor at the screen edge is clamped inside the screen',
      (tester) async {
    // v15 主修之三：锚点矩形夹到屏内（左右留 6dp，和卡片布局边距一致），
    // 缩回去的胶囊不被屏边裁。做法：先让地球转一整圈（30 秒），记下
    // 卡片中心 x 的最小值；再转一圈，等卡片回到最左附近，点它左缘
    // （卡片左缘 +4dp），这时点按位置离屏边最近，夹子一定起作用。
    // 真机视口（主人 vivo：1080×2400 物理，2.88 px/dp → 375×833 逻辑）：
    // 默认测试视口 800×600 太宽，地球半径大，卡片最左也只能到中心 x≈175，
    // 点按离屏边不够近、夹子绑不上；真机视口卡片能贴到左缘（left=6），
    // 点左缘时夹子一定起作用，锚点左缘就贴着 6dp 线。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.88;
    addTearDown(tester.view.reset);
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    final double screenWidth = tester.view.physicalSize.width /
        tester.view.devicePixelRatio;
    double minX = double.infinity;
    for (int i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      final f = cardFinder(tester);
      if (f.evaluate().isEmpty) continue;
      final double x = tester.getCenter(f).dx;
      if (x < minX) minX = x;
    }
    expect(minX, lessThan(double.infinity), reason: '一整圈卡片都没出现');
    // 第二圈：等卡片回到最左附近，点它左缘。
    bool opened = false;
    for (int i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      final f = cardFinder(tester);
      if (f.evaluate().isEmpty) continue;
      final Rect textRect = tester.getRect(f);
      final double x = tester.getCenter(f).dx;
      if (x > minX + 8) continue;
      // 卡片文字左缘往左 20dp 就是卡片左缘 +4dp（文字起于卡片左 +24dp）；
      // 点那里，锚点中心就是这个点。
      final Offset tapPoint =
          Offset(textRect.left - 20, textRect.center.dy);
      await tester.tapAt(tapPoint);
      await settle(tester, 1200);
      opened = find.byKey(const ValueKey('session_input_field'))
          .evaluate()
          .isNotEmpty;
      if (opened) break;
    }
    expect(opened, isTrue, reason: '卡片回到最左附近时点左缘没能打开面板');
    final overlay = tester.widget<GlassMorphOverlay>(
      find.byType(GlassMorphOverlay),
    );
    final Rect anchor = overlay.origin;
    // 锚点矩形完全在屏内，左右各留 6dp（和卡片布局边距一致）。
    expect(anchor.left, greaterThanOrEqualTo(6));
    expect(anchor.right, lessThanOrEqualTo(screenWidth - 6));
    expect(anchor.top, greaterThanOrEqualTo(6));
    // 点按离屏边最近时夹子绑住了，锚点左缘就贴着 6dp 线。
    expect(anchor.left, closeTo(6, 1));
    // 关到底，卡片回来，位置没变。
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    await settle(tester, 1200);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(cardHidden(tester), isFalse);
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });
}
