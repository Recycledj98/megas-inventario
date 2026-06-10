import 'dart:typed_data';

import 'dbf_service.dart';

// Writer de índices NTX (Clipper/Harbour DBFNTX) — pure Dart.
//
// Reconstruye el índice completo (bulk-load bottom-up, igual que INDEX ON /
// REINDEX de Clipper) a partir de un DBF y la expresión de clave. Verificado
// byte a byte contra índices generados por el ERP GC (ver tool/ntx_compare.dart).
//
// Reglas del formato deducidas de los índices de producción:
//  - Orden de claves: comparación byte a byte sin collation (página de códigos
//    OEM del DBF tal cual). Claves iguales → orden por recno ascendente.
//  - El índice incluye TODOS los registros, también los marcados borrados.
//  - DTOS(campo D) y STR(campo N) == bytes crudos del campo en el registro.
//  - Índice de clave numérica (expresión = un único campo N): los espacios a
//    la izquierda se sustituyen por '0'.
//  - maxItem = ((1022 ~/ (itemSize+2)) - 1) redondeado hacia abajo a par.

class NtxException implements Exception {
  final String message;
  NtxException(this.message);
  @override
  String toString() => 'NtxException: $message';
}

/// Definición de un índice NTX asociado a un DBF del servidor.
class NtxIndexDef {
  final String ntxFile;
  final String expression;
  const NtxIndexDef(this.ntxFile, this.expression);
}

/// Índices que mantiene el ERP GC por cada DBF que la app modifica.
/// Fuente: GC05.PRG (rutina de reindexado) — verificado contra los headers
/// de los .ntx de producción.
const Map<String, List<NtxIndexDef>> ntxIndexesByDbf = {
  'ARTICULO.DBF': [
    NtxIndexDef('ARTIC_1.NTX', 'CODIGO_ART'),
    NtxIndexDef('ARTIC_2.NTX', 'NOMBRE_ART+CODMAH_ART+CODIGO_PRO+CODIGO_ART'),
    NtxIndexDef('ARTIC_3.NTX', 'CODMAH_ART+CODIGO_PRO'),
    NtxIndexDef('ARTIC_4.NTX', 'CBARRA_ART'),
    NtxIndexDef('ARTIC_5.NTX', 'CODIGO_FAM+CODIGO_ART'),
  ],
  'STOCKLOT.DBF': [
    NtxIndexDef('STOCKLO1.NTX', 'CODIGO_LOT+CODIGO_ALM+CODIGO_ART'),
    NtxIndexDef('STOCKLO2.NTX',
        'CODIGO_ART+CODIGO_ALM+DTOS(FECCAD_LOT)+CODIGO_LOT+DTOS(FECALT_LOT)'),
    NtxIndexDef('STOCKLO3.NTX', 'CODIGO_PAL'),
    NtxIndexDef('STOCKLO4.NTX', 'CODIGO_UBI+DTOS(FECCAD_LOT)'),
  ],
  'E_S_ALMA.DBF': [
    NtxIndexDef('E_S_AL_1.NTX', 'CODIGO_E_S'),
    NtxIndexDef('E_S_AL_2.NTX', 'DTOS(FECHA_E_S)+CODIGO_ART'),
    NtxIndexDef('E_S_AL_3.NTX', 'CODIGO_ART+DTOS(FECHA_E_S)'),
    NtxIndexDef('E_S_AL_4.NTX',
        'CLIPRO_E_S+STR(CODALB_E_S)+TIPALB_E_S+NORDEN_E_S'),
    NtxIndexDef('E_S_AL_5.NTX',
        'CODIGO_CLI+CODIGO_PRO+CODIGO_ART+DTOS(FECHA_E_S)+STR(CODALB_E_S)+TIPALB_E_S+NORDEN_E_S'),
  ],
};

const _pageSize = 1024;

/// Info del header de un NTX existente (para regenerar con la expresión real
/// de cada instalación en vez de asumir las de GC05.PRG).
class NtxHeaderInfo {
  final String expression;
  final int keySize;
  final int unique;
  const NtxHeaderInfo(this.expression, this.keySize, this.unique);

  static NtxHeaderInfo parse(Uint8List header) {
    if (header.length < 280) throw NtxException('header NTX demasiado corto');
    final bd = ByteData.sublistView(header);
    final exprBytes = header.sublist(22, 278);
    final nul = exprBytes.indexOf(0);
    final expr =
        String.fromCharCodes(exprBytes.sublist(0, nul < 0 ? 256 : nul)).trim();
    return NtxHeaderInfo(expr, bd.getUint16(14, Endian.little), header[278]);
  }
}

class _Segment {
  final int offset; // offset dentro del registro crudo (flag incluido)
  final int length;
  final bool strNum; // STR(campo N): un campo vacío se evalúa como 0
  final int dec;
  const _Segment(this.offset, this.length, {this.strNum = false, this.dec = 0});
}

class _CompiledExpr {
  final List<_Segment> segments;
  final int keySize;
  final bool numericKey;
  final int keyDec;
  const _CompiledExpr(this.segments, this.keySize, this.numericKey, this.keyDec);
}

class _Item {
  final int child;
  final int recno;
  final Uint8List key;
  const _Item(this.child, this.recno, this.key);
}

/// Página cerrada pendiente de serializar (se serializa todo al final porque
/// el flush balanceado puede reescribir la última página cerrada de cada nivel).
class _Page {
  List<_Item> items;
  int rightChild;
  _Page(this.items, this.rightChild);
}

class NtxBuilder {
  /// Construye el archivo NTX completo para [dbf] con la expresión de clave
  /// [expression] (sintaxis xBase: campos tipo C/N/D, '+', DTOS(), STR()).
  static Uint8List build(DbfFile dbf, String expression) {
    final expr = _compile(dbf, expression);
    final itemSize = expr.keySize + 8;
    int maxItem = (1022 ~/ (itemSize + 2)) - 1;
    if (maxItem.isOdd) maxItem--;
    if (maxItem < 2) {
      throw NtxException('clave demasiado larga (${expr.keySize} bytes)');
    }
    final halfPage = maxItem ~/ 2;

    // Claves de todos los registros (incluidos borrados), recno = índice+1.
    final n = dbf.numRecords;
    final keys = List<Uint8List>.generate(n, (i) {
      final raw = dbf.rawRecord(i);
      final key = Uint8List(expr.keySize);
      int pos = 0;
      for (final s in expr.segments) {
        key.setRange(pos, pos + s.length, raw, s.offset);
        if (s.strNum) _renderEmptyNum(key, pos, s.length, s.dec);
        pos += s.length;
      }
      if (expr.numericKey) _zeroFill(key);
      return key;
    });

    final order = List<int>.generate(n, (i) => i);
    order.sort((a, b) {
      final ka = keys[a], kb = keys[b];
      for (int i = 0; i < ka.length; i++) {
        final d = ka[i] - kb[i];
        if (d != 0) return d;
      }
      return a - b; // claves iguales → orden por recno (sort estable)
    });

    // Bulk-load bottom-up: una página se cierra (y recibe el siguiente offset
    // del archivo) cuando se llena y llega la clave que la desborda, que sube
    // al nivel superior. Al acabar las claves, el flush cierra las páginas
    // abiertas de hoja a raíz; si una queda por debajo de halfPage se
    // reequilibra con la última cerrada de su nivel (reparto ceil/floor),
    // reescribiendo aquella en su offset ya asignado y rotando el separador
    // por el nivel superior. Es el comportamiento exacto del REINDEX de
    // Clipper/Harbour, verificado contra los índices de producción.
    final pages = <_Page>[]; // pages[i] vive en el offset (i+1)*1024
    final levels = <List<_Item>>[];
    final lastClosed = <int?>[]; // índice en [pages] por nivel

    int closePage(int level, List<_Item> items, int rightChild) {
      pages.add(_Page(items, rightChild));
      while (lastClosed.length <= level) {
        lastClosed.add(null);
      }
      lastClosed[level] = pages.length - 1;
      return _pageSize * pages.length;
    }

    void addKey(int level, int leftChild, int recno, Uint8List key) {
      while (true) {
        if (levels.length <= level) levels.add(<_Item>[]);
        final page = levels[level];
        if (page.length < maxItem) {
          page.add(_Item(leftChild, recno, key));
          return;
        }
        final offset = closePage(level, page, leftChild);
        levels[level] = <_Item>[];
        level++;
        leftChild = offset;
      }
    }

    for (final i in order) {
      addKey(0, 0, i + 1, keys[i]);
    }
    if (levels.isEmpty) levels.add(<_Item>[]); // DBF vacío → raíz hoja vacía

    int carry = 0;
    for (int level = 0; level < levels.length; level++) {
      var open = levels[level];
      final closedIdx = level < lastClosed.length ? lastClosed[level] : null;
      if (open.length < halfPage && closedIdx != null) {
        // Separador: la clave que subió al cerrar la última página del nivel.
        // Es el último item de la página abierta no vacía más baja por encima.
        int sepLevel = level + 1;
        while (levels[sepLevel].isEmpty) {
          sepLevel++;
        }
        final sep = levels[sepLevel].removeLast();
        final left = pages[closedIdx];
        final leftOffset = _pageSize * (closedIdx + 1);

        final pool = <_Item>[
          ...left.items,
          _Item(left.rightChild, sep.recno, sep.key),
          ...open,
        ];
        final leftN = pool.length ~/ 2; // = ceil((pool.length-1)/2)
        final newSep = pool[leftN];
        left.items = pool.sublist(0, leftN);
        left.rightChild = newSep.child;
        levels[sepLevel].add(_Item(leftOffset, newSep.recno, newSep.key));
        open = pool.sublist(leftN + 1);
      }
      carry = closePage(level, open, carry);
    }
    final rootOffset = carry;

    // Header (página 0).
    final header = Uint8List(_pageSize);
    final bd = ByteData.sublistView(header);
    bd.setUint16(0, 6, Endian.little); // signature
    bd.setUint16(2, 1, Endian.little); // version
    bd.setUint32(4, rootOffset, Endian.little);
    bd.setUint32(8, 0, Endian.little); // nextPage (los REINDEX reales dejan 0)
    bd.setUint16(12, itemSize, Endian.little);
    bd.setUint16(14, expr.keySize, Endian.little);
    bd.setUint16(16, expr.keyDec, Endian.little);
    bd.setUint16(18, maxItem, Endian.little);
    bd.setUint16(20, halfPage, Endian.little);
    final exprBytes = expression.toUpperCase().codeUnits;
    if (exprBytes.length > 255) throw NtxException('expresión demasiado larga');
    header.setRange(22, 22 + exprBytes.length, exprBytes);
    header[278] = 0; // unique

    final out = BytesBuilder(copy: false);
    out.add(header);
    for (final p in pages) {
      out.add(_serializePage(p.items, p.rightChild, maxItem, itemSize, expr.keySize));
    }
    return out.takeBytes();
  }

  /// STR() de un campo N vacío: Clipper evalúa el valor (0), no los espacios.
  /// dec=0 → "      0" · dec>0 → "    0.000".
  static void _renderEmptyNum(Uint8List key, int pos, int length, int dec) {
    for (int i = pos; i < pos + length; i++) {
      if (key[i] != 0x20) return; // no vacío: los bytes crudos ya son STR()
    }
    if (dec > 0 && length >= dec + 2) {
      key[pos + length - dec - 2] = 0x30;
      key[pos + length - dec - 1] = 0x2E;
      for (int i = pos + length - dec; i < pos + length; i++) {
        key[i] = 0x30;
      }
    } else {
      key[pos + length - 1] = 0x30;
    }
  }

  /// Espacios a la izquierda → '0' (claves de índice numérico). Los campos de
  /// estas claves son contadores siempre positivos; un valor negativo no es
  /// representable con esta transformación y se rechaza.
  static void _zeroFill(Uint8List key) {
    for (int i = 0; i < key.length; i++) {
      if (key[i] == 0x20) {
        key[i] = 0x30;
      } else {
        if (key[i] == 0x2D) {
          throw NtxException('clave numérica negativa no soportada');
        }
        break;
      }
    }
  }

  static _CompiledExpr _compile(DbfFile dbf, String expression) {
    final terms = expression.toUpperCase().split('+').map((t) => t.trim());
    final segments = <_Segment>[];
    final fieldTypes = <String>[];
    for (final term in terms) {
      String fieldName = term;
      String? fn;
      final m = RegExp(r'^(DTOS|STR)\((\w+)\)$').firstMatch(term);
      if (m != null) {
        fn = m.group(1);
        fieldName = m.group(2)!;
      } else if (!RegExp(r'^\w+$').hasMatch(term)) {
        throw NtxException('término no soportado en expresión: "$term"');
      }
      final field = dbf.fields.firstWhere(
        (f) => f.name.toUpperCase() == fieldName,
        orElse: () => throw NtxException('campo $fieldName no existe en el DBF'),
      );
      if (fn == 'DTOS' && field.type != 'D') {
        throw NtxException('DTOS sobre campo no-fecha: $fieldName');
      }
      if (fn == 'STR' && field.type != 'N') {
        throw NtxException('STR sobre campo no numérico: $fieldName');
      }
      // En el DBF los campos D son texto YYYYMMDD y los N texto justificado a
      // la derecha: DTOS()/STR() equivalen a copiar los bytes crudos del campo
      // (salvo campo N vacío, que STR() evalúa como 0).
      segments.add(_Segment(1 + field.recOffset, field.length,
          strNum: fn == 'STR', dec: field.decimals));
      fieldTypes.add(field.type);
    }
    if (segments.isEmpty) throw NtxException('expresión vacía');

    final numericKey = segments.length == 1 &&
        fieldTypes[0] == 'N' &&
        !expression.toUpperCase().contains('STR');
    if (!numericKey && fieldTypes.contains('N') &&
        !expression.toUpperCase().contains('STR(')) {
      throw NtxException(
          'campo numérico sin STR() en expresión concatenada: $expression');
    }

    int keyDec = 0;
    if (numericKey) {
      final field = dbf.fields.firstWhere(
          (f) => f.name.toUpperCase() == expression.toUpperCase().trim());
      keyDec = field.decimals;
    }
    final keySize = segments.fold<int>(0, (a, s) => a + s.length);
    return _CompiledExpr(segments, keySize, numericKey, keyDec);
  }

  static Uint8List _serializePage(List<_Item> items, int rightChild,
      int maxItem, int itemSize, int keySize) {
    final page = Uint8List(_pageSize);
    final bd = ByteData.sublistView(page);
    bd.setUint16(0, items.length, Endian.little);
    final base = 2 + (maxItem + 1) * 2;
    // Array de offsets de slots: siempre completo y secuencial. DBFNTX usa las
    // entradas más allá de count como pool de slots libres en inserciones
    // posteriores, así que deben ser válidas todas.
    for (int i = 0; i <= maxItem; i++) {
      bd.setUint16(2 + i * 2, base + i * itemSize, Endian.little);
    }
    for (int i = 0; i < items.length; i++) {
      final off = base + i * itemSize;
      bd.setUint32(off, items[i].child, Endian.little);
      bd.setUint32(off + 4, items[i].recno, Endian.little);
      page.setRange(off + 8, off + 8 + keySize, items[i].key);
    }
    // Slot extra: solo lleva el hijo derecho (en hojas queda 0).
    bd.setUint32(base + items.length * itemSize, rightChild, Endian.little);
    return page;
  }
}
