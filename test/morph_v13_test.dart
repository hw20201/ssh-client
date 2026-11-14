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

/// v13：假会话——只收字节、按写的内容回 canned 输出；close 记一笔。
/// 收到写操作时把原样回显 + 一行 canned 输出推进 stdout（真 pty 也会
/// 把打进去的指令回显回来）。
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

  /// 起主页（带假连接器），地球转起来。
  Future<void> pumpHome(
    WidgetTester tester, {
    SessionConnector? connector,
  }) async {
    await tester.pumpWidget(SshApp(sessionConnector: connector));
    await settle(tester, 2000);
  }

  Future<void> openAdd(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);
  }

  Future<void> fillAddForm(
    WidgetTester tester, {
    required String name,
    required String host,
  }) async {
    await tester.enterText(
      find.byKey(const ValueKey('add_name_field')),
      name,
    );
    await tester.enterText(
      find.byKey(const ValueKey('add_host_field')),
      host,
    );
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('glass_form_save')));
    await settle(tester, 300);
  }

  /// 密码方式保存一个服务器（端口/用户名留空走默认值），返回它的 id。
  Future<String> savePasswordServer(
    WidgetTester tester, {
    required String name,
    required String host,
    String password = 'pw123',
  }) async {
    await openAdd(tester);
    await fillAddForm(tester, name: name, host: host);
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester, 300);
    await tester.enterText(
      find.byKey(const ValueKey('add_password_field')),
      password,
    );
    await tapSave(tester);
    expect(await waitForText(tester, '已保存'), isTrue);
    await settle(tester, 1000);
    await tester.pump(const Duration(seconds: 6));
    final profiles = await loadProfiles();
    expect(profiles, hasLength(1));
    return profiles.first.id;
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

  /// 点地球仪卡片，等会话面板的弹簧走完（输入框可点）。
  Future<void> openSessionPanel(WidgetTester tester, String name) async {
    await tester.tap(find.textContaining(name));
    await settle(tester, 1200);
    expect(find.byKey(const ValueKey('session_input_field')), findsOneWidget);
  }

  Future<void> sendCommand(WidgetTester tester, String command) async {
    await tester.enterText(
      find.byKey(const ValueKey('session_input_field')),
      command,
    );
    await tester.tap(find.byKey(const ValueKey('session_send_button')));
    await settle(tester, 300);
  }

  testWidgets('tapping a globe card opens the session panel directly',
      (tester) async {
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    // 面板在主页上（地球仪卡片还在树上，没有推新页面），输入框和
    // 输出区都在，连接状态到了“已连接”。
    expect(find.textContaining('测试机'), findsWidgets);
    expect(find.byKey(const ValueKey('session_output_list')), findsOneWidget);
    expect(find.textContaining('已连接'), findsWidgets);
    expect(handle.closed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session panel is 0.62 screen height, input at the bottom',
      (tester) async {
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    final overlay = tester.widget<GlassMorphOverlay>(
      find.byType(GlassMorphOverlay),
    );
    expect(overlay.targets, hasLength(1));
    final target = overlay.targets.first;
    final media = MediaQuery.of(tester.element(find.byKey(
      const ValueKey('session_input_field'),
    )));
    // 面板占 0.62 屏高，顶部贴 safe.top + 16，四周留 16。
    expect(target.height, closeTo(media.size.height * 0.62, 2));
    expect(target.top, closeTo(media.padding.top + 16, 2));
    expect(target.left, 16);
    expect(target.width, closeTo(media.size.width - 32, 2));
    // 输入框在面板底部（底边贴着面板底 - 16 的内边距），输出区在它上面。
    final inputRect = tester.getRect(find.byKey(
      const ValueKey('session_input_field'),
    ));
    expect(inputRect.bottom, closeTo(target.bottom - 16, 10));
    final outputRect = tester.getRect(find.byKey(
      const ValueKey('session_output_list'),
    ));
    expect(inputRect.top, greaterThan(outputRect.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending a command shows it and the session output',
      (tester) async {
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    await sendCommand(tester, 'echo hi');
    expect(handle.written, hasLength(1));
    expect(utf8.decode(handle.written.first), 'echo hi\n');
    // 发出去的指令（> 开头）和会话回来的输出都在输出区里。
    expect(find.text('> echo hi'), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);
    // 发完输入框清空、面板保持打开（可连续输）。
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('session_input_field')),
    );
    expect(field.controller?.text, '');
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the panel disconnects and returns to the globe',
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
    expect(handles, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    await settle(tester, 1200);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    // 会话断开了（订阅/session/client 都关了），主页还在。
    // 断开是异步的（先取消两个订阅、再关会话），等它落定。
    expect(await waitForCondition(tester, () => handles.first.closed),
        isTrue);
    expect(find.textContaining('测试机'), findsWidgets);
    // 再点卡片能重新打开（新会话）。
    await openSessionPanel(tester, '测试机');
    expect(handles, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection failure shows the reason in the output area',
      (tester) async {
    Future<SessionHandle> failing(
      ServerProfile profile,
      SavedAuth auth,
      Future<bool> Function(String, Uint8List) verify,
    ) async {
      throw Exception('Authentication failed');
    }

    await pumpHome(tester, connector: failing);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    // 失败原因写进输出区，面板还开着（不是空白）。
    expect(find.textContaining('认证失败'), findsWidgets);
    expect(find.text('连接失败'), findsOneWidget);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending before connect shows the not-connected hint',
      (tester) async {
    Future<SessionHandle> hanging(
      ServerProfile profile,
      SavedAuth auth,
      Future<bool> Function(String, Uint8List) verify,
    ) =>
        Completer<SessionHandle>().future;

    await pumpHome(tester, connector: hanging);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    await sendCommand(tester, 'echo hi');
    expect(find.textContaining('还没连上，等连接成功再发。'), findsOneWidget);
    // 面板照样能关，不崩。
    await tester.tap(find.byKey(const ValueKey('session_panel_close')));
    await settle(tester, 1200);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new output auto-scrolls to the bottom', (tester) async {
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    for (int i = 0; i < 20; i++) {
      await sendCommand(tester, 'cmd $i');
    }
    // 最后一条在视野里，第一条已经滚出去了（输出区只有约 10 行高）。
    expect(find.text('> cmd 19'), findsOneWidget);
    expect(find.text('> cmd 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the scrim closes the panel and disconnects',
      (tester) async {
    final handle = _FakeSessionHandle();
    await pumpHome(tester, connector: (_, _, _) async => handle);
    await savePasswordServer(tester, name: '测试机', host: '192.168.1.10');
    expect(await waitForText(tester, '测试机'), isTrue);
    await openSessionPanel(tester, '测试机');
    // 面板在上半屏（约 16..388），点下半屏的空白（scrim）。
    await tester.tapAt(const Offset(400, 500));
    await settle(tester, 1200);
    expect(find.byType(GlassMorphOverlay), findsNothing);
    expect(await waitForCondition(tester, () => handle.closed), isTrue);
    expect(tester.takeException(), isNull);
  });
}
