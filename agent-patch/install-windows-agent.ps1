$ErrorActionPreference = "Stop"

$directory = "C:\beszel"
$newBinary = Join-Path $directory "beszel-agent-stats.new.exe"
$liveBinary = Join-Path $directory "beszel-agent-stats.exe"
$backupBinary = Join-Path $directory "beszel-agent-stats.pre-balloon.exe"
$installer = Join-Path $directory "install-beszelbar-agent.ps1"

& $newBinary stats 0s | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Yeni agent doğrulama çalıştırmasını geçemedi."
}

if ((Test-Path $liveBinary) -and -not (Test-Path $backupBinary)) {
    Copy-Item $liveBinary $backupBinary
}

Move-Item $newBinary $liveBinary -Force
& $liveBinary stats 0s | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Kurulan agent doğrulama çalıştırmasını geçemedi."
}

Remove-Item $installer -Force -ErrorAction SilentlyContinue
Write-Output "Kuruldu: $liveBinary"
