import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:megas_inventario/services/dbf_service.dart';
import 'package:megas_inventario/services/ntx_service.dart';

// Tests del writer NTX. El formato está validado byte a byte contra los
// índices de producción del ERP GC (ver tool/ntx_compare.dart, que requiere
// la carpeta Indices/ con muestras reales). Estos tests cubren la lógica con
// DBFs sintéticos: estructura del árbol, orden, reequilibrado de cola,
// claves numéricas y casos límite.

const _pageSize = 1024;

/// Construye un DBF en memoria con los campos y registros dados.
Uint8List makeDbf(List<(String, String, int, int)> fieldDefs,
    List<Map<String, dynamic>> rows) {
  final headerSize = 32 + fieldDefs.length * 32 + 1;
  int recordSize = 1;
  for (final f in fieldDefs) {
    recordSize += f.$3;
  }
  final bytes = Uint8List(headerSize + 1);
  final bd = ByteData.sublistView(bytes);
  bytes[0] = 0x03;
  bd.setUint32(4, 0, Endian.little);
  bd.setUint16(8, headerSize, Endian.little);
  bd.setUint16(10, recordSize, Endian.little);
  int off = 32;
  for (final f in fieldDefs) {
    final name = f.$1.codeUnits;
    bytes.setRange(off, off + name.length, name);
    bytes[off + 11] = f.$2.codeUnitAt(0);
    bytes[off + 16] = f.$3;
    bytes[off + 17] = f.$4;
    off += 32;
  }
  bytes[off] = 0x0D;
  bytes[headerSize] = 0x1A;

  final dbf = DbfFile.open(bytes);
  for (final row in rows) {
    dbf.appendRecord(row);
  }
  return dbf.toBytes();
}

/// Lector NTX mínimo: recorre el árbol in-order y devuelve (recno, clave).
List<(int, String)> walkNtx(Uint8List ntx) {
  final bd = ByteData.sublistView(ntx);
  final root = bd.getUint32(4, Endian.little);
  final keySize = bd.getUint16(14, Endian.little);
  final maxItem = bd.getUint16(18, Endian.little);
  final out = <(int, String)>[];
  final visited = <int>{};

  void walk(int pageOffset) {
    if (pageOffset == 0) return;
    expect(visited.add(pageOffset), isTrue, reason: 'ciclo en página $pageOffset');
    expect(pageOffset + _pageSize, lessThanOrEqualTo(ntx.length));
    final pb = ByteData.sublistView(ntx, pageOffset, pageOffset + _pageSize);
    final count = pb.getUint16(0, Endian.little);
    expect(count, lessThanOrEqualTo(maxItem));
    for (int i = 0; i <= count; i++) {
      final itemOff = pb.getUint16(2 + i * 2, Endian.little);
      walk(pb.getUint32(itemOff, Endian.little));
      if (i < count) {
        final recno = pb.getUint32(itemOff + 4, Endian.little);
        final key = String.fromCharCodes(
            ntx.sublist(pageOffset + itemOff + 8, pageOffset + itemOff + 8 + keySize));
        out.add((recno, key));
      }
    }
  }

  walk(root);
  return out;
}

void main() {
  group('NtxBuilder', () {
    test('índice simple: claves ordenadas y recnos correctos', () {
      final dbf = DbfFile.open(makeDbf(
        [('CODIGO', 'C', 5, 0)],
        [for (final c in ['ZZ', 'AA', 'MM', 'BB']) {'CODIGO': c}],
      ));
      final entries = walkNtx(NtxBuilder.build(dbf, 'CODIGO'));
      expect(entries.map((e) => e.$2.trim()).toList(), ['AA', 'BB', 'MM', 'ZZ']);
      expect(entries.map((e) => e.$1).toList(), [2, 4, 3, 1]);
    });

    test('incluye registros marcados como borrados', () {
      final bytes = makeDbf(
        [('CODIGO', 'C', 5, 0)],
        [for (final c in ['A', 'B', 'C']) {'CODIGO': c}],
      );
      // Marcar el registro 2 como borrado (flag 0x2A).
      final dbf0 = DbfFile.open(bytes);
      final headerSize = bytes.length - 1 - 3 * dbf0.recordSize;
      bytes[headerSize + dbf0.recordSize] = 0x2A;
      final entries = walkNtx(NtxBuilder.build(DbfFile.open(bytes), 'CODIGO'));
      expect(entries.length, 3);
    });

    test('claves iguales conservan orden por recno', () {
      final dbf = DbfFile.open(makeDbf(
        [('CODIGO', 'C', 5, 0)],
        [for (int i = 0; i < 10; i++) {'CODIGO': 'X'}],
      ));
      final entries = walkNtx(NtxBuilder.build(dbf, 'CODIGO'));
      expect(entries.map((e) => e.$1).toList(), List.generate(10, (i) => i + 1));
    });

    test('concatenación con DTOS y STR', () {
      final dbf = DbfFile.open(makeDbf(
        [('COD', 'C', 3, 0), ('FEC', 'D', 8, 0), ('NUM', 'N', 7, 0)],
        [
          {'COD': 'B', 'FEC': DateTime(2026, 6, 10), 'NUM': 42},
          {'COD': 'A', 'FEC': null, 'NUM': null}, // fecha y numérico vacíos
        ],
      ));
      final entries = walkNtx(NtxBuilder.build(dbf, 'COD+DTOS(FEC)+STR(NUM)'));
      // Fecha vacía → 8 espacios; STR(N vacío) → 0 con ancho de campo.
      expect(entries[0].$2, 'A  ${' ' * 8}      0');
      expect(entries[1].$2, 'B  20260610     42');
    });

    test('clave numérica pura rellena con ceros', () {
      final dbf = DbfFile.open(makeDbf(
        [('NUM', 'N', 10, 0)],
        [
          {'NUM': 161027},
          {'NUM': 99},
          {'NUM': null},
        ],
      ));
      final entries = walkNtx(NtxBuilder.build(dbf, 'NUM'));
      expect(entries.map((e) => e.$2).toList(),
          ['0000000000', '0000000099', '0000161027']);
    });

    test('clave numérica negativa se rechaza', () {
      final dbf = DbfFile.open(makeDbf(
        [('NUM', 'N', 10, 0)],
        [{'NUM': -5}],
      ));
      expect(() => NtxBuilder.build(dbf, 'NUM'), throwsA(isA<NtxException>()));
    });

    test('campo inexistente se rechaza', () {
      final dbf = DbfFile.open(makeDbf([('COD', 'C', 3, 0)], [{'COD': 'A'}]));
      expect(() => NtxBuilder.build(dbf, 'NOEXISTE'),
          throwsA(isA<NtxException>()));
    });

    test('DBF vacío produce raíz hoja vacía válida', () {
      final dbf = DbfFile.open(makeDbf([('COD', 'C', 3, 0)], []));
      final ntx = NtxBuilder.build(dbf, 'COD');
      expect(ntx.length, _pageSize * 2);
      expect(walkNtx(ntx), isEmpty);
    });

    group('árbol multipágina (claves C 10 → maxItem 50, halfPage 25)', () {
      DbfFile bigDbf(int n) => DbfFile.open(makeDbf(
            [('COD', 'C', 10, 0)],
            [
              for (int i = 0; i < n; i++)
                {'COD': 'K${i.toString().padLeft(6, '0')}'}
            ],
          ));

      void checkAll(int n) {
        final ntx = NtxBuilder.build(bigDbf(n), 'COD');
        final entries = walkNtx(ntx);
        expect(entries.length, n, reason: 'n=$n');
        for (int i = 1; i < entries.length; i++) {
          expect(entries[i - 1].$2.compareTo(entries[i].$2), lessThan(0),
              reason: 'orden en n=$n, i=$i');
        }
        // Ninguna página (salvo la raíz) por debajo de halfPage.
        final bd = ByteData.sublistView(ntx);
        final root = bd.getUint32(4, Endian.little);
        final halfPage = bd.getUint16(20, Endian.little);
        for (int off = _pageSize; off + _pageSize <= ntx.length; off += _pageSize) {
          final count =
              ByteData.sublistView(ntx, off).getUint16(0, Endian.little);
          if (off != root) {
            expect(count, greaterThanOrEqualTo(halfPage),
                reason: 'página $off con $count claves (n=$n)');
          }
        }
      }

      test('llenado exacto y desbordes ±1', () {
        // 50=hoja única exacta; 51=desborde justo (cola vacía → rebalanceo);
        // 52, 101/102 (dos ciclos), 792 (caso real artic_1).
        for (final n in [1, 49, 50, 51, 52, 75, 101, 102, 792]) {
          checkAll(n);
        }
      });

      test('árbol de 3 niveles', () {
        // > 50*51 claves fuerza tercer nivel; 2602 = desborde justo de L1.
        for (final n in [2601, 2602, 2650, 5000]) {
          checkAll(n);
        }
      });
    });

    test('registro de definiciones cubre los DBF que modifica la app', () {
      expect(ntxIndexesByDbf.keys,
          containsAll(['ARTICULO.DBF', 'STOCKLOT.DBF', 'E_S_ALMA.DBF']));
      expect(ntxIndexesByDbf['ARTICULO.DBF'], hasLength(5));
      expect(ntxIndexesByDbf['STOCKLOT.DBF'], hasLength(4));
      expect(ntxIndexesByDbf['E_S_ALMA.DBF'], hasLength(5));
    });
  });
}
