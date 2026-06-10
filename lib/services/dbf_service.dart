import 'dart:convert';
import 'dart:typed_data';

// xBase III+ DBF binary parser / writer — pure Dart, no dependencies.
// Spec: 32-byte header · 32-byte field descriptors · records of fixed width.

class DbfField {
  final String name;
  final String type; // C N D L
  final int length;
  final int decimals;
  final int recOffset; // byte offset within record body (after the deletion flag)

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

  /// Nº de registros al abrir el archivo: los que haya por encima son appends
  /// de esta sesión y se pueden escribir por rango al final del archivo.
  final int _originalNumRecords;

  /// Índices de registros preexistentes con campos modificados en esta sesión.
  final Set<int> _dirtyRecords = {};

  DbfFile._({
    required this.fields,
    required int headerSize,
    required int recordSize,
    required Uint8List bytes,
  })  : _headerSize = headerSize,
        _recordSize = recordSize,
        _bytes = bytes,
        _originalNumRecords =
            ByteData.sublistView(bytes).getUint32(4, Endian.little);

  int get numRecords =>
      ByteData.sublistView(_bytes).getUint32(4, Endian.little);

  int get recordSize => _recordSize;

  /// Bytes crudos del registro [fileIndex] (incluye el flag de borrado en [0]).
  /// Los índices NTX se construyen sobre estos bytes sin decodificar: el orden
  /// de claves de Clipper es byte a byte sobre la página de códigos OEM del DBF.
  Uint8List rawRecord(int fileIndex) {
    final start = _headerSize + fileIndex * _recordSize;
    return Uint8List.sublistView(_bytes, start, start + _recordSize);
  }

  /// Offset absoluto en el archivo y longitud del campo [fieldName] dentro del
  /// registro [fileIndex]. Para escrituras dirigidas por rango sobre el archivo
  /// remoto (actualizar un campo sin reescribir el archivo completo).
  ({int offset, int length})? fieldSlice(int fileIndex, String fieldName) {
    final f = _field(fieldName);
    if (f == null) return null;
    return (
      offset: _headerSize + fileIndex * _recordSize + 1 + f.recOffset,
      length: f.length,
    );
  }

  /// Bytes actuales (ya codificados) del campo [fieldName] del registro
  /// [fileIndex].
  Uint8List? fieldBytes(int fileIndex, String fieldName) {
    final s = fieldSlice(fileIndex, fieldName);
    if (s == null) return null;
    return Uint8List.sublistView(_bytes, s.offset, s.offset + s.length);
  }

  /// All non-deleted records → (fileIndex, data map).
  List<(int, Map<String, dynamic>)> records() {
    final result = <(int, Map<String, dynamic>)>[];
    final n = numRecords;
    for (int i = 0; i < n; i++) {
      final start = _headerSize + i * _recordSize;
      if (_bytes[start] == 0x2A) continue; // deleted
      result.add((i, _readRecord(start)));
    }
    return result;
  }

  /// Returns the file index of the first record whose trimmed string fields
  /// match [keyValues], or -1 if not found.
  int findByKey(Map<String, String> keyValues) {
    final n = numRecords;
    for (int i = 0; i < n; i++) {
      final start = _headerSize + i * _recordSize;
      if (_bytes[start] == 0x2A) continue;
      bool match = true;
      for (final kv in keyValues.entries) {
        final f = _field(kv.key);
        if (f == null) { match = false; break; }
        final raw = latin1.decode(
          _bytes.sublist(start + 1 + f.recOffset, start + 1 + f.recOffset + f.length),
        ).trim();
        if (raw != kv.value.trim()) { match = false; break; }
      }
      if (match) return i;
    }
    return -1;
  }

  /// Read a numeric field value from a given file record index.
  double getNum(int fileIndex, String fieldName) {
    final f = _field(fieldName);
    if (f == null) return 0;
    final start = _headerSize + fileIndex * _recordSize;
    final raw = latin1
        .decode(_bytes.sublist(start + 1 + f.recOffset, start + 1 + f.recOffset + f.length))
        .trim();
    return double.tryParse(raw) ?? 0;
  }

  /// In-place update of fields in record [fileIndex].
  void setFields(int fileIndex, Map<String, dynamic> updates) {
    if (fileIndex < _originalNumRecords) _dirtyRecords.add(fileIndex);
    final start = _headerSize + fileIndex * _recordSize;
    for (final kv in updates.entries) {
      final f = _field(kv.key);
      if (f == null) continue;
      final encoded = _encodeValue(f, kv.value);
      _bytes.setRange(start + 1 + f.recOffset, start + 1 + f.recOffset + f.length, encoded);
    }
  }

  /// Append a new record and return updated bytes.
  void appendRecord(Map<String, dynamic> values) {
    final newBytes = Uint8List(_bytes.length + _recordSize);
    // Copy existing content, skipping the 0x1A EOF byte if present.
    final copyLen = _bytes.isNotEmpty && _bytes.last == 0x1A
        ? _bytes.length - 1
        : _bytes.length;
    newBytes.setRange(0, copyLen, _bytes);

    final writePos = _headerSize + numRecords * _recordSize;
    newBytes[writePos] = 0x20; // valid record

    for (final f in fields) {
      final encoded = _encodeValue(f, values[f.name]);
      newBytes.setRange(
        writePos + 1 + f.recOffset,
        writePos + 1 + f.recOffset + f.length,
        encoded,
      );
    }

    // Update record count in header (uint32 LE at offset 4).
    final bd = ByteData.sublistView(newBytes);
    bd.setUint32(4, numRecords + 1, Endian.little);

    // Restore EOF marker.
    if (newBytes.length > writePos + _recordSize) {
      newBytes[writePos + _recordSize] = 0x1A;
    }

    _bytes = newBytes;
  }

  /// Returns the current bytes ready to write back to the server.
  Uint8List toBytes() => Uint8List.fromList(_bytes);

  // ── Escritura por rangos ────────────────────────────────────────────────────
  // Para subir solo lo cambiado por SMB en vez del archivo completo:
  // registros preexistentes modificados + bloque añadido al final + header.

  bool get hasAppends => numRecords > _originalNumRecords;
  bool get hasChanges => hasAppends || _dirtyRecords.isNotEmpty;
  Set<int> get dirtyRecords => _dirtyRecords;

  /// Bytes y offset absoluto del registro [fileIndex].
  ({int offset, Uint8List bytes}) recordRegion(int fileIndex) => (
        offset: _headerSize + fileIndex * _recordSize,
        bytes: Uint8List.fromList(rawRecord(fileIndex)),
      );

  /// Región añadida desde la apertura (registros nuevos + marca EOF final).
  ({int offset, Uint8List bytes}) appendedRegion() {
    final start = _headerSize + _originalNumRecords * _recordSize;
    return (offset: start, bytes: Uint8List.fromList(_bytes.sublist(start)));
  }

  /// Bytes 1..7 del header xBase: fecha de modificación (YY MM DD) + nº de
  /// registros (u32 LE). Se escriben en el offset 1 del archivo remoto.
  Uint8List headerStampBytes() {
    final now = DateTime.now();
    final b = Uint8List(7);
    b[0] = now.year % 100;
    b[1] = now.month;
    b[2] = now.day;
    ByteData.sublistView(b).setUint32(3, numRecords, Endian.little);
    return b;
  }

  // ── Internals ──────────────────────────────────────────────────────────────

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
        case 'D':
          final t = raw.trim();
          if (t.length == 8 && t != '00000000') {
            try {
              record[f.name] = DateTime(
                int.parse(t.substring(0, 4)),
                int.parse(t.substring(4, 6)),
                int.parse(t.substring(6, 8)),
              );
            } catch (_) {
              record[f.name] = null;
            }
          } else {
            record[f.name] = null;
          }
        case 'L':
          final c = raw.trim().toUpperCase();
          record[f.name] = c == 'T' || c == 'Y' || c == '1';
        default:
          record[f.name] = raw.trimRight();
      }
    }
    return record;
  }

  Uint8List _encodeValue(DbfField f, dynamic value) {
    final buf = Uint8List(f.length);
    buf.fillRange(0, f.length, 0x20); // fill spaces
    if (value == null) return buf;

    switch (f.type) {
      case 'C':
        var s = value.toString();
        if (s.length > f.length) s = s.substring(0, f.length);
        final enc = latin1.encode(s);
        buf.setRange(0, enc.length, enc);

      case 'N':
        final num v = value is num ? value : (double.tryParse(value.toString()) ?? 0.0);
        String s;
        if (f.decimals > 0) {
          s = v.toStringAsFixed(f.decimals);
        } else {
          s = v.round().toString();
        }
        if (s.length > f.length) s = s.substring(s.length - f.length);
        final padded = s.padLeft(f.length);
        final enc = latin1.encode(padded);
        buf.setRange(0, enc.length.clamp(0, f.length), enc);

      case 'D':
        if (value is DateTime) {
          final s =
              '${value.year.toString().padLeft(4, '0')}'
              '${value.month.toString().padLeft(2, '0')}'
              '${value.day.toString().padLeft(2, '0')}';
          final enc = latin1.encode(s);
          buf.setRange(0, enc.length, enc);
        }

      case 'L':
        buf[0] = (value == true) ? 0x54 : 0x46;
    }
    return buf;
  }

  // ── Factory ────────────────────────────────────────────────────────────────

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
        recOffset: fieldOffset,
      ));
      fieldOffset += length;
      offset += 32;
    }

    return DbfFile._(
      fields: fields,
      headerSize: headerSize,
      recordSize: recordSize,
      bytes: Uint8List.fromList(bytes),
    );
  }
}
