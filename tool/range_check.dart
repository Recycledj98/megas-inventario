// Verifica que la escritura por rangos reconstruye exactamente el archivo:
// aplicar dirtyRecords + appendedRegion + headerStampBytes sobre los bytes
// originales debe dar lo mismo que toBytes() (salvo la fecha del header).
//   dart run tool/range_check.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:megas_inventario/services/dbf_service.dart';

void main() {
  final original = File('Indices/STOCKLOT.DBF').readAsBytesSync();
  final dbf = DbfFile.open(Uint8List.fromList(original));

  // Simular lo que hace enviar(): updates in-place + appends.
  dbf.setFields(10, {'UNIDAD_LOT': 123.5, 'UNIANT_LOT': 7.0});
  dbf.setFields(500, {'FECCAD_LOT': DateTime(2027, 1, 15)});
  dbf.appendRecord({
    'CODIGO_ART': 'TEST1', 'CODIGO_ALM': '1', 'CODIGO_LOT': 'L-001',
    'FECALT_LOT': DateTime(2026, 6, 10), 'FECCAD_LOT': DateTime(2027, 6, 10),
    'UNIDAD_LOT': 5.0, 'UNIANT_LOT': 0.0, 'CODIGO_PAL': '', 'CODIGO_UBI': '',
  });
  dbf.appendRecord({
    'CODIGO_ART': 'TEST2', 'CODIGO_ALM': '1', 'CODIGO_LOT': 'L-002',
    'FECALT_LOT': DateTime(2026, 6, 10), 'FECCAD_LOT': DateTime(2027, 6, 10),
    'UNIDAD_LOT': 9.0, 'UNIANT_LOT': 0.0, 'CODIGO_PAL': '', 'CODIGO_UBI': '',
  });

  // Reconstruir aplicando los rangos sobre el original.
  final esperado = dbf.toBytes();
  final remoto = Uint8List(esperado.length)
    ..setRange(0, original.length, original);
  for (final i in dbf.dirtyRecords) {
    final r = dbf.recordRegion(i);
    remoto.setRange(r.offset, r.offset + r.bytes.length, r.bytes);
  }
  final a = dbf.appendedRegion();
  remoto.setRange(a.offset, a.offset + a.bytes.length, a.bytes);
  final stamp = dbf.headerStampBytes();
  remoto.setRange(1, 1 + stamp.length, stamp);

  int diffs = 0;
  for (int i = 0; i < esperado.length; i++) {
    // Bytes 1-3 del header son la fecha de modificación: toBytes() no la
    // actualiza, el stamp sí — se ignoran.
    if (i >= 1 && i <= 3) continue;
    if (esperado[i] != remoto[i]) {
      diffs++;
      if (diffs <= 5) print('diff en byte $i: ${esperado[i]} vs ${remoto[i]}');
    }
  }
  print('dirty=${dbf.dirtyRecords} appends=${dbf.hasAppends} '
      'región=${a.offset}+${a.bytes.length}');
  print(diffs == 0 ? 'RANGOS OK: reconstrucción idéntica' : 'FALLO: $diffs diffs');
  exit(diffs == 0 ? 0 : 1);
}
