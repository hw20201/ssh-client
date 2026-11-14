import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssh_client/ip_geo_database.dart';

import 'geo_test_helpers.dart';

/// GeoDataUpdater 的远端更新测试（普通 test，真实时间 + MockClient，
/// 不碰真实网络：所有 HTTP 都走 MockClient）。
///
/// 注意：测试里直接往数据目录种数据时，种完要调一次
/// `IpGeoDatabase.refresh()`，让单例跟上磁盘状态——真机上数据库
/// 本来就是在数据落盘之后才打开的，这里只是复现那个顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final Directory supportDir;
  var supportPath = '';

  setUpAll(() async {
    supportDir = await Directory.systemTemp.createTemp('ipgeo-remote-test-');
    supportPath = supportDir.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return supportPath;
        }
        return null;
      },
    );
  });

  setUp(() async {
    // 每个测试从干净的数据目录开始，单例复位。
    final dir = Directory('$supportPath/geo');
    if (await dir.exists()) await dir.delete(recursive: true);
    await IpGeoDatabase.refresh();
  });

  Future<Directory> geoDir() async => Directory('$supportPath/geo');

  test('no local data -> downloads and lookup works', () async {
    final dataset = SyntheticGeoDataset(); // 2026-11, 美国坐标。
    var manifestGets = 0;
    var assetGets = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('manifest.json')) {
        manifestGets++;
        return http.Response(dataset.manifestJson, 200);
      }
      assetGets++;
      return http.Response.bytes(dataset.gzipped, 200);
    });
    final result = await GeoDataUpdater(client: client).ensureAndUpdate();
    expect(result.updated, isTrue);
    expect(result.hasData, isTrue);
    expect(result.error, isNull);
    expect(manifestGets, 1);
    expect(assetGets, 1);
    final db = await IpGeoDatabase.open();
    final loc = await db.lookup('8.8.8.8');
    expect(loc, isNotNull);
    expect(loc!.point.lat, greaterThan(20));
    expect(loc.point.lat, lessThan(55));
    expect(loc.point.lon, lessThan(-60));
  });

  test('same version + complete local files -> no asset download', () async {
    final dataset = SyntheticGeoDataset();
    await seedGeoDataDir(await geoDir(), dataset);
    await IpGeoDatabase.refresh();
    var manifestGets = 0;
    var assetGets = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('manifest.json')) {
        manifestGets++;
        return http.Response(dataset.manifestJson, 200);
      }
      assetGets++;
      return http.Response.bytes(dataset.gzipped, 200);
    });
    final result = await GeoDataUpdater(
      client: client,
    ).ensureAndUpdate(force: true);
    expect(result.updated, isFalse);
    expect(result.hasData, isTrue);
    expect(manifestGets, 1);
    expect(assetGets, 0);
  });

  test('SHA-256 mismatch on download -> discards, keeps old data', () async {
    final oldDataset = SyntheticGeoDataset(
      generated: '2026-11',
      lat: 37.75,
      lon: -122.4,
    );
    await seedGeoDataDir(await geoDir(), oldDataset);
    await IpGeoDatabase.refresh();
    final newDataset = SyntheticGeoDataset(
      generated: '2026-12',
      lat: 51.5,
      lon: -0.12,
    );
    // 远程 manifest 是新的，但文件内容被改过一个字节，SHA-256 对不上。
    final corrupted = List<int>.from(newDataset.gzipped);
    corrupted[20] = corrupted[20] ^ 0xFF;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('manifest.json')) {
        return http.Response(newDataset.manifestJson, 200);
      }
      return http.Response.bytes(corrupted, 200);
    });
    final result = await GeoDataUpdater(
      client: client,
    ).ensureAndUpdate(force: true);
    expect(result.updated, isFalse);
    expect(result.hasData, isTrue);
    expect(result.error, isNotNull);
    // 旧数据还在，查到的还是旧坐标（美国）。
    final db = await IpGeoDatabase.open();
    final loc = await db.lookup('8.8.8.8');
    expect(loc, isNotNull);
    expect(loc!.point.lat, greaterThan(20));
    expect(loc.point.lat, lessThan(55));
    expect(loc.point.lon, lessThan(-60));
  });

  test(
    'remote newer version -> downloads new, lookup returns new coordinate',
    () async {
      final oldDataset = SyntheticGeoDataset(
        generated: '2026-11',
        lat: 37.75,
        lon: -122.4,
      );
      await seedGeoDataDir(await geoDir(), oldDataset);
      await IpGeoDatabase.refresh();
      final newDataset = SyntheticGeoDataset(
        generated: '2026-12',
        lat: 51.5,
        lon: -0.12,
      );
      final client = MockClient((request) async {
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response(newDataset.manifestJson, 200);
        }
        return http.Response.bytes(newDataset.gzipped, 200);
      });
      final result = await GeoDataUpdater(
        client: client,
      ).ensureAndUpdate(force: true);
      expect(result.updated, isTrue);
      expect(result.hasData, isTrue);
      final db = await IpGeoDatabase.open();
      final loc = await db.lookup('8.8.8.8');
      expect(loc, isNotNull);
      // 新坐标：伦敦 51.5, -0.12（不是旧的美国坐标）。
      expect(loc!.point.lat, closeTo(51.5, 0.01));
      expect(loc.point.lon, closeTo(-0.12, 0.01));
    },
  );

  test('network error -> keeps old data, no throw', () async {
    final oldDataset = SyntheticGeoDataset();
    await seedGeoDataDir(await geoDir(), oldDataset);
    await IpGeoDatabase.refresh();
    final client = MockClient((request) async {
      throw const SocketException('network unreachable');
    });
    final result = await GeoDataUpdater(
      client: client,
    ).ensureAndUpdate(force: true);
    expect(result.updated, isFalse);
    expect(result.hasData, isTrue);
    expect(result.error, isNotNull);
    final db = await IpGeoDatabase.open();
    expect(await db.lookup('8.8.8.8'), isNotNull);
  });

  test('network error with no local data -> hasData false, no throw', () async {
    final client = MockClient((request) async {
      throw const SocketException('network unreachable');
    });
    final result = await GeoDataUpdater(
      client: client,
    ).ensureAndUpdate(force: true);
    expect(result.updated, isFalse);
    expect(result.hasData, isFalse);
    expect(result.error, isNotNull);
    final db = await IpGeoDatabase.open();
    expect(db.hasData, isFalse);
    expect(await db.lookup('8.8.8.8'), isNull);
  });
}
