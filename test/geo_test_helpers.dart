import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Builds a minimal valid SBGX v1 IPv4 bundle in memory.
///
/// Layout (see `SbgxBundleReader.openFile` in lib/ip_geo_database.dart):
/// 16-byte header (`SBGX`, version 1, family 4, year uint16 BE, month,
/// record count uint32 BE), then a 257-entry bucket table (uint32 BE each),
/// then the records (7 bytes each: 3-byte start offset + int16 lat + int16
/// lon, big-endian).
///
/// The bundle holds exactly one record, in bucket 8 (first octet 8) with
/// start offset 0, so it covers the whole 8.x.x.x range: 8.8.8.8 resolves to
/// the given coordinates, every other first octet has no record.
Uint8List buildSbgxV4({
  required String generated,
  required double lat,
  required double lon,
}) {
  final parts = generated.split('-');
  final year = int.parse(parts[0]);
  final month = int.parse(parts[1]);
  const bucketCount = 256;
  const recordCount = 1;
  final recordOffset = 16 + (bucketCount + 1) * 4;
  final bytes = ByteData(recordOffset + recordCount * 7);
  // Header.
  bytes.setUint8(0, 0x53); // 'S'
  bytes.setUint8(1, 0x42); // 'B'
  bytes.setUint8(2, 0x47); // 'G'
  bytes.setUint8(3, 0x58); // 'X'
  bytes.setUint8(4, 1); // version
  bytes.setUint8(5, 4); // family: IPv4
  bytes.setUint16(6, year, Endian.big);
  bytes.setUint8(8, month);
  bytes.setUint32(9, recordCount, Endian.big);
  // Bytes 13-15 are padding, left 0.
  // Bucket table: buckets 0-8 hold 0 records before them, buckets 9-256
  // hold 1 (the single record lives in bucket 8).
  for (var i = 0; i <= bucketCount; i++) {
    bytes.setUint32(16 + i * 4, i <= 8 ? 0 : 1, Endian.big);
  }
  // The single record: start offset 0, then lat/lon as int16.
  bytes.setUint8(recordOffset, 0);
  bytes.setUint8(recordOffset + 1, 0);
  bytes.setUint8(recordOffset + 2, 0);
  bytes.setInt16(recordOffset + 3, (lat / 90 * 32767).round(), Endian.big);
  bytes.setInt16(recordOffset + 5, (lon / 180 * 32767).round(), Endian.big);
  return bytes.buffer.asUint8List();
}

/// One synthetic geo dataset: a gzipped SBGX v1 IPv4 bundle plus the
/// manifest JSON that describes it (matching byte length + SHA-256).
///
/// Defaults resolve 8.8.8.8 to ~37.75°, -122.4° (US, same ranges the old
/// bundled-data test asserted). Pass another `generated`/`lat`/`lon` for a
/// "newer dataset" (e.g. 2026-12, London 51.5, -0.12).
class SyntheticGeoDataset {
  SyntheticGeoDataset({
    this.generated = '2026-11',
    this.lat = 37.75,
    this.lon = -122.4,
  }) : _sbgx = buildSbgxV4(generated: generated, lat: lat, lon: lon) {
    gzipped = gzip.encode(_sbgx);
  }

  final String generated;
  final double lat;
  final double lon;
  final Uint8List _sbgx;
  late final List<int> gzipped;

  String get manifestJson => jsonEncode({
    'version': 1,
    'generated': generated,
    'assets': [
      {
        'name': 'ip4_city_v1.bin.gz',
        'family': 4,
        // The database checks these on open (expanded size + record
        // count), so the synthetic manifest must carry them, like the
        // real DB-IP manifest does.
        'records': 1,
        'bytes': gzipped.length,
        'unpackedBytes': _sbgx.length,
        'sha256': sha256.convert(gzipped).toString(),
      },
    ],
  });

  Map<String, dynamic> get manifestMap =>
      jsonDecode(manifestJson) as Map<String, dynamic>;
}

/// Writes a dataset's files into [dir] exactly as the app keeps them after
/// a successful download: `ip4_city_v1.bin.gz` + `manifest.json`.
Future<void> seedGeoDataDir(
  Directory dir,
  SyntheticGeoDataset dataset,
) async {
  await dir.create(recursive: true);
  await File(
    '${dir.path}/ip4_city_v1.bin.gz',
  ).writeAsBytes(dataset.gzipped, flush: true);
  await File(
    '${dir.path}/manifest.json',
  ).writeAsString(dataset.manifestJson, flush: true);
}
