import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/ip_geo_database.dart';
import 'package:ssh_client/main.dart';

import 'geo_test_helpers.dart';

/// v22：首次启动地理数据下载弹窗 + 流式进度 + 失败重试。
///
/// 两层测试：
/// - 单元测试（普通 test，真实时间 + 假的流式客户端）：下载进度从 0 到
///   100、取消中途停掉并清掉临时文件。
/// - Widget 测试（testWidgets + 假 runner，不碰真实网络）：本地无数据时
///   弹窗出现、总大小与进度显示、取消关弹窗、失败出现重试、重试成功后
///   自动关、本地已有数据时不弹。
///
/// 注意：弹窗里的下载走注入的 runner（假的），不是真实 HTTP；真实的
/// 流式下载 + 进度回调由上面的单元测试覆盖。

/// 把数据集的 gzipped 字节按 [chunks] 份流式吐出来，每份之间停一下，
/// 让进度回调能看到 0 -> 100 的过程（MockClient 是一次性整包，没有
/// 中间进度，测不到这个）。
class _ChunkedGeoClient extends http.BaseClient {
  _ChunkedGeoClient(this.dataset, {this.chunks = 4});

  final SyntheticGeoDataset dataset;
  final int chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('manifest.json')) {
      final bytes = utf8.encode(dataset.manifestJson);
      return http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length,
      );
    }
    final gzipped = dataset.gzipped;
    final per = (gzipped.length / chunks).ceil();
    final parts = <List<int>>[];
    for (var i = 0; i < gzipped.length; i += per) {
      parts.add(
        gzipped.sublist(i, (i + per).clamp(0, gzipped.length)),
      );
    }
    final controller = StreamController<List<int>>();
    unawaited(() async {
      for (final part in parts) {
        await Future.delayed(const Duration(milliseconds: 10));
        controller.add(part);
      }
      await controller.close();
    }());
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: gzipped.length,
    );
  }
}

/// 弹窗测试用的假下载器：测试手动驱动进度、控制成功/失败。
class _FakeGeoDownloadRunner {
  void Function(GeoDownloadProgress)? onProgress;
  bool Function()? isCancelled;
  var calls = 0;
  Completer<GeoUpdateResult>? completer;

  Future<GeoUpdateResult> call({
    required void Function(GeoDownloadProgress) onProgress,
    required bool Function() isCancelled,
  }) {
    calls++;
    this.onProgress = onProgress;
    this.isCancelled = isCancelled;
    completer = Completer<GeoUpdateResult>();
    return completer!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fakeVault = <String, String>{};
  late final Directory supportDir;
  var supportPath = '';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    supportDir = await Directory.systemTemp.createTemp('ipgeo-first-test-');
    supportPath = supportDir.path;
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
          return supportPath;
        }
        return null;
      },
    );
    await fluid.FluidGlass.ensureInitialized();
  });

  setUp(() async {
    fakeVault.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final dir = Directory('$supportPath/geo');
    if (await dir.exists()) await dir.delete(recursive: true);
    await IpGeoDatabase.refresh();
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

  Future<void> pumpHome(
    WidgetTester tester, {
    GeoFirstDownloadRunner? geoRunner,
  }) async {
    await tester.pumpWidget(
      SshApp(geoFirstDownloadRunner: geoRunner),
    );
    await settle(tester, 2000);
  }

  group('streamed download progress (plain test)', () {
    test('progress goes 0 -> 100 across chunks, then done', () async {
      final dataset = SyntheticGeoDataset();
      final events = <GeoDownloadProgress>[];
      final result = await GeoDataUpdater(
        client: _ChunkedGeoClient(dataset),
      ).ensureAndUpdate(onProgress: events.add);
      expect(result.updated, isTrue);
      expect(result.hasData, isTrue);
      expect(result.error, isNull);
      expect(result.cancelled, isFalse);
      expect(events.first.phase, GeoDownloadPhase.preparing);
      final downloading = events
          .where((e) => e.phase == GeoDownloadPhase.downloading)
          .toList();
      expect(downloading, isNotEmpty);
      // Total is the manifest asset bytes (single synthetic bundle).
      expect(downloading.last.totalBytes, dataset.gzipped.length);
      expect(downloading.last.downloadedBytes, dataset.gzipped.length);
      // Fractions climb monotonically to 1.
      var previous = 0.0;
      for (final e in downloading) {
        expect(e.fraction, greaterThanOrEqualTo(previous));
        previous = e.fraction;
      }
      expect(previous, 1.0);
      expect(events.last.phase, GeoDownloadPhase.done);
      final db = await IpGeoDatabase.open();
      expect(await db.lookup('8.8.8.8'), isNotNull);
    });

    test('cancel mid-download stops, discards .tmp, keeps no data', () async {
      final dataset = SyntheticGeoDataset();
      var cancel = false;
      final result = await GeoDataUpdater(
        client: _ChunkedGeoClient(dataset, chunks: 8),
      ).ensureAndUpdate(
        onProgress: (p) {
          if (p.phase == GeoDownloadPhase.downloading &&
              p.downloadedBytes > 0) {
            cancel = true;
          }
        },
        isCancelled: () => cancel,
      );
      expect(result.cancelled, isTrue);
      expect(result.updated, isFalse);
      expect(result.hasData, isFalse);
      final dir = await geoDataDir();
      expect(
        await File('${dir.path}/ip4_city_v1.bin.gz').exists(),
        isFalse,
      );
      expect(
        await File('${dir.path}/ip4_city_v1.bin.gz.tmp').exists(),
        isFalse,
      );
    });
  });

  group('first-launch download dialog (widget test)', () {
    testWidgets(
      'no local data -> dialog appears, shows total size and progress, '
      'auto-closes on success',
      (tester) async {
        final runner = _FakeGeoDownloadRunner();
        await pumpHome(tester, geoRunner: runner.call);
        expect(
          await waitForText(tester, '首次启动 · 下载位置数据'),
          isTrue,
        );
        expect(runner.calls, 1);
        // Preparing: total not known yet.
        expect(find.text('正在准备下载…'), findsOneWidget);
        // Manifest fetched: total known (26.5MB in the real dataset).
        runner.onProgress!(
          const GeoDownloadProgress(
            phase: GeoDownloadPhase.downloading,
            downloadedBytes: 0,
            totalBytes: 26510177,
          ),
        );
        await tester.pump();
        expect(find.textContaining('共 26.5MB'), findsOneWidget);
        expect(find.textContaining('0%'), findsOneWidget);
        // Halfway.
        runner.onProgress!(
          const GeoDownloadProgress(
            phase: GeoDownloadPhase.downloading,
            downloadedBytes: 13255088,
            totalBytes: 26510177,
          ),
        );
        await tester.pump();
        expect(find.textContaining('13.3MB / 共 26.5MB'), findsOneWidget);
        expect(find.textContaining('50%'), findsOneWidget);
        // Success: the dialog closes by itself.
        runner.completer!.complete(
          const GeoUpdateResult(updated: true, hasData: true),
        );
        await tester.pump();
        await settle(tester, 500);
        expect(find.text('首次启动 · 下载位置数据'), findsNothing);
      },
    );

    testWidgets('cancel closes the dialog and flags the download',
        (tester) async {
      final runner = _FakeGeoDownloadRunner();
      await pumpHome(tester, geoRunner: runner.call);
      expect(
        await waitForText(tester, '首次启动 · 下载位置数据'),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('geo_download_cancel')));
      await tester.pump();
      await settle(tester, 500);
      expect(find.text('首次启动 · 下载位置数据'), findsNothing);
      expect(runner.isCancelled!(), isTrue);
      // Let the abandoned attempt finish cleanly (no crash after pop).
      runner.completer!.complete(
        const GeoUpdateResult(
          updated: false,
          hasData: false,
          cancelled: true,
        ),
      );
      await tester.pump();
    });

    testWidgets(
      'failure shows retry; retry succeeds and the dialog closes',
      (tester) async {
        final runner = _FakeGeoDownloadRunner();
        await pumpHome(tester, geoRunner: runner.call);
        expect(
          await waitForText(tester, '首次启动 · 下载位置数据'),
          isTrue,
        );
        runner.completer!.complete(
          const GeoUpdateResult(
            updated: false,
            hasData: false,
            error: 'SocketException: network unreachable',
          ),
        );
        await tester.pump();
        await settle(tester, 500);
        expect(
          find.byKey(const ValueKey('geo_download_retry')),
          findsOneWidget,
        );
        expect(find.text('下载失败，请检查网络后重试。'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('geo_download_retry')));
        await tester.pump();
        expect(runner.calls, 2);
        // Progress resets to preparing on retry.
        expect(find.text('正在准备下载…'), findsOneWidget);
        runner.completer!.complete(
          const GeoUpdateResult(updated: true, hasData: true),
        );
        await tester.pump();
        await settle(tester, 500);
        expect(find.text('首次启动 · 下载位置数据'), findsNothing);
      },
    );

    testWidgets('local data present -> no dialog', (tester) async {
      final dataset = SyntheticGeoDataset();
      final dir = Directory('$supportPath/geo');
      // Real file I/O (seed + gzip extract + SBGX open) must run in the
      // real async zone: awaiting it directly in testWidgets fake time
      // hangs (same rule as v11-v20: dart:io via tester.runAsync).
      await tester.runAsync(() async {
        await seedGeoDataDir(dir, dataset);
        await IpGeoDatabase.refresh();
      });
      final runner = _FakeGeoDownloadRunner();
      await pumpHome(tester, geoRunner: runner.call);
      await settle(tester, 2000);
      expect(find.text('首次启动 · 下载位置数据'), findsNothing);
      expect(runner.calls, 0);
    });
  });

  group('v23: dialog height fits content (small window)', () {
    testWidgets(
      'dialog is a small window: height far below screen height, '
      'cancel sits right under the status text, no empty space below it',
      (tester) async {
        final runner = _FakeGeoDownloadRunner();
        await pumpHome(tester, geoRunner: runner.call);
        expect(
          await waitForText(tester, '首次启动 · 下载位置数据'),
          isTrue,
        );
        // Drive progress so the total size is known (same as the v22
        // halfway state: 13.3MB / 共 26.5MB（50%）).
        runner.onProgress!(
          const GeoDownloadProgress(
            phase: GeoDownloadPhase.downloading,
            downloadedBytes: 13255088,
            totalBytes: 26510177,
          ),
        );
        await tester.pump();
        final screenHeight =
            tester.view.physicalSize.height / tester.view.devicePixelRatio;
        // v23：量看得见的面板（Dialog 里唯一的 prism LiquidGlass），
        // 不要量 Dialog widget 本身——它的根是 Align，会按松约束
        // 撑满全屏（800×600），面板实际只有约 228dp 高。
        final panelFinder = find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(prism.LiquidGlass),
        );
        expect(panelFinder, findsOneWidget);
        final panelSize = tester.getSize(panelFinder);
        // v23：弹窗高度贴合内容（标题 + 说明 + 进度条 + 状态 + 按钮，
        // 约 228dp）。v22 的根因是 _FormGlassPanel 外层 Column 默认
        // MainAxisSize.max，在 Dialog 的松约束里撑到全屏高（测试面
        // 600dp 高时面板约 552dp）；这条断言在 v22 代码上会挂。
        expect(panelSize.height, lessThan(screenHeight * 0.6));
        // “取消”紧跟在状态文字下面（内容列里 18dp 间距 + 按钮内边距）。
        final statusBottom = tester
            .getBottomLeft(
              find.byKey(const ValueKey('geo_download_progress_text')),
            )
            .dy;
        final cancelTop = tester
            .getTopLeft(find.byKey(const ValueKey('geo_download_cancel')))
            .dy;
        expect(cancelTop - statusBottom, lessThan(60));
        // “取消”下面没有大片空白（面板底边距 17dp + 边框）。
        final panelBottom = tester.getBottomLeft(panelFinder).dy;
        final cancelBottom = tester
            .getBottomLeft(find.byKey(const ValueKey('geo_download_cancel')))
            .dy;
        expect(panelBottom - cancelBottom, lessThan(60));
      },
    );
  });
}
