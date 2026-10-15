param(
    [Parameter(Mandatory=$true)][string]$NdkRoot
)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/clang++.exe'
$inspector = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'NDK compiler not found' }
$source = Join-Path $PSScriptRoot 'src/nativosd.cpp'
$output = Join-Path $PSScriptRoot 'nativosd-arm64'
& $compiler --target=aarch64-linux-android28 -std=c++17 -Wall -Wextra -Werror -fPIE -pie -static-libstdc++ $source -o $output
if ($LASTEXITCODE -ne 0) { throw 'Android compilation failed' }
& $inspector --file-header --dynamic $output
if ($LASTEXITCODE -ne 0) { throw 'ELF inspection failed' }
Get-FileHash -LiteralPath $output -Algorithm SHA256
$runnerSource = Join-Path $PSScriptRoot 'src/session_runner.cpp'
$supervisorSource = Join-Path $PSScriptRoot 'src/session_supervisor.cpp'
$runnerOutput = Join-Path $PSScriptRoot 'nativos-session-runner-arm64'
& $compiler --target=aarch64-linux-android28 -std=c++17 -Wall -Wextra -Werror -fPIE -pie -static-libstdc++ $runnerSource $supervisorSource -o $runnerOutput
if ($LASTEXITCODE -ne 0) { throw 'Android runner compilation failed' }
Get-FileHash -LiteralPath $runnerOutput -Algorithm SHA256
