import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart' as picker;
import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

import 'glass_morph_overlay.dart';
import 'glass_styles.dart';
import 'globe.dart';
import 'ip_geo_database.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 预载 Fluid_Glass 的 fragment 程序，避免第一帧玻璃还没折射就上屏。
  await fluid.FluidGlass.ensureInitialized();
  runApp(const SshApp());
}

class SshApp extends StatefulWidget {
  const SshApp({
    super.key,
    this.sessionConnector,
    this.onGlobeCameraChanged,
    this.geoFirstDownloadRunner,
  });

  /// v13：建会话的出口（测试注入假的；生产默认真 dartssh2）。
  final SessionConnector? sessionConnector;

  /// v18：地球仪相机回调的测试出口（生产不传）：量关闭收尾的旋转
  /// 恢复斜坡用——相机经度是转速的直接信号，比卡片屏上位置准
  /// （卡片位置还受投影影响）。
  final ValueChanged<GlobeCamera>? onGlobeCameraChanged;

  /// v22：首次启动地理数据下载弹窗的测试出口（生产不传）：
  /// 传入后，_load 里本地无数据时弹下载弹窗而不是静默更新，
  /// 且下载走这里给的 runner（测试用假的流式下载）。
  final GeoFirstDownloadRunner? geoFirstDownloadRunner;
  @override
  State<SshApp> createState() => _SshAppState();
}

class _SshAppState extends State<SshApp> {
  final bool _dark = false;
  final prism.ColorStyle _style = prism.ColorStyle.soft;

  @override
  Widget build(BuildContext context) {
    final light = prism.ThemeData(
      colorScheme: prism.ColorScheme.fromSeed(
        seedColor: const Color(0xff3b82b4),
        style: _style,
      ),
    );
    final dark = prism.ThemeData(
      colorScheme: prism.ColorScheme.fromSeed(
        seedColor: const Color(0xff3b82b4),
        brightness: Brightness.dark,
        style: _style,
      ),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff3b82b4)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff3b82b4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: prism.PrismApp(
        title: 'Aster SSH',
        theme: light,
        darkTheme: dark,
        themeMode: _dark ? prism.ThemeMode.dark : prism.ThemeMode.light,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          PrismStrings.delegate,
        ],
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        debugShowCheckedModeBanner: false,
        liquidGlass: prism.LiquidGlassQuality.ultra,
        home: HomePage(
          sessionConnector: widget.sessionConnector,
          onGlobeCameraChanged: widget.onGlobeCameraChanged,
          geoFirstDownloadRunner: widget.geoFirstDownloadRunner,
        ),
      ),
    );
  }
}

class PrismStrings extends prism.UiLocalizations {
  PrismStrings();
  static const delegate = _PrismStringsDelegate();
  @override
  String get back => '返回';
  @override
  String get cancel => '取消';
  @override
  String get clearSearch => '清除搜索';
  @override
  String get close => '关闭';
  @override
  String get copy => '复制';
  @override
  String get cut => '剪切';
  @override
  String get dialog => '对话框';
  @override
  String get hidePassword => '隐藏密码';
  @override
  String get more => '更多';
  @override
  String get noSearchResults => '没有搜索结果';
  @override
  String get paste => '粘贴';
  @override
  String get reset => '重置';
  @override
  String get select => '选择';
  @override
  String get search => '搜索';
  @override
  String get selectAll => '全选';
  @override
  String get showLess => '收起';
  @override
  String get showMore => '展开';
  @override
  String get showPassword => '显示密码';
  @override
  String get sort => '排序';
  @override
  String get submit => '提交';
}

class _PrismStringsDelegate
    extends LocalizationsDelegate<prism.UiLocalizations> {
  const _PrismStringsDelegate();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<prism.UiLocalizations> load(Locale locale) async => PrismStrings();
  @override
  bool shouldReload(_PrismStringsDelegate old) => false;
}

const _vault = FlutterSecureStorage();
const _profilesKey = 'ssh.profiles.v1';

class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.city,
    required this.authType,
  });
  final String id, name, host, username, city, authType;
  final int port;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'city': city,
    'authType': authType,
  };
  factory ServerProfile.fromJson(Map<String, dynamic> map) => ServerProfile(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    host: map['host'] as String? ?? '',
    port: map['port'] as int? ?? 22,
    username: map['username'] as String? ?? '',
    city: map['city'] as String? ?? '',
    authType: map['authType'] as String? ?? 'password',
  );
}

class SavedAuth {
  const SavedAuth({
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
  });
  final String password, privateKey, passphrase;
}

Future<List<ServerProfile>> loadProfiles() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_profilesKey);
  if (raw == null) return [];
  try {
    return (jsonDecode(raw) as List)
        .map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> persistProfiles(List<ServerProfile> profiles) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _profilesKey,
    jsonEncode(profiles.map((e) => e.toJson()).toList()),
  );
}

class HomePage extends StatefulWidget {
  // v7：设置面板已掏空（深色模式、主题风格、字号、默认端口都拿掉，
  // 等主人安排加什么再加）——这三个参数暂时没有 UI 用，先收掉；
  // 主题风格 _style 仍由 SshApp 自己拿着（theme 里在用）。
  const HomePage({
    super.key,
    this.sessionConnector,
    this.onGlobeCameraChanged,
    this.geoFirstDownloadRunner,
  });

  /// v13：建会话的出口（测试注入假的；生产默认真 dartssh2）。
  final SessionConnector? sessionConnector;

  /// v18：地球仪相机回调的测试出口（见 SshApp.onGlobeCameraChanged）。
  final ValueChanged<GlobeCamera>? onGlobeCameraChanged;

  /// v22：首次启动地理数据下载弹窗的测试出口（见 SshApp）。
  final GeoFirstDownloadRunner? geoFirstDownloadRunner;
  @override
  State<HomePage> createState() => _HomePageState();
}

/// Morph 的入口：右下角的 +（添加服务器）、齿轮（设置）、
/// v13：地球仪卡片（进机子后的指令面板）。
enum _MorphKind { add, settings, session }

/// v8：添加表单的胶囊种类（一个字段/功能一个胶囊）。
/// v9：加了 auth（认证方式，可展开）。
/// v10：auth 不再往外弹出密码/私钥两个单独胶囊——它自己向下扩张，
/// 密码和私钥收进 auth 胶囊里面（同一块连续玻璃内），展开后 auth
/// 自己变高（48→144），个数还是 4 个，不多不少。
/// v11：加了 port（端口，默认 22）和 username（用户名，默认 root），
/// 认证方式里多了一个私钥口令行（只在密钥方式时出现）；城市不做
/// 手动胶囊，保存时自动解析（见 _resolveGeoForHost）。
/// 胶囊的数量跟着 _addCapsuleKinds 列表走，不是定死的三个：
/// 以后加字段只在列表里加一个枚举值，再在 _buildAddCapsuleContent
/// 里加一个 case（新种类才需要），目标矩形、淡入窗口、整体高度
/// 都跟着列表走，不改结构。
enum _AddCapsuleKind { name, host, port, username, auth, save }

/// v9：当前认证方式（默认密码）。收起的认证胶囊上显示它；
/// 点认证胶囊里的“密码/私钥”小标签切换。
enum _AuthMethod { password, key }

/// v8：设置的胶囊种类（标题 + 提示，两个）。
/// v9：加了 advanced（高级设置，可向下展开，像 ServerBox 的
/// “SSH 高级”行）。
/// v10：advanced 不再往外弹出一个提示胶囊——它自己向下扩张，
/// 提示收进 advanced 胶囊里面（同一块连续玻璃内），展开后 advanced
/// 自己变高（48→88），个数还是 3 个，不多不少。
enum _SettingsCapsuleKind { title, hint, advanced }

/// 一次 Morph 打开时要带的东西：哪种面板、从哪个按钮长出来、
/// 添加表单是新建还是编辑（编辑目前没有 UI 入口，先留着）。
class _MorphRequest {
  const _MorphRequest({required this.kind, required this.origin, this.profile});
  final _MorphKind kind;
  final Rect origin;
  final ServerProfile? profile;
}

/// v15：会话面板的变形锚面——画成地球仪上那张卡片原样（小蓝点 + 名字 +
/// 位置标签 + 右边 `>`），不再是终端图标。open=0 时脸就是卡片本身，
/// 缩到底、卡片回来那一帧严丝合缝。内容和 globe.dart 里卡片的 Row
/// 一一对上（点颜色是选中态 primary——点开面板时 _selected 就是这台；
/// 字号/行高/间距照抄卡片），尺寸用 globeHostCardSize（136×46），
/// 和锚点矩形同形同位。只差玻璃引擎（morph 的 DrawBackdrop vs 卡片的
/// prism LiquidGlass，参数对不齐、像素级不等——v8 同款诚实说明）。
/// 圆角不在这里定：overlay 的脸在 open=0 时用 originRadius（v15 改成
/// 卡片的 12），和卡片一致。
class _SessionAnchorFace extends StatelessWidget {
  const _SessionAnchorFace({
    super.key,
    required this.name,
    required this.label,
  });

  final String name;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: globeHostCardSize.width,
      height: globeHostCardSize.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9),
        child: Row(
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                '$name\n$label',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      height: 1.15,
                      fontSize: 10.5,
                    ),
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.chevron_right,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}


/// v8：添加表单的状态（字段的控制器）。没有外框、没有 Form——
/// 胶囊是独立 widget（一个字段一个，overlay 各自定位），包不进一个 Form；
/// 校验在保存时手动做（见 _saveAddForm），不靠 validator 的报错行
/// （报错行会把字段顶高、撑出 48 的胶囊）。
/// v9：加了 password（密码）和 keyFileName/keyFilePath（选到的私钥文件，
/// 只记文件名+路径，不读内容）。
/// v11：加了 port（端口，默认 22）、username（用户名，默认 root）、
/// passphrase（私钥口令，只在密钥方式时出现，可留空）、savedKeyPem
///（编辑密钥方式时从 vault 读回来的已保存私钥内容，没换文件时保存沿用它）。
class _AddFormController {
  _AddFormController({
    String? name,
    String? host,
    String? port,
    String? username,
    String? passphrase,
  }) : name = TextEditingController(text: name ?? ''),
       host = TextEditingController(text: host ?? ''),
       port = TextEditingController(text: port ?? '22'),
       username = TextEditingController(text: username ?? 'root'),
       password = TextEditingController(),
       passphrase = TextEditingController(text: passphrase ?? '');
  final TextEditingController name;
  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController username;
  final TextEditingController password;
  final TextEditingController passphrase;
  String? keyFileName;
  String? keyFilePath;
  String? savedKeyPem;
  void dispose() {
    name.dispose();
    host.dispose();
    port.dispose();
    username.dispose();
    password.dispose();
    passphrase.dispose();
  }
}

/// v13：一次 SSH 会话的最小接口。生产用真 dartssh2（见
/// _realSessionConnector），测试注入假的（只收字节、按写的内容回
/// canned 输出，不断言真连网）。类型是公开的——测试要实现它。
abstract class SessionHandle {
  Stream<Uint8List> get stdoutStream;
  Stream<Uint8List> get stderrStream;
  void write(Uint8List data);
  Future<void> close();
}

/// v13：建一次会话。verifyHostKey 是指纹核对回调（首次连接弹对话框，
/// 逻辑在 _HomePageState._verifyHostKey，和 TerminalPage 时代同一套）。
typedef SessionConnector =
    Future<SessionHandle> Function(
      ServerProfile profile,
      SavedAuth auth,
      Future<bool> Function(String type, Uint8List bytes) verifyHostKey,
    );

/// v13：真 dartssh2 的会话句柄（SSHSession + SSHClient 一起关）。
class _RealSessionHandle implements SessionHandle {
  _RealSessionHandle(this._session, this._client);
  final SSHSession _session;
  final SSHClient _client;
  @override
  Stream<Uint8List> get stdoutStream => _session.stdout;
  @override
  Stream<Uint8List> get stderrStream => _session.stderr;
  @override
  void write(Uint8List data) => _session.write(data);
  @override
  Future<void> close() async {
    _session.close();
    _client.close();
  }
}

/// v13：真 dartssh2 实现（TerminalPage._connect 的连接部分原样搬过来，
/// 只是输出不再写进 xterm，而是包成 SessionHandle 交给指令面板）。
/// socket 15 秒超时、认证 40 秒超时不变；出错时把 socket/client
/// 都收掉再抛，原因由调用方写进面板输出区。
Future<SessionHandle> _realSessionConnector(
  ServerProfile profile,
  SavedAuth auth,
  Future<bool> Function(String type, Uint8List bytes) verifyHostKey,
) async {
  SSHSocket? socket;
  SSHClient? client;
  try {
    if (profile.authType == 'key') {
      if (auth.privateKey.isEmpty) {
        throw StateError('没有保存 SSH 私钥，请编辑服务器资料。');
      }
      SSHKeyPair.fromPem(
        auth.privateKey,
        auth.passphrase.isEmpty ? null : auth.passphrase,
      );
    }
    socket = await SSHSocket.connect(
      profile.host,
      profile.port,
      timeout: const Duration(seconds: 15),
    );
    final identities = profile.authType == 'key'
        ? SSHKeyPair.fromPem(
            auth.privateKey,
            auth.passphrase.isEmpty ? null : auth.passphrase,
          )
        : <SSHKeyPair>[];
    client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest: profile.authType == 'password'
          ? () => auth.password
          : null,
      onVerifyHostKey: verifyHostKey,
    );
    await client.authenticated.timeout(const Duration(seconds: 40));
    final session = await client.shell(
      pty: const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24),
    );
    return _RealSessionHandle(session, client);
  } catch (e) {
    client?.close();
    socket?.destroy();
    rethrow;
  }
}

/// v13：指令面板输出区里的一行。
enum _SessionLineKind { command, output, status }

class _SessionLine {
  const _SessionLine(this.kind, this.text);
  final _SessionLineKind kind;
  final String text;
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  List<ServerProfile> _profiles = [];
  final Map<String, IpGeoLocation> _geoLocations = {};
  ServerProfile? _selected;
  bool _loading = true;

  /// Morph 小弹窗的状态：null = 没开。
  ///
  /// 两个胶囊按钮（+ / 齿轮）点开后不再走 showModalBottomSheet，
  /// 而是在主页 Stack 里就地变形：按钮的全局矩形是 anchor 起点，胶囊是
  /// target 终点；GlassMorphOverlay 里两个 SpringValue 按 x/y 插值矩形，
  /// 胶囊内容从第一帧就按最终尺寸排好（OverflowBox），动画期间不重新
  /// 布局，只 clip + 淡入淡出。关闭时弹簧重定向回 0，胶囊变回按钮。
  _MorphRequest? _morph;

  /// v11：overlay 的弹簧关闭（panelBuilder 里传出来的 close，
  /// 保存成功后主动关面板用；关到底时在 _onMorphSettledClosed 里清掉）。
  VoidCallback? _closeMorphPanel;

  /// v11：正在保存时防重复点保存。
  bool _saving = false;

  /// v8：当前打开的添加表单（打开时新建、关到底时释放；和 v7 的
  /// ProfileEditor 一样，每次打开都是新的，不跨次保留）。
  _AddFormController? _addForm;

  /// v5：被点的按钮在面板打开时藏起来（它变成了面板）。
  ///
  /// v8：按钮是普通的 _DialButton（主页 Stack 里的 Positioned，
  /// 不再是 SpeedDial 的孩子），父级 setState 本来就能传进去——
  /// 但 v2 的普通 bool + Opacity 在 SpeedDial 时代是死结（v3 探针
  /// 证实），ValueNotifier 的机制留着：notifier 对象是稳定引用，
  /// 包进按钮的 widget 里（ValueListenableBuilder），值变了通过
  /// 监听直接重建那棵子树。时序：_openMorph 里和 _morph 一起置
  /// true（open=0 时 morph 脸正好盖在按钮原位，交接无缝）；关闭
  /// 全程保持 true；只有弹簧关到底、overlay 卸载的同一帧
  /// （_onMorphSettledClosed）才置回 false。
  final ValueNotifier<bool> _addHidden = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _settingsHidden = ValueNotifier<bool>(false);

  /// v6：弹簧在走（打开/关闭/展开收起）时为 true——overlay 通过它
  /// 通知主页：动画期间把地球 ticker 停掉（autoRotate=false），
  /// 背景不再每帧重抓；弹簧停稳后恢复慢转。动画只有 350–450ms，
  /// 地球 3°/秒只转约 1°，眼睛盯着变形、看不出来；稳定打开后
  /// 恢复实时，地球慢转照样透过玻璃看得到。
  final ValueNotifier<bool> _morphAnimating = ValueNotifier<bool>(false);

  /// v16：地球恢复旋转的代次：每次开面板 +1；_scheduleGlobeResume
  /// 排到的恢复回调发现代次对不上就直接放弃——面板在两帧内重开，
  /// 旧的恢复不能把新面板的地球解冻（_morph != null 的检查是
  /// 第二道，代次是第一道）。
  int _globeResumeGeneration = 0;

  /// v18：地球恢复旋转的延时器（_scheduleGlobeResume 里起）：
  /// 关到底后先等 150ms 再解冻。dispose 时取消，回调里再验
  /// mounted + 代次 + _morph，三道关，旧的恢复不会误触。
  Timer? _globeResumeTimer;

  /// v7：一变多——overlay 每帧把当前 open 写到这里（post-frame，
  /// 见 glass_morph_overlay 的 openNotifier）；胶囊里的多个小胶囊
  /// （_CapsuleStagger）监听它依次淡入。面板内容被 AnimatedBuilder
  /// 的 child 缓存了，不重建，所以小胶囊必须自己监听 notifier。
  final ValueNotifier<double> _morphOpen = ValueNotifier<double>(0);

  /// v19：会话锚点卡片的实时全局矩形（活锚点）——地球仪每帧把选中
  /// 卡片的布局矩形写进来（SshGlobe.anchorCardRect），会话 morph
  /// 的 overlay 每帧读它当 origin（GlassMorphOverlay.liveOrigin）。
  /// 关闭过渡里地球转起来、卡片漂走（实测转 2° 最坏漂 7.13dp），
  /// 脸跟着卡片走，落点不错开。初始值在 _openSessionMorph 里置
  /// 成打开那一刻的锚点矩形。
  final ValueNotifier<Rect> _anchorCardRect =
      ValueNotifier<Rect>(Rect.zero);

  /// v19：会话面板正在关闭（点 ×/空白开始关闭 → 关到底）。地球
  /// 恢复转动就发生在这段时间里：autoRotate 在这段时间里为 true、
  /// 转速 = 12 × smoothstep(1 - open)，点关闭那一刻开始爬，
  /// 过渡结束时回到 12°/秒。关到底（_onMorphSettledClosed）时
  /// 置回 false。
  bool _sessionClosing = false;

  /// v9：认证胶囊是否展开（默认收起）、高级设置胶囊是否展开。
  /// 每次打开面板都是新的（见 _openMorph 里重置，不跨次保留）。
  bool _authExpanded = false;
  bool _advancedExpanded = false;

  /// v9：当前认证方式（默认密码）。收起的认证胶囊上显示它；
  /// 点认证胶囊里的“密码/私钥”小标签切换。
  _AuthMethod _authMethod = _AuthMethod.password;

  /// v9：密码是否明文显示（眼睛切换）。
  bool _passwordVisible = false;

  /// v13：指令面板的会话状态（TerminalPage 时代的连接逻辑搬到主页，
  /// 面板本身就是进机子后的主界面，不再有 xterm 全屏终端页）。
  /// 点卡片开面板时 _startSession 在后台连；状态和输出都写进面板。
  SessionHandle? _sessionHandle;
  StreamSubscription<Uint8List>? _sessionStdoutSub, _sessionStderrSub;
  final List<_SessionLine> _sessionLines = <_SessionLine>[];
  String _sessionPending = '';
  String _sessionStatus = '';
  bool _sessionFingerprintChanged = false;
  final TextEditingController _sessionCmdController = TextEditingController();
  final ScrollController _sessionScrollController = ScrollController();
  String? _sessionCmdError;

  /// v13：输出区最多留的行数（再多就从头上截掉，别无限涨）。
  static const int _sessionMaxLines = 500;

  /// v13：会话面板占屏高的比例（主人原话：比 0.5 稍微变大一点点）。
  static const double _sessionPanelHeightFraction = 0.62;


  /// v8：胶囊的尺寸（主人原话：和现在的功能差不多——
  /// 红框只是示意，不要照抄）。每个高 48、宽 240，胶囊之间
  /// 间距按可见个数走（见 _capsuleGapForCount，3 个及以下 10，
  /// 4 个及以上 8 起往下收）；圆角 18——
  /// 不是全圆药丸（24），是 ServerBox 行那种圆角矩形
  /// （主人 2026-11-13 20:40：“跟这个一样就行了”，
  /// 圆角中等约 16–20，取 18；宽还是 240，不照搬
  /// ServerBox 的通栏宽）。玻璃质感保留（#5 深色玻璃）。
  static const double _capsuleWidth = 240;
  static const double _capsuleHeight = 48;
  static const double _capsuleRadius = 18;

  /// v9：胶囊间距按可见个数走（主人原话：第 4 个胶囊加上以后间距从 10 减到 8）：
  /// 3 个及以下 10；4 个及以上按 16 - 2*count 往下收，底 4。
  /// 3→10、4→8、5→6、6→4、7+→4。是一条规则，不是写死两个数，
  /// 以后加到 5、6 个还能再收。
  static double _capsuleGapForCount(int count) =>
      count <= 3 ? 10.0 : math.max(4.0, 16.0 - 2.0 * count);

  /// v8：添加的胶囊列表（数据）。一个字段/功能一个胶囊；
  /// v10 是四个：名称、地址/IP、认证方式、保存。
  /// v11 是六个：名称、地址/IP、端口、用户名、认证方式、保存。
  /// 认证方式展开时自己变高（密码方式 48→144、密钥方式 48→192，
  /// 密码+私钥+口令在里面），个数不变，还是 6 个。
  /// 加一个字段要改几处：列表 1 处 + 内容 case 1 处 +
  /// 表单控制器 1 处（输入型字段才需要，见 _AddFormController）。
  static const List<_AddCapsuleKind> _addCapsuleKinds = [
    _AddCapsuleKind.name,
    _AddCapsuleKind.host,
    _AddCapsuleKind.port,
    _AddCapsuleKind.username,
    _AddCapsuleKind.auth,
    _AddCapsuleKind.save,
  ];

  /// v8：设置的胶囊列表（数据）。v10 是三个：标题 + 提示 + 高级设置。
  /// 高级设置展开时自己变高（48→88，提示在里面），个数不变，还是 3 个。
  static const List<_SettingsCapsuleKind> _settingsCapsuleKinds = [
    _SettingsCapsuleKind.title,
    _SettingsCapsuleKind.hint,
    _SettingsCapsuleKind.advanced,
  ];

  /// v10：可扩张胶囊展开后多出来的高度——里面的行高。
  /// 认证方式：密码行 48 + 私钥行 48 = 96（展开后 48→144）；
  /// v11：密钥方式时多一个私钥口令行 48 = 144（展开后 48→192），
  /// 密码方式时还是 96（48→144）；
  /// 高级设置：提示行 40（展开后 48→88）。
  static const double _authExpandedExtraHeight = 96;
  static const double _authExpandedExtraHeightWithPassphrase = 144;
  static const double _advancedExpandedExtraHeight = 40;

  /// 第 index 个胶囊的淡入窗口（open 值），内容和玻璃脸共用同一套：
  /// begin = 0.55 + 0.08 * index，end = begin + 0.15，
  /// 自上而下依次进。v7 的三条窗口（名称 0.55→0.70、
  /// 地址 0.63→0.78、保存 0.71→0.86）正好是这个规律；
  /// 第 4、5 个胶囊也按这个规律往后排（密钥是第 4 个，
  /// 0.79→0.94）。钳一下：胶囊太多时 begin 不超过 0.85、
  /// end 不超过 1.0，后面的胶囊一起在末尾淡入，不会永远等不到。
  static ({double begin, double end}) _capsuleWindow(int index) {
    final double begin = math.min(0.55 + 0.08 * index, 0.85);
    return (begin: begin, end: math.min(begin + 0.15, 1.0));
  }

  /// 一个胶囊这会儿的高度：可扩张的胶囊（认证方式/高级设置）展开时
  /// 自己变高（auth 密码方式 48→144、密钥方式 48→192，
  /// advanced 48→88），内容在胶囊里面；
  /// 收起时 48；其余恒 48。个数不变——展开后还是一个胶囊，
  /// 间距按个数走（见 _capsuleGapForCount），不把里面的行数算进去。
  double _capsuleHeightFor(Object kind) {
    if (kind == _AddCapsuleKind.auth) {
      if (!_authExpanded) return _capsuleHeight;
      // v11：口令行只在密钥方式时出现，密钥方式展开后 48→192，
      // 密码方式 48→144。
      final extra = _authMethod == _AuthMethod.key
          ? _authExpandedExtraHeightWithPassphrase
          : _authExpandedExtraHeight;
      return _capsuleHeight + extra;
    }
    if (kind == _SettingsCapsuleKind.advanced) {
      return _advancedExpanded
          ? _capsuleHeight + _advancedExpandedExtraHeight
          : _capsuleHeight;
    }
    return _capsuleHeight;
  }

  /// 一个胶囊的**脸**的淡入窗口：主脸（第 0 个）恒为 1（begin==end）；
  /// 其余按 _capsuleWindow(序号)。
  /// 注意：脸的 (0,0) 只给脸用，内容不要用它（见 _capsuleStaggerWindowFor）。
  ({double begin, double end}) _capsuleWindowFor(Object kind, int index) {
    if (index == 0) return (begin: 0, end: 0);
    return _capsuleWindow(index);
  }

  /// 一个胶囊的**内容**（_CapsuleStagger）的淡入窗口：
  /// 按 _capsuleWindow(序号)，包括第 0 个（0.55→0.70，v8 的做法——
  /// 标题/名称的内容是淡入的，不是一开就满亮度；脸恒为 1、内容淡入，
  /// 两者不要混成一个窗口）。
  ({double begin, double end}) _capsuleStaggerWindowFor(
    Object kind,
    int index,
  ) {
    return _capsuleWindow(index);
  }

  /// 两个胶囊按钮的锚点：点按钮时同步量真实全局矩形，不写死坐标。
  /// onTap 里量的矩形一定还是在屏上的那个按钮（按钮在面板打开时
  /// 才藏，量的时候还在）。
  final GlobalKey _addButtonKey = GlobalKey();
  final GlobalKey _settingsButtonKey = GlobalKey();


  /// Morph 小弹窗要折射的画面来源：主页地球（原来两张底部弹窗的同一份）。
  ///
  /// Fluid_Glass 的 LayerBackdrop 是显式对象、不靠祖先查找，
  /// 玻璃在弹窗路由里也能按全局坐标采到它（见 glass_styles.dart 注释）。
  /// BackdropLayer 只包地球本体，不包右下角的按钮——悬浮按钮不进折射画面。
  final fluid.LayerBackdrop _globeBackdrop = fluid.LayerBackdrop();

  /// 首开预热（v3）：见 _buildShaderWarmup。首帧后画 3 帧就拿掉；
  /// _warmupStarted 保证只启动一次。
  int _warmupFramesLeft = 3;
  bool _warmupStarted = false;

  /// 预热倒数：每帧减 1，到 0 就把预热 widget 从树上拿掉。
  void _startWarmupCountdown() {
    if (_warmupStarted || !mounted) return;
    _warmupStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _countWarmupFrame());
  }

  void _countWarmupFrame() {
    if (!mounted) return;
    if (_warmupFramesLeft > 1) {
      setState(() => _warmupFramesLeft--);
      WidgetsBinding.instance.addPostFrameCallback((_) => _countWarmupFrame());
    } else {
      setState(() => _warmupFramesLeft = 0);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _globeResumeTimer?.cancel();
    _addHidden.dispose();
    _settingsHidden.dispose();
    _addForm?.dispose();
    _morphAnimating.dispose();
    _morphOpen.dispose();
    _anchorCardRect.dispose();
    _globeBackdrop.dispose();
    // v13：会话清理（面板关了也可能残留连接，别漏）。
    _sessionStdoutSub?.cancel();
    _sessionStderrSub?.cancel();
    _sessionHandle?.close();
    _sessionCmdController.dispose();
    _sessionScrollController.dispose();
    super.dispose();
  }

  /// 同步量一个按钮的真实全局矩形；量不到（理论上点按时不会发生）
  /// 返回 null，调用方用 _fallbackOrigin() 兜底。
  Rect? _measureButton(GlobalKey key) {
    final context = key.currentContext;
    if (context == null) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 量不到锚点时的兜底：右下角两个 88x48 胶囊按钮（齿轮在上、
  /// + 在下，间距 18，底边距 16 + safe.bottom），按这个布局反推。
  /// 只是兜底，正常都走实测。
  Rect _fallbackOrigin(_MorphKind kind) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    const childWidth = 88.0;
    const childHeight = 48.0;
    const gap = 18.0;
    const margin = 16.0;
    // + 在下（底边 = safe.bottom + 16），齿轮在 + 上方 18。
    final Rect addRect = Rect.fromLTWH(
      size.width - margin - childWidth,
      size.height - safe.bottom - margin - childHeight,
      childWidth,
      childHeight,
    );
    if (kind == _MorphKind.add) return addRect;
    return Rect.fromLTWH(
      addRect.left,
      addRect.top - gap - childHeight,
      childWidth,
      childHeight,
    );
  }

  void _openMorph(_MorphKind kind, Rect origin, [ServerProfile? profile]) {
    // 一个面板开着时不再开第二个。
    if (_morph != null) return;
    // v16：取消之前排队的地球恢复（_scheduleGlobeResume 的代次 +1，
    // 旧的恢复回调发现代次对不上就放弃，不会解冻新面板的地球）。
    _globeResumeGeneration++;
    setState(() {
      _morph = _MorphRequest(kind: kind, origin: origin, profile: profile);
    });
    // v9：认证/高级的展开态、当前方式、密码可见性，每次打开都是新的
    // （和表单控制器一样，不跨次保留）。
    _authExpanded = false;
    _advancedExpanded = false;
    // v11：编辑时按 profile 的认证方式预填（新建默认密码方式）。
    _authMethod = profile == null
        ? _AuthMethod.password
        : (profile.authType == 'key'
              ? _AuthMethod.key
              : _AuthMethod.password);
    _passwordVisible = false;
    // v8：打开添加时新建表单控制器（每次打开都是新的，不跨次保留，
    // 和 v7 的 ProfileEditor 一样）；关到底时在 _onMorphSettledClosed
    // 里释放。
    // v11：编辑时端口/用户名也预填；密码/口令/已保存私钥从 vault
    // 读回来填进去（见 _prefillEditSecrets，异步，不拦面板打开）。
    if (kind == _MorphKind.add) {
      _addForm = _AddFormController(
        name: profile?.name,
        host: profile?.host,
        port: profile?.port.toString(),
        username: profile?.username,
      );
      if (profile != null) unawaited(_prefillEditSecrets(profile));
    }
    // v5：被点的子按钮在这一帧就藏起来（ValueNotifier 驱动，见
    // _addHidden/_settingsHidden 注释）。morph 脸在 open=0 时画在
    // 按钮原位同形同位，交接无缝；关闭全程保持藏着，只有弹簧关到底、
    // overlay 卸载的同一帧（_onMorphSettledClosed）才回来——变形脸
    // + 真按钮不会同时出现（主人 18:27 实锤：收回时看到的虚影）。
    // 没被点的那个不动，留在原地可见可点。
    (kind == _MorphKind.add ? _addHidden : _settingsHidden).value = true;
    // 面板由 GlassMorphOverlay 在 initState 里直接用弹簧打开，
    // 不用再 forward：第一帧 open 就是 0（玻璃正好是按钮），
    // 不会出现面板先整块闪一下再开始变形。
  }

  /// overlay 双弹簧关到底的通知：v7 立刻卸载，被点的子按钮同一帧
  /// 回来；主按钮（大 ×）单独 150ms 淡入。
  ///
  /// 闪光重定位（主人 2026-11-13 19:33：v6 还是“从高亮突然变暗”）：
  /// v6 的 150ms 交叉淡入本身就是凶手——淡入期间变形脸和真按钮
  /// 同时可见、两层亮面叠加，比任何一层都亮（“高亮”）；淡完变形
  /// 脸一拿掉，只剩真按钮，亮度掉一截（“突然变暗”）。v5 的硬切
  /// （卸载同一帧真按钮满亮度出现）是同一个位置的两层交接问题，
  /// v6 用重叠淡入修它，结果重叠本身又造了一个亮度台阶。
  /// v7 去掉重叠：弹簧关到底时 open 已严格等于 0，morph 脸就是
  /// 按钮原位同形同位、亮度已对齐的版本（表面色/阴影/图标都按
  /// 真按钮调过，见 glass_morph_overlay 的 shadowForOpen /
  /// surfaceColorForOpen 和下面的 anchor 图标），立刻卸载、
  /// 子按钮同一帧满亮度回来——亮度匹配过的两层交接，没有重叠期，
  /// 就没有亮度台阶。主按钮位置不同、无重叠，仍用 150ms 淡入。
  /// scrim 与 _press 已在 v6 洗清（scrim alpha 0.22*open，关到底
  /// 时是 0；press 全程 0），弹簧尾段是减速趋近 0、没有突变
  /// （见 morph_v7_test 的关尾平滑测试）。
  void _onMorphSettledClosed() {
    if (_morph == null) return;
    // v13：会话面板关到底 = 断开并回到地球仪主页（先记下 kind，
    // 下面把 _morph 清掉以后就没法再认了）。
    final bool wasSession = _morph!.kind == _MorphKind.session;
    // v16：断开用的对象先快照下来、字段立刻清掉——延后那一帧的关闭
    // 只碰快照里的旧对象；两帧内重开新会话，新连接进的是已经清掉的
    // 字段，不会被延后的关闭误关（见 _scheduleGlobeResume 的说明）。
    final StreamSubscription<Uint8List>? stdoutSub = _sessionStdoutSub;
    final StreamSubscription<Uint8List>? stderrSub = _sessionStderrSub;
    final SessionHandle? sessionHandle = _sessionHandle;
    _sessionStdoutSub = null;
    _sessionStderrSub = null;
    _sessionHandle = null;
    _sessionPending = '';
    // v16：收尾这帧只做 overlay 卸载 + 卡片回来（setState 里 _morph
    // 清掉）。那一帧里已经要拆掉整块面板子树（DrawBackdrop 玻璃、
    // 输出列表、输入框）再把卡片翻回可见，UI 线程已经很满；再在
    // 同一帧里重启地球 ticker（SshGlobe 重建 + didUpdateWidget +
    // 首个旋转 tick + 背景重抓）并启动会话断开，几件事挤在一起，
    // 就是主人说的“面板变回按钮的最后那一下卡顿”。所以断开和地球
    // 恢复都错后——断开下一帧、地球恢复再下一帧。
    setState(() {
      _morph = null;
      // v19：关闭结束，正在关闭的标志复位（地球不再走 morph 驱动）。
      _sessionClosing = false;
    });
    if (wasSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _disconnectSessionSnapshot(stdoutSub, stderrSub, sessionHandle),
        );
      });
    }
    _addHidden.value = false;
    _settingsHidden.value = false;
    // v8：添加表单控制器释放（下次打开再新建）。
    _addForm?.dispose();
    _addForm = null;
    // v11：存下来的弹簧关闭也清掉（overlay 已卸载，调它会报错）。
    _closeMorphPanel = null;
    // v16：地球恢复旋转错后两帧（_scheduleGlobeResume）：关到底这帧
    // 不解冻，地球继续冻着；等两帧、树稳了再恢复 12°/秒。
    // v7 的教训还在：这里不能依赖 overlay 的 post-frame _syncAnimating
    // 回调来解冻——overlay 已卸载，它的回调因 mounted=false 直接返回；
    // 恢复回调挂在 WidgetsBinding 上（主页的 state 还在），不会丢。
    // v19：会话关闭不走这套——过渡里地球已经在转了（转速绑在 morph
    // 的 open 上，过渡结束时正好回到 12°/秒），关到底这帧直接解冻，
    // 地球继续以 12°/秒转，不要先停 150ms 再恢复（那就是主人说的
    // 第 2 个问题没修好：加速要发生在过渡那段时间里，不是过渡之后）。
    // _morphAnimating 在 overlay 卸载后没人再置回 false（overlay
    // 的 _syncAnimating 已随卸载失效），这里直接置 false；否则
    // autoRotate 一直 false，地球关完就冻住了。
    if (wasSession) {
      _morphAnimating.value = false;
    } else {
      _scheduleGlobeResume();
    }
  }

  /// v16：地球恢复旋转错后两帧。
  /// 收尾那一帧（弹簧关到底、onSettledClosed 回调里）只做 overlay 卸载 +
  /// 卡片回来；地球继续冻着（_morphAnimating 仍是 true），等两帧、
  /// 树稳了再把 _morphAnimating 置回 false、地球恢复 12°/秒。
  /// 两帧约 22ms（90Hz）/ 33ms（60Hz），肉眼看不出地球晚转了，
  /// 但收尾那一帧少了 SshGlobe 重建 + ticker 重启 + 首个旋转 tick +
  /// 背景重抓，顿的那一下就没了。
  /// 恢复回调挂在 WidgetsBinding 上（主页 state 还在，不会像 overlay
  /// 自己的 _syncAnimating 那样因卸载而丢）；代次 + _morph 检查保证
  /// 面板重开时旧的恢复不会解冻新面板的地球。
  void _scheduleGlobeResume() {
    final int generation = ++_globeResumeGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _globeResumeGeneration) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _globeResumeGeneration) return;
        // 面板又开了（_morph 非空）就不解冻：新面板的地球要继续冻着。
        if (_morph != null) return;
        // v18：再晚 150ms 才解冻——主人 13:07 把时机说准了：顿是
        // 在“面板变回按钮、卡片回来之后”，最可疑的就是地球一转、
        // BackdropLayer 立刻全屏重抓背景的第一帧。卡片回来那一刻
        // 地球还冻着（转速 0），等 150ms、断开也落定了，地球才
        // 开始恢复转动（globe.dart 里再用 450ms 斜坡从 0 爬回
        // 12°/秒），和“变回按钮”那一刻拉开距离，全程没有顿。
        // Timer 是真实时间；测试里是假时间，pump 推进就到点。
        _globeResumeTimer?.cancel();
        _globeResumeTimer = Timer(const Duration(milliseconds: 150), () {
          if (!mounted || generation != _globeResumeGeneration) return;
          if (_morph != null) return;
          _morphAnimating.value = false;
        });
      });
      // v16：addPostFrameCallback 本身不排一帧——关到底之后应用是闲的
      // （地球 ticker 停着、弹簧停稳了），没人排帧的话，第二段回调
      // 会一直挂着不跑，地球永远不恢复（实测：最小复现里第二段回调
      // 连 pump 三次都不跑）。这里显式排一帧，下一帧的 post-frame
      // 里第二段回调一定跑；那一帧本身几乎是空的（没有动画在走）。
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  void _openAddMorph() {
    final origin =
        _measureButton(_addButtonKey) ?? _fallbackOrigin(_MorphKind.add);
    _openMorph(_MorphKind.add, origin);
  }

  void _openSettingsMorph() {
    final origin =
        _measureButton(_settingsButtonKey) ??
        _fallbackOrigin(_MorphKind.settings);
    _openMorph(_MorphKind.settings, origin);
  }

  /// v13：点地球仪卡片进会话（TerminalPage 时代是 _connect 推终端页，
  /// 现在直接开指令面板）。tapPosition 是点按的全局坐标（globe 的
  /// onSelectedAt 给的），面板从那里长出来；没有位置时（只走了
  /// onSelected）用地球中心兜底。面板开着时不再开第二个。
  void _openSessionFor(String id, Offset? tapPosition) {
    if (_morph != null) return;
    final found = _profiles.where((p) => p.id == id);
    if (found.isEmpty) return;
    final profile = found.first;
    setState(() => _selected = profile);
    _openSessionMorph(profile, tapPosition);
  }

  /// v13：开会话面板。锚点是点按处一张 136×46 的卡片矩形
  /// （globeHostCardSize，地球仪卡片的尺寸，中心钳在屏幕里）；
  /// 面板打开的同时在后台开始连服务器，状态和输出都写进面板里。
  void _openSessionMorph(ServerProfile profile, Offset? tapPosition) {
    if (_morph != null) return;
    // v16：取消之前排队的地球恢复（和 _openMorph 一样，代次 +1）。
    _globeResumeGeneration++;
    final size = MediaQuery.sizeOf(context);
    final double halfW = globeHostCardSize.width / 2;
    final double halfH = globeHostCardSize.height / 2;
    final Offset rawCenter =
        tapPosition ?? Offset(size.width / 2, size.height * 0.53);
    // v15：锚点中心再往屏内收 6dp（和 layoutGlobeCards 的卡片布局边距
    // 一致）：卡片最贴边也只到 6dp，锚点矩形不能比卡片更贴边，不然
    // 缩回去的胶囊会比卡片多探出去一点、左/右被屏边裁掉
    // （主人 10:56 第一张图：关闭中的胶囊左端贴着屏边）。
    final Offset center = Offset(
      rawCenter.dx.clamp(
        halfW + 6,
        math.max(halfW + 6, size.width - halfW - 6),
      ),
      rawCenter.dy.clamp(
        halfH + 6,
        math.max(halfH + 6, size.height - halfH - 6),
      ),
    );
    final origin = Rect.fromCenter(
      center: center,
      width: globeHostCardSize.width,
      height: globeHostCardSize.height,
    );
    // v19：活锚点的初始值就是打开那一刻的锚点矩形；地球仪每帧会把
    // 选中卡片的实时布局矩形写进来覆盖它。_sessionClosing 复位
    // （新开的面板还没开始关闭）。
    _anchorCardRect.value = origin;
    _sessionClosing = false;
    _resetSessionState();
    setState(() {
      _sessionStatus = '正在连接…';
      _morph = _MorphRequest(
        kind: _MorphKind.session,
        origin: origin,
        profile: profile,
      );
    });
    unawaited(_startSession(profile));
  }

  /// v13：每次开会话面板都是新的（输出、状态、输入框都清掉）。
  void _resetSessionState() {
    _sessionLines.clear();
    _sessionPending = '';
    _sessionStatus = '';
    _sessionCmdError = null;
    _sessionCmdController.clear();
  }

  /// v13：指纹核对（TerminalPage._verifyHostKey 原样搬过来，
  /// 只是 profile 从参数拿——这是安全底线，首次连接必须弹出来核对，
  /// 只有确认匹配才接受并保存；指纹变了直接拒绝）。
  String _sessionPinKey(ServerProfile profile) =>
      'hostkey.${profile.host}:${profile.port}';

  Future<bool> _verifyHostKey(
    ServerProfile profile,
    String type,
    Uint8List bytes,
  ) async {
    final fingerprint = utf8.decode(bytes, allowMalformed: true);
    final prefs = await SharedPreferences.getInstance();
    final pin = prefs.getString(_sessionPinKey(profile));
    final current = '$type|$fingerprint';
    if (pin != null) {
      if (pin == current) return true;
      _sessionFingerprintChanged = true;
      return false;
    }
    if (!mounted) return false;
    final accept =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => _GlassAlert(
            title: '首次连接 · 校验主机',
            caption: '请通过可信渠道核对指纹',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(
                  child: Icon(
                    Icons.verified_user_outlined,
                    size: 30,
                    color: Color(0xff83d9e3),
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  '${profile.name}\n${profile.host}:${profile.port}\n\n$type\n$fingerprint\n\n请通过可信渠道核对指纹。只有确认匹配后才接受。',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('接受并保存'),
              ),
            ],
          ),
        ) ??
        false;
    if (accept) await prefs.setString(_sessionPinKey(profile), current);
    return accept;
  }

  /// v13：连服务器（后台跑，面板先开、状态后到）。凭据从 vault 读，
  /// 和 _connect 时代一样；连接失败的原因写进面板输出区，不让用户
  /// 对着空白猜。面板已经关了（或换了另一台机子），迟到的连接
  /// 直接关掉，不写进已经不存在的面板。
  Future<void> _startSession(ServerProfile profile) async {
    final password = await _vault.read(key: '${profile.id}.password') ?? '';
    final privateKey = await _vault.read(key: '${profile.id}.key') ?? '';
    final passphrase = await _vault.read(key: '${profile.id}.passphrase') ?? '';
    if (!mounted) return;
    if (_morph?.kind != _MorphKind.session ||
        _morph?.profile?.id != profile.id) {
      return;
    }
    _sessionFingerprintChanged = false;
    _appendSessionLine(
      _SessionLineKind.status,
      '正在连接 ${profile.host}:${profile.port}…',
    );
    try {
      final connector = widget.sessionConnector ?? _realSessionConnector;
      final handle = await connector(
        profile,
        SavedAuth(
          password: password,
          privateKey: privateKey,
          passphrase: passphrase,
        ),
        (type, bytes) => _verifyHostKey(profile, type, bytes),
      );
      if (!mounted ||
          _morph?.kind != _MorphKind.session ||
          _morph?.profile?.id != profile.id) {
        await handle.close();
        return;
      }
      _sessionHandle = handle;
      _sessionStdoutSub = handle.stdoutStream.listen(
        _appendSessionOutput,
        onError: _onSessionError,
      );
      _sessionStderrSub = handle.stderrStream.listen(
        _appendSessionOutput,
        onError: _onSessionError,
      );
      if (!mounted) return;
      setState(() => _sessionStatus = '已连接');
      _appendSessionLine(_SessionLineKind.status, '已连接 ${profile.name}');
    } catch (e) {
      if (!mounted) return;
      if (_morph?.kind != _MorphKind.session ||
          _morph?.profile?.id != profile.id) {
        return;
      }
      final message = _sessionFingerprintChanged
          ? '主机指纹与已保存记录不同。为保护连接，本次已拒绝。请先通过可信渠道核实新指纹。'
          : _friendlyError(e);
      setState(() => _sessionStatus = '连接失败');
      _appendSessionLine(_SessionLineKind.status, message);
    }
  }

  /// v13：TerminalPage._friendlyError 原样搬过来。
  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('Authentication') || s.contains('auth')) {
      return '认证失败：请检查用户名、密码或私钥/私钥口令。\n$s';
    }
    if (s.contains('Hostkey') || s.contains('host key')) {
      return '未接受主机指纹。连接已关闭。\n$s';
    }
    return '连接失败：$s';
  }

  /// v13：输出区加一行（指令 / 输出 / 状态），超 500 行从头上截掉。
  void _appendSessionLine(_SessionLineKind kind, String text) {
    if (!mounted) return;
    setState(() {
      _sessionLines.add(_SessionLine(kind, text));
      if (_sessionLines.length > _sessionMaxLines) {
        _sessionLines.removeRange(0, _sessionLines.length - _sessionMaxLines);
      }
    });
    _scrollSessionToBottom();
  }

  /// v13：会话输出（stdout/stderr）追加进来。pty 的行尾是 \r\n，
  /// 数据可能半行半行地到：先攒在 _sessionPending 里，攒满一行
  /// 再进列表；没攒满的那半行也显示在列表最下面一行（实时感）。
  void _appendSessionOutput(Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);
    _sessionPending += text;
    final parts = _sessionPending.split('\n');
    if (parts.length <= 1) {
      if (mounted) setState(() {});
      return;
    }
    _sessionPending = parts.last;
    if (!mounted) return;
    setState(() {
      for (final line in parts.sublist(0, parts.length - 1)) {
        _sessionLines.add(
          _SessionLine(_SessionLineKind.output, line.replaceAll('\r', '')),
        );
      }
      if (_sessionLines.length > _sessionMaxLines) {
        _sessionLines.removeRange(0, _sessionLines.length - _sessionMaxLines);
      }
    });
    _scrollSessionToBottom();
  }

  /// v13：新内容来了自动滚到底（post-frame 里跳，ListView 建好以后）。
  void _scrollSessionToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_sessionScrollController.hasClients) return;
      _sessionScrollController.jumpTo(
        _sessionScrollController.position.maxScrollExtent,
      );
    });
  }

  /// v13：会话断了（stdout/stderr 的 onError，TerminalPage._showError
  /// 原样搬过来——状态改掉、原因写进输出区）。
  void _onSessionError(Object e) {
    if (!mounted) return;
    setState(() => _sessionStatus = '连接中断');
    _appendSessionLine(_SessionLineKind.status, '连接中断：$e');
  }

  /// v13：发指令——`指令 + '\n'` 写进会话；发出去的指令也在输出区
  /// 里看得到，前面加 `>`，和会话输出区分开。发完清空输入框、
  /// 面板保持打开（连续输多条）；空指令不发。还没连上（handle 是
  /// null）时不吞掉，面板里给一句提示。
  void _sendSessionCommand() {
    final text = _sessionCmdController.text.trim();
    if (text.isEmpty) return;
    final handle = _sessionHandle;
    if (handle == null) {
      setState(() => _sessionCmdError = '还没连上，等连接成功再发。');
      return;
    }
    handle.write(Uint8List.fromList(utf8.encode('$text\n')));
    if (_sessionCmdError != null) {
      setState(() => _sessionCmdError = null);
    }
    _appendSessionLine(_SessionLineKind.command, '> $text');
    _sessionCmdController.clear();
  }

  /// v13：断开会话（面板关到底时调）：订阅、session、client 都关干净，
  /// 照抄 TerminalPage 的 dispose/_disconnect。关的时候不 setState——
  /// 面板已经不在树上了。
  /// v16：关快照里的对象，不读字段——_onMorphSettledClosed 已经把字段
  /// 清掉、快照在手里；延后一帧关，关的是旧会话，重开的新会话不受影响。
  Future<void> _disconnectSessionSnapshot(
    StreamSubscription<Uint8List>? stdoutSub,
    StreamSubscription<Uint8List>? stderrSub,
    SessionHandle? handle,
  ) async {
    await stdoutSub?.cancel();
    await stderrSub?.cancel();
    await handle?.close();
  }

  Future<void> _load() async {
    final values = await loadProfiles();
    if (!mounted) return;
    setState(() {
      _profiles = values;
      _loading = false;
      if (values.isNotEmpty) _selected = values.first;
    });
    if (values.isNotEmpty) unawaited(_loadGeoLocations(values));
    // v22：地理数据首次启动不再静默下载——本地没有数据时弹下载弹窗
    // （带进度条、失败可重试）；已有旧数据时才走 v21 的静默后台更新。
    unawaited(_maybeShowGeoFirstDownload());
    // 地球已在树上，开始首开预热倒数（见 _buildShaderWarmup）。
    _startWarmupCountdown();
  }

  /// v11：查不到时的默认落点（法兰克福，主人的机子在那）——
  /// 服务器照常保存、照常能连接，标记放在这里，卡片上写“德国”
  /// （v12：主人说默认称呼改成国家名，默认点在德国）。
  static const IpGeoLocation _defaultGeoLocation = IpGeoLocation(
    point: GeoPoint(50.1109, 8.6821),
    label: '德国',
  );

  /// v11：解析一个 host 的地理位置：IP 直接查库；域名先 DNS 解析
  /// 成 IP 再查库。查不到（内网 IP、DNS 失败、库里没有、库打不开）
  /// 返回默认落点，不抛错、不拦保存。resolved 表示是不是真查到的。
  /// 查库和 DNS 都有短超时（本地文件读 1 秒、DNS 2 秒）：真机上
  /// 这两步都是毫秒级，超时只防极端卡住，保存绝不能被地理位置拖住。
  Future<({IpGeoLocation location, bool resolved})> _resolveGeoForHost(
    String host,
  ) async {
    try {
      final database = await IpGeoDatabase.open();
      final direct = await database
          .lookup(host)
          .timeout(const Duration(seconds: 1), onTimeout: () => null);
      if (direct != null) return (location: direct, resolved: true);
      final addresses = await InternetAddress.lookup(
        host.trim(),
      ).timeout(const Duration(seconds: 2));
      for (final address in addresses) {
        final located = await database
            .lookup(address.address)
            .timeout(const Duration(seconds: 1), onTimeout: () => null);
        if (located != null) return (location: located, resolved: true);
      }
    } catch (error, stack) {
      debugPrint('Geo lookup failed for $host: $error\n$stack');
    }
    return (location: _defaultGeoLocation, resolved: false);
  }

  Future<void> _loadGeoLocations(List<ServerProfile> profiles) async {
    final resolved = <String, IpGeoLocation>{};
    for (final profile in profiles) {
      // Explicitly entered locations remain the user's source of truth.
      if (profile.city.trim().isNotEmpty) continue;
      final geo = await _resolveGeoForHost(profile.host);
      resolved[profile.id] = geo.location;
    }
    if (mounted) {
      setState(() {
        _geoLocations
          ..clear()
          ..addAll(resolved);
      });
    }
  }

  /// v21：后台检查并更新地理数据。测试环境（FLUTTER_TEST）下不跑：
  /// 真实 HTTP/文件 I/O 在 testWidgets 的假时间里会挂起，下载完成
  /// 还可能中途改写地理结果，干扰 morph 测试的“德国”兜底断言。
  Future<void> _refreshGeoDataInBackground() async {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    try {
      final result = await GeoDataUpdater().ensureAndUpdate();
      if (!mounted || !result.updated) return;
      if (_profiles.isNotEmpty) unawaited(_loadGeoLocations(_profiles));
    } catch (_) {
      // 后台更新永不打扰首页；失败时本地数据（或兜底）照常工作。
    }
  }

  /// v22：首次启动下载弹窗是否已弹过（每个应用进程只弹一次；
  /// 取消后下次启动（新进程）没数据还会再弹）。
  bool _geoDialogShown = false;

  /// v22：本地没有地理数据时弹下载弹窗（带进度条、失败可重试），
  /// 而不是 v21 的静默后台下载——主人 16:36：“不然的话，那就挺
  /// 莫名其妙的”。已有旧数据时不弹，走 v21 的静默后台更新。
  /// 测试环境默认不弹（真实 I/O 在 testWidgets 假时间里会挂起）；
  /// 传入 geoFirstDownloadRunner 的测试显式打开这条路。
  Future<void> _maybeShowGeoFirstDownload() async {
    final runner = widget.geoFirstDownloadRunner;
    if (runner == null && Platform.environment['FLUTTER_TEST'] == 'true') {
      return;
    }
    if (_geoDialogShown) return;
    final db = await IpGeoDatabase.open();
    if (!mounted) return;
    if (db.hasData) {
      unawaited(_refreshGeoDataInBackground());
      return;
    }
    _geoDialogShown = true;
    // 首页先出来再弹（_load 在 initState 里调，showDialog 要等第一帧）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final done = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: _GeoFirstDownloadDialog(
            runner: runner ?? _defaultGeoFirstDownloadRunner,
          ),
        ),
      );
      if (done == true && mounted && _profiles.isNotEmpty) {
        unawaited(_loadGeoLocations(_profiles));
      }
    });
  }

  /// v22：生产用的下载 runner（测试用 geoFirstDownloadRunner 注入假的）。
  Future<GeoUpdateResult> _defaultGeoFirstDownloadRunner({
    required void Function(GeoDownloadProgress) onProgress,
    required bool Function() isCancelled,
  }) {
    return GeoDataUpdater().ensureAndUpdate(
      force: true,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// v11：写盘 + 刷新列表和地理位置（保存和删除共用）。
  Future<void> _applyProfiles(List<ServerProfile> values) async {
    await persistProfiles(values);
    if (!mounted) return;
    setState(() {
      _profiles = values;
    });
    if (values.isNotEmpty) unawaited(_loadGeoLocations(values));
  }

  /// 首开预热（v3）：Fluid_Glass 的折射 shader 在第一次画 DrawBackdrop 时
  /// 才在 GPU 上编译；主页的玻璃全是 prism_ui 的（BackdropFilter），
  /// 折射 shader 在第一个 Morph 打开前从没画过——主人录的 Fluid 演示里
  /// 点 + 后冻 0.42 秒，疑似就是这笔首次编译的开销。_load 完成后、
  /// 地球已在树上时，悄悄画一个 1×1、几乎透明（0.01）的 DrawBackdrop，
  /// 用和 Morph 一样的 effects（vibrancy + blur 10 + lens 22/30），
  /// 把 shader 提前编译掉；画满 3 帧就拿掉（编译一次后常驻）。
  /// v10：Morph 脸开了 chromaticAberration（色散走另一支 shader 程序），
  /// 预热的 lens 也改成同样的参数（28/36 + 色散），不然第一次点开
  /// 会在现场编译色散程序、冻一帧。
  /// widget test 测不出真机卡顿——这里只能保证 shader 提前编译，
  /// 真机第一次点开还卡不卡，要主人真机裁决。
  Widget _buildShaderWarmup() {
    return Positioned(
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      child: Opacity(
        opacity: 0.01,
        child: fluid.DrawBackdrop(
          backdrop: _globeBackdrop,
          shape: () => const fluid.RoundedRectangle(28),
          effects: (fluid.BackdropEffectScope scope) => scope
            ..vibrancy()
            ..blur(10)
            ..lens(28, 36, chromaticAberration: true),
          onDrawSurface: (Canvas canvas, Size size) => canvas.drawRect(
            Offset.zero & size,
            Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.62),
          ),
          isolateSurface: false,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// Morph 胶囊的目标矩形（v8）：分开的胶囊，没有外框。
  ///
  /// 尺寸（主人原话：和现在的功能差不多——红框只是示意，不要照抄）：
  /// - 每个胶囊高 48、宽 240（屏不够宽时取屏宽 - 32），圆角 18
  ///   （ServerBox 行那种圆角矩形，不是全圆药丸）；
  /// - 胶囊之间间距按可见个数走（见 _capsuleGapForCount，
  ///   3 个及以下 10，4 个及以上 8 起往下收）；
  /// - 胶囊个数不写死：添加按 _addCapsuleKinds、设置按
  ///   _settingsCapsuleKinds，目标矩形、淡入窗口、整体高度
  ///   都从列表和各自高度算；可扩张的胶囊（认证方式/高级设置）
  ///   展开时自己变高（高度见 _capsuleHeightFor），目标矩形
  ///   跟着变，overlay 里 260ms 的 RectTween 滑过去，不跳变；
  ///   整组竖着居中（屏高一半处），上下钳在可用空间里；
  ///   上下钳在可用空间里；整组是紧凑的一小团，不撑满屏幕，
  ///   下面留着空位，以后加字段有地方放；四边留空，不贴底、
  ///   不盖右下角的按钮；
  /// - 键盘弹起时 viewInsets.bottom 会把整组顶上去，目标矩形的变化
  ///   由 overlay 里的 260ms RectTween 滑过去，不跳变。
  Widget _buildMorphOverlay() {
    final morph = _morph!;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final safe = media.padding;
    final keyboard = media.viewInsets.bottom;
    // v13：会话面板（点地球仪卡片开出来的指令面板）不走胶囊列表——
    // 单个大面板：顶部贴 safe.top + 16（主页没有 AppBar，不用留工具栏），
    // 四周留 16，高 = 0.62 屏高；键盘弹起时底部以键盘顶为限，输入框
    // 不被键盘盖住（目标矩形的变化由 overlay 的 260ms RectTween 滑过去）。
    if (morph.kind == _MorphKind.session) {
      // 会话 morph 一定带 profile（_openSessionMorph 里传的）。
      final profile = morph.profile!;
      final double top = safe.top + 16;
      final double bottomLimit = keyboard > 0
          ? screen.height - safe.bottom - keyboard - 16
          : screen.height - safe.bottom - 16;
      final double height = math.min(
        screen.height * _sessionPanelHeightFraction,
        bottomLimit - top,
      );
      return GlassMorphOverlay(
        backdrop: _globeBackdrop,
        animating: _morphAnimating,
        openNotifier: _morphOpen,
        origin: morph.origin,
        // v19：活锚点——会话 morph 的 origin 跟着卡片的实时位置走
        // （地球仪每帧把选中卡片的布局矩形写进 _anchorCardRect）。
        // 关闭过渡里地球转起来、卡片漂走，脸跟着卡片走，落点不错开。
        liveOrigin: _anchorCardRect,
        // v19：关闭开始的通知——点 ×/空白开始关闭的那一刻，主页
        // 就把 _sessionClosing 置 true，地球开始加速（转速绑在
        // morph 的 open 上），不要等关到底才恢复。
        onCloseStarted: () {
          if (_morph?.kind == _MorphKind.session && !_sessionClosing) {
            setState(() {
              _sessionClosing = true;
            });
          }
        },
        // v15：锚点圆角用卡片的 12（不是 origin 高/2 的 23）：open=0 时
        // 脸就是卡片本身，圆角必须和卡片一致，缩到底、卡片回来那一帧
        // 才严丝合缝。添加/设置面板的锚点是 48 高胶囊按钮，仍用高/2。
        originRadius: 12,
        // v17：锚点端的玻璃改成卡片那套（表面色/阴影/折射都和地球仪卡片
        // 同值）——脸在 open=0 时还带着按钮的青色辉光 + 亮蓝 tint +
        // 强折射 + 色散，卡片却是淡黑阴影 + 深 slate tint + 折射 20，
        // overlay 一卸、亮→暗一闪，就是主人 12:41 说的“高亮一下”。
        // 锚点端改成卡片同值，辉光直接删掉，收尾暗到卡片水平再交接；
        // open=1 的大面板端不变（深色 0xff0e2233 α.38、标准黑阴影、
        // 折射 28/36 + 色散）。
        anchorSurfaceColor: sessionAnchorSurfaceColor,
        anchorShadow: sessionAnchorShadow,
        anchorLensHeight: sessionAnchorLensHeight,
        anchorLensAmount: sessionAnchorLensAmount,
        anchorChromaticAberration: sessionAnchorChromaticAberration,
        targets: <Rect>[Rect.fromLTWH(16, top, screen.width - 32, height)],
        targetRadius: _capsuleRadius,
        // v15：锚面画成卡片原样（小蓝点 + 名字 + 位置标签 + 右边 `>`），
        // 不再是终端图标——主人 10:59 实锤：关闭中的胶囊画着终端图标，
        // 关完的卡片画着名字+国家+`>`，两边长得不一样，收尾看着就是错的。
        // open=0 时脸就是卡片本身，打开再按原来的淡入淡出切到面板内容。
        anchor: _SessionAnchorFace(
          key: const ValueKey('session_anchor_face'),
          name: profile.name,
          label: _geoLocations[profile.id]?.label ?? profile.host,
        ),
        // 单个脸，恒为 1（和胶囊第 0 个主脸一样：begin==end → 恒为 1）。
        faceWindows: const <({double begin, double end})>[(begin: 0, end: 0)],
        onSettledClosed: _onMorphSettledClosed,
        panelBuilder: (context, close) => <Widget>[_buildSessionPanel(close)],
      );
    }
    // 胶囊宽 240，水平居中；小屏兜底：再窄也不小于屏宽 - 32。
    final double width = math.min(_capsuleWidth, screen.width - 32);
    final double left = (screen.width - width) / 2;
    // 按钮柱（v8：两个 48 高胶囊按钮 + 间距 18 + 底边距 16）
    // 的顶部；键盘弹起时按钮在键盘下面，改以键盘顶为限。
    const double buttonStack = 16 + 48 + 18 + 48;
    final double bottomLimit = keyboard > 0
        ? screen.height - safe.bottom - keyboard - 16
        : screen.height - safe.bottom - buttonStack - 16;
    final double topLimit = safe.top + 16;
    // v9：胶囊个数跟着列表走（添加 4、设置 3），不写死。
    // v10：胶囊高度是可变的（认证方式展开 144、高级设置展开 88），
    // 整组高度按实际高度求和，不能再用“个数 × 48”——展开的胶囊
    // 会把整组算矮 40/96，居中就偏了；间距还是按可见个数走
    //（见 _capsuleGapForCount），展开不改变个数。
    final List<Object> kinds = <Object>[
      ...(morph.kind == _MorphKind.add
          ? _addCapsuleKinds
          : _settingsCapsuleKinds),
    ];
    final List<double> heights = <double>[
      for (final Object kind in kinds) _capsuleHeightFor(kind),
    ];
    final int visibleCount = heights.where((double h) => h > 0).length;
    final double gap = _capsuleGapForCount(visibleCount);
    final double groupHeight =
        heights.where((double h) => h > 0).fold(0.0, (a, b) => a + b) +
        (visibleCount - 1) * gap;
    // 整组竖着居中（屏高一半处），上下钳在可用空间里；
    // 极小屏兜底：可用空间再小也不让高度变负（真机和测试面都远大于它）。
    final double groupTop = (screen.height / 2 - groupHeight / 2).clamp(
      topLimit,
      math.max(topLimit, bottomLimit - groupHeight),
    );
    // 每个胶囊的顶边：按各自高度 + 间距往下排（v10：没有 0 高的胶囊了，
    // 可扩张的展开时自己变高，顶边跟着实际高度走）。
    final List<double> tops = List<double>.filled(heights.length, 0);
    double cursor = groupTop;
    for (int i = 0; i < heights.length; i++) {
      tops[i] = cursor;
      cursor += heights[i] + gap;
    }
    final List<Rect> targets = <Rect>[
      for (int i = 0; i < heights.length; i++)
        Rect.fromLTWH(left, tops[i], width, heights[i]),
    ];
    // 玻璃脸的淡入窗口（和内容 _CapsuleStagger 的窗口对齐，
    // 都按 _capsuleWindowFor(种类, 序号) 算）：
    // 第 0 个是主脸（begin==end → 恒为 1），其余跟着自己的窗口淡入。
    final List<({double begin, double end})> faceWindows =
        <({double begin, double end})>[
      for (int i = 0; i < kinds.length; i++)
        _capsuleWindowFor(kinds[i], i),
    ];
    return GlassMorphOverlay(
      backdrop: _globeBackdrop,
      animating: _morphAnimating,
      openNotifier: _morphOpen,
      origin: morph.origin,
      // 胶囊按钮的圆角按实测高度推（48/2 = 24），不再是
      // 写死的 29（58x58 圆钮时代的遗留）；右下角两个触发按钮
      // 还是胶囊药丸形（88×48），形态在开合时从 24 插到 18。
      originRadius: morph.origin.height / 2,
      targets: targets,
      // v8：ServerBox 行的圆角 18，不是全圆药丸（24）。
      targetRadius: _capsuleRadius,
      // 按钮脸由 morph 自己画（图标 22、色 0xffdaf9ff，和真按钮
      // _GlassDialGlyph 的字形一致——原来是 28 白，比真按钮大一圈还亮，
      // 关到底那一刻换回真按钮会露馅）；被点的真按钮已在
      // _openMorph 里瞬间隐藏。
      anchor: Icon(
        morph.kind == _MorphKind.add
            ? Icons.add_rounded
            : Icons.settings_rounded,
        color: const Color(0xffdaf9ff),
        size: 22,
      ),
      faceWindows: faceWindows,
      onSettledClosed: _onMorphSettledClosed,
      panelBuilder: (context, close) {
        // close 是 overlay 的弹簧关闭（scrim 点按直接拿它）；
        // v11：保存成功要主动关面板，存下来给 _saveAddForm 用。
        _closeMorphPanel = close;
        return morph.kind == _MorphKind.add
            ? _buildAddCapsules()
            : _buildSettingsCapsules();
      },
    );
  }

  /// v13：会话面板内容（进机子后的主界面）：标题行（服务器名 + 状态 +
  /// 关闭 ×）在顶，中间是输出区（已发指令 + 会话输出，可滚动、自动
  /// 滚到底），输入行贴在面板底部（像聊天输入框）。内容跟着 open
  /// 晚进（_CapsuleStagger 0.55→0.70，主页同款）。
  /// × 和 scrim 点按都是 overlay 的弹簧关闭，关到底时
  /// _onMorphSettledClosed 断开会话、回到地球仪主页。
  Widget _buildSessionPanel(VoidCallback close) {
    final profile = _morph?.profile;
    return _CapsuleStagger(
      open: _morphOpen,
      begin: 0.55,
      end: 0.70,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.terminal_rounded,
                  color: Color(0xff9ab9c7),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    profile?.name ?? '服务器',
                    style: GlassText.sheetTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(_sessionStatus, style: GlassText.captionStyle),
                IconButton(
                  key: const ValueKey('session_panel_close'),
                  onPressed: close,
                  tooltip: '断开并关闭',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Color(0xffeaf8fc),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildSessionOutput()),
            if (_sessionCmdError != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(_sessionCmdError!, style: GlassText.captionStyle),
            ],
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: _buildSessionCommandField()),
                const SizedBox(width: 12),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: prism.LiquidGlass(
                    style: GlassStyles.chip(),
                    borderRadius: BorderRadius.circular(24),
                    steadyFrost: true,
                    child: IconButton(
                      key: const ValueKey('session_send_button'),
                      onPressed: _sendSessionCommand,
                      tooltip: '发送',
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.send_rounded,
                        color: Color(0xffdaf9ff),
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// v13：输出区——已发指令（`>` 开头，青字）和会话输出（白字）、
  /// 状态提示（灰字）按时间顺序排；没攒满一行的半行也显示在最下面。
  /// 新内容来了自动滚到底（见 _scrollSessionToBottom）。
  Widget _buildSessionOutput() {
    final List<Widget> children = <Widget>[
      for (final _SessionLine line in _sessionLines)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: _buildSessionLine(line),
        ),
      if (_sessionPending.isNotEmpty)
        Text(
          _sessionPending.replaceAll('\r', ''),
          style: GlassText.valueStyle.copyWith(fontFamily: 'monospace'),
        ),
    ];
    return ListView(
      key: const ValueKey('session_output_list'),
      controller: _sessionScrollController,
      padding: EdgeInsets.zero,
      children: children.isEmpty
          ? const <Widget>[
              Text('等待输出…', style: GlassText.hintStyle),
            ]
          : children,
    );
  }

  /// v13：输出区里一行字的样式——指令青字、输出白字（等宽）、状态灰字。
  Widget _buildSessionLine(_SessionLine line) {
    switch (line.kind) {
      case _SessionLineKind.command:
        return Text(
          line.text,
          style: GlassText.valueStyle.copyWith(
            color: const Color(0xff79e5ed),
            fontFamily: 'monospace',
          ),
        );
      case _SessionLineKind.status:
        return Text(line.text, style: GlassText.captionStyle);
      case _SessionLineKind.output:
        return Text(
          line.text,
          style: GlassText.valueStyle.copyWith(fontFamily: 'monospace'),
        );
    }
  }

  /// v13：指令输入框。v12 终端页 _buildCommandField 的装饰原样搬过来
  /// （#5 胶囊输入框同款：透明底、圆角 18、细边框 + 聚焦青边、图标在左），
  /// 只是 key 和提交回调改成会话版。
  Widget _buildSessionCommandField() {
    return DefaultSelectionStyle(
      cursorColor: const Color(0xff79e5ed),
      selectionColor: const Color(0x5579e5ed),
      child: TextField(
        key: const ValueKey('session_input_field'),
        controller: _sessionCmdController,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _sendSessionCommand(),
        autocorrect: false,
        style: GlassText.valueStyle,
        cursorColor: const Color(0xff79e5ed),
        decoration: const InputDecoration(
          hintText: '输入指令…',
          hintStyle: GlassText.hintStyle,
          prefixIcon: Icon(
            Icons.terminal_rounded,
            color: Color(0xff9ab9c7),
          ),
          filled: true,
          fillColor: Colors.transparent,
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: Color(0x3c9bc8d8), width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: Color(0xff65dfe9), width: 1.4),
          ),
        ),
      ),
    );
  }

  /// v8：添加的胶囊（上→下，和 overlay 的 targets 一一对应）。
  /// 按 _addCapsuleKinds 列表生成，一个字段一个胶囊；个数不写死，
  /// 加字段只改列表（+ 内容 case + 表单控制器）。
  /// 每个都是 240 宽、高度跟着展开态走（认证方式展开时 144，
  /// overlay 的脸同步长出来），overlay 各自定位到目标矩形。
  /// 字段不用 _GlassField 包（overlay 的 fluid 脸就是胶囊玻璃，
  /// 再包一层 prism 是双层玻璃）；字段只留边框+文字，fill 透明，
  /// 玻璃由 overlay 的脸给。校验不靠 validator（报错行会撑高胶囊），
  /// 保存时手动查控制器（见 _saveAddForm）。
  List<Widget> _buildAddCapsules() {
    return <Widget>[
      for (int i = 0; i < _addCapsuleKinds.length; i++)
        _CapsuleStagger(
          key: ValueKey('stagger_${_addCapsuleKinds[i].name}'),
          open: _morphOpen,
          begin: _capsuleStaggerWindowFor(_addCapsuleKinds[i], i).begin,
          end: _capsuleStaggerWindowFor(_addCapsuleKinds[i], i).end,
          // 高度跟着展开态走（认证方式展开时 144），
          // overlay 的脸同步长出来。
          child: SizedBox(
            width: _capsuleWidth,
            height: _capsuleHeightFor(_addCapsuleKinds[i]),
            child: _buildAddCapsuleContent(_addCapsuleKinds[i]),
          ),
        ),
    ];
  }

  /// 一个添加胶囊的内容（按种类分发；新种类加一个 case）。
  /// 字段行照 ServerBox 的排法：图标在左、文字在右；
  /// 外形是 ServerBox 行的圆角矩形（圆角 18），不是全圆药丸。
  Widget _buildAddCapsuleContent(_AddCapsuleKind kind) {
    final _AddFormController form = _addForm!;
    switch (kind) {
      case _AddCapsuleKind.name:
        return _buildCapsuleField(
          key: const ValueKey('add_name_field'),
          controller: form.name,
          hintText: '名称',
          icon: Icons.label_outline,
          textInputAction: TextInputAction.next,
        );
      case _AddCapsuleKind.host:
        return _buildCapsuleField(
          key: const ValueKey('add_host_field'),
          controller: form.host,
          hintText: '地址 / IP',
          icon: Icons.language,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
        );
      case _AddCapsuleKind.port:
        return _buildCapsuleField(
          key: const ValueKey('add_port_field'),
          controller: form.port,
          hintText: '端口',
          icon: Icons.settings_ethernet,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
        );
      case _AddCapsuleKind.username:
        return _buildCapsuleField(
          key: const ValueKey('add_username_field'),
          controller: form.username,
          hintText: '用户名',
          icon: Icons.person_outline,
          textInputAction: TextInputAction.next,
        );
      case _AddCapsuleKind.auth:
        return _buildAuthCapsule();
      case _AddCapsuleKind.save:
        return _FormGlassSaveButton(onPressed: _saveAddForm);
    }
  }

  /// v9：认证方式胶囊（第 4 个）。可向下展开：点主体展开/收起，
  /// 点右边的“密码/私钥”小标签切换当前方式。收起时只看到这一个
  /// 胶囊，显示当前方式。
  /// v10：不再往外弹出密码+私钥两个单独的胶囊——胶囊本身向下扩张
  /// （48→144），密码和私钥收进胶囊里面（同一块连续玻璃内）。
  /// 头部还是原来那行（认证方式 + 密码/私钥小标签），展开区和
  /// 方式标签是 Row 里的两个平行手势区（不是嵌套），点标签只切换
  /// 方式，不会触发展开。里面的两行（密码行、私钥行）各 48 高，
  /// 上面一条细分隔线，展开时 260ms 淡入（和 overlay 的目标矩形
  /// 滑动同步），收起时淡出、被胶囊的裁剪盖住。密码输入框
  /// （密文+眼睛切换）和私钥选文件行（file_picker）功能不变，
  /// 只是从“胶囊外面”挪到“胶囊里面”；校验逻辑也不变。
  Widget _buildAuthCapsule() {
    final _AddFormController form = _addForm!;
    return Stack(
      children: [
        // 头部（48）：图标 + “认证方式” + 展开箭头 + 方式小标签。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _capsuleHeight,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  key: const ValueKey('auth_expand_area'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _authExpanded = !_authExpanded),
                  child: Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 16),
                        child: Icon(
                          Icons.vpn_key,
                          color: Color(0xff9ab9c7),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text('认证方式', style: GlassText.valueStyle),
                      const Spacer(),
                      Icon(
                        _authExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: const Color(0xff9ab9c7),
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
              GestureDetector(
                key: const ValueKey('auth_method_chip'),
                onTap: () => setState(() {
                  _authMethod = _authMethod == _AuthMethod.password
                      ? _AuthMethod.key
                      : _AuthMethod.password;
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x3c9bc8d8)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _authMethod == _AuthMethod.password ? '密码' : '私钥',
                        style: GlassText.bodyStyle,
                      ),
                      const Icon(
                        Icons.arrow_drop_down,
                        color: Color(0xff9ab9c7),
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
        ),
        // 密码行（48）：在胶囊里面。
        // 分隔线不画在行容器上（Container 的 Border 会吃掉孩子 1dp 高，
        // 密码框会变成 47 高）——分隔线是单独的一条 1px 线，
        // 和行一起淡入淡出。
        Positioned(
          top: _capsuleHeight,
          left: 0,
          right: 0,
          height: _capsuleHeight,
          child: AnimatedOpacity(
            opacity: _authExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 260),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _buildCapsuleField(
                key: const ValueKey('add_password_field'),
                controller: form.password,
                hintText: '密码',
                icon: Icons.lock,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                obscureText: !_passwordVisible,
                borderless: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    _passwordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                    color: const Color(0xff9ab9c7),
                    size: 22,
                  ),
                  onPressed: () =>
                      setState(() => _passwordVisible = !_passwordVisible),
                ),
              ),
            ),
          ),
        ),
        // 私钥行（48）：同样在胶囊里面。
        Positioned(
          top: _capsuleHeight * 2,
          left: 0,
          right: 0,
          height: _capsuleHeight,
          child: AnimatedOpacity(
            opacity: _authExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 260),
            child: _buildKeyCapsule(form),
          ),
        ),
        // 口令行（48）：只在密钥方式时出现，同样在胶囊里面。
        // 密钥方式展开后胶囊 48→192，密码方式还是 48→144
        //（见 _capsuleHeightFor）；收起或密码方式时这行在胶囊
        // 高度外面，被胶囊的裁剪盖住，和 v10 收起的行一个道理。
        Positioned(
          top: _capsuleHeight * 3,
          left: 0,
          right: 0,
          height: _capsuleHeight,
          child: AnimatedOpacity(
            opacity:
                _authExpanded && _authMethod == _AuthMethod.key ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 260),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _buildCapsuleField(
                key: const ValueKey('add_passphrase_field'),
                controller: form.passphrase,
                hintText: '私钥口令（可选）',
                icon: Icons.password,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                obscureText: true,
                borderless: true,
              ),
            ),
          ),
        ),
        // 两条分隔线（各 1px，密码行顶边、私钥行顶边）：和行一起淡入淡出。
        // 不画在行容器上（Border 会吃掉孩子 1dp 高）。
        Positioned(
          top: _capsuleHeight,
          left: 16,
          right: 16,
          height: 1,
          child: AnimatedOpacity(
            opacity: _authExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 260),
            child: Container(color: const Color(0x2e9bc8d8)),
          ),
        ),
        Positioned(
          top: _capsuleHeight * 2,
          left: 16,
          right: 16,
          height: 1,
          child: AnimatedOpacity(
            opacity: _authExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 260),
            child: Container(color: const Color(0x2e9bc8d8)),
          ),
        ),
        // 第三条分隔线（口令行顶边）：只在密钥方式展开时出现。
        Positioned(
          top: _capsuleHeight * 3,
          left: 16,
          right: 16,
          height: 1,
          child: AnimatedOpacity(
            opacity:
                _authExpanded && _authMethod == _AuthMethod.key ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 260),
            child: Container(color: const Color(0x2e9bc8d8)),
          ),
        ),
      ],
    );
  }

  /// v9：私钥行（点一下选密钥文件）。file_picker 真接了：
  /// 选到文件只记文件名+路径（显示用），不读内容、不落盘；
  /// 点取消什么也不做；选文件出错给一句提示。
  /// v10：它不再是单独的胶囊，是认证方式胶囊里面的第二行
  ///（和密码行一起收进胶囊里）。
  Widget _buildKeyCapsule(_AddFormController form) {
    return GestureDetector(
      key: const ValueKey('key_pick_row'),
      behavior: HitTestBehavior.opaque,
      onTap: _pickKeyFile,
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 16),
            child: Icon(
              Icons.key,
              color: Color(0xff9ab9c7),
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          const Text('私钥', style: GlassText.valueStyle),
          const Spacer(),
          Flexible(
            child: Text(
              form.keyFilePath != null
                  ? (form.keyFileName ?? '已选文件')
                  : (form.savedKeyPem != null
                        ? '已保存的私钥（点一下更换）'
                        : '未选择，点一下选择文件'),
              style: GlassText.hintStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(
            Icons.chevron_right,
            color: Color(0xff9ab9c7),
            size: 22,
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  /// v9：选私钥文件。取消（null）什么也不做；只记文件名+路径。
  Future<void> _pickKeyFile() async {
    final _AddFormController? form = _addForm;
    if (form == null) return;
    try {
      final picker.PlatformFile? file = await picker.FilePicker.pickFile(
        type: picker.FileType.any,
      );
      if (file == null) return;
      setState(() {
        form.keyFileName = file.name;
        form.keyFilePath = file.path;
      });
    } catch (_) {
      _message('选择文件失败，请重试。');
    }
  }

  /// v8：胶囊里的输入框（#5 GlassTextField 的样式参数，抄进我们
  /// 自己的字段，不引 #5 的库）：48 高胶囊（圆角 24 = 高/2）、
  /// 内边距横 16 纵 12、文字 16sp 白 0.9、占位白 0.5、细边框
  /// 0x3c9bc8d8 1px、聚焦青 1.4。hintText（占位式），不再用
  /// floating label。fill 透明——玻璃由 overlay 的脸给。
  /// v10：borderless 给可扩张胶囊里面的行用（认证方式里的密码行）：
  /// 那行已经在胶囊里面了，不再画自己的圆角边框（不然边框贴着
  /// 胶囊边、里外两层框），只留文字+图标，横向内边距收成 4。
  Widget _buildCapsuleField({
    required Key key,
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    TextInputType? keyboardType,
    required TextInputAction textInputAction,
    bool obscureText = false,
    bool borderless = false,
    Widget? suffixIcon,
  }) {
    return DefaultSelectionStyle(
      cursorColor: const Color(0xff79e5ed),
      selectionColor: const Color(0x5579e5ed),
      child: TextField(
        key: key,
        controller: controller,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        obscureText: obscureText,
        autocorrect: false,
        style: GlassText.valueStyle,
        cursorColor: const Color(0xff79e5ed),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: GlassText.hintStyle,
          prefixIcon: Icon(icon, color: const Color(0xff9ab9c7)),
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: Colors.transparent,
          contentPadding: EdgeInsets.symmetric(
            horizontal: borderless ? 4 : 16,
            vertical: 12,
          ),
          enabledBorder: borderless
              ? InputBorder.none
              : const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                  borderSide: BorderSide(color: Color(0x3c9bc8d8), width: 1),
                ),
          focusedBorder: borderless
              ? InputBorder.none
              : const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                  borderSide: BorderSide(color: Color(0xff65dfe9), width: 1.4),
                ),
        ),
      ),
    );
  }

  /// v8：设置的胶囊（上→下，和 overlay 的 targets 一一对应）。
  /// 按 _settingsCapsuleKinds 列表生成：标题一个、提示一个、
  /// 高级设置一个，三个独立的胶囊，没有外框、没有标题栏。
  /// 标题是小胶囊条（图标 + “设置”，照 ServerBox 行的排法）；
  /// 提示是一句提示，等主人安排加什么。深色模式、主题风格、
  /// 终端字号、默认端口、主机指纹、离线地理定位那一节全拿掉
  /// （不是删功能，是先收起来——值还在 SharedPreferences /
  /// 默认值里，UI 以后再接）。
  /// v10：高级设置不再往外弹出一个提示胶囊——它自己向下扩张
  /// （48→88），提示收进胶囊里面；高度跟着展开态走，
  /// overlay 的脸同步长出来。
  List<Widget> _buildSettingsCapsules() {
    return <Widget>[
      for (int i = 0; i < _settingsCapsuleKinds.length; i++)
        _CapsuleStagger(
          key: ValueKey('stagger_settings_${_settingsCapsuleKinds[i].name}'),
          open: _morphOpen,
          begin: _capsuleStaggerWindowFor(_settingsCapsuleKinds[i], i).begin,
          end: _capsuleStaggerWindowFor(_settingsCapsuleKinds[i], i).end,
          // 高度跟着展开态走（高级设置展开时 88），
          // overlay 的脸同步长出来。
          child: SizedBox(
            width: _capsuleWidth,
            height: _capsuleHeightFor(_settingsCapsuleKinds[i]),
            child: _buildSettingsCapsuleContent(_settingsCapsuleKinds[i]),
          ),
        ),
    ];
  }

  /// 一个设置胶囊的内容（按种类分发；新种类加一个 case）。
  Widget _buildSettingsCapsuleContent(_SettingsCapsuleKind kind) {
    switch (kind) {
      case _SettingsCapsuleKind.title:
        // 标题胶囊：图标在左、“设置”在右（ServerBox 行的排法）。
        return const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(
                Icons.settings_rounded,
                color: Color(0xff9ab9c7),
                size: 22,
              ),
              SizedBox(width: 12),
              Text('设置', style: GlassText.valueStyle),
            ],
          ),
        );
      case _SettingsCapsuleKind.hint:
        return const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '设置内容正在整理，敬请期待。',
              style: GlassText.bodyStyle,
              textAlign: TextAlign.center,
              maxLines: 2,
            ),
          ),
        );
      case _SettingsCapsuleKind.advanced:
        return _buildAdvancedCapsule();
    }
  }

  /// v9：高级设置胶囊（可向下展开，像 ServerBox 的“SSH 高级”行）。
  /// 点一下展开、再点收起。
  /// v10：不再往外弹出一个提示胶囊——胶囊本身向下扩张（48→88），
  /// 提示收进胶囊里面（同一块连续玻璃内）。头部还是原来那行
  /// （图标 + “高级设置” + 展开箭头），下面的提示行 40 高，
  /// 上面一条细分隔线，展开时 260ms 淡入（和 overlay 的目标矩形
  /// 滑动同步），收起时淡出、被胶囊的裁剪盖住。高级里的具体内容
  /// 等主人定，机制先做出来。
  Widget _buildAdvancedCapsule() {
    return Stack(
      children: [
        // 头部（48）：图标 + “高级设置” + 展开箭头。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _capsuleHeight,
          child: GestureDetector(
            key: const ValueKey('advanced_expand_area'),
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                setState(() => _advancedExpanded = !_advancedExpanded),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: Icon(
                    Icons.tune,
                    color: Color(0xff9ab9c7),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Text('高级设置', style: GlassText.valueStyle),
                const Spacer(),
                Icon(
                  _advancedExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: const Color(0xff9ab9c7),
                  size: 22,
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
        // 提示行（40）：在胶囊里面。
        Positioned(
          top: _capsuleHeight,
          left: 0,
          right: 0,
          height: _advancedExpandedExtraHeight,
          child: AnimatedOpacity(
            opacity: _advancedExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 260),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: const Text(
                '高级设置内容待定。',
                style: GlassText.bodyStyle,
              ),
            ),
          ),
        ),
        // 分隔线（1px，提示行顶边）：和行一起淡入淡出。
        // 不画在行容器上（Border 会吃掉孩子 1dp 高）。
        Positioned(
          top: _capsuleHeight,
          left: 16,
          right: 16,
          height: 1,
          child: AnimatedOpacity(
            opacity: _advancedExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 260),
            child: Container(color: const Color(0x2e9bc8d8)),
          ),
        ),
      ],
    );
  }

  /// v8：保存（只校验，不落盘、不关面板——v7 的做法）。
  /// 没有 Form/validator：报错行会把字段顶高、撑出 48 的胶囊，
  /// 所以空着点保存只弹一句提示，不在字段下挂报错行。
  /// v9：认证字段的校验也接进来（按当前方式查密码或私钥）。
  /// v11：保存真的落盘了——建 ServerProfile（新建用时间戳 id，
  /// 编辑沿用原来的 id），写 SharedPreferences（ssh.profiles.v1），
  /// 凭据写 vault（key 和 _connect 读的对上），关面板、刷新地球仪、
  /// 弹一句确认。端口空着算 22、用户名空着算 root；城市不填，
  /// 保存时自动解析（IP 查库、域名先 DNS 再查库），查不到放默认
  /// 落点、不拦保存。写盘出错弹明确的错，不静默吞掉。
  Future<void> _saveAddForm() async {
    final _AddFormController? form = _addForm;
    if (form == null || _saving) return;
    final name = form.name.text.trim();
    final host = form.host.text.trim();
    if (name.isEmpty || host.isEmpty) {
      _message('请填写名称和地址。');
      return;
    }
    final portText = form.port.text.trim();
    final port = portText.isEmpty ? 22 : int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      _message('端口要在 1–65535 之间。');
      return;
    }
    final username = form.username.text.trim().isEmpty
        ? 'root'
        : form.username.text.trim();
    // 认证凭据（按当前方式只取对应的那一项；密钥内容是 PEM 文本，
    // 不是文件路径——_connect 读的是内容）。
    var password = '';
    var keyPem = '';
    var passphrase = '';
    if (_authMethod == _AuthMethod.password) {
      password = form.password.text;
      if (password.isEmpty) {
        _message('请填写密码。');
        return;
      }
    } else {
      passphrase = form.passphrase.text;
      if (form.keyFilePath != null) {
        final pem = await _readKeyFile(form.keyFilePath!);
        if (pem == null) {
          _message('无法读取私钥文件，请重新选择。');
          return;
        }
        if (!pem.contains('PRIVATE KEY')) {
          _message('请导入或粘贴有效的私钥 PEM。');
          return;
        }
        keyPem = pem;
      } else if (form.savedKeyPem != null && form.savedKeyPem!.isNotEmpty) {
        // 编辑时没换文件，沿用 vault 里已保存的私钥内容。
        keyPem = form.savedKeyPem!;
      } else {
        _message('请选择私钥文件。');
        return;
      }
    }
    _saving = true;
    try {
      final editing = _morph?.profile;
      final id =
          editing?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
      await _vault.write(
        key: '$id.password',
        value: _authMethod == _AuthMethod.password ? password : '',
      );
      await _vault.write(
        key: '$id.key',
        value: _authMethod == _AuthMethod.key ? keyPem : '',
      );
      await _vault.write(
        key: '$id.passphrase',
        value: _authMethod == _AuthMethod.key ? passphrase : '',
      );
      final saved = ServerProfile(
        id: id,
        name: name,
        host: host,
        port: port,
        username: username,
        city: '',
        authType: _authMethod == _AuthMethod.password ? 'password' : 'key',
      );
      final next = [..._profiles];
      final index = next.indexWhere((p) => p.id == id);
      if (index >= 0) {
        next[index] = saved;
      } else {
        next.add(saved);
      }
      await persistProfiles(next);
      final geo = await _resolveGeoForHost(host);
      if (!mounted) return;
      setState(() {
        _profiles = next;
        _selected = saved;
        _geoLocations[saved.id] = geo.location;
      });
      _closeMorphPanel?.call();
      _message(
        editing == null
            ? (geo.resolved ? '已保存' : '已保存，城市解析不到，已放在德国。')
            : (geo.resolved ? '已更新' : '已更新，城市解析不到，已放在德国。'),
      );
    } catch (e) {
      _message('保存失败：$e');
    } finally {
      _saving = false;
    }
  }

  /// v11：读私钥文件内容（PEM 文本）。读不出来返回 null，
  /// 调用处提示、不存空串假装存好了。
  Future<String?> _readKeyFile(String path) async {
    try {
      return await File(path).readAsString();
    } catch (_) {
      try {
        final bytes = await File(path).readAsBytes();
        return utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return null;
      }
    }
  }

  /// v11：编辑时把 vault 里已保存的凭据读回表单（原始源码
  /// ProfileEditor 的 _loadSecret 同款做法）：密码和口令直接
  /// 填进输入框；私钥内容留在 savedKeyPem 里，没换文件时保存沿用它，
  /// 私钥行显示“已保存的私钥（点一下更换）”。
  Future<void> _prefillEditSecrets(ServerProfile profile) async {
    final _AddFormController? form = _addForm;
    if (form == null) return;
    try {
      final password =
          await _vault.read(key: '${profile.id}.password') ?? '';
      final keyPem = await _vault.read(key: '${profile.id}.key') ?? '';
      final passphrase =
          await _vault.read(key: '${profile.id}.passphrase') ?? '';
      if (!mounted || _addForm != form) return;
      setState(() {
        form.password.text = password;
        form.passphrase.text = passphrase;
        if (keyPem.isNotEmpty) form.savedKeyPem = keyPem;
      });
    } catch (_) {
      // 凭据读不回来不拦编辑，保存时会重新校验。
    }
  }

  /// 弹一句提示（SnackBar，玻璃条样式）。
  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        content: _GlassChip(
          subtle: true,
          radius: 14,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Text(text),
          ),
        ),
      ),
    );
  }

  /// v11：长按地球仪上的服务器卡片 → 编辑 / 删除。
  Future<void> _showHostActions(ServerProfile profile) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(profile.name),
        content: Text('${profile.host}:${profile.port}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'edit'),
            child: const Text('编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (action == 'edit') {
      _openEditMorph(profile);
    } else if (action == 'delete') {
      await _delete(profile);
    }
  }

  /// v11：打开编辑（复用添加的胶囊面板，_openMorph 的 profile 参数
  /// 就是编辑入口，表单和认证方式按 profile 预填）。
  void _openEditMorph(ServerProfile profile) {
    final origin =
        _measureButton(_addButtonKey) ?? _fallbackOrigin(_MorphKind.add);
    _openMorph(_MorphKind.add, origin, profile);
  }

  /// v11：删服务器（原始源码的 _delete 原样复用）：先确认，
  /// 再清 vault 里它的三个 key、从列表里拿掉、写盘、刷新地球仪。
  Future<void> _delete(ServerProfile profile) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除服务器？'),
        content: Text('“${profile.name}”及其本机保存的凭据将被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _vault.delete(key: '${profile.id}.password');
    await _vault.delete(key: '${profile.id}.key');
    await _vault.delete(key: '${profile.id}.passphrase');
    final next = _profiles.where((p) => p.id != profile.id).toList();
    await _applyProfiles(next);
    if (_selected?.id == profile.id) {
      setState(() => _selected = next.isEmpty ? null : next.first);
    }
    _message('已删除 ${profile.name}。');
  }

  @override
  Widget build(BuildContext context) {
    final darkTheme = Theme.of(context).copyWith(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff3b82b4),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: Colors.black,
    );
    return Theme(
      data: darkTheme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.black,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.black,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
        child: Stack(
          children: <Widget>[
            Scaffold(
              backgroundColor: Colors.black,
              body: SafeArea(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : fluid.BackdropLayer(
                        backdrop: _globeBackdrop,
                        // 运动中半分辨率抓取（语义按 fluid_glass 的
                        // layer_backdrop.dart 核实）：motionPixelRatio 是绝对
                        // 像素比，与设备 DPR 直接比；地球转着、连续两帧都重抓
                        // 时才降到这个值，停下后下一帧补一张全分辨率抓取。
                        // 转着的时候玻璃本来就糊，看不出差别。
                        motionPixelRatio:
                            MediaQuery.devicePixelRatioOf(context) * 0.5,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _morphAnimating,
                          builder: (context, animating, child) => SshGlobe(
                            hosts: _profiles
                                .map(
                                  (p) => GlobeHost(
                                    id: p.id,
                                    name: p.name,
                                    address: p.host,
                                    city: p.city,
                                    location: _geoLocations[p.id]?.point,
                                    locationLabel: _geoLocations[p.id]?.label,
                                  ),
                                )
                                .toList(),
                            selectedId: _selected?.id,
                            // v14：会话面板打开期间，被点的那张卡片藏起来
                            // （v5 同款机制——它变成了面板，面板和真卡片不能
                            // 同时露在锚点处；主人 10:42 实锤：关闭瞬间卡片
                            // 已完整露着、面板还在缩小，两个玻璃层同时可见）。
                            // _morph 在 _openSessionMorph 里和 overlay 同一帧
                            // 置上，卡片同一帧藏起；关到底、overlay 卸载的
                            // 同一帧（_onMorphSettledClosed）_morph 清掉，
                            // 卡片同一帧回来。添加/设置面板的锚点是右下角按钮，
                            // 不是地球仪卡片，不走这里。
                            hiddenCardId:
                                _morph?.kind == _MorphKind.session
                                    ? _morph?.profile?.id
                                    : null,
                            // Morph 面板开着时地球降速慢转（3°/秒，正常 12°/秒的
                            // 25%），不停：面板在下面、上面绝大部分地球都没透过
                            // 玻璃，突然停了比较尴尬。
                            // v15：会话面板打开全程把地球彻底定住（不只是
                            // 动画那几百毫秒）：面板开着时卡片跟着地球慢转
                            // （3°/秒）漂走，关闭时面板缩回的是点开那一刻
                            // 的旧锚点，落点和卡片错开约 75dp（主人 10:56
                            // 两张图实锤）。_morph 是 session 且没开始关闭
                            // 时 autoRotate 全程 false；关到底、_morph 清掉
                            // 的同一帧（_onMorphSettledClosed）再恢复 12°/秒。
                            // v19：会话面板正在关闭（点 ×/空白开始关闭 →
                            // 关到底）时地球也要转——转速绑在 morph 的
                            // open 上（morphDrivenRotation + morphOpen），
                            // 点关闭那一刻开始爬，过渡结束时回到 12°/秒。
                            // autoRotate 在这段时间里为 true；面板开着
                            // （没开始关闭）时还是冻着（v15：卡片不能漂）。
                            // 添加/设置面板的锚点是右下角固定按钮，不受
                            // 地球转影响，不走这里。
                            autoRotate:
                                _sessionClosing ||
                                (!animating &&
                                    _morph?.kind != _MorphKind.session),
                            rotationSpeed:
                                (_morph == null || _sessionClosing) ? 12 : 3,
                            // v19：会话关闭过渡里转速由 morph 的 open
                            // 驱动（globe.dart 的 _morphFactor）；其余
                            // 时候走原来的时间斜坡。
                            morphDrivenRotation: _sessionClosing,
                            morphOpen: _morphOpen,
                            // v19：活锚点——地球仪把选中卡片的实时
                            // 全局矩形写进 _anchorCardRect，会话 morph
                            // 每帧读它当 origin。
                            anchorCardRect: _anchorCardRect,
                            // v18：相机回调只接测试出口，生产不传（见
                            // SshApp.onGlobeCameraChanged）。
                            onCameraChanged: widget.onGlobeCameraChanged,
                            // With the footer removed, a host card is the direct,
                            // uncluttered way to open that SSH connection.
                            // v13：点卡片直接开指令面板（不再进终端页）。
                            // v3：面板开着时点卡片不能误开第二个。
                            onSelected: (id) => _openSessionFor(id, null),
                            onSelectedAt: (id, position) =>
                                _openSessionFor(id, position),
                            // v11：长按卡片 → 编辑 / 删除（面板开着时不触发）。
                            onHostLongPress: (id) {
                              if (_morph != null) return;
                              final found = _profiles.where((p) => p.id == id);
                              if (found.isEmpty) return;
                              _showHostActions(found.first);
                            },
                          ),
                        ),
                      ),
              ),
            ),
            // v7：不再包交叉淡入（那就是闪光的凶手）——overlay 直接挂，
            // 关到底立刻卸载，被点的子按钮同一帧回来（见
            // _onMorphSettledClosed）。
            if (_morph != null) _buildMorphOverlay(),
            // v8：右下角只剩添加和设置两个胶囊按钮（SpeedDial 已拿掉，
            // 大 × 主按钮直接删掉——本来就只需要这两个，没必要收纳）。
            // 按钮放在 overlay 上面一层（Stack 里后放的在上面），
            // scrim 盖不到它们，面板开着时没被点的那个照样能点；
            // 被点的那个藏起来（IgnorePointer + Opacity 0），点按
            // 透到 scrim 去关面板（v5 的死区在 v8 里顺带修了——v7 是
            // SpeedDialChild 自己的 FAB 在 IgnorePointer 外面吞点按）。
            // 齿轮在上、+ 在下（v7 的顺序），间距 18（v7 是 12，
            // 主人让设置和添加之间的间隔稍微变大一点点，+6）。
            if (!_loading)
              Positioned(
                right: 16,
                bottom: 16 + MediaQuery.paddingOf(context).bottom,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _DialButton(
                      key: _settingsButtonKey,
                      glyphKey: const ValueKey('glass_settings_action'),
                      hidden: _settingsHidden,
                      icon: Icons.settings_rounded,
                      tooltip: '设置',
                      onTap: _openSettingsMorph,
                    ),
                    const SizedBox(height: 18),
                    _DialButton(
                      key: _addButtonKey,
                      glyphKey: const ValueKey('glass_add_action'),
                      hidden: _addHidden,
                      icon: Icons.add_rounded,
                      tooltip: '添加服务器',
                      onTap: _openAddMorph,
                    ),
                  ],
                ),
              ),
            // 首开预热（v3）：地球已在树上才画，画满 3 帧就拿掉。
            if (!_loading && _warmupFramesLeft > 0) _buildShaderWarmup(),
          ],
        ),
      ),
    );
  }
}

/// v8：右下角的胶囊按钮（+ / 齿轮），普通的 Material + InkWell，
/// 不再是 SpeedDial 的孩子。ValueNotifier 藏起/回来（v5 的机制，
/// 载体从 SpeedDial 孩子换成普通按钮）；IgnorePointer 包在最外层，
/// 藏起时点按透到下面的 scrim 去关面板（v5 的死区在 v8 里修了——
/// v7 是 SpeedDialChild 自己的 FAB 在 IgnorePointer 外面吞点按）。
/// key 是 GlobalKey（_measureButton 量锚点用）；glyphKey 是
/// ValueKey（测试定位 _GlassDialGlyph 用）。
class _DialButton extends StatelessWidget {
  const _DialButton({
    super.key,
    required this.glyphKey,
    required this.hidden,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final ValueKey<String> glyphKey;
  final ValueNotifier<bool> hidden;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: hidden,
      builder: (BuildContext context, bool isHidden, Widget? child) {
        return Opacity(
          opacity: isHidden ? 0.0 : 1.0,
          child: IgnorePointer(ignoring: isHidden, child: child),
        );
      },
      child: Tooltip(
        message: tooltip,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: _GlassDialGlyph(key: glyphKey, icon: icon),
          ),
        ),
      ),
    );
  }
}

class _GlassDialGlyph extends StatelessWidget {
  const _GlassDialGlyph({super.key, required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      height: 48,
      child: prism.LiquidGlass(
        style: GlassStyles.dialGlyph(),
        borderRadius: BorderRadius.circular(24),
        steadyFrost: true,
        shadows: const [BoxShadow(color: Color(0x5500cde5), blurRadius: 14)],
        child: Center(
          child: Icon(icon, color: const Color(0xffdaf9ff), size: 22),
        ),
      ),
    );
  }
}

/// 紧凑玻璃块：设置行、小按钮、提示条共用。玻璃只做点缀，不包整页。
class _GlassChip extends StatelessWidget {
  const _GlassChip({
    required this.child,
    this.radius = 18,
    this.subtle = false,
  });
  final Widget child;
  final double radius;
  final bool subtle;
  @override
  Widget build(BuildContext context) => prism.LiquidGlass(
    style: subtle ? GlassStyles.chipSubtle() : GlassStyles.chip(),
    borderRadius: BorderRadius.circular(radius),
    steadyFrost: true,
    shadows: const [
      BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4)),
    ],
    child: child,
  );
}

/// 一变多（v7）：胶囊框里的多个小胶囊（字段、保存按钮、设置提示）
/// 跟着 morph 长出来。淡入窗口对齐面板脸 alpha（(open-0.55)/0.45，
/// 55% 以后才进）：每个小胶囊有自己的开始/结束 open，自上而下
/// 依次进（名称 → 地址 → 保存），8px 上滑 + 淡入，不花哨。
/// 监听 _morphOpen（overlay 每帧 post-frame 写）；面板内容被
/// AnimatedBuilder 的 child 缓存了，不重建，所以小胶囊必须自己
/// 监听 notifier 才能逐帧动。收回时 open 下降，小胶囊在面板缩完
/// 之前先淡出（窗口反向走）。
class _CapsuleStagger extends StatelessWidget {
  const _CapsuleStagger({
    super.key,
    required this.open,
    required this.begin,
    required this.end,
    required this.child,
  });
  final ValueNotifier<double> open;
  final double begin;
  final double end;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: open,
      builder: (BuildContext context, double value, Widget? cachedChild) {
        final double t = ((value - begin) / (end - begin)).clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: cachedChild,
          ),
        );
      },
      child: child,
    );
  }
}

/// 文本输入框的玻璃内衬（v7：#5 GlassTextField 样式——深色玻璃、细边框、
/// 微高光、大圆角胶囊）：48 高、圆角 24 = 高/2（全胶囊），字段自己的
/// 边框负责描边（InputDecorationTheme，圆角 24），玻璃只提供磨砂 +
/// 淡色 + 一圈微高光（GlassStyles.field 的 rim .3）。
/// 用 ConstrainedBox(minHeight: 48) 而不是定死 48：校验报错行出现时
/// 字段要能长高（不然报错行直接溢出）；平时 48，报错时照样圆。
/// v22：首次启动地理数据下载弹窗（主人 2026-11-14 16:36：静默后台下载
/// “挺莫名其妙的”，要一个看得见的弹窗 + 进度条 + 失败重试）。
///
/// 只在本地完全没有地理数据时弹（模态：点外面关不掉、返回键也关不掉，
/// 要么等下完、要么点“取消”）；已有旧数据时不弹，走 v21 的静默后台更新。
/// 两个城市库合起来算一个总进度（manifest 里各文件字节数相加），
/// 不给每个文件各一个进度条。
/// 下完、SHA-256 校验通过、数据替换成功后自动关掉，地球仪随即解析位置；
/// 失败时显示一句原因 + “重试”按钮，点“重试”从头再下一次（不断点续传）；
/// 点“取消”停止下载、关弹窗，下次启动没数据再弹一次。
/// 样式复用 _GlassAlert（GlassStyles.panel 的玻璃 + 胶囊按钮那套）。
class _GeoFirstDownloadDialog extends StatefulWidget {
  const _GeoFirstDownloadDialog({required this.runner});

  /// 启动一次下载尝试：开弹窗时调一次，点“重试”时再调一次。
  /// [onProgress] 收合并进度；[isCancelled] 由下载方在块之间轮询。
  final GeoFirstDownloadRunner runner;

  @override
  State<_GeoFirstDownloadDialog> createState() =>
      _GeoFirstDownloadDialogState();
}

class _GeoFirstDownloadDialogState extends State<_GeoFirstDownloadDialog> {
  GeoDownloadProgress _progress = const GeoDownloadProgress(
    phase: GeoDownloadPhase.preparing,
  );
  String? _failure;
  bool _cancelled = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _startAttempt();
  }

  Future<void> _startAttempt() async {
    final attempt = ++_attempt;
    _cancelled = false;
    setState(() {
      _failure = null;
      _progress = const GeoDownloadProgress(
        phase: GeoDownloadPhase.preparing,
      );
    });
    final result = await widget.runner(
      onProgress: (p) {
        if (mounted && attempt == _attempt) {
          setState(() => _progress = p);
        }
      },
      isCancelled: () => _cancelled || attempt != _attempt,
    );
    if (!mounted || attempt != _attempt) return;
    if (result.cancelled) {
      // 用户点的取消：直接关弹窗（下次启动没数据再弹）。
      Navigator.of(context).pop(false);
      return;
    }
    if (result.hasData && result.error == null) {
      // 下完且可用（不论是新下的还是本来就有的）：自动关掉。
      Navigator.of(context).pop(true);
      return;
    }
    // 失败：留弹窗，显示一句原因 + “重试”。
    setState(() => _failure = _friendlyGeoDownloadError(result.error));
  }

  void _cancel() {
    _cancelled = true;
    // 弹窗立刻关掉（取消要灵敏）；下载方在下一个轮询点看到取消信号后
    // 停掉、清掉临时文件，晚到的结果不再有人消费。
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final failed = _failure != null;
    final totalKnown = _progress.totalBytes > 0;
    final description = failed
        ? _failure!
        : totalKnown
        ? '首次启动需要下载约 ${_formatGeoBytes(_progress.totalBytes)} 的 IP 位置数据，用于在地球仪上显示服务器所在位置。'
        : '正在连接服务器，准备下载 IP 位置数据……';
    final status = failed
        ? '下载失败，请重试。'
        : _progress.phase == GeoDownloadPhase.verifying ||
              (_progress.phase == GeoDownloadPhase.downloading &&
                  _progress.fraction >= 1)
        ? '正在校验数据…'
        : _progress.phase == GeoDownloadPhase.downloading
        ? '已下载 ${_formatGeoBytes(_progress.downloadedBytes)} / 共 ${_formatGeoBytes(_progress.totalBytes)}（${(_progress.fraction * 100).round()}%）'
        : _progress.phase == GeoDownloadPhase.done
        ? '下载完成'
        : '正在准备下载…';
    return _GlassAlert(
      key: const ValueKey('geo_download_dialog'),
      title: '首次启动 · 下载位置数据',
      caption: '下载后，服务器会在地球仪上显示真实位置',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            description,
            style: failed
                ? GlassText.bodyStyle.copyWith(
                    color: const Color(0xffff9d8a),
                  )
                : GlassText.bodyStyle,
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: const ValueKey('geo_download_bar'),
              value: failed
                  ? 0
                  : totalKnown
                  ? _progress.fraction
                  : null,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: .12),
              valueColor: const AlwaysStoppedAnimation<Color>(
                GlassText.accent,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            status,
            key: const ValueKey('geo_download_progress_text'),
            style: GlassText.captionStyle,
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('geo_download_cancel'),
          onPressed: _cancel,
          child: const Text('取消'),
        ),
        if (failed)
          FilledButton(
            key: const ValueKey('geo_download_retry'),
            onPressed: _startAttempt,
            child: const Text('重试'),
          ),
      ],
    );
  }
}

/// v22：下载量格式化（十进制 MB，和主人说的“约 26.5MB”一致；
/// 小文件按 KB/B 显示，测试用的合成数据集走这支）。
String _formatGeoBytes(int bytes) {
  if (bytes >= 1000000) {
    return '${(bytes / 1000000).toStringAsFixed(1)}MB';
  }
  if (bytes >= 1000) return '${(bytes / 1000).toStringAsFixed(0)}KB';
  return '$bytes B';
}

/// v22：下载失败的技术原因翻成一句人话（只给弹窗显示用，日志里仍是原值）。
String _friendlyGeoDownloadError(String? error) {
  final raw = error ?? '';
  if (raw.contains('SHA256') || raw.contains('SHA-256')) {
    return '下载的数据校验失败，请重试。';
  }
  if (raw.contains('HTTP')) return '下载失败（服务器返回错误），请检查网络后重试。';
  return '下载失败，请检查网络后重试。';
}

/// 玻璃弹窗：复用 _FormGlassPanel 的视觉语言（标题栏 + 青色竖条）。
class _GlassAlert extends StatelessWidget {
  const _GlassAlert({
    super.key,
    required this.title,
    required this.caption,
    required this.content,
    required this.actions,
  });
  final String title;
  final String caption;
  final Widget content;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    elevation: 0,
    insetPadding: const EdgeInsets.symmetric(horizontal: 24),
    child: _FormGlassPanel(
      title: title,
      caption: caption,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          content,
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                actions[i],
              ],
            ],
          ),
        ],
      ),
    ),
  );
}

class _FormGlassPanel extends StatelessWidget {
  const _FormGlassPanel({
    required this.title,
    required this.caption,
    required this.child,
  });
  final String title;
  final String caption;
  final Widget child;
  @override
  Widget build(BuildContext context) => prism.LiquidGlass(
    style: GlassStyles.panel(),
    borderRadius: BorderRadius.circular(24),
    steadyFrost: true,
    shadows: const [
      BoxShadow(color: Color(0x2000cfe8), blurRadius: 22, spreadRadius: 1),
      BoxShadow(color: Color(0x55000000), blurRadius: 16, offset: Offset(0, 7)),
    ],
    child: Container(
      padding: const EdgeInsets.fromLTRB(15, 16, 15, 17),
      decoration: BoxDecoration(
        color: const Color(0xff0c1b28).withValues(alpha: .50),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x5595d1e2), width: .9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 29,
                decoration: BoxDecoration(
                  color: const Color(0xff69e0eb),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(color: Color(0x9972e3ec), blurRadius: 9),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: GlassText.label,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: GlassText.caption),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

class _FormGlassSaveButton extends StatelessWidget {
  const _FormGlassSaveButton({required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('glass_form_save'),
    height: 48,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xff24829a), Color(0xff124d68)],
            ),
          ),
        ),
        prism.LiquidGlass(
          style: GlassStyles.save(),
          borderRadius: BorderRadius.circular(18),
          steadyFrost: true,
          shadows: const [
            BoxShadow(
              color: Color(0x3900d6e8),
              blurRadius: 20,
              offset: Offset(0, 5),
            ),
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 12,
              offset: Offset(0, 6),
            ),
          ],
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: const Color(0xff82eaf1).withValues(alpha: .58),
              ),
            ),
            child: FilledButton.icon(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Colors.transparent,
                foregroundColor: const Color(0xffeffdff),
                disabledBackgroundColor: Colors.transparent,
                disabledForegroundColor: const Color(0xffb8d1d9),
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存服务器'),
            ),
          ),
        ),
      ],
    ),
  );
}
