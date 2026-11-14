import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_client/ip_geo_database.dart';

/// 城市自动解析的库级证明（普通 test，真实时间）。
///
/// 为什么不用 testWidgets 测真坐标：widget 测试跑在假时间里，真实
/// 文件读时通时挂，保存那一步可能 1 秒超时走默认落点，且保存后
/// _loadGeoLocations 还会在后台再查一次——都是测试环境的假时间问题。
/// 普通 test 不在假时间里，文件读正常完成，这里断言的就是库本身
/// 的解析能力；App 保存时调的是同一个 `IpGeoDatabase.lookup`，
/// 真机上文件读是毫秒级，保存那一步直接落真坐标。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final Directory supportDir;

  setUpAll(() async {
    supportDir = await Directory.systemTemp.createTemp('ipgeo-test-');
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
  });

  test('public IP 8.8.8.8 resolves to real US coordinates', () async {
    final db = await IpGeoDatabase.open();
    final loc = await db.lookup('8.8.8.8');
    expect(loc, isNotNull);
    // 标签是“约 xx°, xx°”；查不到的默认落点才写“德国”。
    expect(loc!.label, contains('约 '));
    // 8.8.8.8 在美国境内（不是默认的法兰克福 50.11°, 8.68°）。
    expect(loc.point.lat, greaterThan(20));
    expect(loc.point.lat, lessThan(55));
    expect(loc.point.lon, lessThan(-60));
  });

  test('private IP returns null (falls back to the default spot)', () async {
    final db = await IpGeoDatabase.open();
    expect(await db.lookup('192.168.1.10'), isNull);
    expect(await db.lookup('127.0.0.1'), isNull);
    expect(await db.lookup('10.0.0.5'), isNull);
  });

  test('hostname is not resolved by the database itself', () async {
    final db = await IpGeoDatabase.open();
    expect(await db.lookup('localhost'), isNull);
  });
}
