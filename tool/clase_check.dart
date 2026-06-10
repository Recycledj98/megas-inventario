// Cuenta valores no vacíos de CODIG#_CLA en ARTICULO.DBF de muestra.
import 'dart:io';
import 'dart:typed_data';
import 'package:megas_inventario/services/dbf_service.dart';

void main() {
  final dbf = DbfFile.open(
      Uint8List.fromList(File('Indices/ARTICULO.DBF').readAsBytesSync()));
  for (final n in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) {
    final vals = <String>{};
    int count = 0;
    for (final (_, rec) in dbf.records()) {
      final v = (rec['CODIG${n}_CLA'] as String? ?? '').trim();
      if (v.isNotEmpty) { count++; vals.add(v); }
    }
    print('CODIG${n}_CLA: $count artículos, distintos: ${vals.take(8).toList()}');
  }
}
