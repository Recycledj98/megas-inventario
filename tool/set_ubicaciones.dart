// ignore_for_file: avoid_print
// Uso: dart tool/set_ubicaciones.dart [--dry-run]
//   --dry-run  muestra los cambios sin escribir el fichero.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ── DbfService inline ─────────────────────────────────────────────────────────

class DbfField {
  final String name;
  final String type;
  final int length;
  final int decimals;
  final int recOffset;
  const DbfField({
    required this.name,
    required this.type,
    required this.length,
    required this.decimals,
    required this.recOffset,
  });
}

class DbfFile {
  final List<DbfField> fields;
  final int _headerSize;
  final int _recordSize;
  Uint8List _bytes;

  DbfFile._({
    required this.fields,
    required int headerSize,
    required int recordSize,
    required Uint8List bytes,
  })  : _headerSize = headerSize,
        _recordSize = recordSize,
        _bytes = bytes;

  int get numRecords =>
      ByteData.sublistView(_bytes).getUint32(4, Endian.little);

  List<(int, Map<String, dynamic>)> records() {
    final result = <(int, Map<String, dynamic>)>[];
    final n = numRecords;
    for (int i = 0; i < n; i++) {
      final start = _headerSize + i * _recordSize;
      if (_bytes[start] == 0x2A) continue;
      result.add((i, _readRecord(start)));
    }
    return result;
  }

  void setFields(int fileIndex, Map<String, dynamic> updates) {
    final start = _headerSize + fileIndex * _recordSize;
    for (final kv in updates.entries) {
      final f = _field(kv.key);
      if (f == null) continue;
      final encoded = _encodeValue(f, kv.value);
      _bytes.setRange(
          start + 1 + f.recOffset, start + 1 + f.recOffset + f.length, encoded);
    }
  }

  Uint8List toBytes() => Uint8List.fromList(_bytes);

  DbfField? _field(String name) {
    final up = name.toUpperCase();
    for (final f in fields) {
      if (f.name.toUpperCase() == up) return f;
    }
    return null;
  }

  Map<String, dynamic> _readRecord(int recStart) {
    final record = <String, dynamic>{};
    for (final f in fields) {
      final from = recStart + 1 + f.recOffset;
      final raw = latin1.decode(_bytes.sublist(from, from + f.length));
      switch (f.type) {
        case 'C':
          record[f.name] = raw.trimRight();
        case 'N':
          final t = raw.trim();
          if (t.isEmpty) {
            record[f.name] = f.decimals > 0 ? 0.0 : 0;
          } else if (f.decimals > 0) {
            record[f.name] = double.tryParse(t) ?? 0.0;
          } else {
            record[f.name] = int.tryParse(t) ?? 0;
          }
        default:
          record[f.name] = raw.trimRight();
      }
    }
    return record;
  }

  Uint8List _encodeValue(DbfField f, dynamic value) {
    final buf = Uint8List(f.length);
    buf.fillRange(0, f.length, 0x20);
    if (value == null) return buf;
    if (f.type == 'C') {
      var s = value.toString();
      if (s.length > f.length) s = s.substring(0, f.length);
      final enc = latin1.encode(s);
      buf.setRange(0, enc.length, enc);
    }
    return buf;
  }

  static DbfFile open(Uint8List bytes) {
    if (bytes.length < 32) throw FormatException('DBF demasiado corto');
    final bd = ByteData.sublistView(bytes);
    final headerSize = bd.getUint16(8, Endian.little);
    final recordSize = bd.getUint16(10, Endian.little);
    final fields = <DbfField>[];
    int offset = 32;
    int fieldOffset = 0;
    while (offset + 32 <= headerSize && bytes[offset] != 0x0D) {
      final nameBytes = bytes.sublist(offset, offset + 11);
      int nameEnd = 0;
      while (nameEnd < 11 && nameBytes[nameEnd] != 0) nameEnd++;
      final name = latin1.decode(nameBytes.sublist(0, nameEnd));
      final type = String.fromCharCode(bytes[offset + 11]);
      final length = bytes[offset + 16];
      final decimals = bytes[offset + 17];
      fields.add(DbfField(
          name: name,
          type: type,
          length: length,
          decimals: decimals,
          recOffset: fieldOffset));
      fieldOffset += length;
      offset += 32;
    }
    return DbfFile._(
        fields: fields,
        headerSize: headerSize,
        recordSize: recordSize,
        bytes: bytes);
  }
}

// ── Generador de ubicaciones ficticias ───────────────────────────────────────

// Formato: <pasillo>-<estantería>-<nivel>
// Pasillos: A..E  |  Estanterías: 01..08  |  Niveles: 1..4
// Se asignan secuencialmente por orden de CODIGO_ART para que artículos
// cercanos en código queden en la misma zona.

String _ubicacion(int n) {
  const pasillos = ['A', 'B', 'C', 'D', 'E'];
  const estanterias = 8;
  const niveles = 4;
  final nivel = (n % niveles) + 1;
  final estanteria = ((n ~/ niveles) % estanterias) + 1;
  final pasillo = pasillos[(n ~/ (niveles * estanterias)) % pasillos.length];
  return '$pasillo-${estanteria.toString().padLeft(2, '0')}-$nivel';
}

// ── Main ─────────────────────────────────────────────────────────────────────

void main(List<String> args) {
  final dryRun = args.contains('--dry-run');
  final path = r'C:\GC24\ARTICULO.DBF';

  final file = File(path);
  if (!file.existsSync()) {
    print('ERROR: No se encuentra $path');
    exit(1);
  }

  final dbf = DbfFile.open(file.readAsBytesSync());

  // Verificar que el campo UBICAC_ART existe
  final campoUbicacion = dbf.fields.where((f) => f.name.toUpperCase() == 'UBICAC_ART').toList();
  if (campoUbicacion.isEmpty) {
    print('ERROR: El campo UBICAC_ART no existe en $path');
    print('Campos disponibles: ${dbf.fields.map((f) => f.name).join(', ')}');
    exit(1);
  }
  print('Campo UBICAC_ART encontrado (longitud ${campoUbicacion.first.length})');

  final recs = dbf.records();
  print('Total registros activos: ${recs.length}');

  // Ordenar por CODIGO_ART para asignación consistente
  recs.sort((a, b) {
    final ca = (a.$2['CODIGO_ART'] as String? ?? '').trim();
    final cb = (b.$2['CODIGO_ART'] as String? ?? '').trim();
    return ca.compareTo(cb);
  });

  int contador = 0;
  for (final (idx, rec) in recs) {
    final codigo = (rec['CODIGO_ART'] as String? ?? '').trim();
    if (codigo.isEmpty) continue;
    final ub = _ubicacion(contador++);
    if (dryRun) {
      print('  [$idx] $codigo  →  $ub');
    } else {
      dbf.setFields(idx, {'UBICAC_ART': ub});
    }
  }

  if (dryRun) {
    print('\n[DRY RUN] Nada escrito. Quita --dry-run para aplicar.');
  } else {
    // Backup antes de sobreescribir
    final backup = File('${path}_backup');
    backup.writeAsBytesSync(file.readAsBytesSync());
    print('Backup creado: ${backup.path}');

    file.writeAsBytesSync(dbf.toBytes());
    print('✓ $path actualizado con $contador ubicaciones ficticias.');
  }
}
