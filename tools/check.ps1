# Syntax-checks every .lua file in the addon using LuaJIT (Lua 5.1, matches WoW).
# Usage:  powershell -ExecutionPolicy Bypass -File tools\check.ps1
# Exits 1 if any file fails to parse.

$ErrorActionPreference = "Stop"

$luajit = (Get-Command luajit.exe -ErrorAction SilentlyContinue).Source
if (-not $luajit) {
    $fallback = "$env:LOCALAPPDATA\Programs\LuaJIT\bin\luajit.exe"
    if (Test-Path $fallback) { $luajit = $fallback }
}
if (-not $luajit) {
    Write-Error "luajit.exe not found. Install with: winget install --id DEVCOM.LuaJIT -e"
    exit 2
}

$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $root -Recurse -Filter *.lua |
    Where-Object { $_.FullName -notmatch "\\tools\\" }

$failed = 0
foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1)
    # loadfile() parses/compiles without executing: a pure syntax check.
    $err = & $luajit -e "local f,e=loadfile([[$($f.FullName)]]); if not f then io.stderr:write(e) os.exit(1) end" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "OK   $rel"
    } else {
        Write-Host "FAIL $rel" -ForegroundColor Red
        Write-Host "     $err" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "$failed file(s) failed." -ForegroundColor Red
    exit 1
} else {
    Write-Host "All $($files.Count) file(s) OK." -ForegroundColor Green
}
