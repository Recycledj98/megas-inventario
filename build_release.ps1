# build_release.ps1 — genera megas_inventario.apk listo para subir a GitHub Releases
# Uso: .\build_release.ps1

$ErrorActionPreference = "Stop"

Write-Host "Generando codigo Drift..." -ForegroundColor Cyan
flutter pub run build_runner build --delete-conflicting-outputs

Write-Host "Compilando APK release..." -ForegroundColor Cyan
flutter build apk --release

$src  = "build\app\outputs\flutter-apk\app-release.apk"
$dest = "build\app\outputs\flutter-apk\megas_inventario.apk"

if (Test-Path $src) {
    Copy-Item $src $dest -Force
    $size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
    Write-Host ""
    Write-Host "APK listo: $dest ($size MB)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Pasos para publicar en GitHub Releases:" -ForegroundColor Yellow
    Write-Host "  1. Actualiza 'version' en version.json"
    Write-Host "  2. Ve a: https://github.com/Recycledj98/megas-inventario/releases/new"
    Write-Host "  3. Tag: v<version>  (ej: v1.6.0)"
    Write-Host "  4. Adjunta: megas_inventario.apk  +  version.json"
    Write-Host "  5. Publica"
} else {
    Write-Host "Error: no se encontro el APK en $src" -ForegroundColor Red
    exit 1
}
