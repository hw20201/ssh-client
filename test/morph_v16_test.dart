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

/// v13 同款假会话（v14 直接复用，v15 沿用，v16 沿用）。
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
    rects.sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
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

  /// 经度差取最短弧（lon 在 ±180 之间 wrap）。
  double lonDelta(double from, double to) {
    double d = to - from;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  /// 点 × 关闭会话面板，逐帧 16ms 推进直到 overlay 卸载，
  /// 返回关闭过程中每帧的脸矩形（最后采到的就是落点那一帧）。
  Future<List<Rect>> closeSessionPanelStepwise(
    WidgetTester tester,
  ) async {
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    final faces = <Rect>[faceRect(tester)];
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(GlassMorphOverlay).evaluate().isEmpty) break;
      faces.add(faceRect(tester));
    }
    expect(find.byType(GlassMorphOverlay), findsNothing);
    return faces;
  }

  testWidgets('session close: globe is already rotating at unmount',
      (tester) async {
    // v19：v16 的“收尾错后两帧再恢复”只留给添加/设置 morph；会话
    // 关闭改成 morph 驱动——点关闭那一刻地球就开始加速，过渡结束
    // 时回到 12°/秒，关到底直接解冻，不再等两帧。所以这个测试的
    // 断言翻过来：关到底那一刻卡片已经漂了（过渡里地球转了约 2°），
    // 关完再推 1 秒卡片继续漂（没有关后停顿）；再等 3 秒，经度走
    // 了约 36°（恢复了，没冻死）。原来 v16 的断言（关完两帧卡片
    // 纹丝不动）是旧行为，v19 故意改掉了。
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
    // 面板开着等 5 秒（地球冻着，卡片钉住）。
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Offset cardWhileOpen = cardCenter(tester);
    await closeSessionPanelStepwise(tester);
    // overlay 刚卸载那一刻：卡片相对打开时漂了（过渡里地球转了
    // 约 2°），但漂得不多（有界，< 10dp）。漂移的下界不做断言——
    // 漂多少取决于卡片在盘上的位置，下界可以接近 0；过渡里地球
    // 在转这件事由 morph_v19_test 的经度日志证明。
    final Offset settled = cardCenter(tester);
    final double drift = (settled - cardWhileOpen).distance;
    expect(drift, lessThan(10), reason: '关闭过渡里卡片漂得太多');
    // 关完再推 1 秒（10 帧 100ms）：地球还在转（12°/秒），卡片
    // 继续漂——没有关后停顿。
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Offset stillMoving = cardCenter(tester);
    expect((stillMoving - settled).distance, greaterThan(1),
        reason: '关完 1 秒卡片几乎没动，地球关完先停了一下再恢复');
    // 再等 3 秒：地球恢复 12°/秒（没冻死）。直接量经度，不用量卡片
    // 投影位移——卡片在盘上走椭圆，某段投影位移很小（实测 3 秒总
    // 位移只有约 4dp），5dp 的阈值会误报；经度是位置无关的直接信号，
    // 3 秒 × 12°/秒 = 约 36°。
    final int lonMark = lonLog.length;
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(lonLog.length - lonMark, greaterThan(10),
        reason: '3 秒内地球没转，经度回调没来');
    final double lonMoved = lonDelta(lonLog[lonMark], lonLog.last).abs();
    expect(lonMoved, greaterThan(20),
        reason: '地球没有恢复旋转，3 秒经度只走了 $lonMoved°（应约 36°）');
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('close animation stays smooth frame by frame',
      (tester) async {
    // v16 回归：收尾错峰不能在关闭动画里引入跳变——面板脸逐帧单调
    // 缩小、无跳变（v7 同款：单步跌幅 < 120dp），落点贴着卡片。
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    final Offset cardWhileOpen = cardCenter(tester);
    final faces = await closeSessionPanelStepwise(tester);
    expect(faces.length, greaterThan(2));
    double prevArea = double.infinity;
    double prevHeight = double.infinity;
    for (final face in faces) {
      final double area = face.width * face.height;
      // 面积大致单调不增：关闭弹簧是欠阻尼的（0.88/0.92），收尾会轻微
      // 过冲回弹，面积可能比上一帧大一点点（实测约 0.04%），
      // 所以放 2% 的容差；真正跳变是几百上千，2% 盖不住它。
      // 高度单调不增、单步跌幅 < 120dp 是严格的（v14 同款）。
      expect(area, lessThanOrEqualTo(prevArea * 1.02 + 1));
      expect(face.height, lessThanOrEqualTo(prevHeight + 1));
      if (prevHeight != double.infinity) {
        expect(prevHeight - face.height, lessThan(120));
      }
      prevArea = area;
      prevHeight = face.height;
    }
    final Rect lastFace = faces.last;
    expect(lastFace.center.dx, closeTo(cardWhileOpen.dx, 30));
    expect(lastFace.center.dy, closeTo(cardWhileOpen.dy, 30));
    expect(lastFace.height, closeTo(46, 20));
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session disconnect still happens after close',
      (tester) async {
    // v16 回归：断开改成“快照 + 延后一帧关”，旧会话还是要关干净，
    // 不能漏（dispose 里也有关，但面板关到底这条路必须自己关）。
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    await closeSessionPanelStepwise(tester);
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('off-center tap still lands exactly on the card (no drop)',
      (tester) async {
    // v16-drop：主人实锤——收回时面板会“突然往下掉一下”。
    // 根因：锚点按点按点算，点按点可以落在卡片任意位置（名字那一行
    // 偏上十几 dp），脸缩到比卡片高出一截的地方，overlay 一卸、
    // 卡片在更低处露出来，肉眼就是往下掉。修法：锚点改成卡片本身
    // 的全局中心（globe.dart 两处 onTapUp），和点按点无关。
    // 点卡片上沿（离卡片中心约 18dp）开面板：没修的话，锚点比卡片
    // 高约 18dp，收回必掉；修好以后锚点就是卡片中心，零位移交接。
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    // 卡片的实时矩形，点它上沿开面板（离中心约 18dp）。
    final Rect cardRect = tester.getRect(cardFinder(tester));
    final Offset cardCenterBefore = cardRect.center;
    await tester.tapAt(cardRect.topCenter + const Offset(0, 5));
    await settle(tester, 1200);
    expect(find.byKey(const ValueKey('session_input_field')), findsOneWidget);
    // 锚点就是卡片中心，和点按点（上沿）无关。
    final overlay = tester.widget<GlassMorphOverlay>(
      find.byType(GlassMorphOverlay),
    );
    expect(overlay.origin.center.dx, closeTo(cardCenterBefore.dx, 2));
    expect(overlay.origin.center.dy, closeTo(cardCenterBefore.dy, 2));
    // 面板开着等 5 秒（地球冻着，卡片钉住），再逐帧收回。
    // 注意：冻住的基准是开面板后（已冻住）的卡片位置，不是点按前
    // 的——点按和冻住之间地球还转了几毫秒，卡片会挪约 0.6dp，
    // 那不是漂移，是点按时刻到冻住时刻的正常转动。
    final Offset cardCenterAtOpen = cardCenter(tester);
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(cardCenter(tester).dx, closeTo(cardCenterAtOpen.dx, 0.5));
    expect(cardCenter(tester).dy, closeTo(cardCenterAtOpen.dy, 0.5));
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    // 逐帧 16ms 推进，记每帧脸的中心。
    final faceCenters = <Offset>[];
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(GlassMorphOverlay).evaluate().isEmpty) break;
      faceCenters.add(faceRect(tester).center);
    }
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(faceCenters.length, greaterThan(2));
    // v19：关闭过渡里地球转、卡片漂，所以落点的参照是卡片在
    // unmount 那一刻的实时位置（关完立刻量），不是点按前的旧位置。
    // 收尾最后一帧：脸的中心和实时卡片中心差 ≤2dp（x、y 都要）——
    // 零位移交接，overlay 卸掉时肉眼看不出任何跳动。卡片相对点按
    // 前的漂移有界（±10dp）。
    await tester.pump();
    final Offset liveCard = cardCenter(tester);
    expect(liveCard.dx, closeTo(cardCenterBefore.dx, 10));
    expect(liveCard.dy, closeTo(cardCenterBefore.dy, 10));
    final Offset lastFace = faceCenters.last;
    expect(lastFace.dx, closeTo(liveCard.dx, 2));
    expect(lastFace.dy, closeTo(liveCard.dy, 2));
    // 脸的中心 y 单调收向实时卡片：到卡片的距离每步不增（3dp 容差，
    // 欠阻尼弹簧收尾有约 1dp 的过冲回弹），单步不超过 40dp。
    double prevDist = (faceCenters.first.dy - liveCard.dy).abs();
    double prevY = faceCenters.first.dy;
    for (final c in faceCenters.skip(1)) {
      final double dist = (c.dy - liveCard.dy).abs();
      expect(dist, lessThanOrEqualTo(prevDist + 3));
      expect((c.dy - prevY).abs(), lessThan(40));
      prevDist = dist;
      prevY = c.dy;
    }
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening within the deferral window is safe',
      (tester) async {
    // v16 关键：关到底后两帧内重开——旧的地球恢复回调必须取消
    // （代次 + _morph 检查），不能把新面板的地球解冻；延后那一帧的
    // 断开只关快照里的旧会话，不能误关新开的会话。
    // v19：会话关闭不再排恢复回调（关到底直接解冻，地球在过渡里
    // 已经转起来了），这里的“恢复回调”只剩添加/设置 morph 那条路；
    // 这个测试验证的不变量不变：重开后旧会话关、新会话活、新面板
    // 开着时地球冻着。
    final handles = <_FakeSessionHandle>[];
    await pumpHome(
      tester,
      connector: (_, _, _) async {
        final h = _FakeSessionHandle();
        handles.add(h);
        return h;
      },
    );
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    expect(handles, hasLength(1));
    await closeSessionPanelStepwise(tester);
    // overlay 刚卸载、恢复回调还没跑完，立刻重开同一张卡片。
    await tester.tap(find.textContaining('测试机'));
    await settle(tester, 1200);
    expect(find.byKey(const ValueKey('session_input_field')), findsOneWidget);
    expect(handles, hasLength(2));
    final _FakeSessionHandle oldHandle = handles[0];
    final _FakeSessionHandle newHandle = handles[1];
    // 旧会话关了，新会话活着。
    expect(await waitForCondition(tester, () => oldHandle.closed), isTrue);
    expect(newHandle.closed, isFalse);
    // 新面板开着等 5 秒：地球必须还冻着（旧的恢复没解冻它）。
    final Offset before = cardCenter(tester);
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Offset after = cardCenter(tester);
    expect(after.dx, closeTo(before.dx, 0.5));
    expect(after.dy, closeTo(before.dy, 0.5));
    // 再关新面板，新会话也关干净。
    await closeSessionPanelStepwise(tester);
    expect(await waitForCondition(tester, () => newHandle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });
}
