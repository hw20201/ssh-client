import 'dart:io';

import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/ip_geo_database.dart';
import 'package:ssh_client/main.dart';

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

  Future<void> openAdd(WidgetTester tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
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

  testWidgets('unresolved host card shows the country name Germany',
      (tester) async {
    await openAdd(tester);
    await fillAddForm(tester, name: '内网机', host: '192.168.1.10');
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester, 300);
    await tester.enterText(
      find.byKey(const ValueKey('add_password_field')),
      'pw123',
    );
    await tapSave(tester);
    // 保存提示也改成“已放在德国。”。
    expect(await waitForText(tester, '已放在德国'), isTrue);
    await settle(tester, 1000);
    await tester.pump(const Duration(seconds: 6));
    final card = tester.widget<Text>(find.textContaining('内网机'));
    expect(card.data, contains('德国'));
    expect(card.data, isNot(contains('默认位置')));
    expect(tester.takeException(), isNull);
  });

}
