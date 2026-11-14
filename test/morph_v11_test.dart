import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart' as picker;
import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_client/globe.dart';
import 'package:ssh_client/ip_geo_database.dart';
import 'package:ssh_client/main.dart';

/// v9 同款假 picked file（PlatformFile 是 abstract base class；
/// path 是从 uri 派生的 getter，uri 指真实临时文件，保存时就能
/// 真读到文件内容）。
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

/// v9 同款假 file_picker 平台（result 为 null 就是用户点了取消）。
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

  /// v11：记账式假 vault——write 存下来、read 读出来、delete 清掉，
  /// 这样测试能断言凭据真的进了 vault（不是只看界面）。
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
    // IpGeoDatabase.open() 要 getApplicationSupportDirectory（解压
    // SBGX 数据文件到这里），测试里指到一个真实临时目录。
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
    // geo 库预热：第一次 open 要现场解压 26MB，真实 I/O。setUpAll
    // 不在假时间里，直接跑完；预热一次后单例常驻，测试里的保存
    // 直接复用。不要在每个测试里 runAsync 预热——实测在第四个
    // 测试里 runAsync 预热会挂起（假时间 + 单例 _tail 链的交互）。
    final geoDb = await IpGeoDatabase.open();
    await geoDb.lookup('8.8.8.8');
  });

  setUp(() async {
    fakeVault.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  // 地球一直在转，pumpAndSettle() 永远等不到；用 100ms 小步
  // 显式推进（v9 同款）。
  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    final int steps = (ms / 100).ceil();
    for (int i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
  }

  /// 等一段文字出现（保存提示、地球仪卡片都靠它）。光 pump 假时间不够：
  /// 保存要做真实 I/O（第一次现场解压 26MB geo 库、读密钥文件），
  /// 真实 I/O 只在真实时间里推进，假时间里会永远挂起（实测）；
  /// 所以每轮先 runAsync 跳出假时间、真实等 500ms，再 pump 一帧。
  /// 预算 30 秒真实时间。
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
    String? port,
    String? username,
  }) async {
    await tester.enterText(
      find.byKey(const ValueKey('add_name_field')),
      name,
    );
    await tester.enterText(
      find.byKey(const ValueKey('add_host_field')),
      host,
    );
    if (port != null) {
      await tester.enterText(
        find.byKey(const ValueKey('add_port_field')),
        port,
      );
    }
    if (username != null) {
      await tester.enterText(
        find.byKey(const ValueKey('add_username_field')),
        username,
      );
    }
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
    // geo 库已在 setUpAll 预热（单例常驻），这里不用再预热。
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
    // 保存后关面板要等弹簧走完才卸载（约 450ms），不等的话表单的
    // 输入框还挂在树上，找卡片会撞上两个 'Frankfurt机'。
    await settle(tester, 1000);
    // 公网 IP 的保存会在查库排队链（_tail）上挂一个 5 秒超时 Timer：
    // 假时间里文件读挂起时它要到 5 秒才烧掉；不等它烧完就结束测试，
    // 框架会报“测试结束时还有 Timer 挂起”。推 6 秒假时间把它烧掉
    // （真时间里只是一瞬间，pump 不等真实时间）。
    await tester.pump(const Duration(seconds: 6));
    final profiles = await loadProfiles();
    expect(profiles, hasLength(1));
    return profiles.first.id;
  }

  testWidgets('password save persists profile + vault, defaults 22/root, default geo marker',
      (tester) async {
    await savePasswordServer(
      tester,
      name: 'Frankfurt机',
      host: '192.168.1.10',
    );
    final profiles = await loadProfiles();
    final saved = profiles.first;
    expect(saved.name, 'Frankfurt机');
    expect(saved.host, '192.168.1.10');
    expect(saved.port, 22);
    expect(saved.username, 'root');
    expect(saved.city, '');
    expect(saved.authType, 'password');
    expect(fakeVault['${saved.id}.password'], 'pw123');
    expect(fakeVault['${saved.id}.key'], '');
    expect(fakeVault['${saved.id}.passphrase'], '');
    // 内网 IP 查不到城市，标记放在默认落点（法兰克福），卡片写“德国”。
    expect(await waitForText(tester, 'Frankfurt机'), isTrue);
    final card = tester.widget<Text>(find.textContaining('Frankfurt机'));
    expect(card.data, contains('德国'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('key save reads PEM content into vault + passphrase',
      (tester) async {
    final keyFile = File('${supportDir.path}/id_test');
    // 真实文件写操作要 runAsync（假时间里会永远挂起，实测）。
    await tester.runAsync(() async {
      await keyFile.writeAsString(
        '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        'AAAAB3NzaC1yc2EAAAADAQABAAABgQ==\n'
        '-----END OPENSSH PRIVATE KEY-----\n',
      );
    });
    final original = picker.FilePickerPlatform.instance;
    final fakePicker = FakeFilePickerPlatform()
      ..result = FakePlatformFile(name: 'id_test', uri: Uri.file(keyFile.path));
    picker.FilePickerPlatform.instance = fakePicker;
    addTearDown(() {
      picker.FilePickerPlatform.instance = original;
    });

    await openAdd(tester);
    await fillAddForm(tester, name: '密钥机', host: '8.8.8.8');
    await tester.tap(find.byKey(const ValueKey('auth_method_chip')));
    await settle(tester, 300);
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester, 300);
    await tester.tap(find.byKey(const ValueKey('key_pick_row')));
    await settle(tester, 300);
    expect(find.text('id_test'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('add_passphrase_field')),
      'myphrase',
    );
    await tapSave(tester);
    expect(await waitForText(tester, '已保存'), isTrue);
    // 同 savePasswordServer：公网 IP 的保存会在查库排队链（_tail）上
    // 挂一个 5 秒超时 Timer，推 6 秒假时间把它烧掉，免得测试结束时
    // 框架报“还有 Timer 挂起”。
    await tester.pump(const Duration(seconds: 6));

    final profiles = await loadProfiles();
    expect(profiles, hasLength(1));
    final saved = profiles.first;
    expect(saved.authType, 'key');
    // vault 里是 PEM 内容，不是文件路径。
    expect(fakeVault['${saved.id}.key'], contains('PRIVATE KEY'));
    expect(fakeVault['${saved.id}.key'], isNot(contains('/id_test')));
    expect(fakeVault['${saved.id}.passphrase'], 'myphrase');
    expect(fakeVault['${saved.id}.password'], '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid port blocks save', (tester) async {
    await openAdd(tester);
    await fillAddForm(
      tester,
      name: '坏端口',
      host: '1.2.3.4',
      port: '70000',
    );
    await tester.tap(find.byKey(const ValueKey('auth_expand_area')));
    await settle(tester, 300);
    await tester.enterText(
      find.byKey(const ValueKey('add_password_field')),
      'x',
    );
    await tapSave(tester);
    expect(await waitForText(tester, '端口要在 1–65535 之间。'), isTrue);
    expect(await loadProfiles(), isEmpty);
    // 面板还开着（没保存、没关）。
    expect(find.byKey(const ValueKey('add_name_field')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('public IP resolves to real coordinates on the globe',
      (tester) async {
    final id = await savePasswordServer(tester, name: '美国机', host: '8.8.8.8');
    // 不等卡片转到正面：远端标记（美国）在背面，要转 130° 才可见，
    // 假时间里等它转过来又慢又不稳。直接读地球仪收到的宿主——
    // 保存完成、标记的坐标非空，就是“公网 IP 保存后落到地球仪上”。
    final globe = tester.widget<SshGlobe>(find.byType(SshGlobe));
    final host = globe.hosts.singleWhere((h) => h.id == id);
    expect(host.location, isNotNull);
    // “8.8.8.8 真解析成美国坐标”这一步不在这里断言：testWidgets
    // 的假时间里真实文件读时通时挂（单跑时曾拿到约 37.42°, -122.08°，
    // 整文件跑时可能 1 秒超时走默认落点），且保存后 _loadGeoLocations
    // 还会在后台再查一次、可能把坐标刷回默认落点——都是测试环境的
    // 假时间问题，不是 App 的错。真坐标的证明在 test/ip_geo_test.dart
    //（普通 test，真实时间）：库本身把 8.8.8.8 解析成美国的真实坐标；
    // 真机上文件读是毫秒级，保存那一步直接落真坐标。
    expect(tester.takeException(), isNull);
  });

  testWidgets('hostname resolving to a private IP falls back to the default spot',
      (tester) async {
    await savePasswordServer(tester, name: '本机', host: 'localhost');
    expect(await waitForText(tester, '本机'), isTrue);
    final card = tester.widget<Text>(find.textContaining('本机'));
    expect(card.data, contains('德国'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press a card deletes the server and its vault keys',
      (tester) async {
    final id = await savePasswordServer(
      tester,
      name: '删我',
      host: '192.168.1.10',
    );
    expect(await waitForText(tester, '删我'), isTrue);
    await tester.longPress(find.textContaining('删我'));
    await settle(tester, 500);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settle(tester, 500);
    expect(find.text('删除服务器？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settle(tester, 500);
    expect(await loadProfiles(), isEmpty);
    expect(fakeVault.containsKey('$id.password'), isFalse);
    expect(fakeVault.containsKey('$id.key'), isFalse);
    expect(fakeVault.containsKey('$id.passphrase'), isFalse);
    // 地球仪上这个标记已经没了（直接读 widget，不靠文字找卡片）。
    final globe = tester.widget<SshGlobe>(find.byType(SshGlobe));
    expect(globe.hosts.any((h) => h.id == id), isFalse);
    // “已删除 删我。”是 4 秒自动消失的 SnackBar，等它消失后再断言
    // 屏幕上找不着“删我”——不然这条提示本身也会被 textContaining 命中。
    // 注意：推 5 秒只烧掉它的 4 秒定时、刚开始退场动画，退场还要
    // 再跑几帧才真正卸载，得再 settle 一下。
    await tester.pump(const Duration(seconds: 5));
    await settle(tester, 500);
    expect(find.textContaining('删我'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit prefills the form and updates the same profile',
      (tester) async {
    final id = await savePasswordServer(
      tester,
      name: '改名机',
      host: '192.168.1.10',
      password: 'oldpw',
    );
    expect(await waitForText(tester, '改名机'), isTrue);
    await tester.longPress(find.textContaining('改名机'));
    await settle(tester, 500);
    await tester.tap(find.text('编辑'));
    await settle(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('add_name_field')))
          .controller
          ?.text,
      '改名机',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('add_host_field')))
          .controller
          ?.text,
      '192.168.1.10',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('add_port_field')))
          .controller
          ?.text,
      '22',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('add_username_field')))
          .controller
          ?.text,
      'root',
    );
    // 密码从 vault 读回来（异步预填，多等一会儿）。
    await settle(tester, 500);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('add_password_field')))
          .controller
          ?.text,
      'oldpw',
    );
    await tester.enterText(
      find.byKey(const ValueKey('add_name_field')),
      '改名后',
    );
    await tapSave(tester);
    expect(await waitForText(tester, '已更新'), isTrue);
    final profiles = await loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.first.id, id);
    expect(profiles.first.name, '改名后');
    expect(fakeVault['$id.password'], 'oldpw');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a globe card opens the session panel (connect chain)',
      (tester) async {
    await savePasswordServer(tester, name: '本地机', host: '127.0.0.1');
    expect(await waitForText(tester, '本地机'), isTrue);
    await tester.tap(find.textContaining('本地机'));
    await settle(tester, 1200);
    // v13：点卡片直接开指令面板（不再进终端页）——面板在主页上，
    // 输入框和输出区都在；连接在后台跑，状态先是“正在连接…”。
    expect(find.byKey(const ValueKey('session_input_field')), findsOneWidget);
    expect(find.byKey(const ValueKey('session_output_list')), findsOneWidget);
    expect(find.textContaining('正在连接'), findsWidgets);
    // 真机上 127.0.0.1:22 拒绝连接很快；但在 testWidgets 的假时间里
    // 真实 socket 连接挂起、不会自己拒绝，全靠连接里 15 秒超时把它
    // 打下来。注意要分两步推假时间：先推一小步，让连接启动、15 秒
    // Timer 挂上；再推 16 秒，让超时触发、“连接失败”出现在输出区、
    // Timer 跑完，测试结束时才没有挂起的 Timer。一步推 16 秒不够——
    // Timer 是在那一帧里才创建的，截止时间在这一帧的 16 秒窗口之外，
    // 烧不到它。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 16));
    await settle(tester, 500);
    // 失败原因写进面板输出区，不崩就是链路通了
    // （真连网要主人真机上自己的服务器）。
    expect(find.textContaining('连接失败'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
