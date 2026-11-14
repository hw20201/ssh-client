import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';

/// v8：胶囊的表面色——open=0 时是按钮 tint（和真按钮一致），
/// open=1 时是胶囊的深色（和 GlassStyles.field() 的 tint 同色
/// 0xff0e2233，不再是 v7 面板的表面白 .62——v8 没有外框，
/// 胶囊本身就是深色玻璃，和 #5 的输入框一个颜色）。
/// 真按钮（_GlassDialGlyph + GlassStyles.dialGlyph）：
/// 玻璃 tint 0xff315b73 alpha .45（v10：.58→.45）、
/// 辉光 BoxShadow(0x5500cde5, blur 14, offset 0)、图标 22、色 0xffdaf9ff。
/// morph 脸原来在 open=0 时是表面白 0.3 + 黑阴影（v6 改成 alpha=open，
/// 关到底阴影是 0）——比真按钮亮（表面白）又比真按钮暗（没辉光），
/// 任何硬切或淡入淡出都露馅。所以表面色和阴影都从 open=0 的按钮值
/// 插值到 open=1 的胶囊值；纯函数，方便单元测试直接断言端点。
/// 诚实说明：这是两个不同玻璃引擎（fluid 的 DrawBackdrop vs prism 的
/// LiquidGlass）的参数对齐——颜色/模糊半径/偏移量对得上，但 haze/
/// rim/bevel 这些引擎内部项没法一一对应；像素级完全一致只能真机看，
/// 这里保证的是没有双层重叠、没有硬切、端点参数一致。

/// 按钮的青色辉光（和 _GlassDialGlyph 的 BoxShadow 同参数：
/// 0x5500cde5、blur 14、offset 0）。
final fluid.GlassShadow buttonGlowShadow = fluid.GlassShadow(
  radius: 14,
  offset: Offset.zero,
  color: const Color(0x5500cde5),
  alpha: 1.0,
);

/// morph 脸的阴影：open=0 时是锚点的阴影，open=1 时是胶囊的
/// 黑阴影（GlassShadow.standard）。中间 GlassShadow.lerp 走锚点→黑。
/// 默认锚点是按钮的青色辉光（buttonGlowShadow）——v6/v7 的做法：
/// 关到底时阴影不是 0，而是和真按钮一样的辉光，卸载那一刻真按钮
/// 带着同样的辉光出现，没有亮度台阶。添加/设置 morph 的锚点就是
/// 右下角胶囊按钮（本来就带着青色辉光），仍用这个默认值。
/// v17：会话 morph 的锚点是地球仪卡片，卡片没有青色辉光，只有一层
/// 淡黑阴影（globe.dart：黑 .13、blur 11、offset (0,4)）——脸在
/// open=0 时还带着青色辉光，overlay 一卸、亮→暗一闪，就是主人
/// 12:41 说的“高亮一下”。会话 morph 传 sessionAnchorShadow，
/// 辉光直接删掉，收尾暗到卡片水平再交接。
fluid.GlassShadow shadowForOpen(double open, [fluid.GlassShadow? anchor]) =>
    fluid.GlassShadow.lerp(
      anchor ?? buttonGlowShadow,
      fluid.GlassShadow.standard,
      open,
    );

/// morph 脸的表面色：open=0 时是锚点的玻璃 tint，open=1 时是胶囊的
/// 深色（0xff0e2233 alpha .38，和 v10 的 GlassStyles.field() 的
/// tint 一致）。默认锚点是按钮的玻璃 tint（0xff315b73 alpha .45，
/// 和 v10 的 GlassStyles.dialGlyph() 一致）。
/// v10：两端 alpha 各降一档（.58→.45、.55→.38），玻璃更透；
/// 两端仍和真按钮/胶囊的 tint 对齐，关到底交接没有亮度台阶。
/// v17：会话 morph 的锚点是地球仪卡片，tint 是卡片的深 slate
/// （0xff16242e alpha .42，和 GlassStyles.card() 一致）——脸在
/// open=0 时还是按钮的亮蓝 tint（0xff315b73），比卡片亮，收尾
/// 也是一道亮度台阶。会话 morph 传 sessionAnchorSurfaceColor。
Color surfaceColorForOpen(double open, [Color? anchor]) => Color.lerp(
  anchor ?? const Color(0xff315b73).withValues(alpha: .45),
  const Color(0xff0e2233).withValues(alpha: .38),
  open,
)!;

/// v17：会话 morph 的锚点玻璃（和地球仪卡片同值；单点来源在
/// GlassStyles.card() 与 globe.dart 卡片的 BoxShadow，这里只写
/// 死数值、注释里写明出处——改卡片玻璃时同步改这里）：
/// - 表面色：卡片 tint 0xff16242e alpha .42；
/// - 阴影：卡片的淡黑阴影（黑 .13、blur 11、offset (0,4)），没有青色辉光；
/// - 折射：高 12、量 18、色散关——小矩形（136×46）上强折射（量 28）
///   + 七波长分光会把亮背景聚到边缘，收尾那一下就是“高亮”；
///   卡片的 prism 折射是 20，脸的量 18 与之同档。
final Color sessionAnchorSurfaceColor =
    const Color(0xff16242e).withValues(alpha: .42);
final fluid.GlassShadow sessionAnchorShadow = fluid.GlassShadow(
  radius: 11,
  offset: const Offset(0, 4),
  // 黑 .13 编在颜色的 alpha 里（0x21 ≈ .129），alpha 字段留 1.0：
  // 渲染时有效透明度 = 颜色 alpha × alpha 字段，而 GlassShadow.lerp
  // 是颜色与 alpha 各自插值——.13 编在 alpha 字段里，插到标准阴影
  // （颜色黑 .1、alpha 1.0）的途中有效透明度会先升到 .31 再落回 .1，
  // 中间鼓一包；编在颜色里则有效透明度 .129→.102 单调，关闭时只暗不亮。
  color: const Color(0x21000000),
  alpha: 1.0,
);
const double sessionAnchorLensHeight = 12;
const double sessionAnchorLensAmount = 18;
const bool sessionAnchorChromaticAberration = false;

/// morph 脸的折射（lens）随 open 插值：高与量从锚点端滑到大面板端
/// （高 28、量 36）。默认锚点端是按钮的（高 16、量 28、色散开）；
/// 会话锚点端是卡片的（高 12、量 18、色散关，见上）。
/// 色散是布尔量，没法插值：锚点端要色散时全程开；锚点端不要色散时，
/// open ≥ 0.5 才开——收尾段（open < 0.5）色散是关的，亮往暗走；
/// 开关发生在脸还比较大的时候（open 0.5 附近），不留突然的亮闪。
/// 高与量都是 open 的单调函数：关闭时（open 减小）折射只暗不亮，
/// 没有跳变。
({double height, double amount, bool chromaticAberration}) lensForOpen(
  double open, {
  double anchorHeight = 16,
  double anchorAmount = 28,
  bool anchorChromatic = true,
}) => (
  height: ui.lerpDouble(anchorHeight, 28, open)!,
  amount: ui.lerpDouble(anchorAmount, 36, open)!,
  chromaticAberration: anchorChromatic || open >= 0.5,
);

/// 按钮变多个胶囊的 Morph（照抄 Fluid_Glass 演示的 _GlassMorph，
/// example/lib/catalog/destinations/lab_morph_content.dart）：
/// 两个 SpringValue _x/_y 驱动，矩形按 x 插左右边、按 y 插上下边，
/// 玻璃质感（blur/lens/表面色）随 open 同步插值，按钮脸与胶囊脸交叉淡入淡出，
/// 半途点 scrim 掉头，全部是弹簧重定向，不是时间线动画。
///
/// 与演示不同的地方（主人已定）：
/// - 目标不是一个面板矩形，而是多个胶囊矩形（个数跟着字段列表走：
///   添加名称/地址/IP/保存，设置标题/提示），各自独立、没有外框；
///   每个胶囊有自己的一张玻璃脸（DrawBackdrop），从按钮矩形插值到
///   自己的目标矩形；第 0 个胶囊是主脸（从 open=0 起就带着按钮的
///   玻璃长出来），其余胶囊的脸按窗口淡入——open=0 时只有一个脸，
///   不会三层叠加变亮（v6 的教训）；
/// - target 会变（键盘弹起），每个胶囊各有一根 260ms 的 RectTween
///   把目标矩形的变化滑过去（原来 AnimatedPositioned 的作用），不跳变；
/// - 没有标题栏了，拖回随之没了，关闭只走 scrim 点按和主页的 _closeMorph。
class GlassMorphOverlay extends StatefulWidget {
  const GlassMorphOverlay({
    super.key,
    required this.backdrop,
    required this.origin,
    required this.originRadius,
    required this.targets,
    required this.targetRadius,
    required this.anchor,
    required this.panelBuilder,
    required this.onSettledClosed,
    this.animating,
    this.openNotifier,
    this.liveOrigin,
    this.onCloseStarted,
    this.faceWindows,
    this.anchorSurfaceColor,
    this.anchorShadow,
    this.anchorLensHeight = 16,
    this.anchorLensAmount = 28,
    this.anchorChromaticAberration = true,
  });

  /// 要折射的画面（主页地球的 LayerBackdrop）。
  final fluid.Backdrop backdrop;

  /// 点按时实测的按钮全局矩形（anchor 态的起点）。
  final Rect origin;

  /// 按钮的圆角（88x48 胶囊按钮 → 24 = 高/2）。
  final double originRadius;

  /// 每个胶囊的目标矩形（上→下，和 panelBuilder 返回的列表一一对应）。
  /// 个数跟着字段列表走（添加名称/地址/IP/保存，设置标题/提示）。
  final List<Rect> targets;

  /// 所有胶囊的圆角（v8：18——ServerBox 行的圆角矩形，不是全圆药丸；
  /// 按钮 88x48 是药丸形 24，变形时圆角从 24 插到 18）。
  final double targetRadius;

  /// 按钮脸：morph 自己画的 + / 齿轮图标（22、色 0xffdaf9ff，
  /// 与真按钮 _GlassDialGlyph 的字形一致）。只画在第 0 个胶囊的
  /// 脸上（主脸）；被点的真按钮在点按瞬间隐藏，不先缩走——同一块
  /// 玻璃从头到尾只有 morph 在画按钮脸。
  final Widget anchor;

  /// 每个胶囊的内容（上→下，和 targets 一一对应）。close 是 overlay
  /// 自己的弹簧关闭（保存成功走它；没有标题栏了，拖回也随之没了，
  /// 关闭只走 scrim 点按和主页的 _closeMorph）。
  final List<Widget> Function(BuildContext context, VoidCallback close)
  panelBuilder;

  /// 双弹簧在关闭态（_open == false）都回到 0 后通知一次，
  /// 主页再把 _morph 从树上拿掉。
  final VoidCallback onSettledClosed;

  /// v6：弹簧在走时（打开/关闭）通知主页——主页用它在动画期间
  /// 把地球 ticker 停掉（背景不再每帧重抓），停稳后恢复。由 overlay
  /// 在 _motion 的监听里写，只在 true/false 翻转时才通知一次。
  final ValueNotifier<bool>? animating;

  /// v7：一变多——overlay 把当前 open（胶囊脸 alpha 的自变量）每帧
  /// 写给主页的 notifier，胶囊里的多个小胶囊（字段、保存按钮、设置
  /// 提示）监听它依次淡入。写在 post-frame 回调里（见 _syncAnimating
  /// 的注释），不能在 build 里直接写（ValueListenableBuilder 是
  /// 兄弟子树，build 中写 notifier 会抛 markNeedsBuild called
  /// during build）。滞后一帧（约 11ms），看不出来。
  final ValueNotifier<double>? openNotifier;

  /// v19：活锚点——锚点矩形的实时值（主页传进来，地球仪每帧把选中
  /// 卡片的布局矩形写进去）。传了它，build 里矩形插值和提前交接
  /// 都用这个值，不用固定的 widget.origin；关闭过渡里地球转起来、
  /// 卡片漂走，脸跟着卡片走，落点不错开。没传时用 widget.origin
  /// （添加/设置 morph 的锚点是右下角固定按钮，不漂，不用活锚点）。
  /// 只读 .value，不监听；overlay 本来就每帧因弹簧重建，读到的
  /// 就是最新值。
  final ValueNotifier<Rect>? liveOrigin;

  /// v19：关闭开始的通知（_close 里弹簧真正开始往 0 走时调一次）。
  /// 主页用它在点 ×/空白开始关闭的那一刻就让地球开始加速（转速
  /// 绑在 morph 的 open 上），而不是等关到底才恢复。
  final VoidCallback? onCloseStarted;

  /// 每个胶囊的玻璃脸淡入窗口（open 值，和内容 _CapsuleStagger
  /// 的窗口对齐）。第 0 个胶囊是主脸（begin==end 时恒为 1，
  /// 从 open=0 起就带着按钮的玻璃长出来）；其余胶囊的脸跟着
  /// 自己的窗口淡入——open=0 时只有一个脸（不会三层叠加变亮），
  /// 长开了三个脸才各自到位。没传时默认全部恒为 1。
  final List<({double begin, double end})>? faceWindows;

  /// v17：锚点端的玻璃（open=0 时脸的表面色/阴影/折射）。
  /// 不传时是按钮那套（表面 0xff315b73 α.45、青色辉光、折射
  /// 高 16/量 28/色散开）——添加/设置 morph 的锚点是右下角胶囊
  /// 按钮，本来就长这样，不动。
  /// 会话 morph 的锚点是地球仪卡片，传卡片那套（见
  /// sessionAnchorSurfaceColor / sessionAnchorShadow /
  /// sessionAnchorLensHeight / sessionAnchorLensAmount /
  /// sessionAnchorChromaticAberration），收尾暗到卡片水平再交接。
  final Color? anchorSurfaceColor;
  final fluid.GlassShadow? anchorShadow;
  final double anchorLensHeight;
  final double anchorLensAmount;
  final bool anchorChromaticAberration;

  @override
  State<GlassMorphOverlay> createState() => _GlassMorphOverlayState();
}

class _GlassMorphOverlayState extends State<GlassMorphOverlay>
    with TickerProviderStateMixin {
  late final fluid.SpringValue _x = fluid.SpringValue(
    vsync: this,
    value: 0,
    visibilityThreshold: 0.001,
  );
  late final fluid.SpringValue _y = fluid.SpringValue(
    vsync: this,
    value: 0,
    visibilityThreshold: 0.001,
  );
  late final fluid.InteractiveHighlight _press =
      fluid.InteractiveHighlight(vsync: this);
  late final AnimationController _targetController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late List<RectTween> _targetTweens = <RectTween>[
    for (final Rect target in widget.targets)
      RectTween(begin: target, end: target),
  ];
  late final Listenable _motion = Listenable.merge(<Listenable>[
    _x,
    _y,
    _targetController,
  ]);

  bool _open = false;
  bool _closeNotified = false;

  /// v18：收尾提前交接的回调只排一次（见 build 里的锚点贴合检查）。
  bool _earlySettleScheduled = false;

  /// 这一帧 build 算出来的 open（builder 里写，post-frame 回调里读
  /// 了写给 openNotifier）。
  double _lastOpen = 0;

  // 弹簧参数原样照抄演示（springOf(dampingRatio, stiffness)，
  // mass 1，damping = 2 * ratio * sqrt(stiffness)）。
  // SpringDescription 是 Flutter 的 package:flutter/physics.dart 里的类，
  // 这里用类型推断，不另 import。
  static final _openX = fluid.springOf(0.82, 420);
  static final _openY = fluid.springOf(0.72, 230);
  static final _closeX = fluid.springOf(0.88, 300);
  static final _closeY = fluid.springOf(0.92, 520);

  @override
  void initState() {
    super.initState();
    // v6：弹簧/目标动画在走时通知主页（见 animating）——主页在动画期间
    // 把地球停掉，背景不再每帧重抓；停稳后恢复慢转。_motion 每帧都
    // 通知，_syncAnimating 只在 true/false 翻转时才写 notifier，
    // 所以每轮动画最多两次重建，不会每帧都动主页。
    _motion.addListener(_syncAnimating);
    // 面板只在点按后才挂上树，所以一创建就直接打开——创建即点按，
    // 不需要演示那种“点按钮脸再开”的第二步。
    _open = true;
    _x.animateTo(1, _openX);
    _y.animateTo(1, _openY);
    _syncAnimating();
  }

  /// 弹簧/目标动画是不是在走（_x/_y 的 ticker 在跑，或 260ms 的
  /// RectTween 在走）。只在翻转时写 notifier，而且统一推迟到这一帧
  /// 画完后（post-frame）再写——_syncAnimating 可能在 build 阶段
  /// 被触发（initState 里直接调、didUpdateWidget 里 forward），
  /// 那时直接写 notifier 会让 ValueListenableBuilder 在 build 中
  /// 被 markNeedsBuild（它和 overlay 是兄弟子树，不在当前 building
  /// 的祖先链上，框架直接抛错，24 个测试就是这么挂的）。
  /// 推迟一帧再冻地球：动画才开始 1 帧（约 11ms），无影响；
  /// 回调里重新算当前值，所以翻转不会丢。
  bool _syncScheduled = false;

  void _syncAnimating() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      final bool animating =
          _x.isAnimating || _y.isAnimating || _targetController.isAnimating;
      final ValueNotifier<bool>? target = widget.animating;
      if (target != null && target.value != animating) {
        target.value = animating;
      }
      // v7：一并把这一帧的 open 写出去（读 _lastOpen：builder 在
      // 同一帧的 build 阶段已经把它更新到最新值）。
      final ValueNotifier<double>? openTarget = widget.openNotifier;
      if (openTarget != null && openTarget.value != _lastOpen) {
        openTarget.value = _lastOpen;
      }
    });
  }

  @override
  void didUpdateWidget(covariant GlassMorphOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 目标矩形变了（键盘弹起/收起，整组胶囊上下移）：每根 RectTween
    // 都从当前显示值滑向新目标，260ms，不跳变。个数变了（理论上
    // 不会发生：一个 overlay 实例只对应一种面板）就整组重建。
    final bool targetsChanged =
        widget.targets.length != oldWidget.targets.length ||
        widget.targets.asMap().entries.any(
          (entry) => entry.value != oldWidget.targets[entry.key],
        );
    if (targetsChanged) {
      _targetTweens = <RectTween>[
        for (int i = 0; i < widget.targets.length; i++)
          RectTween(
            begin: i < _targetTweens.length
                ? _targetTweens[i].evaluate(_targetController)
                : widget.targets[i],
            end: widget.targets[i],
          ),
      ];
      _targetController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _motion.removeListener(_syncAnimating);
    _x.dispose();
    _y.dispose();
    _press.dispose();
    _targetController.dispose();
    super.dispose();
  }

  /// 当前显示的目标矩形（target 变化时 260ms 滑过去的中间值）。
  /// RectTween.evaluate 返回可空，但 begin/end 都给了 target，不会是 null。
  List<Rect> get _displayTargets => <Rect>[
    for (final RectTween tween in _targetTweens)
      tween.evaluate(_targetController) ?? widget.targets.first,
  ];

  void _openPanel() {
    if (_open) return;
    setState(() => _open = true);
    _x.animateTo(1, _openX);
    _y.animateTo(1, _openY);
  }

  void _close({double velocity = 0}) {
    if (!_open && _x.value == 0 && _y.value == 0) {
      _notifyClosedIfSettled();
      return;
    }
    // v19：真正开始关闭（之前是开着的）就通知主页——点 ×/空白
    // 开始关闭的那一刻，地球就开始加速（转速绑在 morph 的 open
    // 上），不要等关到底才恢复。半途掉头（开着一半点关闭）也算
    // 关闭开始，一样通知。
    final bool wasOpen = _open;
    // v18：新一轮关闭，提前交接的回调可以再排。
    _earlySettleScheduled = false;
    setState(() => _open = false);
    if (wasOpen) widget.onCloseStarted?.call();
    // 半途掉头：从当前值和当前速度重定向回 0（演示原样，
    // x 带 0.55 倍速、y 带全速）。
    _x.animateTo(0, _closeX, withVelocity: velocity * 0.55);
    _y.animateTo(0, _closeY, withVelocity: velocity);
    _x.whenSettled(_notifyClosedIfSettled);
    _y.whenSettled(_notifyClosedIfSettled);
  }

  void _notifyClosedIfSettled() {
    if (_open || _closeNotified) return;
    if (_x.value != 0 || _y.value != 0) return;
    _closeNotified = true;
    widget.onSettledClosed();
  }

  /// 第 i 个胶囊的玻璃脸透明度：主脸（窗口 begin==end）恒为 1；
  /// 其余按窗口从 open 插值（和内容 _CapsuleStagger 的窗口对齐）。
  double _faceAlpha(int i, double open) {
    final List<({double begin, double end})>? windows = widget.faceWindows;
    if (windows == null || i >= windows.length) return 1.0;
    final ({double begin, double end}) window = windows[i];
    if (window.end <= window.begin) return 1.0;
    return ((open - window.begin) / (window.end - window.begin))
        .clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // 胶囊的内容只建一次：panelBuilder 在外层 build 调一次，
    // AnimatedBuilder 的 builder 每帧只重算矩形/形状/透明度，不重建
    // 内容（演示是每帧建 panel，我们的表单重，用闭包缓存；close 是
    // 稳定的 tear-off）。
    final List<Widget> panelChildren = widget.panelBuilder(context, _close);
    return AnimatedBuilder(
      animation: _motion,
      builder: (BuildContext context, Widget? _) {
        final double x = _x.value;
        final double y = _y.value;
        final double open = math.min(x, y).clamp(0.0, 1.0);
        // v7：这一帧的 open 记下来，post-frame 回调里写给 openNotifier。
        _lastOpen = open;
        final List<Rect> displayTargets = _displayTargets;
        // 脸的交叉淡入淡出（演示原样）：按钮脸在前 30% 淡出。
        final double anchorAlpha = (1 - open / 0.3).clamp(0.0, 1.0);
        final bool resting = x == 0 && y == 0 && !_open;

        final List<Widget> faces = <Widget>[];
        for (int i = 0; i < displayTargets.length; i++) {
          final Rect target = displayTargets[i];
          // v19：活锚点——传了 liveOrigin 就用实时矩形（地球仪每帧
          // 把选中卡片的布局矩形写进去），关闭过渡里地球转起来、
          // 卡片漂走，脸跟着卡片走；没传时用固定的 widget.origin。
          final Rect origin = widget.liveOrigin?.value ?? widget.origin;
          // 矩形插值：x 插左右边、y 插上下边（演示原样）。
          final Rect rect = Rect.fromLTRB(
            ui.lerpDouble(origin.left, target.left, x)!,
            ui.lerpDouble(origin.top, target.top, y)!,
            ui.lerpDouble(origin.right, target.right, x)!,
            ui.lerpDouble(origin.bottom, target.bottom, y)!,
          );
          // v18：收尾提前交接——主脸已经贴到锚点（四边都在 1dp 内）
          // 就立刻交接，别等弹簧爬完 0.001 的收敛阈值。实测（v18
          // 诊断）：关闭 X 弹簧（0.88/300）到 0.001 要约 0.45 秒，
          // 脸在第 20 帧就贴到锚点了，overlay 却到第 32 帧才卸——
          // 中间 12 帧（192ms）脸停在按钮上不动、卡片还藏着、地球
          // 还冻着，就是主人说的“莫名其妙顿了一下”。这里钉到 0
          // 只改 < 1dp 的矩形，肉眼看不出；回调里再验一遍 _open
          // （半途点脸重开会把它翻回 true，那时不许钉）。
          // v19：贴合检查对的也是活锚点（origin 是实时值），脸追着
          // 漂走的卡片贴上去，交接那一刻脸和卡片严丝合缝。
          if (i == 0 && !_open && !_closeNotified && !_earlySettleScheduled) {
            if ((rect.left - origin.left).abs() <= 1.0 &&
                (rect.top - origin.top).abs() <= 1.0 &&
                (rect.right - origin.right).abs() <= 1.0 &&
                (rect.bottom - origin.bottom).abs() <= 1.0) {
              _earlySettleScheduled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _closeNotified || _open) return;
                _x.snapTo(0);
                _y.snapTo(0);
                _notifyClosedIfSettled();
              });
            }
          }
          // v8：按钮和胶囊同高 48、圆角都是 24，插值全程不变；
          // clamp 是兜底（rect.shortestSide/2 = 24）。
          final double radius = math.min(
            ui.lerpDouble(widget.originRadius, widget.targetRadius, open)!,
            rect.shortestSide / 2,
          );
          final fluid.RoundedRectangularShape shape = fluid.RoundedRectangle(
            radius,
          );
          final double faceAlpha = _faceAlpha(i, open);

          Widget face = Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              // 按钮脸只画在主脸（第 0 个胶囊）上，居中。
              if (i == 0 && anchorAlpha > 0)
                Center(
                  child: Opacity(
                    opacity: anchorAlpha,
                    child: Transform.scale(
                      scale: 1 - 0.25 * (1 - anchorAlpha),
                      child: widget.anchor,
                    ),
                  ),
                ),
              // 内容常驻树上，不用 if (panelAlpha > 0) 守门：open < 0.55
              // 时内容自己的 _CapsuleStagger 已经是 0；藏靠它，
              // 挡点按靠下面的 IgnorePointer。
              // OverflowBox 对齐到目标矩形（v7 的做法）：内容全尺寸
              // （240x48），变形中靠脸的 ClipPath 逐步露出。
              OverflowBox(
                alignment: Alignment.center,
                minWidth: target.width,
                maxWidth: target.width,
                minHeight: target.height,
                maxHeight: target.height,
                child: IgnorePointer(
                  // 未展开时挡住点按（演示原样：!_open || open < 0.9）。
                  ignoring: !_open || open < 0.9,
                  child: Material(
                    // 添加表单的 TextField 需要它（0×0 修复时补的兜底）。
                    type: MaterialType.transparency,
                    child: panelChildren[i],
                  ),
                ),
              ),
            ],
          );
          face = ClipPath(clipper: fluid.GlassShapeClipper(shape), child: face);

          // 主脸带按压高光 + 关到一半时点缩回去的按钮脸再打开
          // （演示原样）；其余脸只吸住点按，不让它落到下面的 scrim
          // 去关面板（字段、保存按钮在它下面，先命中，不受影响）。
          final bool canPress = resting || (!_open && open < 0.05);
          if (i == 0) {
            face = _press.wrapOverlay(
              child: GestureDetector(
                behavior: _open
                    ? HitTestBehavior.opaque
                    : HitTestBehavior.deferToChild,
                // 脸上的空白玻璃要吸住点按，不让它落到下面的 scrim 去关面板
                // （演示靠整面拖拽的 recognizer 挡，我们的拖只挂标题栏，
                // 所以这里补一个空 onTap 吸住它；再深的控件——输入框、
                // 保存按钮——都在它下面，先命中，不受影响）。
                onTap: () {},
                child: fluid.DragInspector(
                  behavior: HitTestBehavior.translucent,
                  onDragStart: canPress
                      ? (Offset p, Size _) => _press.handleDown(p)
                      : null,
                  onDrag: canPress
                      ? (Offset p, Offset _, Size _) => _press.handleMove(p)
                      : null,
                  onDragEnd: _press.handleUp,
                  onDragCancel: _press.handleUp,
                  // 关到一半时点缩回去的按钮脸，把它再打开（演示原样）。
                  onTap: canPress ? _openPanel : null,
                  child: face,
                ),
              ),
            );
          } else {
            face = GestureDetector(
              behavior: _open
                  ? HitTestBehavior.opaque
                  : HitTestBehavior.deferToChild,
              onTap: () {},
              child: face,
            );
          }

          // 玻璃质感随 open 同步插值（演示原样）：
          // v10：blur 2→10 改成 1.5→8（更少磨砂、更透），
          // lens 折射高度 12→22 改成 16→28、折射量 24→30 改成 28→36，
          // 再开 chromaticAberration（七波长分光、棱镜色散边），
          // 折射更看得出来；表面色 v8 改成
          // surfaceColorForOpen（按钮 tint → 胶囊深色）。
          // 注意：色散走的是另一支 shader 程序（RefractionWithDispersion），
          // 首开预热（main.dart 的 _buildShaderWarmup）也要用同样的
          // lens 参数去编译它，不然第一次点开会在现场编译、冻一帧。
          // v17：锚点端的玻璃改成可传参（表面色/阴影/折射都从 widget
          // 的 anchor* 读，默认还是按钮那套）——会话 morph 的锚点是
          // 地球仪卡片，传卡片那套，收尾段折射量与高度滑到卡片水平、
          // 色散关掉、辉光删掉，亮往暗走，交接那一帧没有亮度跳变。
          final Widget glass = fluid.DrawBackdrop(
            backdrop: widget.backdrop,
            shape: () => shape,
            // v7：阴影从按钮辉光插值到面板黑阴影（见 shadowForOpen）——
            // v6 的 alpha=open 在这里被取代：v6 关到底时阴影是 0，
            // 真按钮却带着青色辉光出现，亮度对不上；v7 关到底时阴影
            // 就是按钮的辉光（同色同 blur 同 offset），卸载那一刻真
            // 按钮带着同样的辉光出现，没有亮度台阶。打开时阴影跟着
            // 胶囊从辉光过渡到黑阴影。
            // v17：会话 morph 的锚点阴影是卡片的淡黑阴影（没有辉光），
            // 见 shadowForOpen 的 anchor 参数。
            shadow: () => shadowForOpen(open, widget.anchorShadow),
            effects: (fluid.BackdropEffectScope scope) {
              final lens = lensForOpen(
                open,
                anchorHeight: widget.anchorLensHeight,
                anchorAmount: widget.anchorLensAmount,
                anchorChromatic: widget.anchorChromaticAberration,
              );
              scope
                ..vibrancy()
                ..blur(ui.lerpDouble(1.5, 8, open)!)
                ..lens(
                  lens.height,
                  lens.amount,
                  chromaticAberration: lens.chromaticAberration,
                );
            },
            onDrawSurface: (Canvas canvas, Size size) => canvas.drawRect(
              Offset.zero & size,
              Paint()
                ..color = surfaceColorForOpen(
                  open,
                  widget.anchorSurfaceColor,
                ),
            ),
            isolateSurface: false,
            repaint: _press,
            child: face,
          );
          // 主脸恒为 1，不包 Opacity（省一层）；其余脸按窗口淡入。
          faces.add(
            Positioned.fromRect(
              rect: rect,
              child: faceAlpha >= 1.0
                  ? glass
                  : Opacity(opacity: faceAlpha, child: glass),
            ),
          );
        }

        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // scrim：全屏（v4：v3 只盖到面板底边，面板下面那块大黑区
            // ——面板底边到屏底约 430px——根本没有 scrim，点那里什么
            // 反应都没有，主人 2026-11-13 18:05 录屏实锤；v2 的全屏
            // scrim 是对的，改回来。0×0 修复保留：scrim 仍是
            // Positioned，有明确边界；overlay 的 Stack 没有非定位子
            // 节点时按 constraints.biggest 取满屏，Positioned.fill
            // 盖满它。两个胶囊按钮是主页 Stack 里 overlay 之上的
            // Positioned（v8：SpeedDial 已拿掉，按钮不再住在
            // OverlayEntry 里，改放 overlay 上面一层），scrim 盖不到
            // 它们，照样能点；被点的那个面板打开时是藏起来的
            // （IgnorePointer + Opacity 0），点按透到 scrim 去关面板。
            if (open > 0.001 || _open)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _open ? _close : null,
                  child: ColoredBox(
                    color: const Color(0xFF000000)
                        .withValues(alpha: 0.22 * open),
                  ),
                ),
              ),
            ...faces,
          ],
        );
      },
    );
  }
}
