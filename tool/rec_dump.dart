// Dump crudo de registros de E_S_Alma.DBF por índice (base 0).
//   dart run tool/rec_dump.dart 1061555 1061575
import 'dart:io';
import 'dart:typed_data';
import 'package:megas_inventario/services/dbf_service.dart';

void main(List<String> args) {
  final dbf = DbfFile.open(
      Uint8List.fromList(File('Indices/E_S_Alma.DBF').readAsBytesSync()));
  final from = int.parse(args[0]), to = int.parse(args[1]);
  for (int i = from; i < to && i < dbf.numRecords; i++) {
    final raw = dbf.rawRecord(i);
    final del = raw[0] == 0x2A ? 'DEL' : '   ';
    final s = String.fromCharCodes(raw.sublist(1));
    print('rec ${i + 1} $del |$s|');
  }
}
