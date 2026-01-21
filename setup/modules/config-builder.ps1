# ==============================================================================
# config-builder.ps1 - Configuration file helper module
# ==============================================================================
# This module provides helpers for updating generated stack files.
# ==============================================================================

function Update-StackBackupNetwork {
    <#
    .SYNOPSIS
    Updates swarm-stack.yml to attach the database service to backup-net.

    .PARAMETER StackFile
    Path to swarm-stack.yml.

    .PARAMETER EnableBackupNetwork
    "true" to enable backup-net, otherwise "false".
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StackFile,
        [string]$EnableBackupNetwork = "false"
    )

    if (-not (Test-Path $StackFile)) {
        Write-Host "[ERROR] Stack file not found: $StackFile" -ForegroundColor Red
        return $false
    }

    $lines = Get-Content $StackFile -ErrorAction SilentlyContinue
    $out = New-Object System.Collections.Generic.List[string]

    $enable = ($EnableBackupNetwork -eq "true")
    $inDb = $false
    $inNetworks = $false
    $skippingBackupDef = $false
    $addedBackupDef = $false
    $addedDb = $false

    foreach ($line in $lines) {
        if ($line -match '^networks:\s*$') { $inNetworks = $true }
        if ($inNetworks -and $line -match '^secrets:\s*$') {
            $inNetworks = $false
            $skippingBackupDef = $false
        }

        if ($inNetworks -and $line -match '^\s{2}backup:\s*$') {
            $skippingBackupDef = $true
            continue
        }
        if ($skippingBackupDef) {
            if ($line -match '^\s{2}[A-Za-z0-9_]+:\s*$' -or $line -match '^secrets:\s*$') {
                $skippingBackupDef = $false
            } else {
                continue
            }
        }

        if ($line -match '^\s{2}db:\s*$') {
            $inDb = $true
        } elseif ($inDb -and $line -match '^\s{2}[A-Za-z0-9_]+:\s*$' -and $line -notmatch '^\s{2}db:\s*$') {
            $inDb = $false
        }

        if ($inDb -and $line -match '^\s{6}-\sbackup\s*$') {
            continue
        }

        $out.Add($line)

        if ($inNetworks -and $enable -and ($line -match '^\s{4}driver:\s*overlay\s*$') -and -not $addedBackupDef) {
            $out.Add('  backup:')
            $out.Add('    external: true')
            $out.Add('    name: backup-net')
            $addedBackupDef = $true
        }

        if ($inDb -and $enable -and ($line -match '^\s{6}-\sbackend\s*$') -and -not $addedDb) {
            $out.Add('      - backup')
            $addedDb = $true
        }
    }

    try {
        $out | Set-Content -Path $StackFile -Encoding utf8
        return $true
    } catch {
        Write-Host "[ERROR] Failed to update backup network in $StackFile: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

try {
    if ($null -ne $ExecutionContext.SessionState.Module) {
        Export-ModuleMember -Function Update-StackBackupNetwork
    }
} catch { }
