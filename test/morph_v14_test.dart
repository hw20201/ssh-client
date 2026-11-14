import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/glass_morph_overlay.dart';
import 'package:ssh_client/ip_geo_database.dart';
import 'package:ssh_client/main.dart';

/// v13 同款假会话（v14 直接复用）。
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

  testWidgets('session panel open hides the anchor card', (tester) async {
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    // 打开前卡片露着。
    expect(cardHidden(tester), isFalse);
    await openSessionPanel(tester, '测试机');
    // 面板开着，锚点卡片藏起来了（它变成了面板），锚点处只有面板这一层玻璃。
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(cardHidden(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'card stays hidden through the whole close, single glass layer',
      (tester) async {
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    final overlay = tester.widget<GlassMorphOverlay>(
      find.byType(GlassMorphOverlay),
    );
    final Rect anchor = overlay.origin;
    expect(cardHidden(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    // 收回逐帧 16ms 推进：卡片全程藏着（锚点处只有一个玻璃层在动），
    // 脸的高度单调递减、落点回到锚点。欠阻尼弹簧尾段有约 0.1dp 的过冲，
    // 单调断言留 1dp 容差（v7 同款）。
    double prevHeight = faceRect(tester).height;
    double minHeight = prevHeight;
    Rect lastFace = faceRect(tester);
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(GlassMorphOverlay).evaluate().isEmpty) break;
      expect(cardHidden(tester), isTrue);
      final Rect face = faceRect(tester);
      expect(face.height, lessThanOrEqualTo(prevHeight + 1.0));
      expect(prevHeight - face.height, lessThan(120));
      prevHeight = face.height;
      if (face.height < minHeight) minHeight = face.height;
      lastFace = face;
    }
    // 脸确实收回去了（从 0.62 屏高收到接近锚点的 46）。
    expect(minHeight, lessThan(60));
    // 落点回到锚点（最后采到的脸矩形贴着锚点矩形）。
    expect(lastFace.center.dx, closeTo(anchor.center.dx, 30));
    expect(lastFace.center.dy, closeTo(anchor.center.dy, 30));
    expect(lastFace.height, closeTo(anchor.height, 20));
    await settle(tester);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    // 关到底卡片回来了。
    expect(cardHidden(tester), isFalse);
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('after full close the card returns and can be re-opened',
      (tester) async {
    final handles = <_FakeSessionHandle>[];
    await pumpHome(
      tester,
      connector: (_, _, _) async {
        final handle = _FakeSessionHandle();
        handles.add(handle);
        return handle;
      },
    );
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    expect(cardHidden(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    await settle(tester, 1200);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(cardHidden(tester), isFalse);
    expect(await waitForCondition(tester, () => handles.first.closed),
        isTrue);
    // 再点卡片能重新打开（新会话），卡片又藏起来。
    await openSessionPanel(tester, '测试机');
    expect(handles, hasLength(2));
    expect(cardHidden(tester), isTrue);
    expect(tester.takeException(), isNull);
  });
}
