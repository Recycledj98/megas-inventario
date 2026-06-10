# Cambios — sesión 2026-05-31

## v2.1.1 → v2.1.4

---

### fix: edición de ubicación de artículos

**Ficheros:** `home_screen.dart`, `lot_editor_screen.dart`, `legacy_service.dart`

El campo `ubicacion` se recogía en `ArticuloEditDialog` pero no se pasaba a
`updateArticuloFields` ni a `saveArticuloFields`. Ahora se propaga correctamente
en los dos puntos de llamada (desde `HomeScreen` y desde `LotEditorScreen`).

Además se añadió el guard `if (ConfigService.isLegacyMode)` que faltaba en
`LotEditorScreen._openArticuloEdit` — antes intentaba escribir al SMB siempre,
aunque la app estuviera en modo API.

---

### fix: modales no se cierran al pulsar fuera

**Ficheros:** `home_screen.dart`, `lot_editor_screen.dart`, `config_screen.dart`

Todos los `showDialog` reciben ahora `barrierDismissible: false` para evitar
cierres accidentales al tocar la pantalla fuera del diálogo.

Diálogos afectados: nueva sesión, update disponible, eliminar conteo, editar
artículo, salir, añadir línea de lote, eliminar línea, confirmar envío, filtros
recibir.

---

### feat: "Acerca de" como ventana independiente

**Ficheros:** `config_screen.dart`

La tarjeta "Acerca de" se eliminó de la lista de secciones de configuración y
se convirtió en un `Dialog` independiente (`_AcercaDeDialog`). Se accede
mediante un botón `TextButton` al pie de la tarjeta **Inventario**, separado
por un divisor.

El diálogo muestra: logo, nombre de app, versión instalada, fecha de
compilación, empresa, desarrollador, botón "Buscar actualizaciones" y botón de
licencias.

El estado de búsqueda de updates (`_buscandoUpdate`, `_updateMsg`,
`_buscarActualizacion`) se movió al propio diálogo.

---

### feat: rollback a versión anterior

**Ficheros:** `update_service.dart`, `config_screen.dart`

`UpdateService.getReleases()` llama a la API de GitHub
(`/repos/Recycledj98/megas-inventario/releases`) y devuelve la lista de
releases publicados con su APK asset.

En `_AcercaDeDialog` se añadió un `ExpansionTile` "Versiones anteriores" que:
- Carga los releases al expandirse
- Muestra un `DropdownButtonFormField` con todas las versiones disponibles
- Al seleccionar una versión muestra sus notas de release
- Detecta downgrade (versión < instalada) y muestra aviso: "Android bloquea el
  downgrade. Desinstala la app primero."
- Botón "Instalar esta versión" descarga e instala el APK via
  `UpdateService.downloadAndInstall()`
- `OpenFilex.open()` ya lanza excepción si falla (antes se ignoraba el
  resultado); el mensaje de error se muestra en el diálogo

`UpdateService.compareVersions()` añadido para comparar versiones semánticas.

---

### feat: backup automático de configuración antes de instalar versión anterior

**Ficheros:** `config_service.dart`, `update_service.dart`,
`config_screen.dart`, `AndroidManifest.xml`

`ConfigService.exportToJson()` serializa todos los ajustes (modo API/legacy,
credenciales SMB, empresa, usuario, preferencias de visualización, columnas,
orden) a un `Map<String, dynamic>`.

`ConfigService.importFromJson()` restaura todos esos campos en
`SharedPreferences`.

`UpdateService.saveConfigBackup()` intenta escribir el JSON en:
1. `/storage/emulated/0/Download/megas_config_backup.json` (sobrevive
   desinstalación — funciona en Android ≤ 10 con los permisos añadidos)
2. Directorio externo de la app como fallback
3. Directorio de documentos internos como último recurso

`UpdateService.restoreConfigBackupIfExists()` busca el fichero en todas las
rutas candidatas, importa la config y borra el fichero.

`ConfigScreen._restoreBackupIfNeeded()` se llama en `initState` via
`addPostFrameCallback`. Si encuentra un backup lo restaura automáticamente,
recarga todos los campos de estado y muestra el toast "✅ Configuración
restaurada automáticamente".

El backup se dispara automáticamente en `_instalarRelease()` antes de iniciar
la descarga del APK.

`AndroidManifest.xml`: añadidos
`WRITE_EXTERNAL_STORAGE` (maxSdkVersion=29) y `READ_EXTERNAL_STORAGE`
(maxSdkVersion=32), y `android:requestLegacyExternalStorage="true"` en
`<application>` para Android 10.

> **Limitación**: en Android 11+ el permiso `WRITE_EXTERNAL_STORAGE` no aplica
> (scoped storage). El backup cae al directorio externo de la app que se borra
> al desinstalar. Sin `MANAGE_EXTERNAL_STORAGE` no es posible escribir en
> Downloads en Android 11+ sin dependencias adicionales.

---

### fix: texto negro en diálogos

**Ficheros:** `main.dart`, `home_screen.dart`

`GoogleFonts.inter(fontSize: 14)` no especifica color, por lo que los
`TextSpan` en `RichText` y el contenido de los diálogos heredaban blanco del
tema oscuro.

Corrección global: `dialogTheme` en `_buildTheme()` añade `titleTextStyle` y
`contentTextStyle` con `color: colorScheme.onSurface` explícito.

El `RichText` del diálogo de salida recibió adicionalmente
`.copyWith(color: cs.onSurface)` en el estilo raíz del `TextSpan` porque
`RichText` no hereda `DefaultTextStyle`.

---

### fix: texto visible en desplegable de versiones anteriores

**Ficheros:** `config_screen.dart`

El popup del `DropdownButtonFormField` se renderiza en el overlay raíz (fuera
del diálogo) y no heredaba el `contentTextStyle` del `dialogTheme`. El texto
aparecía blanco sobre fondo blanco.

Solución: `style: TextStyle(color: cs.onSurface)` en el
`DropdownButtonFormField` y en cada `DropdownMenuItem`, más
`dropdownColor: colorScheme.surfaceContainerHigh` para el fondo del popup.

---

### ux: notificaciones (AppToast) desde abajo

**Fichero:** `lib/widgets/app_toast.dart`

Cambiado el anclaje de `top: 0` → `bottom: 0`, la animación de entrada de
`Offset(0, -1)` → `Offset(0, 1)` (desliza desde abajo), y el `SafeArea` de
`bottom: false` → `top: false` con padding `fromLTRB(16, 0, 16, 12)` para
respetar la barra de navegación del sistema.

---

### ux: mensaje de sincronización simplificado

**Fichero:** `home_screen.dart`

`_doSync` y `_doRecibir` mostraban el número de artículos y lotes cargados.
Ahora muestran simplemente **"Sincronizado con éxito"**.

---

### tool: script de ubicaciones ficticias

**Fichero:** `tool/set_ubicaciones.dart`

Script Dart standalone que lee `C:\GC24\ARTICULO.DBF`, asigna ubicaciones
ficticias en formato `PASILLO-ESTANTERÍA-NIVEL` (A-01-1 … E-08-4) ordenadas
por `CODIGO_ART`, crea un backup automático y escribe el fichero modificado.

Uso: `dart tool/set_ubicaciones.dart [--dry-run]`

Resultado: 461 artículos actualizados.

---

## Historial de versiones y builds

Cada versión se genera con `flutter build apk --release`, se copia a
`release/megas_inventario.apk` y se actualizan `release/version.json` y
`version.json_` con la misma versión y notas.

| Versión | Build | Fecha      | Cambios principales                                                              |
|---------|-------|------------|----------------------------------------------------------------------------------|
| 2.1.1   | +28   | 2026-05-31 | fix ubicación artículos · barrierDismissible en modales                         |
| 2.1.2   | +29   | 2026-05-31 | feat Acerca de independiente · rollback versión anterior · fix guard legacyMode  |
| 2.1.3   | +30   | 2026-05-31 | feat backup config automático pre-downgrade · fix texto blanco en diálogos      |
| 2.1.4   | +31   | 2026-05-31 | fix dropdown versiones (color texto) · dropdownColor explícito                  |
| 2.1.5   | +32   | 2026-05-31 | ux toast desde abajo · mensaje sync simplificado ("Sincronizado con éxito")     |

### Patrón de bump de versión

Cada petición "genera el APK X.Y.Z" implica:
1. `pubspec.yaml` → `version: X.Y.Z+N`
2. `version.json_` → `"version": "X.Y.Z"` + notas
3. `release/version.json` → ídem
4. `flutter build apk --release`
5. Copiar `build/app/outputs/flutter-apk/app-release.apk` → `release/megas_inventario.apk`

El número de build (`+N`) es siempre el anterior +1.
El último build conocido es **+32** (v2.1.5).

### Pendiente de subir a GitHub

Las siguientes versiones tienen APK en `release/` pero **no tienen release
creada en GitHub** porque `gh` CLI no está instalado. Para crear la release:

```
https://github.com/Recycledj98/megas-inventario/releases/new
Tag: vX.Y.Z  |  Título: vX.Y.Z
Assets: release/megas_inventario.apk + release/version.json
```

El `version.json` publicado en la release es el que usa el auto-update
de la app (`UpdateService._versionUrl`).

El commit más reciente en `master` es `233a644` (bump 2.1.2+29 con feat
del Acerca de y rollback). Los cambios de 2.1.3 a 2.1.5 están en el
working tree / commits posteriores según el estado del repo.
