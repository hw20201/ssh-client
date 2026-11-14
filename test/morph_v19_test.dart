import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/glass_morph_overlay.dart';
import 'package:ssh_client/globe.dart';
import 'package:ssh_client/ip_geo_database.dart';
import 'package:ssh_client/main.dart';

/// v19：地球恢复转动要发生在面板变为按钮的那段时间里。
/// 主人验收 v18 说第 1 个问题（顿）修好了，第 2 个（地球恢复）没有：
/// v18 是关闭完全落定后先等 150ms 再解冻、再用 450ms 爬回 12°/秒——
/// 地球在面板缩回去的全程都是冻着的，变完按钮才开始转。主人要的是
/// 加速发生在过渡那段时间里：点关闭那一刻开始爬，过渡结束时回到
/// 12°/秒。
/// 修法：
/// 1. 转速绑在关闭变形本身上：点 ×/空白开始关闭（overlay 的
///    onCloseStarted）那一刻地球就开始加速，转速 =
///    12 × smoothstep(1 - open)，open 从 1 → 0，转速从 0 爬到
///    满速；过渡结束时正好回到 12°/秒，关到底直接解冻，不再等
///    150ms、不再走时间斜坡。
/// 2. 活锚点：过渡里地球转起来、卡片会漂走（实测：转 2° 最坏漂
///    7.13dp，远超 2dp 预算），变形锚点必须实时跟着卡片的当前
///    位置走。地球仪每帧把选中卡片的布局矩形写进 _anchorCardRect，
///    overlay 每帧读它当 origin；落点断言对的是卡片在 unmount 那
///    一帧的实时位置（不是打开时的旧位置）。
/// v18 的顿修法保留（提前交接 snapTo、parked ≤ 2 帧）。
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

  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    final int steps = (ms / 100).ceil();
    for (int i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
  }

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

  Future<void> pumpHome(
    WidgetTester tester, {
    SessionConnector? connector,
    ValueChanged<GlobeCamera>? onGlobeCameraChanged,
  }) async {
    await tester.pumpWidget(
      SshApp(
        sessionConnector: connector,
        onGlobeCameraChanged: onGlobeCameraChanged,
      ),
    );
    await settle(tester, 2000);
  }

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

  Future<void> openSessionPanel(WidgetTester tester, String name) async {
    await tester.tap(find.textContaining(name));
    await settle(tester, 1200);
    expect(find.byKey(const ValueKey('session_input_field')), findsOneWidget);
  }

  Rect? faceRectOrNull(WidgetTester tester) {
    final rects = <Rect>[];
    for (final e in find.byType(fluid.DrawBackdrop).evaluate()) {
      final box = e.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.width < 10) continue;
      rects.add(rect);
    }
    if (rects.isEmpty) return null;
    rects.sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    return rects.first;
  }

  Finder cardFinder(WidgetTester tester) {
    return find.descendant(
      of: find.byType(SshGlobe),
      matching: find.text('测试机\n德国'),
    );
  }

  Offset? cardCenterOrNull(WidgetTester tester) {
    final f = cardFinder(tester);
    if (f.evaluate().isEmpty) return null;
    return tester.getCenter(f);
  }

  /// 点 × 关闭，逐帧 16ms 推进，记每帧的脸矩形 / overlay 在不在 /
  /// 卡片中心 / 经度日志长度；overlay 卸掉后再推 60 帧（约 1 秒）。
  /// 返回（帧记录，unmount 帧号）。
  Future<(List<Map<String, Object?>>, int)> closeSessionPanelRecorded(
    WidgetTester tester,
    List<double> lonLog,
  ) async {
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    final frames = <Map<String, Object?>>[];
    int unmountFrame = -1;
    for (int i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final bool overlay =
          find.byType(GlassMorphOverlay).evaluate().isNotEmpty;
      if (!overlay && unmountFrame < 0) unmountFrame = i;
      frames.add(<String, Object?>{
        'frame': i,
        'face': faceRectOrNull(tester),
        'overlay': overlay,
        'card': cardCenterOrNull(tester),
        'lonCount': lonLog.length,
      });
      if (unmountFrame >= 0 && i - unmountFrame >= 60) break;
    }
    expect(unmountFrame, greaterThanOrEqualTo(0));
    return (frames, unmountFrame);
  }

  /// 经度差取最短弧（lon 在 ±180 之间 wrap）。
  double lonDelta(double from, double to) {
    double d = to - from;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  testWidgets(
      'close ramps globe speed during the morph; live anchor lands on card',
      (tester) async {
    // v19 主修：(1) 地球恢复转动发生在面板变为按钮的那段时间里——
    // 点关闭那一刻开始爬，过渡结束时回到 12°/秒；(2) 活锚点——
    // 过渡里地球转起来、卡片漂走，脸跟着卡片走，落点对的是卡片
    // 在 unmount 那一帧的实时位置。v18 的顿修法保留（parked ≤ 2 帧）。
    // 真机视口（v15 同款）：1080×2400 物理，2.88 px/dp → 375×833 逻辑。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.88;
    addTearDown(tester.view.reset);

    final handle = _FakeSessionHandle();
    final lonLog = <double>[];
    await pumpHome(
      tester,
      connector: (_, _, _) async => handle,
      onGlobeCameraChanged: (c) => lonLog.add(c.lon),
    );
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    lonLog.clear();
    final Offset cardWhileOpen = cardCenterOrNull(tester)!;

    final (frames, unmountFrame) =
        await closeSessionPanelRecorded(tester, lonLog);

    // --- 1. 脸贴到锚点后 overlay 立刻卸，没有 parked 尾巴（v18 保留）---
    final Rect finalFace = frames[unmountFrame - 1]['face'] as Rect;
    int firstAtAnchor = -1;
    for (int i = 0; i < unmountFrame; i++) {
      final Rect? f = frames[i]['face'] as Rect?;
      if (f == null) continue;
      if ((f.center.dx - finalFace.center.dx).abs() <= 1 &&
          (f.center.dy - finalFace.center.dy).abs() <= 1 &&
          (f.width - finalFace.width).abs() <= 1 &&
          (f.height - finalFace.height).abs() <= 1) {
        firstAtAnchor = i;
        break;
      }
    }
    expect(firstAtAnchor, greaterThanOrEqualTo(0));
    expect(unmountFrame - firstAtAnchor, lessThanOrEqualTo(2),
        reason: '脸贴到锚点后 overlay 还挂着，顿的那一下回来了');
    // 脸全程单调缩向卡片、无跳变（v16 同款断言）。
    double prevArea = double.infinity;
    double prevHeight = double.infinity;
    for (int i = 0; i < unmountFrame; i++) {
      final Rect? f = frames[i]['face'] as Rect?;
      if (f == null) continue;
      final double area = f.width * f.height;
      expect(area, lessThanOrEqualTo(prevArea * 1.02 + 1));
      expect(f.height, lessThanOrEqualTo(prevHeight + 1));
      if (prevHeight != double.infinity) {
        expect(prevHeight - f.height, lessThan(120));
      }
      prevArea = area;
      prevHeight = f.height;
    }
    expect(finalFace.height, closeTo(46, 20));

    // --- 2. 地球在关闭过渡里就开始转（不是关完才转）---
    int firstLonFrame = -1;
    for (int i = 0; i < frames.length; i++) {
      if ((frames[i]['lonCount'] as int) > 0) {
        firstLonFrame = i;
        break;
      }
    }
    expect(firstLonFrame, greaterThanOrEqualTo(0));
    expect(firstLonFrame, lessThanOrEqualTo(4),
        reason: '点关闭后地球没在过渡里开始转，还在等关完才恢复');
    // 过渡里经度一直在变（地球一直在加速转）。
    final int lonAtUnmount = frames[unmountFrame]['lonCount'] as int;
    expect(lonAtUnmount, greaterThan(10),
        reason: '关闭过渡里经度没怎么变，地球基本没转起来');

    // --- 3. 转速在过渡里从 0 爬到 12°/s，过渡结束时回到满速 ---
    // 每 5 个 tick 一段算转速（帧是 16ms，5 tick = 80ms）。
    final speeds = <double>[];
    for (int i = 0; i + 5 < lonAtUnmount && i < 30; i += 5) {
      final double d = lonDelta(lonLog[i], lonLog[i + 5]);
      speeds.add(d / (5 * 0.016));
    }
    expect(speeds.length, greaterThanOrEqualTo(2));
    // 关闭弹簧是指数衰减（0.88/300），前 80ms open 就从 1 掉到约
    // 0.3，所以 smoothstep(1-open) 的斜坡前快后慢：第一段约 5°/s，
    // 不是 < 3°/s。关键是它明显低于满速、且单调爬到 12——不是一帧
    // 跳变。视觉上“面板变按钮”也基本在前 160ms 完成（open 到 0.05），
    // 地球在前 160ms 爬到满速、和视觉进度对齐。
    expect(speeds.first, lessThan(8),
        reason: '关闭刚开始转速就接近满速，斜坡没从低爬起来');
    for (int i = 1; i < speeds.length; i++) {
      expect(speeds[i], greaterThanOrEqualTo(speeds[i - 1] - 0.5),
          reason: '转速不是单调爬升，中途掉了');
    }
    expect(speeds.last, closeTo(12, 2),
        reason: '过渡结束时转速没回到满速 12°/s');

    // --- 4. 关完之后转速保持满速，没有先停一下再恢复 ---
    // unmount 后 60 帧的经度：取关完后前 10 个 tick 的转速。
    final int lonAfter = lonLog.length;
    expect(lonAfter - lonAtUnmount, greaterThanOrEqualTo(10));
    final double postSpeed = lonDelta(
          lonLog[lonAtUnmount],
          lonLog[lonAtUnmount + 10],
        ) /
        (10 * 0.016);
    expect(postSpeed, closeTo(12, 1.5),
        reason: '关完之后地球先停了一下再恢复，过渡结束没保持满速');

    // --- 5. 活锚点落点：脸落在卡片在 unmount 那一帧的实时位置 ---
    final Offset? liveCard = frames[unmountFrame]['card'] as Offset?;
    expect(liveCard, isNotNull);
    expect(finalFace.center.dx, closeTo(liveCard!.dx, 2));
    expect(finalFace.center.dy, closeTo(liveCard.dy, 2));
    // 诊断：这次关闭里卡片漂了多少（活锚点吸收掉的漂移量）。
    // 主断言（脸落在 liveCard 2dp 内）已经证明脸跟着活锚点走——
    // 要是卡片漂了 > 2dp 而脸还停在打开时的旧位置，主断言就过不了。
    final double drift = (liveCard - cardWhileOpen).distance;
    // ignore: avoid_print
    print(
        'V19-CLOSE-DRIFT card drift during close = '
        '${drift.toStringAsFixed(2)}dp');
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  test('card drift for a 2-degree globe rotation can exceed 2dp',
      () {
    // v19 诊断（实测）：关闭过渡里地球总共约转 2°（斜坡平均 6°/s ×
    // 约 0.33s），卡片漂多少取决于标记在盘上的位置——最坏 7.13dp，
    // 远超 2dp 预算，所以固定锚点不够，必须用活锚点。这个测试把
    // 这个界钉死：最坏漂移 > 2dp（活锚点必需）且 < 10dp（量级合理）。
    // 真机视口 375×833：center (187.5, 441.49)，radius ≈ 169.1，
    // 和 globe.dart build 里算的一致。
    const Offset center = Offset(187.5, 441.49);
    const double radius = 169.1;
    const Rect bounds = Rect.fromLTWH(6, 6, 363, 821);
    const Rect reserved = Rect.fromLTWH(293, 751, 76, 76);
    const GeoPoint frankfurt = GeoPoint(50.11, 8.68);

    Rect cardRectAt(double lon) {
      final projection = GlobeProjection(
        GlobeCamera(lat: 18, lon: lon),
        center,
        radius,
      );
      final point = projection.project(frankfurt);
      final layout = layoutGlobeCards(
        anchors: <GlobeAnchor>[
          (
            id: '1',
            at: point.offset,
            depth: point.depth,
            size: globeHostCardSize
          ),
        ],
        bounds: bounds,
        globeCenter: center,
        reserved: <Rect>[reserved],
      );
      return layout.single.rect;
    }

    double worst = 0;
    for (double lon = -180; lon < 180; lon += 10) {
      final Rect a = cardRectAt(lon);
      final Rect b = cardRectAt(lon + 2);
      final double d = (b.center - a.center).distance;
      if (d > worst) worst = d;
    }
    expect(worst, greaterThan(2),
        reason: '转 2° 的最坏漂移没超过 2dp，活锚点的前提不存在了');
    expect(worst, lessThan(10), reason: '漂移量级不合理，投影参数可能错了');
  });
}
