import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart' as picker;
import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/glass_morph_overlay.dart';
import 'package:ssh_client/ip_geo_database.dart';
import 'package:ssh_client/main.dart';

/// v9：一个假的 picked file（PlatformFile 是 abstract base class，
/// 子类要标 final；xFile/length/read* 只是占位，App 只读 name/path）。
final class FakePlatformFile extends picker.PlatformFile {
  FakePlatformFile({required this.name, required this.uri});

  @override
  final String name;

  @override
  final Uri uri;

  @override
  XFile get xFile => XFile(uri.toFilePath());

  @override
  int? lengthSync() => 0;

  @override
  Future<int?> length() async => 0;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream.empty();
}

/// v9：一个假的 file_picker 平台（默认构造就带对 token，
/// FilePickerPlatform.instance 的 verifyToken 能过）。
/// result 为 null 就是用户点了取消。
class FakeFilePickerPlatform extends picker.FilePickerPlatform {
  picker.PlatformFile? result;

  @override
  Future<picker.PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    picker.FileType type = picker.FileType.any,
    List<String>? allowedExtensions,
    Function(picker.FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    picker.AndroidOptions androidOptions = const picker.AndroidOptions(),
    picker.DarwinOptions darwinOptions = const picker.DarwinOptions(),
    picker.WindowsOptions windowsOptions = const picker.WindowsOptions(),
    picker.LinuxOptions linuxOptions = const picker.LinuxOptions(),
    picker.WebOptions webOptions = const picker.WebOptions(),
  }) async {
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// v11：保存测试要用的临时目录（真私钥文件 + geo 库解压目录）。
  late final Directory supportDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    supportDir = await Directory.systemTemp.createTemp('ipgeo-test-v9-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => null,
    );
    // IpGeoDatabase.open() 要 getApplicationSupportDirectory，测试里
    // 指到真实临时目录（v11 同款）；不 mock 的话保存时的地理位置
    // 解析会直接抛错走默认落点，也能跑，但和 v11 的行为对不齐。
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
    // geo 库预热：第一次 open 要现场解压 26MB，真实 I/O，
    // setUpAll 不在假时间里，直接跑完；预热一次后单例常驻，
    // 保存测试里的解析直接复用（v11 同款）。
    final geoDb = await IpGeoDatabase.open();
    await geoDb.lookup('8.8.8.8');
  });

  setUp(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  // The globe has a continuously running rotation ticker, so
  // pumpAndSettle() never settles. Advance the fake clock with explicit
  // pumps instead, in small 100ms steps.
  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    final int steps = (ms / 100).ceil();
    for (int i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
  }

  /// v11：等一段文字出现（保存提示靠它）。光 pump 假时间不够：
  /// 保存要做真实 I/O（读密钥文件、查 geo 库），真实 I/O 只在
  /// 真实时间里推进；每轮先 runAsync 跳出假时间、真实等 500ms，
  /// 再 pump 一帧。预算 30 秒真实时间（v11 同款）。
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

  Future<void> openSettings(WidgetTester tester) async {
    await tester.pumpWidget(const SshApp());
    await settle(tester, 2000);
    await tester.tap(find.byKey(const ValueKey('glass_settings_action')));
    await settle(tester);
  }

  /// 胶囊的玻璃脸矩形（上→下排好）：树上只有 morph 的脸是
  /// fluid.DrawBackdrop，按 top 排序就是胶囊顺序。
  List<Rect> capsuleRects(WidgetTester tester) {
    final rects = <Rect>[];
    for (final e in find.byType(fluid.DrawBackdrop).evaluate()) {
      final box = e.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.width < 10) continue; // 预热的 1x1（如果还在）
      rects.add(rect);
    }
    rects.sort((a, b) => a.top.compareTo(b.top));
    return rects;
  }

  /// 可见胶囊之间的间距（上→下）。
  List<double> visibleGaps(WidgetTester tester) {
    final visible =
        capsuleRects(tester).where((r) => r.height > 0).toList();
    return <double>[
      for (int i = 1; i < visible.length; i++)
        visible[i].top - visible[i - 1].bottom,
    ];
  }

  /// v10：一行是不是完整落在某张脸里面（上下左右都用 <= 比，
  /// 底边贴着脸的底边也算在里面——Rect.contains 的底边是开区间，
  /// 行底正好贴着脸底会被它判成外面）。
  bool rectInsideFace(Rect inner, Rect face) =>
      inner.top >= face.top &&
      inner.bottom <= face.bottom &&
      inner.left >= face.left &&
      inner.right <= face.right;

  /// v11：密码输入框是不是在认证方式胶囊的脸里面
  ///（展开后才在里面；收起时它在脸下面，被裁剪盖住）。
  /// v11 有 6 个胶囊，认证方式是第 5 个（下标 4）；密码框按 key 找，
  /// 不再按 TextField 下标（v11 树里有 6 个 TextField，下标变了）。
  bool passwordFieldInsideAuthFace(WidgetTester tester) {
    final field =
        tester.getRect(find.byKey(const ValueKey('add_password_field')));
    final face = capsuleRects(tester)[4];
    return rectInsideFace(field, face);
  }

  /// v10：私钥行是不是在认证方式胶囊的脸里面（同上）。
  bool keyRowInsideAuthFace(WidgetTester tester) {
    final row = tester.getRect(find.byKey(const ValueKey('key_pick_row')));
    final face = capsuleRects(tester)[4];
    return rectInsideFace(row, face);
  }

  /// v11：私钥口令行是不是在认证方式胶囊的脸里面
  ///（只在密钥方式展开时在里面；密码方式展开后它在 144 的脸外面，
  /// 收起时更在外面）。
  bool passphraseFieldInsideAuthFace(WidgetTester tester) {
    final field =
        tester.getRect(find.byKey(const ValueKey('add_passphrase_field')));
    final face = capsuleRects(tester)[4];
    return rectInsideFace(field, face);
  }

  // ==========================================================================
  // v10: auth capsule expands in place (password + key inside it)
  // ==========================================================================

  testWidgets('auth capsule expands in place: password + key inside it',
      (tester) async {
    await openAdd(tester);

    // 默认收起：6 张脸（146/198/250/302/354/406，间距 4），
    // 认证方式是第 5 个，48 高；
    // 密码框、私钥行、口令行在树上，但在脸外面（被裁剪盖住、点不到）。
    List<Rect> rects = capsuleRects(tester);
    expect(rects.length, 6);
    expect(rects[0], const Rect.fromLTWH(280, 146, 240, 48));
    expect(rects[1], const Rect.fromLTWH(280, 198, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 250, 240, 48));
    expect(rects[3], const Rect.fromLTWH(280, 302, 240, 48));
    expect(rects[4], const Rect.fromLTWH(280, 354, 240, 48));
    expect(rects[5], const Rect.fromLTWH(280, 406, 240, 48));
    expect(passwordFieldInsideAuthFace(tester), isFalse);
    expect(keyRowInsideAuthFace(tester), isFalse);
    expect(passphraseFieldInsideAuthFace(tester), isFalse);
    expect(find.text('认证方式'), findsOneWidget);
    expect(find.text('私钥'), findsOneWidget);
    expect(find.text('未选择，点一下选择文件'), findsOneWidget);

    // 点一下展开（密码方式）：还是 6 张脸，没有单独的胶囊跳出来；
    // 认证方式自己变高（48→144），整组重新居中（50-454，底边贴着
    // 按钮柱顶的上限 454，不会盖住按钮），间距还是 4；
    // 密码框和私钥行进了胶囊里面；口令行只在密钥方式时出现，
    // 密码方式展开后它还在脸外面。
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester);
    rects = capsuleRects(tester);
    expect(rects.length, 6);
    expect(rects[0], const Rect.fromLTWH(280, 50, 240, 48));
    expect(rects[1], const Rect.fromLTWH(280, 102, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 154, 240, 48));
    expect(rects[3], const Rect.fromLTWH(280, 206, 240, 48));
    expect(rects[4], const Rect.fromLTWH(280, 258, 240, 144));
    expect(rects[5], const Rect.fromLTWH(280, 406, 240, 48));
    expect(passwordFieldInsideAuthFace(tester), isTrue);
    expect(keyRowInsideAuthFace(tester), isTrue);
    expect(passphraseFieldInsideAuthFace(tester), isFalse);

    // 切到密钥方式（展开态不变）：认证方式再长一截（144→192，
    // 多了口令行），整组重新居中（16-468，底边离按钮柱顶 470
    // 只剩 2dp）；密码框、私钥行、口令行都在胶囊里面。
    await tester.tap(find.byKey(const ValueKey('auth_method_chip')));
    await settle(tester);
    rects = capsuleRects(tester);
    expect(rects.length, 6);
    expect(rects[0], const Rect.fromLTWH(280, 16, 240, 48));
    expect(rects[1], const Rect.fromLTWH(280, 68, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 120, 240, 48));
    expect(rects[3], const Rect.fromLTWH(280, 172, 240, 48));
    expect(rects[4], const Rect.fromLTWH(280, 224, 240, 192));
    expect(rects[5], const Rect.fromLTWH(280, 420, 240, 48));
    expect(passwordFieldInsideAuthFace(tester), isTrue);
    expect(keyRowInsideAuthFace(tester), isTrue);
    expect(passphraseFieldInsideAuthFace(tester), isTrue);

    // 再点收起：认证方式缩回 48，整组回到 146-454；
    // 三行又回到脸外面。
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester);
    rects = capsuleRects(tester);
    expect(rects.length, 6);
    expect(rects[0], const Rect.fromLTWH(280, 146, 240, 48));
    expect(rects[4], const Rect.fromLTWH(280, 354, 240, 48));
    expect(rects[5], const Rect.fromLTWH(280, 406, 240, 48));
    expect(passwordFieldInsideAuthFace(tester), isFalse);
    expect(keyRowInsideAuthFace(tester), isFalse);
    expect(passphraseFieldInsideAuthFace(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('method chip toggles password/key without expanding',
      (tester) async {
    await openAdd(tester);

    // 默认方式是密码：芯片上是“密码”（芯片 + 密码框的 hint，共 2 个“密码”）。
    expect(find.text('密码'), findsNWidgets(2));
    expect(find.text('私钥'), findsOneWidget); // 只有私钥那一行的标签
    expect(passwordFieldInsideAuthFace(tester), isFalse);

    // 点芯片切到私钥：芯片变“私钥”（共 2 个），“密码”只剩 hint（1 个），
    // 认证胶囊还是收起的（密码框还在脸外面）。
    await tester.tap(find.byKey(const ValueKey('auth_method_chip')));
    await settle(tester, 300);
    expect(find.text('私钥'), findsNWidgets(2));
    expect(find.text('密码'), findsOneWidget);
    expect(passwordFieldInsideAuthFace(tester), isFalse);

    // 再点切回密码。
    await tester.tap(find.byKey(const ValueKey('auth_method_chip')));
    await settle(tester, 300);
    expect(find.text('密码'), findsNWidgets(2));
    expect(find.text('私钥'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('password is obscured, eye toggles visibility',
      (tester) async {
    await openAdd(tester);
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester);

    // v11：树里有 6 个 TextField（名称/地址/端口/用户名/密码/口令），
    // 密码框是第 5 个，按 key 找，不再按 at(2)。
    final passwordField = find.byKey(const ValueKey('add_password_field'));
    expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);

    await tester.enterText(passwordField, 'hunter2');
    expect(
      tester.widget<TextField>(passwordField).controller?.text,
      'hunter2',
    );

    // 点眼睛：明文，图标变 visibility。
    await tester.tap(find.byIcon(Icons.visibility_off));
    await settle(tester, 300);
    expect(tester.widget<TextField>(passwordField).obscureText, isFalse);
    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(
      tester.widget<TextField>(passwordField).controller?.text,
      'hunter2',
    );

    // 再点眼睛：回密文。
    await tester.tap(find.byIcon(Icons.visibility));
    await settle(tester, 300);
    expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'private key row picks a file (mocked); cancel keeps the old state',
      (tester) async {
    final original = picker.FilePickerPlatform.instance;
    final fake = FakeFilePickerPlatform();
    picker.FilePickerPlatform.instance = fake;
    addTearDown(() {
      picker.FilePickerPlatform.instance = original;
    });

    await openAdd(tester);
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester);

    // 先取消（null）：还是“未选择”。
    fake.result = null;
    await tester.tap(find.byKey(const ValueKey('key_pick_row')));
    await settle(tester, 300);
    expect(find.text('未选择，点一下选择文件'), findsOneWidget);

    // 选到文件：显示文件名。
    fake.result = FakePlatformFile(
      name: 'id_ed25519',
      uri: Uri.file('/tmp/id_ed25519'),
    );
    await tester.tap(find.byKey(const ValueKey('key_pick_row')));
    await settle(tester, 300);
    expect(find.text('id_ed25519'), findsOneWidget);
    expect(find.text('未选择，点一下选择文件'), findsNothing);

    // 再取消：之前选的文件还在（取消不清空）。
    fake.result = null;
    await tester.tap(find.byKey(const ValueKey('key_pick_row')));
    await settle(tester, 300);
    expect(find.text('id_ed25519'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v10: gap follows the visible count (expand no longer adds capsules)
  // ==========================================================================

  testWidgets('gap follows the visible count (3->10, 4->8, 5->6, 6->4)',
      (tester) async {
    // 间距规则 _capsuleGapForCount：3 个及以下 10，
    // 4 个及以上按 16 - 2*个数往下收、底 4（4→8、5→6、6→4）。
    // 界面里能直接看到的只有 3 个胶囊的设置和 6 个胶囊的添加，
    // 4→8、5→6 是同一条规则算出来的，没有对应的界面可点。
    // 设置收起：3 个可见 → 间距 10。
    await openSettings(tester);
    expect(visibleGaps(tester), <double>[10, 10]);

    // 设置展开：还是 3 个胶囊（高级设置自己变高，不多出胶囊）→ 间距还是 10。
    await tester.tap(find.byKey(const ValueKey('advanced_expand_area')));
    await settle(tester);
    expect(visibleGaps(tester), <double>[10, 10]);

    // 添加收起：6 个可见 → 间距 4。
    await tester.tapAt(const Offset(400, 100)); // scrim 关掉设置
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('glass_add_action')));
    await settle(tester);
    expect(visibleGaps(tester), <double>[4, 4, 4, 4, 4]);

    // 添加展开：还是 6 个胶囊（认证方式自己变高）→ 间距还是 4。
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester);
    expect(visibleGaps(tester), <double>[4, 4, 4, 4, 4]);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v10: advanced settings capsule expands in place
  // ==========================================================================

  testWidgets('advanced settings expands in place, then collapses',
      (tester) async {
    await openSettings(tester);

    // 默认收起：3 张脸（218/276/334），高级设置 48 高。
    List<Rect> rects = capsuleRects(tester);
    expect(rects.length, 3);
    expect(rects[0], const Rect.fromLTWH(280, 218, 240, 48));
    expect(rects[1], const Rect.fromLTWH(280, 276, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 334, 240, 48));
    expect(find.text('高级设置'), findsOneWidget);
    expect(find.text('高级设置内容待定。'), findsOneWidget);

    // 点一下展开：还是 3 张脸，没有单独的胶囊跳出来；高级设置自己
    // 变高（48→88），整组重新居中（198-402），间距还是 10；
    // 提示在胶囊里面。
    await tester.tap(find.byKey(const ValueKey('advanced_expand_area')));
    await settle(tester);
    rects = capsuleRects(tester);
    expect(rects.length, 3);
    expect(rects[0], const Rect.fromLTWH(280, 198, 240, 48));
    expect(rects[1], const Rect.fromLTWH(280, 256, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 314, 240, 88));
    expect(find.text('高级设置内容待定。'), findsOneWidget);

    // 再点收起：高级设置缩回 48，整组回到 218-382。
    await tester.tap(find.byKey(const ValueKey('advanced_expand_area')));
    await settle(tester);
    rects = capsuleRects(tester);
    expect(rects.length, 3);
    expect(rects[0], const Rect.fromLTWH(280, 218, 240, 48));
    expect(rects[2], const Rect.fromLTWH(280, 334, 240, 48));
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v9: save validation for the key method
  // ==========================================================================

  testWidgets('save validates the key method: no key file prompts, then ok',
      (tester) async {
    // v11：保存真的读私钥文件内容（要含 PRIVATE KEY），假 picker
    // 必须指一个真实临时文件；v9 的 /tmp/id_ed25519 不存在，
    // 保存时会走到“无法读取私钥文件”。
    final keyFile = File('${supportDir.path}/id_ed25519');
    await tester.runAsync(() async {
      await keyFile.writeAsString(
        '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        'AAAAB3NzaC1yc2EAAAADAQABAAABgQ==\n'
        '-----END OPENSSH PRIVATE KEY-----\n',
      );
    });
    final original = picker.FilePickerPlatform.instance;
    final fake = FakeFilePickerPlatform();
    picker.FilePickerPlatform.instance = fake;
    addTearDown(() {
      picker.FilePickerPlatform.instance = original;
    });

    await openAdd(tester);

    // 切到私钥方式，填好名称+地址就点保存：提示选私钥文件。
    await tester.tap(find.byKey(const ValueKey('auth_method_chip')));
    await settle(tester, 300);
    await tester.enterText(
      find.byKey(const ValueKey('add_name_field')),
      'srv-main',
    );
    await tester.enterText(
      find.byKey(const ValueKey('add_host_field')),
      '1.2.3.4',
    );
    await tester.tap(find.byKey(const ValueKey('glass_form_save')));
    await settle(tester, 300);
    expect(find.text('请选择私钥文件。'), findsOneWidget);
    expect(find.byType(GlassMorphOverlay), findsOneWidget);

    // 等提示消失，展开认证方式选好私钥再点：v11 保存真的落盘
    //（SharedPreferences + vault），提示“已保存”
    //（1.2.3.4 查不到城市时是“已保存，城市解析不到，已放在德国。”，
    // 两种都以“已保存”开头）。
    await settle(tester, 4500);
    expect(find.text('请选择私钥文件。'), findsNothing);
    fake.result = FakePlatformFile(
      name: 'id_ed25519',
      uri: Uri.file(keyFile.path),
    );
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('key_pick_row')));
    await settle(tester, 300);
    expect(find.text('id_ed25519'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('glass_form_save')));
    await settle(tester, 300);
    expect(await waitForText(tester, '已保存'), isTrue);
    // 保存后关面板要等弹簧走完才卸载；公网 IP 的保存会在查库排队链
    // 上挂一个 5 秒超时 Timer，推 6 秒假时间把它烧掉，免得测试
    // 结束时框架报“还有 Timer 挂起”（v11 同款）。
    await settle(tester, 1000);
    await tester.pump(const Duration(seconds: 6));
    // 落盘真的写进去了：读回来看。
    final profiles = await loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.first.name, 'srv-main');
    expect(profiles.first.host, '1.2.3.4');
    expect(profiles.first.port, 22);
    expect(profiles.first.username, 'root');
    expect(profiles.first.authType, 'key');
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // v9: pubspec has no speed_dial
  // ==========================================================================

  test('pubspec and lock have no flutter_speed_dial', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('speed_dial'), isFalse);
    final lock = File('pubspec.lock').readAsStringSync();
    expect(lock.contains('flutter_speed_dial'), isFalse);
  });
}
