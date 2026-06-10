// Busca claves con un prefijo en un NTX y cuenta el total.
//   dart run tool/find_key.dart Indices/E_S_AL_3.NTX "0760403"
import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final prefix = args[1];
  final bd = ByteData.sublistView(Uint8List.fromList(bytes));
  final root = bd.getUint32(4, Endian.little);
  final keySize = bd.getUint16(14, Endian.little);
  int total = 0, matches = 0;

  void walk(int off) {
    if (off == 0 || off + 1024 > bytes.length) return;
    final pb = ByteData.sublistView(Uint8List.fromList(bytes), off, off + 1024);
    final count = pb.getUint16(0, Endian.little);
    for (int i = 0; i <= count; i++) {
      final s = pb.getUint16(2 + i * 2, Endian.little);
      walk(pb.getUint32(s, Endian.little));
      if (i < count) {
        total++;
        final key = String.fromCharCodes(
            bytes.sublist(off + s + 8, off + s + 8 + keySize));
        if (key.startsWith(prefix)) {
          matches++;
          if (matches <= 12) {
            print('rec ${pb.getUint32(s + 4, Endian.little)} |$key|');
          }
        }
      }
    }
  }

  walk(root);
  print('total claves: $total · coincidencias "$prefix": $matches');
}
