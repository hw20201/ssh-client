import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'globe.dart';

/// Approximate city-level coordinates from the locally downloaded DB-IP
/// Lite data. The SBGX data contains coordinates, not city labels, so the
/// UI says so.
class IpGeoLocation {
  const IpGeoLocation({required this.point, required this.label});

  final GeoPoint point;
  final String label;

  factory IpGeoLocation.fromPoint(GeoPoint point) => IpGeoLocation(
        point: point,
        label:
            '约 ${point.lat.toStringAsFixed(2)}°, ${point.lon.toStringAsFixed(2)}°',
      );
}

/// Reader for lollipopkit/ipgeo-shards SBGX v1. The index table is held in
/// memory; lookups load just one bucket and binary-search its fixed-size rows.
class SbgxBundleReader {
  SbgxBundleReader._({
    required RandomAccessFile file,
    required this.family,
    required this.year,
    required this.month,
    required this.recordCount,
    required int recordOffset,
    required Uint32List bucketOffsets,
  })  : _file = file,
        _recordOffset = recordOffset,
        _bucketOffsets = bucketOffsets;

  final RandomAccessFile _file;
  final int family;
  final int year;
  final int month;
  final int recordCount;
  final int _recordOffset;
  final Uint32List _bucketOffsets;
  int get _offsetBytes => family == 4 ? 3 : 4;
  int get _recordBytes => _offsetBytes + 4;

  static Future<SbgxBundleReader> openFile(
    File file, {
    required int expectedFamily,
  }) async {
    final handle = await file.open();
    try {
      final header = await handle.read(16);
      if (header.length != 16 ||
          ascii.decode(header.sublist(0, 4)) != 'SBGX' ||
          header[4] != 1 ||
          header[5] != expectedFamily) {
        throw FormatException('Invalid SBGX v1 header for IPv$expectedFamily.');
      }
      final headerData = ByteData.sublistView(header);
      final year = headerData.getUint16(6, Endian.big);
      final month = header[8];
      final count = headerData.getUint32(9, Endian.big);
      final bucketBits = expectedFamily == 4 ? 8 : 16;
      final bucketCount = 1 << bucketBits;
      final bucketTable = await handle.read((bucketCount + 1) * 4);
      if (bucketTable.length != (bucketCount + 1) * 4) {
        throw const FormatException('Truncated SBGX bucket table.');
      }
      final bucketData = ByteData.sublistView(bucketTable);
      final offsets = Uint32List(bucketCount + 1);
      for (var i = 0; i <= bucketCount; i++) {
        offsets[i] = bucketData.getUint32(i * 4, Endian.big);
      }
      final recordOffset = 16 + bucketTable.length;
      final expectedLength =
          recordOffset + count * (expectedFamily == 4 ? 7 : 8);
      if (offsets.first != 0 ||
          offsets.last != count ||
          expectedLength != await handle.length()) {
        throw const FormatException('SBGX index or record length is invalid.');
      }
      for (var i = 0; i < bucketCount; i++) {
        if (offsets[i] > offsets[i + 1] || offsets[i + 1] > count) {
          throw const FormatException('SBGX bucket index is out of order.');
        }
      }
      return SbgxBundleReader._(
        file: handle,
        family: expectedFamily,
        year: year,
        month: month,
        recordCount: count,
        recordOffset: recordOffset,
        bucketOffsets: offsets,
      );
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  /// Looks up an IP literal. This reader intentionally performs no DNS lookup.
  Future<GeoPoint?> lookup(String address) async {
    final normalized = address.trim().replaceAll(RegExp(r'^\[|\]$'), '');
    final ip = InternetAddress.tryParse(normalized);
    if (ip == null || (ip.type == InternetAddressType.IPv4 ? 4 : 6) != family) {
      return null;
    }
    final bytes = ip.rawAddress;
    final bucket = family == 4 ? bytes[0] : (bytes[0] << 8) | bytes[1];
    var keyOffset = 0;
    final keyEnd = family == 4
        ? bytes.length
        : 6; // SBGX IPv6 indexes /48 only.
    for (var i = family == 4 ? 1 : 2; i < keyEnd; i++) {
      keyOffset = (keyOffset << 8) | bytes[i];
    }
    final first = _bucketOffsets[bucket];
    final afterLast = _bucketOffsets[bucket + 1];
    if (first == afterLast) return null;

    final rowCount = afterLast - first;
    await _file.setPosition(_recordOffset + first * _recordBytes);
    final rows = await _file.read(rowCount * _recordBytes);
    if (rows.length != rowCount * _recordBytes) {
      throw const FormatException('Truncated SBGX bucket data.');
    }
    final data = ByteData.sublistView(rows);
    var low = 0;
    var high = rowCount - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final rowStart = _readOffset(data, mid * _recordBytes);
      if (rowStart <= keyOffset) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (found < 0) return null;
    final coordinateOffset = found * _recordBytes + _offsetBytes;
    final latitude = data.getInt16(coordinateOffset, Endian.big);
    final longitude = data.getInt16(coordinateOffset + 2, Endian.big);
    if (latitude == -32768) return null;
    final point = GeoPoint(latitude / 32767 * 90, longitude / 32767 * 180);
    if (point.lat < -90 ||
        point.lat > 90 ||
        point.lon < -180 ||
        point.lon > 180) {
      return null;
    }
    return point;
  }

  int _readOffset(ByteData data, int at) {
    if (family == 4) {
      return (data.getUint8(at) << 16) |
          (data.getUint8(at + 1) << 8) |
          data.getUint8(at + 2);
    }
    return data.getUint32(at, Endian.big);
  }

  Future<void> close() => _file.close();
}

/// Local geo-data directory: `<application-support>/geo/`.
/// Downloaded .bin.gz files, the local manifest.json and the extracted
/// .bin files all live here; the app never reads them from Flutter assets.
Future<Directory> geoDataDir() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory('${support.path}/geo');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Result of a geo-data ensure/update run.
class GeoUpdateResult {
  const GeoUpdateResult({
    required this.updated,
    required this.hasData,
    this.error,
  });

  /// Local data changed (downloaded or replaced).
  final bool updated;

  /// Usable local data exists after the run.
  final bool hasData;

  /// Last error, if any. Never thrown to the caller.
  final String? error;
}

/// Downloads and updates the IP geolocation dataset from GitHub Releases.
///
/// The dataset is no longer bundled in the APK (it was 26.5MB, 57% of the
/// package). The app downloads it on first launch and checks the remote
/// manifest (at most once a day) for a newer dataset version; a newer
/// version is downloaded and only replaces the local files after its
/// SHA-256 checks pass. Without local data (first launch, still
/// downloading, offline) the app keeps working on the default spot.
class GeoDataUpdater {
  GeoDataUpdater({http.Client? client}) : _client = client ?? http.Client();

  /// Fixed download address: the `geo-data-latest` release. Publishing a
  /// new dataset only needs moving this tag; the app needs no new release.
  static const manifestUrl =
      'https://github.com/hw20201/ssh-client/releases/download/geo-data-latest/manifest.json';
  static const baseUrl =
      'https://github.com/hw20201/ssh-client/releases/download/geo-data-latest/';

  static const checkInterval = Duration(hours: 24);

  final http.Client _client;

  /// Makes sure usable local geo data exists and is up to date.
  /// Never throws; failures are reported in the result.
  Future<GeoUpdateResult> ensureAndUpdate({bool force = false}) async {
    try {
      final dir = await geoDataDir();
      final localManifest = File('${dir.path}/manifest.json');
      // Seed: copy the bundled manifest in as the initial local manifest,
      // so the app knows the dataset version before the first download.
      if (!await localManifest.exists()) {
        try {
          final bundled = await rootBundle.load(IpGeoDatabase.manifestAsset);
          final bytes = bundled.buffer.asUint8List(
            bundled.offsetInBytes,
            bundled.lengthInBytes,
          );
          await localManifest.writeAsBytes(bytes, flush: true);
        } catch (_) {
          // No seed; the remote fetch below is the source of truth.
        }
      }
      // Throttle: at most one remote check a day unless forced.
      if (!force) {
        final lastCheck = File('${dir.path}/last_check.txt');
        if (await lastCheck.exists()) {
          final millis =
              int.tryParse((await lastCheck.readAsString()).trim());
          if (millis != null &&
              DateTime.now().millisecondsSinceEpoch - millis <
                  checkInterval.inMilliseconds) {
            final db = await IpGeoDatabase.open();
            return GeoUpdateResult(updated: false, hasData: db.hasData);
          }
        }
      }
      final response = await _client
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        final db = await IpGeoDatabase.open();
        return GeoUpdateResult(
          updated: false,
          hasData: db.hasData,
          error: 'manifest HTTP ${response.statusCode}',
        );
      }
      final remote =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (remote['version'] != 1 || remote['generated'] is! String) {
        final db = await IpGeoDatabase.open();
        return GeoUpdateResult(
          updated: false,
          hasData: db.hasData,
          error: 'bad remote manifest',
        );
      }
      final remoteGenerated = remote['generated'] as String;
      final entries =
          (remote['assets'] as List).cast<Map<String, dynamic>>();
      // Same version and local files complete + valid: nothing to do.
      String? localGenerated;
      if (await localManifest.exists()) {
        try {
          final local = jsonDecode(await localManifest.readAsString())
              as Map<String, dynamic>;
          localGenerated = local['generated'] as String?;
        } catch (_) {
          localGenerated = null;
        }
      }
      if (localGenerated == remoteGenerated &&
          await _localFilesComplete(dir, entries)) {
        await _recordCheck(dir);
        return const GeoUpdateResult(updated: false, hasData: true);
      }
      // Download every asset, verify, then replace atomically.
      final staged = <File>[];
      try {
        for (final entry in entries) {
          final name = entry['name'] as String;
          final res = await _client
              .get(Uri.parse('$baseUrl$name'))
              .timeout(const Duration(seconds: 60));
          if (res.statusCode != 200) {
            throw HttpException(
              'Download $name failed: HTTP ${res.statusCode}',
            );
          }
          final bytes = res.bodyBytes;
          if (bytes.length != entry['bytes'] ||
              sha256.convert(bytes).toString() != entry['sha256']) {
            throw FormatException(
              'Downloaded $name failed its SHA256 check.',
            );
          }
          final tmp = File('${dir.path}/$name.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
          staged.add(tmp);
        }
        for (final entry in entries) {
          final name = entry['name'] as String;
          final tmp = File('${dir.path}/$name.tmp');
          final target = File('${dir.path}/$name');
          if (await target.exists()) await target.delete();
          await tmp.rename(target.path);
        }
        await localManifest.writeAsString(jsonEncode(remote), flush: true);
        await _cleanupExtracted(dir, keepGenerated: remoteGenerated);
        await _recordCheck(dir);
        await IpGeoDatabase.refresh();
        final db = await IpGeoDatabase.open();
        return GeoUpdateResult(updated: true, hasData: db.hasData);
      } catch (e) {
        for (final tmp in staged) {
          if (await tmp.exists()) await tmp.delete();
        }
        final db = await IpGeoDatabase.open();
        return GeoUpdateResult(
          updated: false,
          hasData: db.hasData,
          error: e.toString(),
        );
      }
    } catch (e) {
      // Seeding or the manifest fetch failed (e.g. offline). Local data,
      // if any, is untouched; report whether it exists.
      final db = await IpGeoDatabase.open();
      return GeoUpdateResult(
        updated: false,
        hasData: db.hasData,
        error: e.toString(),
      );
    }
  }

  Future<bool> _localFilesComplete(
    Directory dir,
    List<Map<String, dynamic>> entries,
  ) async {
    for (final entry in entries) {
      final file = File('${dir.path}/${entry['name']}');
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      if (bytes.length != entry['bytes'] ||
          sha256.convert(bytes).toString() != entry['sha256']) {
        return false;
      }
    }
    return true;
  }

  Future<void> _recordCheck(Directory dir) async {
    try {
      await File('${dir.path}/last_check.txt').writeAsString(
        DateTime.now().millisecondsSinceEpoch.toString(),
        flush: true,
      );
    } catch (_) {
      // Throttle bookkeeping is best-effort.
    }
  }

  /// Drops extracted .bin files of old versions and stray .tmp files.
  Future<void> _cleanupExtracted(
    Directory dir, {
    required String keepGenerated,
  }) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.split('/').last;
        if (name.endsWith('.tmp')) {
          try {
            await entity.delete();
          } catch (_) {}
        } else if (name.startsWith('ipgeo-') && name.endsWith('.bin')) {
          if (!name.contains(keepGenerated)) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    // Legacy extracted files from the bundled-data era (v0.1.0) live in
    // the support dir root; drop them, the new data lives under geo/.
    try {
      final support = await getApplicationSupportDirectory();
      await for (final entity in Directory(support.path).list()) {
        if (entity is! File) continue;
        final name = entity.path.split('/').last;
        if (name.startsWith('ipgeo-') &&
            (name.endsWith('.bin') || name.endsWith('.bin.tmp'))) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}

/// Offline lookup over the locally downloaded monthly IPv4 and IPv6 SBGX
/// bundles. Server addresses are never sent to the data publisher or
/// another service.
///
/// v21: the bundles are no longer in the APK; they are downloaded to
/// `<support>/geo/` by [GeoDataUpdater]. If no usable local data exists yet
/// (first launch, still downloading, offline, corrupt), [open] returns an
/// empty database whose lookups return null, and the caller falls back to
/// the default spot — the app never blocks or errors on geo.
class IpGeoDatabase {
  IpGeoDatabase._(this._readers);

  IpGeoDatabase._empty() : _readers = const {};

  static const attribution =
      'IP geolocation by DB-IP (https://db-ip.com), CC BY 4.0 '
      '(https://creativecommons.org/licenses/by/4.0/).';

  /// Bundled seed manifest (assets/geo/manifest.json). The updater copies
  /// it to the local data dir on first launch; the remote manifest is the
  /// source of truth after that.
  static const manifestAsset = 'assets/geo/manifest.json';

  static Future<IpGeoDatabase>? _opening;

  final Map<int, SbgxBundleReader> _readers;

  /// Whether any family reader is loaded (i.e. usable local data exists).
  bool get hasData => _readers.isNotEmpty;

  Future<void> _tail = Future<void>.value();

  /// Opens the database from the locally downloaded data.
  /// Never throws: without usable local data it returns an empty database.
  static Future<IpGeoDatabase> open() {
    _opening ??= _open().catchError((Object error, StackTrace stack) {
      debugPrint('IpGeoDatabase.open failed, using empty database: $error');
      _opening = null;
      return IpGeoDatabase._empty();
    });
    return _opening!;
  }

  /// Closes the current readers and re-opens from local data.
  /// Called after the updater installs a new dataset, and by tests to
  /// reset the singleton between data-dir changes.
  static Future<IpGeoDatabase> refresh() async {
    final previous = _opening;
    _opening = null;
    if (previous != null) {
      try {
        final db = await previous;
        await db._closeReaders();
      } catch (_) {
        // Opening failed; nothing to close.
      }
    }
    return open();
  }

  Future<void> _closeReaders() async {
    for (final reader in _readers.values) {
      await reader.close();
    }
  }

  static Future<IpGeoDatabase> _open() async {
    final dir = await geoDataDir();
    final manifestFile = File('${dir.path}/manifest.json');
    if (!await manifestFile.exists()) {
      return IpGeoDatabase._empty();
    }
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    if (manifest['version'] != 1 || manifest['generated'] is! String) {
      return IpGeoDatabase._empty();
    }
    final generated = manifest['generated'] as String;
    final yearMonth = generated.split('-');
    final year = int.tryParse(yearMonth.isNotEmpty ? yearMonth[0] : '');
    final month =
        int.tryParse(yearMonth.length > 1 ? yearMonth[1] : '');
    if (year == null || month == null) {
      return IpGeoDatabase._empty();
    }
    final entries = (manifest['assets'] as List).cast<Map<String, dynamic>>();
    final readers = <int, SbgxBundleReader>{};
    for (final family in const [4, 6]) {
      try {
        // A family may be missing (partial download): skip it, keep the other.
        final matches =
            entries.where((e) => e['family'] == family).toList();
        if (matches.isEmpty) continue;
        final entry = matches.single;
        final name = entry['name'] as String;
        final packedFile = File('${dir.path}/$name');
        if (!await packedFile.exists()) continue;
        final packed = await packedFile.readAsBytes();
        if (packed.length != entry['bytes'] ||
            sha256.convert(packed).toString() != entry['sha256']) {
          debugPrint('Local geo $name failed its SHA256 check, skipping.');
          continue;
        }
        final extracted = File('${dir.path}/ipgeo-$generated-ip$family.bin');
        final isCached = await extracted.exists() &&
            await extracted.length() == entry['unpackedBytes'];
        if (!isCached) {
          final temporary = File('${extracted.path}.tmp');
          if (await temporary.exists()) await temporary.delete();
          try {
            await Stream<List<int>>.value(packed)
                .transform(gzip.decoder)
                .pipe(temporary.openWrite());
            if (await temporary.length() != entry['unpackedBytes']) {
              throw FormatException('Expanded $name has an unexpected size.');
            }
            if (await extracted.exists()) await extracted.delete();
            await temporary.rename(extracted.path);
          } catch (_) {
            if (await temporary.exists()) await temporary.delete();
            rethrow;
          }
        }
        final reader = await SbgxBundleReader.openFile(
          extracted,
          expectedFamily: family,
        );
        if (reader.year != year ||
            reader.month != month ||
            reader.recordCount != entry['records']) {
          await reader.close();
          throw FormatException(
            'IPv$family database metadata differs from its manifest.',
          );
        }
        readers[family] = reader;
      } catch (e) {
        debugPrint('Skipping IPv$family geo data: $e');
      }
    }
    return IpGeoDatabase._(readers);
  }

  /// Only numeric, public IPs are eligible; hostnames are never DNS-resolved.
  Future<IpGeoLocation?> lookup(String host) {
    final normalized = host.trim().replaceAll(RegExp(r'^\[|\]$'), '');
    final ip = InternetAddress.tryParse(normalized);
    if (ip == null || !isPublicInternetAddress(ip)) {
      return Future<IpGeoLocation?>.value(null);
    }
    final bytes = ip.rawAddress;
    final isV4Mapped =
        ip.type == InternetAddressType.IPv6 &&
        bytes.take(10).every((v) => v == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255;
    final lookupIp = isV4Mapped
        ? InternetAddress.fromRawAddress(bytes.sublist(12))
        : ip;
    final family = lookupIp.type == InternetAddressType.IPv4 ? 4 : 6;
    final result = _tail.then((_) async {
      final point = await _readers[family]?.lookup(lookupIp.address);
      return point == null ? null : IpGeoLocation.fromPoint(point);
    });
    // RandomAccessFile has a shared seek position; serialize its lookups.
    // 但 _tail 绝不能被一次卡住的读永远拖死（读挂起时，后面所有查库
    // 都会堵上）：真机上一次读是毫秒级，5 秒超时只防极端情况；
    // 超时后 _tail 放行，后面的读自己重新定位再读，顶多这次读的
    // 结果丢了（调用方有自己的超时/默认落点兜底）。
    _tail = result
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {})
        .timeout(const Duration(seconds: 5), onTimeout: () {});
    return result;
  }

  static bool isPublicInternetAddress(InternetAddress ip) {
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      final a = b[0], second = b[1];
      if (a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 169 && second == 254) ||
          (a == 172 && second >= 16 && second <= 31) ||
          (a == 192 && second == 168) ||
          (a == 100 && second >= 64 && second <= 127) ||
          (a == 192 && second == 0 && b[2] == 0) ||
          (a == 198 && (second == 18 || second == 19))) {
        return false;
      }
      return true;
    }
    final allZero = b.every((v) => v == 0);
    final loopback = b.take(15).every((v) => v == 0) && b[15] == 1;
    final v4Mapped =
        b.take(10).every((v) => v == 0) && b[10] == 255 && b[11] == 255;
    if (allZero ||
        loopback ||
        b[0] == 0xff ||
        (b[0] & 0xfe) == 0xfc ||
        (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)) {
      return false;
    }
    if (v4Mapped) {
      return isPublicInternetAddress(
        InternetAddress.fromRawAddress(b.sublist(12)),
      );
    }
    // Documentation-only IPv6 block has no real-world location.
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) {
      return false;
    }
    return true;
  }
}
