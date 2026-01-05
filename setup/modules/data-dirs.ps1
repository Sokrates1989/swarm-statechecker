# data-dirs.ps1
# PowerShell module for preparing data directories and install files

function Initialize-DataRoot {
    <#
    .SYNOPSIS
    Creates required directory structure under DATA_ROOT and copies install files
    (schema + migrations) into place.

    .PARAMETER DataRoot
    The data root directory.

    .PARAMETER ProjectRoot
    The project root directory.

    .OUTPUTS
    System.Boolean
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        Write-Host "[ERROR] DATA_ROOT cannot be empty" -ForegroundColor Red
        return $false
    }

    Write-Host "" 
    Write-Host "[DATA] Preparing DATA_ROOT: $DataRoot" -ForegroundColor Cyan

    $dirs = @(
        Join-Path $DataRoot "logs/api",
        Join-Path $DataRoot "logs/check",
        Join-Path $DataRoot "db_data",
        Join-Path $DataRoot "install/database/migrations"
    )

    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    $schemaSrc = Join-Path $ProjectRoot "install/database/state_checker.sql"
    $schemaDst = Join-Path $DataRoot "install/database/state_checker.sql"

    if (-not (Test-Path $schemaSrc)) {
        Write-Host "[ERROR] Missing schema file: $schemaSrc" -ForegroundColor Red
        return $false
    }

    Copy-Item $schemaSrc $schemaDst -Force

    $migSrc = Join-Path $ProjectRoot "install/database/migrations"
    $migDst = Join-Path $DataRoot "install/database/migrations"

    if (Test-Path $migSrc) {
        Copy-Item (Join-Path $migSrc "*") $migDst -Recurse -Force

        $runMig = Join-Path $migDst "run_migrations.sh"
        if (Test-Path $runMig) {
            $chmod = Get-Command chmod -ErrorAction SilentlyContinue
            if ($null -ne $chmod) {
                & chmod +x $runMig 2>$null
            }
        }
    }

    Write-Host "[OK] DATA_ROOT prepared" -ForegroundColor Green
    return $true
}

if ($null -ne $ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Initialize-DataRoot
}
