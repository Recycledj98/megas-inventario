import 'dart:io';
import 'package:path_provider/path_provider.dart';

enum LogNivel { info, error, auditoria }

class LogEntry {
  final DateTime timestamp;
  final String mensaje;
  final LogNivel nivel;

  LogEntry(this.timestamp, this.mensaje, this.nivel);

  bool get isError => nivel == LogNivel.error;
  bool get isAudit => nivel == LogNivel.auditoria;

  String toLine() {
    final n = nivel == LogNivel.error ? 'E'
        : nivel == LogNivel.auditoria ? 'A'
        : 'I';
    return '${timestamp.toIso8601String()}|$n|$mensaje';
  }

  static LogEntry? fromLine(String line) {
    final parts = line.split('|');
    if (parts.length < 3) return null;
    final ts = DateTime.tryParse(parts[0]);
    if (ts == null) return null;
    final nivel = parts[1] == 'E' ? LogNivel.error
        : parts[1] == 'A' ? LogNivel.auditoria
        : LogNivel.info;
    final msg = parts.sublist(2).join('|');
    return LogEntry(ts, msg, nivel);
  }
}

class LogService {
  static const _maxEntradas = 300;
  static const _fileName = 'inventario_log.txt';
  static const _auditFileName = 'inventario_auditoria.txt';

  static Future<File> _archivo() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<File> _archivoAuditoria() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_auditFileName');
  }

  // ── Incidencias (errores, borrables) ────────────────────────────────────────

  /// Registra un mensaje de error o info. Borrable por el usuario.
  static void registrar(String mensaje, {bool isError = false}) {
    _escribirIncidencia(mensaje, isError ? LogNivel.error : LogNivel.info);
  }

  static void _escribirIncidencia(String mensaje, LogNivel nivel) async {
    try {
      final file = await _archivo();
      final entry = LogEntry(DateTime.now(), mensaje, nivel);
      await file.writeAsString('${entry.toLine()}\n',
          mode: FileMode.append, flush: true);
      await _rotarSiNecesario(file);
    } catch (_) {}
  }

  static Future<void> _rotarSiNecesario(File file) async {
    try {
      final lineas = await file.readAsLines();
      if (lineas.length > _maxEntradas) {
        final recorte = lineas.skip(lineas.length - _maxEntradas).join('\n');
        await file.writeAsString('$recorte\n');
      }
    } catch (_) {}
  }

  /// Devuelve las incidencias ordenadas de más reciente a más antigua.
  static Future<List<LogEntry>> obtenerRegistros() async {
    try {
      final file = await _archivo();
      if (!await file.exists()) return [];
      final lineas = await file.readAsLines();
      return lineas.reversed
          .map(LogEntry.fromLine)
          .whereType<LogEntry>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Borra el log de incidencias. El de auditoría NO se puede borrar.
  static Future<void> limpiar() async {
    try {
      final file = await _archivo();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  // ── Auditoría (movimientos y config, NUNCA se borra) ────────────────────────

  /// Registra un evento de auditoría permanente: envíos, recepciones, cambios de config.
  static void auditar(String mensaje) async {
    try {
      final file = await _archivoAuditoria();
      final entry = LogEntry(DateTime.now(), mensaje, LogNivel.auditoria);
      await file.writeAsString('${entry.toLine()}\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// Devuelve el registro de auditoría de más reciente a más antiguo.
  static Future<List<LogEntry>> obtenerAuditoria() async {
    try {
      final file = await _archivoAuditoria();
      if (!await file.exists()) return [];
      final lineas = await file.readAsLines();
      return lineas.reversed
          .map(LogEntry.fromLine)
          .whereType<LogEntry>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Traduce excepciones técnicas a texto comprensible para el usuario.
  /// Incluye el error técnico entre paréntesis para que el técnico pueda diagnosticar.
  static String traducirError(Object e) {
    final s = e.toString();
    final raw = s.length > 100 ? '${s.substring(0, 100)}…' : s;

    // ── Errores SMB específicos (deben ir ANTES del catch genérico de SMB) ──
    // Archivo o carpeta no encontrada en el servidor de archivos
    if (s.contains('STATUS_OBJECT_NAME_NOT_FOUND') ||
        s.contains('STATUS_NO_SUCH_FILE') ||
        s.contains('STATUS_OBJECT_PATH_NOT_FOUND') ||
        s.contains('STATUS_BAD_NETWORK_NAME') ||
        s.contains('STATUS_OBJECT_NAME_INVALID')) {
      return 'Archivo o carpeta no encontrada en el servidor (¿cambió el nombre del fichero DBF?) — $raw';
    }
    // Acceso denegado al fichero
    if (s.contains('STATUS_ACCESS_DENIED') ||
        s.contains('STATUS_SHARING_VIOLATION')) {
      return 'Sin permiso para acceder al archivo en el servidor (fichero en uso o sin permisos) — $raw';
    }
    // Credenciales SMB inválidas
    if (s.contains('STATUS_LOGON_FAILURE') ||
        s.contains('STATUS_WRONG_PASSWORD') ||
        s.contains('STATUS_NO_SUCH_USER') ||
        s.contains('STATUS_ACCOUNT_DISABLED')) {
      return 'Usuario o contraseña incorrectos para el servidor de archivos — $raw';
    }
    // Ruta compartida no encontrada (share incorrecto)
    if (s.contains('STATUS_BAD_NETWORK_PATH') ||
        s.contains('STATUS_NETWORK_NAME_DELETED')) {
      return 'La carpeta compartida no existe en el servidor (comprueba el nombre de recurso compartido) — $raw';
    }

    // ── Errores de red generales ────────────────────────────────────────────
    if (s.contains('SocketException') ||
        s.contains('Connection refused') ||
        s.contains('Network is unreachable') ||
        s.contains('Connection timed out')) {
      return 'No se pudo conectar al servidor (sin red o servidor apagado) — $raw';
    }
    if (s.contains('TimeoutException') ||
        s.contains('timed out') ||
        s.contains('timeout')) {
      return 'La conexión tardó demasiado y se canceló (tiempo de espera agotado) — $raw';
    }
    if (s.contains('HandshakeException') || s.contains('certificate')) {
      return 'Error de seguridad en la conexión (certificado SSL inválido) — $raw';
    }

    // ── Errores HTTP ────────────────────────────────────────────────────────
    if (s.contains('401') || s.contains('Unauthorized')) {
      return 'Credenciales incorrectas (usuario o contraseña inválidos) — $raw';
    }
    if (s.contains('403') || s.contains('Forbidden')) {
      return 'Sin permiso para acceder a este recurso — $raw';
    }
    if (s.contains('404') || s.contains('Not Found')) {
      return 'Recurso no encontrado en el servidor — $raw';
    }
    if (s.contains('500') || s.contains('Internal Server Error')) {
      return 'Error interno del servidor — $raw';
    }

    // ── SMB genérico (al final, solo si no se identificó antes) ────────────
    if (s.contains('SMB') || s.contains('smb') || s.contains('Smb') ||
        s.contains('SmbException')) {
      return 'Error de comunicación con el servidor de archivos — $raw';
    }

    // ── Otros ───────────────────────────────────────────────────────────────
    if (s.contains('PathNotFoundException') || s.contains('No such file')) {
      return 'No se encontró el archivo — $raw';
    }
    if (s.contains('DatabaseException') || s.contains('SqliteException')) {
      return 'Error en la base de datos local — $raw';
    }
    if (s.contains('FormatException') || s.contains('JSON')) {
      return 'Los datos recibidos tienen un formato incorrecto — $raw';
    }

    return raw;
  }
}
