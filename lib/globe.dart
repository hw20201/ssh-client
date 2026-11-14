import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'glass_styles.dart';

/// Server projection and card packing follow the same orthographic/depth-first
/// approach as ServerBox's globe (commit 6aa8549684dcede40c9a59c032ac207e316b5aa8).
/// Coastline asset: Natural Earth 110m, public domain, in ServerBox SBGL format.
const double maximumGlobeZoom = 6.0;
const double horizonFadeDepth = 0.12; // cos(83°), approximately 7° from limb.
const Size globeHostCardSize = Size(136, 46);
const double _rad = math.pi / 180;

class GeoPoint {
  const GeoPoint(this.lat, this.lon);
  final double lat, lon;
}

class ProjectedPoint {
  const ProjectedPoint(this.offset, this.depth);
  final Offset offset;
  final double depth;
  bool get visible => depth > 1e-9;
  double get fade => (depth / horizonFadeDepth).clamp(0.0, 1.0);
}

class GlobeCamera {
  const GlobeCamera({this.lat = 18, this.lon = 8});
  final double lat, lon;
  GlobeCamera drag(Offset delta, double radius) {
    if (radius <= 0) return this;
    var lon = (this.lon - delta.dx / radius / _rad + 180) % 360;
    if (lon < 0) lon += 360;
    return GlobeCamera(
      lat: (lat + delta.dy / radius / _rad).clamp(-89.9, 89.9).toDouble(),
      lon: lon - 180,
    );
  }
}

class GlobeProjection {
  GlobeProjection(this.camera, this.center, this.radius)
    : _sinLat = math.sin(camera.lat * _rad),
      _cosLat = math.cos(camera.lat * _rad),
      _sinLon = math.sin(camera.lon * _rad),
      _cosLon = math.cos(camera.lon * _rad);
  final GlobeCamera camera;
  final Offset center;
  final double radius;
  // Cache the view basis once per frame: coastline projection calls this thousands of times.
  final double _sinLat, _cosLat, _sinLon, _cosLon;

  ProjectedPoint project(GeoPoint point) {
    final dl = (point.lon - camera.lon) * _rad;
    final p = point.lat * _rad, c = camera.lat * _rad;
    final x = math.cos(p) * math.sin(dl);
    final y =
        math.cos(c) * math.sin(p) - math.sin(c) * math.cos(p) * math.cos(dl);
    final z =
        math.sin(c) * math.sin(p) + math.cos(c) * math.cos(p) * math.cos(dl);
    return ProjectedPoint(
      Offset(center.dx + radius * x, center.dy - radius * y),
      z,
    );
  }

  List<List<Offset>> projectRing(Float32List vectors) {
    final count = vectors.length ~/ 3;
    if (count < 2) return const [];
    final runs = <List<Offset>>[];
    var run = <Offset>[];
    var startsAtFirst = false, keptFirst = false, keptLast = false;
    for (var i = 0; i < count; i++) {
      final q = projectVector(
        vectors[i * 3],
        vectors[i * 3 + 1],
        vectors[i * 3 + 2],
      );
      if (q.visible) {
        if (i == 0) startsAtFirst = true;
        run.add(q.offset);
      } else {
        if (run.length > 1) {
          runs.add(run);
          if (startsAtFirst) keptFirst = true;
        }
        run = <Offset>[];
        startsAtFirst = false;
      }
    }
    if (run.length > 1) {
      runs.add(run);
      if (startsAtFirst) keptFirst = true;
      keptLast = true;
    }
    // Only join the real stored ring seam when both endpoints are in visible runs.
    if (keptFirst && keptLast) runs.last.add(runs.first.first);
    return runs;
  }

  ProjectedPoint projectVector(double x, double y, double z) {
    final rightX = -_sinLon, rightY = _cosLon;
    final upX = -_sinLat * _cosLon, upY = -_sinLat * _sinLon, upZ = _cosLat;
    final viewX = rightX * x + rightY * y;
    final viewY = upX * x + upY * y + upZ * z;
    final depth = _cosLat * _cosLon * x + _cosLat * _sinLon * y + _sinLat * z;
    return ProjectedPoint(
      Offset(center.dx + radius * viewX, center.dy - radius * viewY),
      depth,
    );
  }

  GeoPoint? unproject(Offset point) {
    if (radius <= 0) return null;
    final x = (point.dx - center.dx) / radius,
        y = (center.dy - point.dy) / radius;
    final r2 = x * x + y * y;
    if (r2 > 1) return null;
    final z = math.sqrt(1 - r2), c = camera.lat * _rad, lon = camera.lon * _rad;
    final lat = math.asin(z * math.sin(c) + y * math.cos(c));
    final lng = lon + math.atan2(x, z * math.cos(c) - y * math.sin(c));
    return GeoPoint(lat / _rad, ((lng / _rad + 540) % 360) - 180);
  }
}

typedef GlobeAnchor = ({String id, Offset at, double depth, Size size});
typedef GlobePlacement = ({String id, Rect rect, Offset anchor, double depth});

List<GlobePlacement> layoutGlobeCards({
  required List<GlobeAnchor> anchors,
  required Rect bounds,
  required Offset globeCenter,
  List<Rect> reserved = const [],
  double gap = 6,
  int maxCandidates = 96,
}) {
  final ordered = [...anchors]
    ..sort((a, b) {
      final d = b.depth.compareTo(a.depth);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
  final used = <Rect>[...reserved], result = <GlobePlacement>[];
  for (final a in ordered) {
    final away = a.at - globeCenter;
    final direction = away.distance < .001
        ? const Offset(0, -1)
        : away / away.distance;
    final ideal = Rect.fromCenter(
      center: a.at + direction * (a.size.longestSide / 2 + gap * 2),
      width: a.size.width,
      height: a.size.height,
    );
    final stride = a.size.shortestSide + gap;
    var best = _clampRect(ideal, bounds), bestScore = double.infinity;
    for (var n = 0; n < maxCandidates; n++) {
      const goldenAngle = 2.39996322972865332;
      final shift = n == 0
          ? Offset.zero
          : Offset(math.cos(n * goldenAngle), math.sin(n * goldenAngle)) *
                (stride * math.sqrt(n.toDouble()) * .9);
      final candidate = _clampRect(ideal.shift(shift), bounds);
      final score = _overlap(candidate, used, gap);
      if (score <= 0) {
        best = candidate;
        bestScore = 0;
        break;
      }
      if (score < bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    used.add(best);
    result.add((id: a.id, rect: best, anchor: a.at, depth: a.depth));
  }
  return result;
}

double _overlap(Rect candidate, List<Rect> existing, double gap) {
  var sum = 0.0;
  for (final rect in existing) {
    final i = candidate.inflate(gap / 2).intersect(rect.inflate(gap / 2));
    if (i.width > 0 && i.height > 0) sum += i.width * i.height;
  }
  return sum;
}

Rect _clampRect(Rect r, Rect b) {
  var dx = 0.0, dy = 0.0;
  if (r.width <= b.width) {
    if (r.left < b.left) dx = b.left - r.left;
    if (r.right > b.right) dx = b.right - r.right;
  } else {
    dx = b.left - r.left;
  }
  if (r.height <= b.height) {
    if (r.top < b.top) dy = b.top - r.top;
    if (r.bottom > b.bottom) dy = b.bottom - r.bottom;
  } else {
    dy = b.top - r.top;
  }
  return r.shift(Offset(dx, dy));
}

class GlobeLand {
  const GlobeLand(this.rings);
  final List<Float32List> rings;
  static GlobeLand? tryParse(Uint8List bytes) {
    if (bytes.length < 7 ||
        bytes[0] != 83 ||
        bytes[1] != 66 ||
        bytes[2] != 71 ||
        bytes[3] != 76 ||
        bytes[4] != 1) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    final count = data.getUint16(5, Endian.big);
    var at = 7;
    final rings = <Float32List>[];
    for (var r = 0; r < count; r++) {
      if (at + 2 > bytes.length) return null;
      final points = data.getUint16(at, Endian.big);
      at += 2;
      if (at + points * 4 > bytes.length) return null;
      final v = Float32List(points * 3);
      for (var i = 0; i < points; i++) {
        final lat = data.getInt16(at, Endian.big) / 32767 * 90 * _rad;
        final lon = data.getInt16(at + 2, Endian.big) / 32767 * 180 * _rad;
        at += 4;
        final cl = math.cos(lat);
        v[3 * i] = cl * math.cos(lon);
        v[3 * i + 1] = cl * math.sin(lon);
        v[3 * i + 2] = math.sin(lat);
      }
      rings.add(v);
    }
    return GlobeLand(rings);
  }

  static Future<GlobeLand?> load() async {
    try {
      final data = await rootBundle.load('assets/geo/land_110m.bin');
      return tryParse(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (e, st) {
      debugPrint('GlobeLand asset load failed: $e\n$st');
      return null;
    }
  }
}

const Map<String, GeoPoint> _cities = {
  'london': GeoPoint(51.5072, -.1276),
  'paris': GeoPoint(48.8566, 2.3522),
  'frankfurt': GeoPoint(50.1109, 8.6821),
  'berlin': GeoPoint(52.52, 13.405),
  'amsterdam': GeoPoint(52.3676, 4.9041),
  'tokyo': GeoPoint(35.6762, 139.6503),
  'osaka': GeoPoint(34.6937, 135.5023),
  'singapore': GeoPoint(1.3521, 103.8198),
  'hong kong': GeoPoint(22.3193, 114.1694),
  'shanghai': GeoPoint(31.2304, 121.4737),
  'beijing': GeoPoint(39.9042, 116.4074),
  'taipei': GeoPoint(25.033, 121.5654),
  'seoul': GeoPoint(37.5665, 126.978),
  'sydney': GeoPoint(-33.8688, 151.2093),
  'new york': GeoPoint(40.7128, -74.006),
  'los angeles': GeoPoint(34.0522, -118.2437),
  'san francisco': GeoPoint(37.7749, -122.4194),
  'seattle': GeoPoint(47.6062, -122.3321),
  'toronto': GeoPoint(43.6532, -79.3832),
  'vancouver': GeoPoint(49.2827, -123.1207),
  'mumbai': GeoPoint(19.076, 72.8777),
  'dubai': GeoPoint(25.2048, 55.2708),
  'moscow': GeoPoint(55.7558, 37.6173),
  'helsinki': GeoPoint(60.1699, 24.9384),
};
GeoPoint? resolveGlobeLocation(String text) {
  final normalized = text.trim().toLowerCase();
  if (_cities.containsKey(normalized)) return _cities[normalized];
  final match = RegExp(
    r'^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$',
  ).firstMatch(text);
  if (match == null) return null;
  final lat = double.tryParse(match.group(1)!),
      lon = double.tryParse(match.group(2)!);
  if (lat == null ||
      lon == null ||
      lat < -90 ||
      lat > 90 ||
      lon < -180 ||
      lon > 180) {
    return null;
  }
  return GeoPoint(lat, lon);
}

class GlobeHost {
  const GlobeHost({
    required this.id,
    required this.name,
    required this.address,
    required this.city,
    this.connected = false,
    this.onTap,
    this.location,
    this.locationLabel,
  });
  final String id, name, address, city;

  /// Database-resolved coordinates take precedence over the optional city text.
  final GeoPoint? location;
  final String? locationLabel;
  final bool connected;
  final VoidCallback? onTap;
}

class SshGlobe extends StatefulWidget {
  const SshGlobe({
    super.key,
    required this.hosts,
    required this.selectedId,
    required this.onSelected,
    this.onSelectedAt,
    this.onHostLongPress,
    this.autoRotate = true,
    this.rotationSpeed = 12,
    this.onZoomChanged,
    this.onCameraChanged,
    this.hiddenCardId,
    this.anchorCardRect,
    this.morphDrivenRotation = false,
    this.morphOpen,
  });
  final List<GlobeHost> hosts;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  /// v13：点卡片时附带点按的全局坐标（主页拿它当变形锚点——面板从
  /// 卡片那里长出来）。没传时只走 onSelected（锚点用地球中心兜底）。
  final void Function(String id, Offset globalPosition)? onSelectedAt;

  /// v11：长按宿主卡片（编辑 / 删除的入口）。
  final ValueChanged<String>? onHostLongPress;
  final bool autoRotate;
  final double rotationSpeed;

  /// Reports the current zoom, also useful to verify pinch interaction.
  final ValueChanged<double>? onZoomChanged;
  final ValueChanged<GlobeCamera>? onCameraChanged;

  /// v14：藏起来的那张卡片（会话面板打开期间，锚点卡片不能露在那儿——
  /// 它变成了面板，面板和真卡片不能同时出现在锚点处，否则就是
  /// 双层残影。卡片留在布局里（位置还占着，别的卡片不重排），
  /// 只是透明；关到底、面板卸载的同一帧再回来）。
  final String? hiddenCardId;

  /// v19：活锚点——地球仪每帧把选中卡片（会话锚点）的实时全局矩形
  /// 写进来，主页的会话 morph 每帧读它当 origin。关闭过渡里地球
  /// 转起来、卡片漂走（实测：转 2° 最坏漂 7.13dp，远超 2dp 预算），
  /// 脸跟着卡片走，落点不错开。只写 .value，不监听，不会触发重建。
  final ValueNotifier<Rect>? anchorCardRect;

  /// v19：转速是不是由 morph 的 open 值驱动（会话关闭过渡里）。
  /// 为 true 时 _tick 里不用时间斜坡（_rampFactor），转速 =
  /// rotationSpeed × smoothstep(1 - open)：点关闭那一刻 open=1、
  /// 转速 0；过渡结束 open=0、转速满速，和关闭变形绑在一起。
  /// 为 false 时走原来的时间斜坡（首次启动/拖拽松手/恢复转动）。
  final bool morphDrivenRotation;

  /// v19：morph 的当前 open 值（主页的 _morphOpen，overlay 每帧
  /// post-frame 写）。morphDrivenRotation 为 true 时 _tick 每帧
  /// 读它算转速因子；不传时因子按 0 算（不转）。
  final ValueNotifier<double>? morphOpen;
  @override
  State<SshGlobe> createState() => _SshGlobeState();
}

class _SshGlobeState extends State<SshGlobe>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration? _last;
  GlobeCamera _camera = const GlobeCamera();
  bool _interacting = false;
  double _zoom = 1, _scaleStartZoom = 1;
  bool _initialZoomApplied = false;
  GlobeLand? _land;

  /// v18：恢复转动的斜坡——转速从 0 慢慢爬回满速，不要一帧从 0 跳
  /// 到 12°/秒。实测（v18 诊断）：恢复后第一个 tick 就已经是满速
  /// 12°/秒，地球一帧就从静止跳到满速转；主人说的“点缩小成按钮
  /// 的时候地球开始慢慢恢复转动”要的就是这个斜坡。
  /// _resumeStart 是恢复那一刻的 ticker 时间（基准 tick 上记），
  /// 450ms 内用 smoothstep 从 0 爬到 1。
  static const Duration _resumeRamp = Duration(milliseconds: 450);
  Duration? _resumeStart;
  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    if (widget.autoRotate) _ticker.start();
    GlobeLand.load().then((v) {
      if (mounted) setState(() => _land = v);
    });
  }

  @override
  void didUpdateWidget(covariant SshGlobe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.autoRotate != widget.autoRotate) {
      if (widget.autoRotate) {
        _last = null;
        if (!_ticker.isActive) _ticker.start();
      } else if (_ticker.isActive) {
        _ticker.stop();
        // v18：停下就把斜坡起点清掉，下次恢复重新从 0 爬。
        _resumeStart = null;
      }
    }
    if (oldWidget.morphDrivenRotation != widget.morphDrivenRotation) {
      // v19：驱动方式切换时把时间斜坡清掉——morph 驱动时不用它
      // （因子就是 morph 的 open），切回来时也不能让它从 0 再爬
      // （转速会先掉下去再爬回来）；清掉后 _rampFactor 直接返回
      // 1.0，转速保持满速，不顿。
      _resumeStart = null;
    }
  }

  void _beginInteraction() {
    _interacting = true;
    _last = null;
    // v18：拖拽也清掉斜坡起点，松手后重新从 0 爬（和恢复转动一样）。
    _resumeStart = null;
    if (_ticker.isActive) _ticker.stop();
  }

  void _endInteraction() {
    if (!_interacting) return;
    _interacting = false;
    // Start a fresh elapsed-time baseline: the idle ticker resumes smoothly
    // without catching up time spent dragging or pinching.
    _last = null;
    if (widget.autoRotate && !_ticker.isActive) _ticker.start();
  }

  void _tick(Duration elapsed) {
    final prev = _last;
    _last = elapsed;
    if (prev == null || !widget.autoRotate || _interacting) {
      // 基准 tick：恢复（或首次启动）的起点，斜坡从这里开始爬。
      if (prev == null) _resumeStart = elapsed;
      return;
    }
    final seconds = (elapsed - prev).inMicroseconds / 1000000;
    if (seconds > 0) {
      // v19：morph 驱动的转速（会话关闭过渡里）：转速 =
      // rotationSpeed × smoothstep(1 - open)。open 从 1 → 0，
      // 转速从 0 爬到满速，和关闭变形绑在一起；过渡结束时正好
      // 回到满速。非 morph 驱动时走原来的时间斜坡。
      final double factor = widget.morphDrivenRotation
          ? _morphFactor()
          : _rampFactor(elapsed);
      setState(
        () => _camera = GlobeCamera(
          lat: _camera.lat,
          lon: _wrap(
            _camera.lon +
                widget.rotationSpeed * factor * seconds,
          ),
        ),
      );
      widget.onCameraChanged?.call(_camera);
    }
  }

  /// v19：morph 驱动的转速因子（0→1，smoothstep）。open=1（面板
  /// 全开）时 0，open=0（变成按钮）时 1；关闭里 open 单调减小，
  /// 因子单调增大，转速单调爬回满速。open 的欠阻尼过冲只有约
  /// 1dp，t 钳在 [0,1]，因子不会反向。
  double _morphFactor() {
    final double open = widget.morphOpen?.value ?? 0.0;
    final double t = (1.0 - open).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// v18：恢复转动的斜坡系数（0→1，450ms，smoothstep）。
  /// 起步慢、中间加速、落点柔和，转速单调爬回满速；爬完后恒为 1，
  /// 正常转动不受影响。
  double _rampFactor(Duration elapsed) {
    final Duration? start = _resumeStart;
    if (start == null) return 1.0;
    final double t =
        ((elapsed - start).inMilliseconds / _resumeRamp.inMilliseconds)
            .clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  double _wrap(double lon) => ((lon + 180) % 360) - 180;
  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final baseRadius = math
            .min(size.height * .405, size.width * .315)
            .clamp(52.0, 120.0)
            .toDouble();
        final fitZoom =
            (math.min(size.width * .47, size.height * .47) / baseRadius)
                .clamp(1.0, maximumGlobeZoom)
                .toDouble();
        // Keep the same near-full-globe initial composition while allowing a
        // much closer user-controlled zoom, including panning across the globe.
        final maxZoom = maximumGlobeZoom;
        if (!_initialZoomApplied) {
          _zoom = (fitZoom * .96).clamp(1.0, 2.1).toDouble();
          _scaleStartZoom = _zoom;
          _initialZoomApplied = true;
        }
        final radius = baseRadius * _zoom.clamp(.65, maxZoom);
        final center = Offset(size.width * .5, size.height * .53);
        final projection = GlobeProjection(_camera, center, radius);
        final points = <({GlobeHost host, ProjectedPoint point})>[];
        for (final host in widget.hosts) {
          final loc = host.location ?? resolveGlobeLocation(host.city);
          if (loc != null) {
            points.add((host: host, point: projection.project(loc)));
          }
        }
        final anchors = points
            .where((p) => p.point.visible)
            .map(
              (p) => (
                id: p.host.id,
                at: p.point.offset,
                depth: p.point.depth,
                size: globeHostCardSize,
              ),
            )
            .toList();
        final layout = layoutGlobeCards(
          anchors: anchors,
          bounds: Rect.fromLTWH(6, 6, size.width - 12, size.height - 12),
          globeCenter: center,
          reserved: [Rect.fromLTWH(size.width - 82, size.height - 82, 76, 76)],
        );
        final placements = {for (final p in layout) p.id: p};
        // v19：活锚点——把选中卡片（会话锚点）的实时全局矩形写出去，
        // 主页的会话 morph 每帧读它当 origin。地球每帧 ticker
        // setState 都会重建，矩形就是最新的；只写 .value、不监听，
        // 不会触发重建循环。卡片不可见（转到背面）或 RenderBox
        // 还没出来时保留上一次的值。矩形是 globe 内坐标，转全局
        // 坐标要加 globe 自己的全局偏移（localToGlobal，上一帧
        // 布局的位置，globe 在屏上的位置帧间不动）。
        final ValueNotifier<Rect>? anchorRectTarget = widget.anchorCardRect;
        if (anchorRectTarget != null && widget.selectedId != null) {
          final GlobePlacement? placement = placements[widget.selectedId];
          final RenderBox? box = context.findRenderObject() as RenderBox?;
          if (placement != null && box != null && box.hasSize) {
            anchorRectTarget.value = placement.rect.shift(
              box.localToGlobal(Offset.zero),
            );
          }
        }
        final palette = GlobePalette.from(context);
        final leaders = <GlobeLeader>[];
        for (final item in points.where((e) => e.point.visible)) {
          final placement = placements[item.host.id];
          if (placement == null) continue;
          // v14：藏起来的卡片不画引线（不然线头会悬在空地方）。
          if (item.host.id == widget.hiddenCardId) continue;
          final rect = placement.rect;
          final end = Offset(
            item.point.offset.dx.clamp(rect.left, rect.right).toDouble(),
            item.point.offset.dy.clamp(rect.top, rect.bottom).toDouble(),
          );
          leaders.add((
            card: rect,
            anchor: item.point.offset,
            endpoint: end,
            fade: item.point.fade,
          ));
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // ScaleGestureRecognizer handles both one-finger surface rotation and two-finger pinch.
          onScaleStart: (_) {
            _beginInteraction();
            _scaleStartZoom = _zoom;
          },
          onScaleEnd: (_) => _endInteraction(),
          onScaleUpdate: (d) {
            final nextZoom = (_scaleStartZoom * d.scale)
                .clamp(.65, maxZoom)
                .toDouble();
            if ((nextZoom - _zoom).abs() < .001 &&
                d.focalPointDelta.distance < .1) {
              return;
            }
            setState(() {
              _zoom = nextZoom;
              _camera = _camera.drag(d.focalPointDelta, radius);
            });
            widget.onZoomChanged?.call(_zoom);
            widget.onCameraChanged?.call(_camera);
          },
          onTapUp: (d) {
            // v13：点按位置一起交给主页（变形锚点用）。
            // v16-drop：锚点传卡片的全局中心，不传点按点——点按点可以
            // 落在卡片的任意位置（比如名字那一行，偏上十几 dp），
            // 锚点按点按点算就会比卡片高出一截，收回时脸停在偏上的
            // 地方，overlay 一卸、卡片在更低处露出来，肉眼就是
            // “突然往下掉一下”。全局中心 = 点按全局坐标 −
            // 点按地球仪内坐标 + 卡片地球仪内中心（d.localPosition
            // 是地球仪内的坐标，placement.rect 是卡片在地球仪内的矩形）。
            Offset cardCenter(GlobePlacement p) =>
                d.globalPosition - d.localPosition + p.rect.center;
            void select(String id, [GlobePlacement? placement]) {
              final at = widget.onSelectedAt;
              final Offset position = placement != null
                  ? cardCenter(placement)
                  : d.globalPosition;
              if (at != null) {
                at(id, position);
              } else {
                widget.onSelected(id);
              }
            }

            for (final tapped in placements.values) {
              if (tapped.rect.contains(d.localPosition)) {
                select(tapped.id, tapped);
                return;
              }
            }
            for (final p in points.where((e) => e.point.visible)) {
              if ((p.point.offset - d.localPosition).distance < 18) {
                select(p.host.id, placements[p.host.id]);
                return;
              }
            }
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: GlobePainter(
                    projection: projection,
                    land: _land,
                    points: points.map((e) => e.point).toList(),
                    leaders: leaders,
                    palette: palette,
                  ),
                ),
              ),
              for (final entry in placements.entries)
                Builder(
                  builder: (context) {
                    final host = widget.hosts.firstWhere(
                      (h) => h.id == entry.key,
                    );
                    final pl = entry.value;
                    final fade = (pl.depth / horizonFadeDepth).clamp(0.0, 1.0);
                    // v14：会话面板打开期间，锚点卡片藏起来（v5 同款机制）——
                    // 它变成了面板；卡片留在布局里（位置还占着，不重排），
                    // 只是透明，关到底同一帧再回来。点按不用另挡：面板开着
                    // 时 overlay 的 scrim 盖在地球仪上面，卡片本来就点不到；
                    // _openSessionFor / 长按入口也都有 _morph != null 的守门。
                    final bool cardHidden =
                        widget.hiddenCardId == host.id;
                    return Positioned(
                      left: pl.rect.left,
                      top: pl.rect.top,
                      width: pl.rect.width,
                      height: pl.rect.height,
                      child: Opacity(
                        opacity: cardHidden ? 0.0 : fade,
                        child: GestureDetector(
                          // v13：onTapUp 才能拿到点按的全局坐标（变形锚点用）；
                          // 没传 onSelectedAt 时回落到 onSelected。
                          // v16-drop：锚点传卡片的全局中心，不传点按点——
                          // 点按点可以落在卡片任意位置（名字那一行偏上十几
                          // dp），锚点按点按点算就比卡片高出一截，收回时脸
                          // 停在偏上的地方，overlay 一卸、卡片在更低处露出来，
                          // 肉眼就是“突然往下掉一下”。卡片全局中心 =
                          // 点按全局坐标 − 点按卡片内坐标 + 卡片半尺寸
                          // （d.localPosition 是卡片内的坐标，pl.rect 是
                          // 卡片在地球仪内的矩形、尺寸就是卡片尺寸）。
                          onTapUp: (d) {
                            final at = widget.onSelectedAt;
                            if (at != null) {
                              at(
                                host.id,
                                d.globalPosition -
                                    d.localPosition +
                                    Offset(
                                      pl.rect.width / 2,
                                      pl.rect.height / 2,
                                    ),
                              );
                            } else {
                              widget.onSelected(host.id);
                            }
                          },
                          onLongPress: () =>
                              widget.onHostLongPress?.call(host.id),
                          child: prism.LiquidGlass(
                            style: GlassStyles.card(),
                            borderRadius: BorderRadius.circular(12),
                            steadyFrost: true,
                            shadows: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: .13),
                                blurRadius: 11,
                                offset: const Offset(0, 4),
                              ),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: widget.selectedId == host.id
                                          ? scheme.primary
                                          : host.connected
                                          ? const Color(0xff55aa62)
                                          : scheme.outline,
                                    ),
                                  ),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text(
                                      '${host.name}\n${host.locationLabel ?? host.address}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
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
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class GlobePalette {
  const GlobePalette({
    required this.lit,
    required this.shadow,
    required this.land,
    required this.grid,
    required this.glow,
    required this.leader,
  });
  final Color lit, shadow, land, grid, glow, leader;
  factory GlobePalette.from(BuildContext context) {
    final s = Theme.of(context).colorScheme,
        dark = Theme.of(context).brightness == Brightness.dark;
    return GlobePalette(
      lit: Color.alphaBlend(
        s.primary.withValues(alpha: dark ? .58 : .34),
        s.surfaceContainerHighest,
      ),
      shadow: Color.alphaBlend(
        s.surface.withValues(alpha: .88),
        s.surfaceContainerLow,
      ),
      land: s.onSurface.withValues(alpha: .53),
      grid: s.onSurface.withValues(alpha: .10),
      glow: s.primary.withValues(alpha: dark ? .32 : .18),
      leader: s.onSurface.withValues(alpha: .36),
    );
  }
}

typedef GlobeLeader = ({
  Rect card,
  Offset anchor,
  Offset endpoint,
  double fade,
});

class GlobePainter extends CustomPainter {
  const GlobePainter({
    required this.projection,
    required this.land,
    required this.points,
    required this.leaders,
    required this.palette,
  });
  final GlobeProjection projection;
  final GlobeLand? land;
  final List<ProjectedPoint> points;
  final List<GlobeLeader> leaders;
  final GlobePalette palette;
  static const _light = Offset(-.35, -.45);
  static final List<Float32List> _latitudeGrid = _makeLatitudeGrid();
  static final List<Float32List> _longitudeGrid = _makeLongitudeGrid();

  static List<Float32List> _makeLatitudeGrid() => [
    for (var latitude = -60; latitude <= 60; latitude += 30)
      Float32List.fromList([
        for (var i = 0; i <= 120; i++)
          ..._unitVector(latitude.toDouble(), -180 + i * 3.0),
      ]),
  ];
  static List<Float32List> _makeLongitudeGrid() => [
    for (var longitude = -180; longitude < 180; longitude += 30)
      Float32List.fromList([
        for (var i = 0; i <= 60; i++)
          ..._unitVector(-90 + i * 3.0, longitude.toDouble()),
      ]),
  ];
  static List<double> _unitVector(double latitude, double longitude) {
    final lat = latitude * _rad, lon = longitude * _rad, cosLat = math.cos(lat);
    return [cosLat * math.cos(lon), cosLat * math.sin(lon), math.sin(lat)];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = projection.center, r = projection.radius;
    // A restrained outside glow lets the globe fade naturally into the black canvas.
    canvas.drawCircle(
      c,
      r * 1.18,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          r * 1.18,
          [
            Colors.transparent,
            palette.glow.withValues(alpha: .07),
            Colors.transparent,
          ],
          const [.76, .89, 1],
        ),
    );
    // Soft grounding shadow and a gentler terminator keep the globe dimensional
    // without the conspicuous dark inner crescent in the previous build.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(c.dx, c.dy + r * .79),
        width: r * 1.35,
        height: r * .28,
      ),
      Paint()
        ..color = palette.shadow.withValues(alpha: .10)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = ui.Gradient.radial(
          c + Offset(_light.dx, _light.dy) * r * .46,
          r * 1.42,
          [
            palette.lit,
            Color.lerp(palette.lit, palette.shadow, .19)!,
            Color.lerp(palette.lit, palette.shadow, .78)!,
          ],
          const [0, .46, 1],
        ),
    );
    final clip = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    canvas.save();
    canvas.clipPath(clip);
    canvas.drawCircle(
      c + Offset(_light.dx, _light.dy) * r * .36,
      r * .72,
      Paint()
        ..shader = ui.Gradient.radial(
          c + Offset(_light.dx, _light.dy) * r * .36,
          r * .72,
          [
            Colors.white.withValues(alpha: .09),
            Colors.white.withValues(alpha: .025),
            Colors.transparent,
          ],
          const [0, .48, 1],
        ),
    );
    final gridPaint = Paint()
      ..color = palette.grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7
      ..isAntiAlias = true;
    for (final ring in _latitudeGrid) {
      for (final line in projection.projectRing(ring)) {
        _stroke(canvas, line, gridPaint);
      }
    }
    for (final ring in _longitudeGrid) {
      for (final line in projection.projectRing(ring)) {
        _stroke(canvas, line, gridPaint);
      }
    }
    final landPaint = Paint()
      ..color = palette.land
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.05
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    for (final ring in land?.rings ?? const <Float32List>[]) {
      for (final line in projection.projectRing(ring)) {
        _stroke(canvas, line, landPaint);
      }
    }
    canvas.restore();
    // The leader shares the exact same depth fade as its dot and card.
    for (final line in leaders) {
      if (line.fade <= 0) continue;
      final path = Path()..moveTo(line.anchor.dx, line.anchor.dy);
      final mid = Offset(
        (line.anchor.dx + line.endpoint.dx) / 2,
        (line.anchor.dy + line.endpoint.dy) / 2 - 5,
      );
      path.quadraticBezierTo(
        mid.dx,
        mid.dy,
        line.endpoint.dx,
        line.endpoint.dy,
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round
          ..color = palette.leader.withValues(
            alpha: palette.leader.a * line.fade,
          )
          ..isAntiAlias = true,
      );
    }
    // Subtle rim highlight reinforces the sphere against the card surface.
    canvas.drawCircle(
      c,
      r - .5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = palette.leader.withValues(alpha: .18)
        ..isAntiAlias = true,
    );
    for (final point in points.where((p) => p.visible)) {
      final fade = point.fade;
      if (fade <= 0) continue;
      final dotColor = palette.leader.withValues(
        alpha: palette.leader.a * fade,
      );
      // host card positions are independent widgets; leader rendered by their anchor pairing in future layout updates
      canvas.drawCircle(
        point.offset,
        4.8,
        Paint()
          ..color = palette.glow.withValues(alpha: palette.glow.a * .45 * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      );
      canvas.drawCircle(point.offset, 3.6, Paint()..color = dotColor);
    }
  }

  void _stroke(Canvas canvas, List<Offset> points, Paint paint) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final point = points[i];
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant GlobePainter old) =>
      old.projection.camera.lat != projection.camera.lat ||
      old.projection.camera.lon != projection.camera.lon ||
      old.projection.center != projection.center ||
      old.projection.radius != projection.radius ||
      old.land != land ||
      old.points.length != points.length ||
      old.leaders.length != leaders.length ||
      old.palette != palette;
}
