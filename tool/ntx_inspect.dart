// Inspector de archivos NTX (Clipper/Harbour DBFNTX) — uso:
//   dart run tool/ntx_inspect.dart Indices/artic_1.ntx [--keys N] [--hex]
//
// Parsea el header, recorre el árbol B in-order y verifica que las claves
// salgan en orden ascendente byte a byte (Latin-1). Sirve para fijar el
// contrato del writer: collation, formato de claves numéricas y estructura.

import 'dart:io';
import 'dart:typed_data';

const pageSize = 1024;

class NtxHeader {
  final int signature; // u16 @0
  final int version; // u16 @2
  final int root; // u32 @4  offset de la página raíz
  final int nextPage; // u32 @8  primer offset libre (≈ tamaño de archivo)
  final int itemSize; // u16 @12 = keySize + 8
  final int keySize; // u16 @14
  final int keyDec; // u16 @16
  final int maxItem; // u16 @18 claves máx por página
  final int halfPage; // u16 @20
  final String keyExpr; // char[256] @22, terminada en NUL
  final int unique; // u8 @278

  NtxHeader._(this.signature, this.version, this.root, this.nextPage,
      this.itemSize, this.keySize, this.keyDec, this.maxItem, this.halfPage,
      this.keyExpr, this.unique);

  static NtxHeader parse(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final exprBytes = bytes.sublist(22, 22 + 256);
    final nul = exprBytes.indexOf(0);
    final expr = String.fromCharCodes(
        exprBytes.sublist(0, nul < 0 ? 256 : nul));
    return NtxHeader._(
      bd.getUint16(0, Endian.little),
      bd.getUint16(2, Endian.little),
      bd.getUint32(4, Endian.little),
      bd.getUint32(8, Endian.little),
      bd.getUint16(12, Endian.little),
      bd.getUint16(14, Endian.little),
      bd.getUint16(16, Endian.little),
      bd.getUint16(18, Endian.little),
      bd.getUint16(20, Endian.little),
      expr,
      bytes[278],
    );
  }
}

class NtxEntry {
  final int recno;
  final Uint8List key;
  NtxEntry(this.recno, this.key);
}

/// Recorre el árbol in-order desde [pageOffset] y añade entradas a [out].
void walk(Uint8List bytes, NtxHeader h, int pageOffset, List<NtxEntry> out,
    Set<int> visited) {
  if (pageOffset == 0) return;
  if (!visited.add(pageOffset)) {
    throw StateError('ciclo: página $pageOffset visitada dos veces');
  }
  if (pageOffset + pageSize > bytes.length) {
    throw StateError('página $pageOffset fuera de archivo');
  }
  final bd = ByteData.sublistView(bytes, pageOffset, pageOffset + pageSize);
  final count = bd.getUint16(0, Endian.little);
  if (count > h.maxItem) {
    throw StateError('página $pageOffset: count=$count > maxItem=${h.maxItem}');
  }
  // Array de offsets u16 (count+1 entradas) relativo al inicio de página.
  for (int i = 0; i <= count; i++) {
    final itemOff = bd.getUint16(2 + i * 2, Endian.little);
    final child = bd.getUint32(itemOff, Endian.little);
    walk(bytes, h, child, out, visited);
    if (i < count) {
      final recno = bd.getUint32(itemOff + 4, Endian.little);
      final key = Uint8List.sublistView(
          bytes, pageOffset + itemOff + 8, pageOffset + itemOff + 8 + h.keySize);
      out.add(NtxEntry(recno, Uint8List.fromList(key)));
    }
  }
}

int compareBytes(Uint8List a, Uint8List b) {
  for (int i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

String latin1Str(Uint8List b) =>
    String.fromCharCodes(b.map((c) => c >= 32 ? c : 46));

String hexStr(Uint8List b) =>
    b.map((c) => c.toRadixString(16).padLeft(2, '0')).join(' ');

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('uso: dart run tool/ntx_inspect.dart <archivo.ntx> [--keys N] [--hex]');
    exit(2);
  }
  final path = args[0];
  final showKeys = args.contains('--keys')
      ? int.parse(args[args.indexOf('--keys') + 1])
      : 5;
  final hex = args.contains('--hex');

  final bytes = File(path).readAsBytesSync();
  final h = NtxHeader.parse(Uint8List.fromList(bytes));

  print('=== $path (${bytes.length} bytes, ${bytes.length ~/ pageSize} páginas) ===');
  print('signature=0x${h.signature.toRadixString(16)} version=${h.version}');
  print('root=${h.root} nextPage=${h.nextPage}');
  print('itemSize=${h.itemSize} keySize=${h.keySize} keyDec=${h.keyDec}');
  print('maxItem=${h.maxItem} halfPage=${h.halfPage} unique=${h.unique}');
  print('expr="${h.keyExpr}"');
  if (h.itemSize != h.keySize + 8) {
    print('!! itemSize != keySize+8 — revisar supuesto de layout');
  }

  final entries = <NtxEntry>[];
  walk(Uint8List.fromList(bytes), h, h.root, entries, <int>{});
  print('claves: ${entries.length}');

  // Verificar orden ascendente byte a byte.
  int violations = 0;
  for (int i = 1; i < entries.length; i++) {
    if (compareBytes(entries[i - 1].key, entries[i].key) > 0) {
      violations++;
      if (violations <= 5) {
        print('DESORDEN en #$i:');
        print('  prev rec=${entries[i - 1].recno} "${latin1Str(entries[i - 1].key)}" [${hexStr(entries[i - 1].key)}]');
        print('  curr rec=${entries[i].recno} "${latin1Str(entries[i].key)}" [${hexStr(entries[i].key)}]');
      }
    }
  }
  print(violations == 0
      ? 'ORDEN OK: ascendente byte a byte (Latin-1 crudo)'
      : 'VIOLACIONES DE ORDEN BYTE A BYTE: $violations — collation NO es orden de bytes');

  // Claves con bytes > 127 (acentos/Ñ) → evidencia de collation.
  final accented = entries.where((e) => e.key.any((b) => b > 127)).take(10);
  final accList = accented.toList();
  if (accList.isNotEmpty) {
    print('claves con bytes >127 (${accList.length} primeras):');
    for (final e in accList) {
      print('  rec=${e.recno} "${latin1Str(e.key)}"${hex ? ' [${hexStr(e.key)}]' : ''}');
    }
  } else {
    print('sin claves con bytes >127');
  }

  if (args.contains('--pages')) {
    print('mapa de páginas (offset: count, tipo, hijos):');
    for (int off = pageSize; off + pageSize <= bytes.length; off += pageSize) {
      final bd2 = ByteData.sublistView(
          Uint8List.fromList(bytes), off, off + pageSize);
      final cnt = bd2.getUint16(0, Endian.little);
      final children = <int>[];
      for (int i = 0; i <= cnt && i <= h.maxItem; i++) {
        final io = bd2.getUint16(2 + i * 2, Endian.little);
        children.add(bd2.getUint32(io, Endian.little));
      }
      final isLeaf = children.every((c) => c == 0);
      print('  $off: count=$cnt ${isLeaf ? "HOJA" : "RAMA hijos=$children"}'
          '${off == h.root ? "  <-- ROOT" : ""}');
    }
  }

  print('primeras $showKeys:');
  for (final e in entries.take(showKeys)) {
    print('  rec=${e.recno} "${latin1Str(e.key)}"${hex ? ' [${hexStr(e.key)}]' : ''}');
  }
  print('últimas $showKeys:');
  for (final e in entries.skip(entries.length - showKeys < 0 ? 0 : entries.length - showKeys)) {
    print('  rec=${e.recno} "${latin1Str(e.key)}"${hex ? ' [${hexStr(e.key)}]' : ''}');
  }
}
