import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'globe.dart';

/// Approximate city-level coordinates from the locally bundled DB-IP Lite data.
/// The SBGX data contains coordinates, not city labels, so the UI says so.
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
  }) : _file = file,
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

/// Offline lookup over preloaded monthly IPv4 and IPv6 SBGX bundles.
/// Server addresses are never sent to the data publisher or another service.
class IpGeoDatabase {
  IpGeoDatabase._(this._readers);

  static const datasetVersion = '2026-11';
  static const attribution =
      'IP geolocation by DB-IP (https://db-ip.com), CC BY 4.0 '
      '(https://creativecommons.org/licenses/by/4.0/).';
  static const manifestAsset = 'assets/geo/manifest.json';
  static Future<IpGeoDatabase>? _opening;

  final Map<int, SbgxBundleReader> _readers;
  Future<void> _tail = Future<void>.value();

  static Future<IpGeoDatabase> open() =>
      _opening ??= _open().catchError((Object error, StackTrace stack) {
        _opening = null;
        Error.throwWithStackTrace(error, stack);
      });

  static Future<IpGeoDatabase> _open() async {
    final manifestData = await rootBundle.load(manifestAsset);
    final manifestBytes = manifestData.buffer.asUint8List(
      manifestData.offsetInBytes,
      manifestData.lengthInBytes,
    );
    final manifest =
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    if (manifest['generated'] != datasetVersion || manifest['version'] != 1) {
      throw const FormatException('Unsupported bundled IP database manifest.');
    }
    final entries = (manifest['assets'] as List).cast<Map<String, dynamic>>();
    final support = await getApplicationSupportDirectory();
    final readers = <int, SbgxBundleReader>{};
    try {
      for (final family in const [4, 6]) {
        final entry = entries.singleWhere((e) => e['family'] == family);
        final name = entry['name'] as String;
        final compressed = await rootBundle.load('assets/geo/$name');
        final packed = compressed.buffer.asUint8List(
          compressed.offsetInBytes,
          compressed.lengthInBytes,
        );
        if (packed.length != entry['bytes'] ||
            sha256.convert(packed).toString() != entry['sha256']) {
          throw FormatException(
            'Bundled $name failed its SHA256 manifest check.',
          );
        }
        final extracted = File(
          '${support.path}/ipgeo-$datasetVersion-ip$family.bin',
        );
        final isCached =
            await extracted.exists() &&
            await extracted.length() == entry['unpackedBytes'];
        if (!isCached) {
          final temporary = File('${extracted.path}.tmp');
          if (await temporary.exists()) await temporary.delete();
          try {
            await Stream<List<int>>.value(
              packed,
            ).transform(gzip.decoder).pipe(temporary.openWrite());
            if (await temporary.length() != entry['unpackedBytes']) {
              throw FormatException('Expanded $name has an unexpected size.');
            }
            final previous = await extracted.exists();
            if (previous) await extracted.delete();
            await temporary.rename(extracted.path);
          } catch (_) {
            if (await temporary.exists()) await temporary.delete();
            rethrow;
          }
        }
        readers[family] = await SbgxBundleReader.openFile(
          extracted,
          expectedFamily: family,
        );
        final reader = readers[family]!;
        if (reader.year != 2026 ||
            reader.month != 11 ||
            reader.recordCount != entry['records']) {
          throw FormatException(
            'Bundled IPv$family database metadata differs from its manifest.',
          );
        }
      }
      return IpGeoDatabase._(readers);
    } catch (_) {
      for (final reader in readers.values) {
        await reader.close();
      }
      rethrow;
    }
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
