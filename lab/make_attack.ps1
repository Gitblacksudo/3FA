# make_attack.ps1 - Escenario de ataque reproducible para el TFM Centinela.
#
# Simula reconocimiento / movimiento lateral por abuso de la ServiceAccount
# 'victim-sa': enumera secrets, serviceaccounts y RBAC en todo el cluster,
# y consulta sus propios permisos. Es el comportamiento que el detector IA
# debe marcar como anomalia frente al baseline legitimo (get pods/configmaps).
#
# Uso (demo de un solo comando):
#   .\make_attack.ps1                       # 90 s de ataque, peticion cada 3 s
#   .\make_attack.ps1 -DurationSeconds 120  # personalizar duracion
#
# Requiere: el detector corriendo en modo deteccion (python compare.py) para
# capturar el ataque en results.csv.

param(
    [int]$DurationSeconds = 90,
    [double]$IntervalSeconds = 3,
    [string]$Pod = "victim-pod"
)

$ErrorActionPreference = "SilentlyContinue"

# Acciones de reconocimiento RBAC (todas permitidas por el ClusterRole sobre-permisado)
$recon = @(
    @("get", "secrets", "-A"),
    @("get", "serviceaccounts", "-A"),
    @("auth", "can-i", "--list"),
    @("get", "clusterroles"),
    @("get", "clusterrolebindings")
)

Write-Host "[attack] Inicio del reconocimiento desde '$Pod' - $DurationSeconds s" -ForegroundColor Red
Write-Host "[attack] Marca de inicio (UTC): $((Get-Date).ToUniversalTime().ToString('o'))" -ForegroundColor Yellow

$end = (Get-Date).AddSeconds($DurationSeconds)
$count = 0
while ((Get-Date) -lt $end) {
    foreach ($cmd in $recon) {
        kubectl exec $Pod -- kubectl @cmd 2>$null | Out-Null
        $count++
    }
    $left = [int]($end - (Get-Date)).TotalSeconds
    Write-Host ("[attack] {0,3}s restantes | {1} peticiones enviadas" -f $left, $count)
    Start-Sleep -Seconds $IntervalSeconds
}

Write-Host "[attack] Marca de fin (UTC): $((Get-Date).ToUniversalTime().ToString('o'))" -ForegroundColor Yellow
Write-Host "[attack] Completado: $count peticiones de reconocimiento." -ForegroundColor Red
