// Dump de estructura de un DBF: campos, anchos, nº de registros (incl. borrados).
//   dart run tool/dbf_struct.dart Indices/E_S_ALMA.DBF

import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final bd = ByteData.sublistView(Uint8List.fromList(bytes));
  final numRecords = bd.getUint32(4, Endian.little);
  final headerSize = bd.getUint16(8, Endian.little);
  final recordSize = bd.getUint16(10, Endian.little);
  print('=== ${args[0]} ===');
  print('numRecords=$numRecords headerSize=$headerSize recordSize=$recordSize');

  int offset = 32;
  while (offset + 32 <= headerSize && bytes[offset] != 0x0D) {
    final nameBytes = bytes.sublist(offset, offset + 11);
    int nameEnd = 0;
    while (nameEnd < 11 && nameBytes[nameEnd] != 0) nameEnd++;
    final name = String.fromCharCodes(nameBytes.sublist(0, nameEnd));
    final type = String.fromCharCode(bytes[offset + 11]);
    final length = bytes[offset + 16];
    final decimals = bytes[offset + 17];
    print('  ${name.padRight(11)} $type ${length.toString().padLeft(3)},$decimals');
    offset += 32;
  }

  // Contar registros marcados como borrados (0x2A).
  int deleted = 0;
  for (int i = 0; i < numRecords; i++) {
    final start = headerSize + i * recordSize;
    if (start < bytes.length && bytes[start] == 0x2A) deleted++;
  }
  print('borrados=$deleted activos=${numRecords - deleted}');
}
