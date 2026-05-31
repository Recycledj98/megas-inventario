import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class UpdateInfo {
  final String version;
  final String url;
  final String notas;
  const UpdateInfo({required this.version, required this.url, required this.notas});
}

class ReleaseInfo {
  final String version;   // tag sin 'v', p.ej. "2.1.1"
  final String tagName;   // tag original, p.ej. "v2.1.1"
  final String notas;
  final String url;       // URL directa del APK asset
  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.notas,
    required this.url,
  });
}

class UpdateService {
  static const _versionUrl =
      'https://github.com/Recycledj98/megas-inventario'
      '/releases/latest/download/version.json';

  static final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
  ));

  // Sin timeout para descargas del APK (~100 MB)
  static final _dioDl = Dio();

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();

      // GitHub devuelve Content-Type: octet-stream en los assets de releases.
      // Forzar ResponseType.plain para obtener el String y parsear manualmente.
      final resp = await _dio.get(
        _versionUrl,
        options: Options(responseType: ResponseType.plain),
      );

      final Map<String, dynamic> data = resp.data is String
          ? jsonDecode(resp.data as String) as Map<String, dynamic>
          : resp.data as Map<String, dynamic>;

      final latest = (data['version'] as String? ?? '').trim();
      final url    = (data['url']     as String? ?? '').trim();
      final notas  = (data['notas']   as String? ?? '').trim();

      debugPrint('UpdateService: instalada=${info.version} disponible=$latest');

      if (latest.isNotEmpty && url.isNotEmpty && _isNewer(latest, info.version)) {
        return UpdateInfo(version: latest, url: url, notas: notas);
      }
    } catch (e) {
      debugPrint('UpdateService error: $e');
    }
    return null;
  }

  /// Como checkForUpdate pero devuelve el error como String en lugar de null.
  /// Útil para el botón "Buscar actualizaciones" en Ajustes.
  static Future<({UpdateInfo? update, String? error, String? instalada, String? disponible})>
      checkForUpdateVerbose() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final resp = await _dio.get(
        _versionUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final Map<String, dynamic> data = resp.data is String
          ? jsonDecode(resp.data as String) as Map<String, dynamic>
          : resp.data as Map<String, dynamic>;
      final latest = (data['version'] as String? ?? '').trim();
      final url    = (data['url']     as String? ?? '').trim();
      final notas  = (data['notas']   as String? ?? '').trim();
      if (latest.isNotEmpty && url.isNotEmpty && _isNewer(latest, info.version)) {
        return (update: UpdateInfo(version: latest, url: url, notas: notas),
                error: null, instalada: info.version, disponible: latest);
      }
      return (update: null, error: null,
              instalada: info.version, disponible: latest);
    } catch (e) {
      return (update: null, error: e.toString(), instalada: null, disponible: null);
    }
  }

  static const _releasesUrl =
      'https://api.github.com/repos/Recycledj98/megas-inventario/releases';

  /// Devuelve la lista de releases publicados en GitHub, más reciente primero.
  /// Cada release debe tener un asset llamado "megas_inventario.apk".
  static Future<List<ReleaseInfo>> getReleases() async {
    final resp = await _dio.get<List<dynamic>>(
      _releasesUrl,
      options: Options(headers: {'Accept': 'application/vnd.github+json'}),
    );
    final list = resp.data ?? [];
    final result = <ReleaseInfo>[];
    for (final item in list) {
      final tag = (item['tag_name'] as String? ?? '').trim();
      final body = (item['body'] as String? ?? '').trim();
      final assets = item['assets'] as List<dynamic>? ?? [];
      String apkUrl = '';
      for (final asset in assets) {
        if ((asset['name'] as String? ?? '').endsWith('.apk')) {
          apkUrl = (asset['browser_download_url'] as String? ?? '').trim();
          break;
        }
      }
      if (tag.isEmpty || apkUrl.isEmpty) continue;
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      result.add(ReleaseInfo(version: version, tagName: tag, notas: body, url: apkUrl));
    }
    return result;
  }

  static bool _isNewer(String latest, String current) {
    List<int> parse(String v) =>
        v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final l = parse(latest);
    final c = parse(current);
    for (int i = 0; i < 3; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    return false;
  }

  static Future<void> downloadAndInstall(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : await getApplicationDocumentsDirectory();
    final savePath =
        '${(dir ?? await getTemporaryDirectory()).path}/megas_inventario_update.apk';

    await _dioDl.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );

    await OpenFilex.open(savePath);
  }
}
