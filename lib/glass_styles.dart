import 'package:fluid_glass/fluid_glass.dart' as fluid;
import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

/// 全 App 共用的液态玻璃样式：只用这一套 token（深青 tint + 青色高光），
/// 不再各处各一套。
///
/// v10（主人 2026-11-13 22:08：玻璃再透明一点、折射再明显一点）：
/// 全套 tint alpha 下调（更透）、haze/blur 下调（更少磨砂）、
/// refraction/dispersion/rim 上调（折射更明显、色散与边缘高光更强）。
/// 文字清晰度不靠玻璃兜底——GlassText 的 value/label/body/hint/
/// caption 都加了一层淡黑阴影（sheetTitle 原来就有）。
/// 每项的改前值都记在下面各样式的注释里，方便回退。
///
/// 生效前提（已按 prism_ui 5d8ed7ab 源码核实）：
/// - 必须走 PrismApp(liquidGlass: ultra) + LiquidGlassHost + Impeller 才是
///   完整 shader 路径；standard 会强制 dispersion = 0、haze = 0。
/// - refraction 有效上限 = 窗格短边 / 2；bevel 有效上限 = 短边 / 4。
///   下面每个样式的数值都按它实际使用的窗格尺寸取在上限之内，避免“调了白调”。
/// - dispersion 只在边缘 10dp 内可见；contrast 在 tint.a == 1 时失效。
abstract final class GlassStyles {
  /// 表单区段面板（大窗格，短边 > 200dp）：双层磨砂 + 轻折射。
  /// v10：tint .46→.36、blur 2.5→2、haze .38→.28、
  /// refraction 40→48、dispersion 2→3、rim .45→.55。
  static prism.LiquidGlassStyle panel() => prism.LiquidGlassStyle(
    tint: const Color(0xff173246).withValues(alpha: .36),
    contrast: -.16,
    blur: 2,
    haze: .28,
    hazeBlur: 14,
    refraction: 48,
    bevel: 16,
    saturation: 1.4,
    rim: .55,
    rimWidth: 1.1,
    rimTail: .15,
    rimFocus: .4,
    dispersion: 3,
    hairline: .22,
  );

  /// 紧凑玻璃块（设置行、小按钮、提示条；行高约 56~72dp，半短边 ~28）。
  /// v10：tint .55→.42、blur 2→1.5、haze .3→.2、
  /// refraction 12→18、新增 dispersion 2、rim .4→.5、rimWidth 1→1.2。
  static prism.LiquidGlassStyle chip() => prism.LiquidGlassStyle(
    tint: const Color(0xff173246).withValues(alpha: .42),
    contrast: -.16,
    blur: 1.5,
    haze: .2,
    hazeBlur: 12,
    refraction: 18,
    bevel: 6,
    saturation: 1.35,
    rim: .5,
    rimWidth: 1.2,
    rimTail: .12,
    dispersion: 2,
    hairline: .22,
  );

  /// 低调版（说明性行、提示条）：更薄的 tint、更轻的磨砂。
  /// v10：tint .32→.24、blur 1.5→1、haze .25→.18、
  /// refraction 10→14、新增 dispersion 1、rim .3→.38。
  static prism.LiquidGlassStyle chipSubtle() => prism.LiquidGlassStyle(
    tint: const Color(0xff173246).withValues(alpha: .24),
    contrast: -.1,
    blur: 1,
    haze: .18,
    hazeBlur: 9,
    refraction: 14,
    bevel: 5,
    saturation: 1.25,
    rim: .38,
    rimWidth: .9,
    dispersion: 1,
    hairline: .18,
  );

  /// 文本输入框内衬（v7：#5 GlassTextField 样式——字段自己的边框负责
  /// 描边；圆角 24 与 InputDecorationTheme 的边框半径一致；rim .3 +
  /// hairline .18 是一圈微高光，对应 #5 的白 12% 定向 glow）。
  /// v10：tint .45→.38、blur 1.5→1、haze .25→.18、
  /// refraction 8→14、新增 dispersion 2、rim .3→.4。
  /// tint alpha 和 morph 脸 open=1 的表面色（surfaceColorForOpen）
  /// 保持一致（都是 0xff0e2233 alpha .38），见 overlay 的注释。
  static prism.LiquidGlassStyle field() => prism.LiquidGlassStyle(
    tint: const Color(0xff0e2233).withValues(alpha: .38),
    contrast: -.12,
    blur: 1,
    haze: .18,
    hazeBlur: 8,
    refraction: 14,
    bevel: 5,
    saturation: 1.3,
    rim: .4,
    rimWidth: .9,
    dispersion: 2,
    hairline: .18,
  );

  /// 地球主机卡片（136 x 46，半短边 23；折射 16、斜面 9 均在上限内）。
  /// v10：tint .55→.42、blur 2→1.5、haze .3→.22、
  /// refraction 16→20、新增 dispersion 2、rim .38→.48。
  static prism.LiquidGlassStyle card() => prism.LiquidGlassStyle(
    tint: const Color(0xff16242e).withValues(alpha: .42),
    contrast: -.15,
    blur: 1.5,
    haze: .22,
    hazeBlur: 10,
    refraction: 20,
    bevel: 9,
    saturation: 1.4,
    rim: .48,
    rimWidth: 1,
    dispersion: 2,
    hairline: .22,
  );

  /// 保存按钮（高 48dp，圆角 18；青色渐变在玻璃之下，玻璃只做折射 + 磨砂）。
  /// v10：tint .42→.32、blur 2→1.5、haze .35→.25、
  /// refraction 20→24（48 高窗格的上限）、dispersion 2→3、rim .5→.6。
  static prism.LiquidGlassStyle save() => prism.LiquidGlassStyle(
    tint: const Color(0xff1d7f9c).withValues(alpha: .32),
    contrast: -.2,
    blur: 1.5,
    haze: .25,
    hazeBlur: 10,
    refraction: 24,
    bevel: 12,
    saturation: 1.6,
    rim: .6,
    rimWidth: 1.2,
    dispersion: 3,
    hairline: .3,
  );

  /// 右下角胶囊按钮（88 x 48，半短边 24；v7：圆钮改胶囊；
  /// v8：SpeedDial 已拿掉，这是普通 _DialButton 的玻璃）。
  /// v10：tint .58→.45、blur 1.5→1、haze .4→.3、
  /// refraction 14→18、新增 dispersion 2、rim .38→.5、rimWidth 1.2→1.4。
  /// tint alpha 和 morph 脸 open=0 的表面色（surfaceColorForOpen）
  /// 保持一致（都是 0xff315b73 alpha .45），关到底交接才没有亮度台阶。
  static prism.LiquidGlassStyle dialGlyph() => prism.LiquidGlassStyle(
    tint: const Color(0xff315b73).withValues(alpha: .45),
    contrast: -.2,
    blur: 1,
    haze: .3,
    hazeBlur: 9,
    refraction: 18,
    bevel: 8,
    saturation: 1.6,
    rim: .5,
    rimWidth: 1.4,
    dispersion: 2,
    hairline: .22,
  );

  // ---------------------------------------------------------------------------
  // Fluid_Glass（1 号）透视玻璃：Morph 小弹窗的表面与配色。
  //
  // Backdrop 路线结论（按 fluid_glass 0.5.6 源码核实）：
  // - LayerBackdrop 是显式对象，不靠 InheritedWidget 祖先查找；玻璃在弹窗
  //   路由里也能按全局坐标采到主页地球（consumerToSourceTransform 用
  //   getTransformTo(null)；RenderDrawBackdrop._isCaptured 只查玻璃自身祖先链，
  //   弹窗路由里没有 RenderBackdropLayer 祖先；嵌套检测只拦“玻璃画在自己要
  //   折射的子树里”的情况，独立路由不触发）。
  // - 所以 Morph 面板走 LayerBackdrop 真折射，不走 nativeBackdrop（后者是
  //   compositor 滤镜、无折射；演示里弹窗用它是因为便宜且 barrier dim 免费，
  //   我们要的是折射，dim 用透明 barrier 解决）。
  // - LiquidSheet 本身没用：它自带的顶栏没有关闭按钮，且内容模型是 min 高
  //   Column，装不下可滚动的添加表单；LiquidPanel 是 LiquidSheet
  //   内部委托的同一个表面图元，形状与效果一致。
  // - v2 的 sheetGradient（不透明渐变）已删：玻璃后面必须看得见地球，
  //   字看不清只靠字色/字重/阴影与面板着色解决，不许再拿不透明兜底。
  // ---------------------------------------------------------------------------

  /// Morph 小弹窗共用的 Fluid_Glass 配色：沿用 GlassText 的 token
  ///（近白字 + 青色强调），表面着色只够让白字站稳。
  /// v10：container alpha .30→.20（更透）。
  static final fluid.LiquidGlassColors fluidColors = fluid
      .LiquidGlassColors
      .dark
      .copyWith(
        accent: GlassText.accent,
        toggleAccent: GlassText.accent,
        container: const Color(0xff0c1924).withValues(alpha: .20),
        content: GlassText.label,
      );

  /// Morph 小弹窗的表面着色：深青底、透明度 20%——只够让白字站稳，
  /// 绝不盖住后面的地球。v10：.30→.20。
  static final Color fluidSheetSurface = const Color(
    0xff0c1924,
  ).withValues(alpha: .20);

  /// 底部弹窗的形状：顶圆角（与 v2 的 24 一致），底边贴屏不倒角。
  /// 底部弹窗已拆、Morph 改走下面的 fluidPopupShape，这个形状留着备用。
  static fluid.RoundedRectangularShape fluidSheetShape([double radius = 24]) =>
      fluid.UnevenRoundedRectangle.only(topStart: radius, topEnd: radius);

  /// Morph 小弹窗的形状：四角全圆 28（底部弹窗用的 fluidSheetShape 只有
  /// 顶圆角、底边贴屏；悬浮小弹窗四边都离屏，必须全圆；与
  /// GlassMorphOverlay 的 targetRadius 取同一个值，变形到达终点时正好
  /// 贴合面板边）。
  static fluid.RoundedRectangularShape fluidPopupShape() =>
      const fluid.RoundedRectangle(28);
}

/// Morph 小弹窗共用的文字层级与开关色：只用这一套 token，
/// 不再各处从主题里继承颜色（主题在浅色模式下会给出深色文字，
/// 落在深色玻璃上几乎看不见；表单的 copyWith 暗色 Theme 也一样，
/// 它不会重算 textTheme）。
///
/// 层级（按对比度从高到低）：
/// - 标题 title：近白 0xfff2fbfd，20sp w700；
/// - 标签 label：近白 0xffedf6fa，16sp；
/// - 输入值 value：纯白，16sp；
/// - 说明 body：0xffc3d6de，14sp；
/// - 字段浮标 fieldLabel：0xffaec2cc（沿用表单原值）；
/// - 占位 hint：0xff9db8c4，16sp；
/// - 面板小字 caption：0xffa5c0ce（沿用面板原值）。
/// 强调色 accent 0xff79e5ed 沿用表单浮动标签的青色；开关选中态也用它。
/// 清晰度只靠文字颜色与不透明度，不加厚玻璃。
abstract final class GlassText {
  static const Color accent = Color(0xff79e5ed);
  static const Color accentBar = Color(0xff69e0eb);
  static const Color title = Color(0xfff2fbfd);
  static const Color label = Color(0xffedf6fa);
  static const Color value = Color(0xffffffff);
  static const Color body = Color(0xffc3d6de);
  static const Color fieldLabel = Color(0xffaec2cc);
  static const Color hint = Color(0xff9db8c4);
  static const Color caption = Color(0xffa5c0ce);
  static const Color icon = Color(0xff9ab9c7);
  static const Color closeIcon = Color(0xffeaf8fc);
  static const Color handle = Color(0x66aec2cc);

  static const TextStyle sheetTitle = TextStyle(
    color: title,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    // 透视玻璃上的字：颜色与字重不变，加一层淡黑阴影兜底——地球偶有亮斑时
    // 标题仍站得住；阴影不是不透明底，不遮后面的地球。
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 1)),
    ],
  );
  static const TextStyle labelStyle = TextStyle(
    color: label,
    fontSize: 16,
    // v10：玻璃更透以后，字靠自己站稳——每级文字都加一层淡黑阴影
    //（和 sheetTitle 原来那层一样的做法），不加厚玻璃。
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );
  static const TextStyle valueStyle = TextStyle(
    color: value,
    fontSize: 16,
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );
  static const TextStyle bodyStyle = TextStyle(
    color: body,
    fontSize: 14,
    height: 1.45,
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );
  static const TextStyle captionStyle = TextStyle(
    color: caption,
    fontSize: 13,
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );
  static const TextStyle hintStyle = TextStyle(
    color: hint,
    fontSize: 16,
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );
  static const TextStyle fieldLabelStyle = TextStyle(
    color: fieldLabel,
    fontSize: 16,
  );
  static const TextStyle floatingLabelStyle = TextStyle(color: accent);

  /// 深色玻璃开关：关闭态深 slate、开启态强调色。
  static const Color switchActiveTrack = Color(0xff1f8aa8);
  static const Color switchActiveThumb = Color(0xffffffff);
  static const Color switchInactiveTrack = Color(0xff3d5260);
  static const Color switchInactiveThumb = Color(0xffd7e5ea);
}
