// Valida NtxBuilder contra los índices NTX reales generados por el ERP GC.
//   dart run tool/ntx_compare.dart
//
// Para cada DBF de Indices/ reconstruye sus índices y los compara con los
// .ntx de producción. Comparación: header completo + por página (count,
// array de offsets, items usados y el hijo derecho del slot extra). La zona
// de items más allá de count se ignora: Clipper deja basura residual del
// buffer al escribir páginas parciales.

import 'dart:io';
import 'dart:typed_data';

import 'package:megas_inventario/services/dbf_service.dart';
import 'package:megas_inventario/services/ntx_service.dart';

const pageSize = 1024;

// Nombres de archivo reales en Indices/ (minúsculas tal como se copiaron).
const sampleFiles = {
  'ARTICULO.DBF': ['artic_1.ntx', 'artic_2.ntx', 'artic_3.ntx', 'artic_4.ntx', 'artic_5.ntx'],
  'STOCKLOT.DBF': ['stocklo1.ntx', 'stocklo2.ntx', 'stocklo3.ntx', 'stocklo4.ntx'],
  'E_S_ALMA.DBF': ['e_s_al_1.ntx', 'e_s_al_2.ntx', 'e_s_al_3.ntx', 'e_s_al_4.ntx', 'e_s_al_5.ntx'],
};

void main(List<String> args) {
  final dump = args.contains('--dump'); // escribe built a Indices/built_*.ntx
  int pass = 0, fail = 0;
  for (final entry in sampleFiles.entries) {
    final dbf = DbfFile.open(
        Uint8List.fromList(File('Indices/${entry.key}').readAsBytesSync()));
    final defs = ntxIndexesByDbf[entry.key]!;
    for (int d = 0; d < defs.length; d++) {
      final def = defs[d];
      final real = Uint8List.fromList(
          File('Indices/${entry.value[d]}').readAsBytesSync());
      final sw = Stopwatch()..start();
      final built = NtxBuilder.build(dbf, def.expression);
      sw.stop();
      if (dump) {
        File('Indices/built_${entry.value[d]}').writeAsBytesSync(built);
      }
      final errors = compare(built, real);
      if (errors.isEmpty) {
        pass++;
        print('PASS ${def.ntxFile}  (${built.length} bytes, ${sw.elapsedMilliseconds} ms)');
      } else {
        fail++;
        print('FAIL ${def.ntxFile}:');
        for (final e in errors.take(8)) {
          print('  $e');
        }
        if (errors.length > 8) print('  ... y ${errors.length - 8} más');
      }
    }
  }
  print('\n$pass PASS, $fail FAIL');
  exit(fail == 0 ? 0 : 1);
}

List<String> compare(Uint8List built, Uint8List real) {
  final errors = <String>[];
  if (built.length != real.length) {
    errors.add('tamaño: built=${built.length} real=${real.length}');
    return errors;
  }

  // Header completo.
  for (int i = 0; i < pageSize; i++) {
    if (built[i] != real[i]) {
      errors.add('header byte $i: built=${built[i]} real=${real[i]}');
      if (errors.length > 10) return errors;
    }
  }
  if (errors.isNotEmpty) return errors;

  final bd = ByteData.sublistView(built);
  final itemSize = bd.getUint16(12, Endian.little);
  final maxItem = bd.getUint16(18, Endian.little);
  final base = 2 + (maxItem + 1) * 2;

  // Comparación lógica por página: los items se leen a través del array de
  // slots de cada archivo. Harbour deja el array permutado en las páginas que
  // reequilibra al cerrar el índice; cualquier permutación válida es
  // equivalente para DBFNTX (es pura indirección), así que no se compara la
  // disposición física, solo el contenido en orden lógico.
  for (int off = pageSize; off + pageSize <= built.length; off += pageSize) {
    final bb = ByteData.sublistView(built, off, off + pageSize);
    final rb = ByteData.sublistView(real, off, off + pageSize);
    final bCount = bb.getUint16(0, Endian.little);
    final rCount = rb.getUint16(0, Endian.little);
    if (bCount != rCount) {
      errors.add('página $off: count built=$bCount real=$rCount');
      continue;
    }
    // Validar que ambos arrays de slots son permutaciones válidas.
    for (final pair in [(bb, 'built'), (rb, 'real')]) {
      final seen = <int>{};
      for (int i = 0; i <= maxItem; i++) {
        final so = pair.$1.getUint16(2 + i * 2, Endian.little);
        if (so < base || so + itemSize > pageSize || (so - base) % itemSize != 0 ||
            !seen.add(so)) {
          errors.add('página $off (${pair.$2}): slot[$i]=$so inválido');
        }
      }
    }
    for (int i = 0; i <= bCount; i++) {
      final bo = bb.getUint16(2 + i * 2, Endian.little);
      final ro = rb.getUint16(2 + i * 2, Endian.little);
      if (i == bCount) {
        // Slot extra: solo el hijo derecho.
        final bRight = bb.getUint32(bo, Endian.little);
        final rRight = rb.getUint32(ro, Endian.little);
        if (bRight != rRight) {
          errors.add('página $off: hijo derecho built=$bRight real=$rRight');
        }
        break;
      }
      for (int k = 0; k < itemSize; k++) {
        if (built[off + bo + k] != real[off + ro + k]) {
          errors.add('página $off item $i byte $k: '
              'built=${built[off + bo + k]} real=${real[off + ro + k]}');
          if (errors.length > 20) return errors;
          break;
        }
      }
    }
  }
  return errors;
}
