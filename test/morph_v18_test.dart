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

/// v18：关闭收尾“莫名其妙顿一下” + 地球恢复转动。
/// 根因（v18 诊断，实测）：
/// 1. 顿：关闭 X 弹簧（0.88/300）到 0.001 的收敛阈值要约 0.45 秒，
///    脸在第 20 帧就贴到锚点了，overlay 却到第 32 帧才卸——中间
///    12 帧（192ms）脸停在按钮上不动、卡片还藏着、地球还冻着，
///    就是主人说的“面板变成按钮以后，顿了一下”。修法：脸贴到
///    锚点（四边 1dp 内）就提前交接，弹簧尾巴直接钉到 0。
/// 2. 地球恢复：恢复后第一个 tick 就已经是满速 12°/秒（0→12 一帧
///    跳变），而且只比卡片回来晚 4 帧。修法：卡片回来后再晚 150ms
///    才解冻（_scheduleGlobeResume 里加 Timer），解冻后转速用
///    450ms smoothstep 从 0 爬回 12°/秒（globe.dart 的斜坡）。
/// v19：主人验收说第 1 个（顿）修好了，第 2 个（地球恢复）没有——
/// 加速要发生在面板变为按钮的那段时间里，不是过渡结束之后。所以
/// 会话关闭的恢复改成 morph 驱动（点关闭那一刻开始爬，过渡结束
/// 时回到 12°/秒），旧的“关完等 150ms 再恢复”只留给添加/设置
/// morph。原来这个文件的测试 1（断言关完晚恢复）已移到
/// morph_v19_test.dart 按新行为重写；这里只剩测试 2（重开回归）。
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

  testWidgets('reopening after close still works (early settle + timer)',
      (tester) async {
    // v18 回归：提前交接 + 150ms 延时恢复，不能破坏重开——
    // 旧的恢复定时器不能把新面板的地球解冻（代次 + _morph 检查）。
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
    await closeSessionPanelRecorded(tester, <double>[]);
    // overlay 刚卸载、150ms 恢复定时器还没到点，立刻重开同一张卡片。
    await tester.tap(find.textContaining('测试机'));
    await settle(tester, 1200);
    expect(find.byKey(const ValueKey('session_input_field')), findsOneWidget);
    expect(handles, hasLength(2));
    final _FakeSessionHandle oldHandle = handles[0];
    final _FakeSessionHandle newHandle = handles[1];
    expect(await waitForCondition(tester, () => oldHandle.closed), isTrue);
    expect(newHandle.closed, isFalse);
    // 新面板开着等 5 秒：地球必须还冻着（旧的恢复没解冻它）。
    final Offset before = cardCenterOrNull(tester)!;
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Offset after = cardCenterOrNull(tester)!;
    expect(after.dx, closeTo(before.dx, 0.5));
    expect(after.dy, closeTo(before.dy, 0.5));
    // 再关新面板，新会话也关干净。
    await closeSessionPanelRecorded(tester, <double>[]);
    expect(await waitForCondition(tester, () => newHandle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });
}
