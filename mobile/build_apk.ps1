$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$definesFile = Join-Path $scriptDir 'config\dart_defines.json'

if (-not (Test-Path -LiteralPath $definesFile)) {
    throw "Missing dart define file: $definesFile"
}

$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $flutterCmd) {
    $fallbackFlutter = Join-Path $env:USERPROFILE 'develop\flutter\bin\flutter.bat'
    if (Test-Path -LiteralPath $fallbackFlutter) {
        $flutterCmd = $fallbackFlutter
    } else {
        $flutterCmd = 'flutter'
    }
}

& $flutterCmd build apk --dart-define-from-file="$definesFile" @args
