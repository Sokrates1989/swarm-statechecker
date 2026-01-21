# ==============================================================================
# backup_integration.ps1 - Backup network integration helpers
# ==============================================================================
# Module: backup_integration.ps1
# Description:
#   Integrates the swarm-statechecker MySQL service with the shared backup-net
#   overlay used by the Swarm Backup-Restore stack.
# ==============================================================================

function ConvertTo-TruthyValue {
    <#
    .SYNOPSIS
    Converts common truthy strings to a boolean.

    .PARAMETER Value
    Value to evaluate.

    .OUTPUTS
    System.Boolean
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $normalized = $Value.Trim().ToLowerInvariant()
    return @("true", "1", "yes", "y").Contains($normalized)
}

function Get-EnvValueFromFile {
    <#
    .SYNOPSIS
    Reads a single key from a dotenv-style file.

    .PARAMETER EnvFile
    Path to the env file.

    .PARAMETER Key
    Key to read.

    .PARAMETER DefaultValue
    Value to use when the key is missing.

    .OUTPUTS
    System.String
    #>
    param(
        [Parameter(Mandatory = $true)][string]$EnvFile,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$DefaultValue = ""
    )

    if (-not (Test-Path $EnvFile)) { return $DefaultValue }
    $line = Get-Content $EnvFile -ErrorAction SilentlyContinue | Where-Object { $_ -match "^$([Regex]::Escape($Key))=" } | Select-Object -First 1
    if (-not $line) { return $DefaultValue }
    return ($line -split "=", 2)[1].Trim().Trim('"')
}

function Get-BackupRestoreStackInfo {
    <#
    .SYNOPSIS
    Detects a deployed Swarm Backup-Restore stack via stack or image names.

    .OUTPUTS
    System.Collections.Hashtable or $null
    #>
    $defaultStack = "backup-restore"
    $defaultApiImage = "sokrates1989/backup-restore"
    $defaultWebImage = "sokrates1989/backup-restore-web"

    $stackName = $null
    $source = $null

    try {
        $stacks = docker stack ls --format "{{.Name}}" 2>$null
        if ($stacks -contains $defaultStack) {
            $stackName = $defaultStack
            $source = "stack"
        }
    } catch { }

    if (-not $stackName) {
        try {
            $services = docker service ls --format "{{.Name}} {{.Image}}" 2>$null
            foreach ($svc in $services) {
                if ($svc -match $defaultApiImage -or $svc -match $defaultWebImage) {
                    $svcName = ($svc -split " ")[0]
                    $stackName = ($svcName -split "_")[0]
                    $source = "image"
                    break
                }
            }
        } catch { }
    }

    if (-not $stackName) { return $null }
    return @{ StackName = $stackName; Source = $source }
}

function Write-BackupRestoreGuidance {
    <#
    .SYNOPSIS
    Prints guidance for the Swarm Backup-Restore integration.
    #>
    $defaultStack = "backup-restore"
    $defaultApiImage = "sokrates1989/backup-restore"
    $defaultWebImage = "sokrates1989/backup-restore-web"

    Write-Host "[INFO] This backup network is used by the Swarm Backup-Restore deployment." -ForegroundColor Gray
    Write-Host "       Use it with the 'swarm-backup-restore' deployment repo (which deploys the" -ForegroundColor Gray
    Write-Host "       backup-restore API/Web images from the 'backup-restore' project)." -ForegroundColor Gray

    $info = Get-BackupRestoreStackInfo
    if ($null -ne $info) {
        if ($info.Source -eq "stack") {
            Write-Host "[OK] Detected backup-restore stack: $($info.StackName) (by stack name)." -ForegroundColor Green
        } else {
            Write-Host "[OK] Detected backup-restore stack: $($info.StackName) (by image match)." -ForegroundColor Green
        }
    } else {
        Write-Host "[WARN] No backup-restore stack detected yet." -ForegroundColor Yellow
        Write-Host "       Default stack name: $defaultStack" -ForegroundColor Yellow
        Write-Host "       Default images: $defaultApiImage, $defaultWebImage" -ForegroundColor Yellow
        Write-Host "       Deploy it from the swarm-backup-restore repo (quick-start.sh)." -ForegroundColor Yellow
    }
    Write-Host ""
}

function Test-BackupNetworkExists {
    <#
    .SYNOPSIS
    Checks whether the backup-net overlay exists.

    .OUTPUTS
    System.Boolean
    #>
    try {
        docker network inspect "backup-net" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-DbBackupNetworkAttachment {
    <#
    .SYNOPSIS
    Verifies that the DB service is attached to the backup network.

    .PARAMETER StackName
    Stack name to inspect.

    .PARAMETER NetworkName
    Network name to verify.

    .PARAMETER Retries
    Number of retries before failing.

    .PARAMETER WaitSeconds
    Seconds to wait between retries.

    .OUTPUTS
    System.Boolean
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StackName,
        [string]$NetworkName = "backup-net",
        [int]$Retries = 6,
        [int]$WaitSeconds = 5
    )

    $dbService = "${StackName}_db"
    try {
        docker service inspect $dbService 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[WARN] Swarm service '$dbService' not found. Skipping backup network check." -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "[WARN] Swarm service '$dbService' not found. Skipping backup network check." -ForegroundColor Yellow
        return $false
    }

    $networkId = $null
    try {
        $networkId = docker network inspect $NetworkName --format "{{.ID}}" 2>$null
    } catch { }
    if ([string]::IsNullOrWhiteSpace($networkId)) {
        Write-Host "[WARN] Network '$NetworkName' not found. Skipping backup network check." -ForegroundColor Yellow
        return $false
    }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $serviceNetworks = docker service inspect $dbService --format "{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}" 2>$null
        if ($serviceNetworks -and (" $serviceNetworks " -match " $networkId ")) {
            Write-Host "[OK] Database service '$dbService' is attached to '$NetworkName'." -ForegroundColor Green
            return $true
        }
        Write-Host "[WAIT] '$NetworkName' attachment not confirmed yet (attempt $attempt/$Retries)." -ForegroundColor Gray
        Start-Sleep -Seconds $WaitSeconds
    }

    Write-Host "[WARN] Database service '$dbService' is not attached to '$NetworkName'." -ForegroundColor Yellow
    Write-Host "       Check: docker service inspect $dbService --format '{{json .Spec.TaskTemplate.Networks}}'" -ForegroundColor Yellow
    return $false
}

function Write-BackupRestoreSecurityGuidance {
    <#
    .SYNOPSIS
    Prints security guidance for MySQL backup credentials.

    .PARAMETER DbName
    Database name.

    .PARAMETER DbUser
    Database owner/user.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DbName,
        [Parameter(Mandatory = $true)][string]$DbUser
    )

    $backupUser = "statechecker_backup"

    Write-Host "Security hardening (recommended):" -ForegroundColor Yellow
    try {
        $opts = docker network inspect backup-net --format "{{json .Options}}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $opts -match "encrypted") {
            Write-Host "  1) [OK] Network 'backup-net' appears to be encrypted (overlay)" -ForegroundColor Green
        } else {
            Write-Host "  1) [WARN] Network 'backup-net' does not appear to be encrypted." -ForegroundColor Yellow
            Write-Host "           For highest security, create it with:" -ForegroundColor Yellow
            Write-Host "           docker network rm backup-net  # only if no stacks are attached" -ForegroundColor Yellow
            Write-Host "           docker network create --driver overlay --opt encrypted backup-net" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  1) [WARN] Could not inspect network encryption settings." -ForegroundColor Yellow
    }

    Write-Host "  2) Choose credentials for Backup-Restore (single user for backup + restore)." -ForegroundColor Yellow
    Write-Host "     Simplest: reuse the DB owner '$DbUser' (works for backup + restore)." -ForegroundColor Gray
    Write-Host "     Alternative: create '$backupUser' with backup-friendly permissions:" -ForegroundColor Gray
    Write-Host "       CREATE USER '$backupUser'@'%' IDENTIFIED BY '<GENERATE_STRONG_PASSWORD>';" -ForegroundColor Gray
    Write-Host "       GRANT SELECT, SHOW VIEW, LOCK TABLES, EVENT, TRIGGER ON `\"$DbName\"`.* TO '$backupUser'@'%';" -ForegroundColor Gray
    Write-Host "       FLUSH PRIVILEGES;" -ForegroundColor Gray

    Write-Host "  3) Credential scope" -ForegroundColor Yellow
    Write-Host "     - Backup-Restore uses one credential for backup + restore." -ForegroundColor Gray
    Write-Host "     - Restores require owner/DDL permissions (read-only roles will fail)." -ForegroundColor Gray
    Write-Host "     - Protect access via secrets + network isolation (backup-net)." -ForegroundColor Gray
    Write-Host ""
}

function Show-BackupRestoreConnectionInfo {
    <#
    .SYNOPSIS
    Prints connection details for the Backup-Restore UI.

    .OUTPUTS
    System.Boolean
    #>
    $envFile = Join-Path (Get-Location).Path ".env"
    if (-not (Test-Path $envFile)) {
        Write-Host "[ERROR] .env not found. Run the setup wizard first." -ForegroundColor Red
        return $false
    }

    $enabledRaw = Get-EnvValueFromFile -EnvFile $envFile -Key "ENABLE_BACKUP_NETWORK" -DefaultValue "false"
    if (-not (ConvertTo-TruthyValue $enabledRaw)) {
        Write-Host "[WARN] Backup integration is not enabled. Info below assumes 'backup-net' is attached." -ForegroundColor Yellow
    }

    $stackName = Get-EnvValueFromFile -EnvFile $envFile -Key "STACK_NAME" -DefaultValue "statechecker"
    $dbName = Get-EnvValueFromFile -EnvFile $envFile -Key "DB_NAME" -DefaultValue "state_checker"
    $dbUser = Get-EnvValueFromFile -EnvFile $envFile -Key "DB_USER" -DefaultValue "state_checker"
    $dbType = Get-EnvValueFromFile -EnvFile $envFile -Key "DB_TYPE" -DefaultValue "mysql"

    Write-Host "Backup-Restore UI connection details:" -ForegroundColor Cyan
    Write-Host "  - Network:      backup-net" -ForegroundColor Gray
    Write-Host "  - DB Type:      $dbType" -ForegroundColor Gray
    Write-Host "  - DB Host:      ${stackName}_db" -ForegroundColor Gray
    Write-Host "  - DB Port:      3306" -ForegroundColor Gray
    Write-Host "  - Database:     $dbName" -ForegroundColor Gray
    Write-Host "  - Username:     $dbUser" -ForegroundColor Gray
    Write-Host "  - Password:     <DB user password>" -ForegroundColor Gray
    Write-Host ""

    return $true
}

function Invoke-SetupBackupIntegration {
    <#
    .SYNOPSIS
    Enables backup integration and optionally redeploys the stack.

    .OUTPUTS
    System.Boolean
    #>
    $envFile = Join-Path (Get-Location).Path ".env"
    $stackFile = Join-Path (Get-Location).Path "swarm-stack.yml"

    if (-not (Test-Path $envFile)) {
        Write-Host "[ERROR] .env not found. Run the setup wizard first." -ForegroundColor Red
        return $false
    }
    if (-not (Test-Path $stackFile)) {
        Write-Host "[ERROR] swarm-stack.yml not found. Run the setup wizard first." -ForegroundColor Red
        return $false
    }

    Write-Host "" 
    Write-Host "[BACKUP] Central Backup Integration" -ForegroundColor Cyan
    Write-Host "==================================" -ForegroundColor Cyan
    Write-Host "" 

    Write-BackupRestoreGuidance

    if (-not (Test-BackupNetworkExists)) {
        Write-Host "[ERROR] Network 'backup-net' not found." -ForegroundColor Red
        Write-Host "        Deploy the Swarm Backup-Restore stack first so it can create the network." -ForegroundColor Yellow
        return $false
    }

    Update-EnvValue -EnvFile $envFile -Key "ENABLE_BACKUP_NETWORK" -Value "true" | Out-Null
    if (Get-Command Update-StackBackupNetwork -ErrorAction SilentlyContinue) {
        $null = Update-StackBackupNetwork -StackFile $stackFile -EnableBackupNetwork "true"
    }

    Write-Host "" 
    Write-Host "[OK] Updated .env and swarm-stack.yml" -ForegroundColor Green
    Write-Host "" 

    $stackName = Get-EnvValueFromFile -EnvFile $envFile -Key "STACK_NAME" -DefaultValue "statechecker"
    $dbName = Get-EnvValueFromFile -EnvFile $envFile -Key "DB_NAME" -DefaultValue "state_checker"
    $dbUser = Get-EnvValueFromFile -EnvFile $envFile -Key "DB_USER" -DefaultValue "state_checker"

    Write-BackupRestoreSecurityGuidance -DbName $dbName -DbUser $dbUser
    $null = Show-BackupRestoreConnectionInfo

    $redeploy = Read-Host "Redeploy the stack now to apply the backup network? (Y/n)"
    if ($redeploy -notmatch "^[Nn]$") {
        if (Get-Command Invoke-EnsureDataDirsBeforeDeploy -ErrorAction SilentlyContinue) {
            if (-not (Invoke-EnsureDataDirsBeforeDeploy)) {
                Write-Host "[ERROR] Deployment aborted due to data directory preparation failure." -ForegroundColor Red
                return $false
            }
        }

        if (Get-Command Invoke-StackDeploy -ErrorAction SilentlyContinue) {
            Invoke-StackDeploy
            $null = Test-DbBackupNetworkAttachment -StackName $stackName
            $null = Show-BackupRestoreConnectionInfo
        } else {
            Write-Host "[WARN] Invoke-StackDeploy is not available in this session." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[INFO] Redeploy required: use 'Deploy stack' after enabling backup integration." -ForegroundColor Gray
    }

    return $true
}

try {
    if ($null -ne $ExecutionContext.SessionState.Module) {
        Export-ModuleMember -Function Show-BackupRestoreConnectionInfo, Invoke-SetupBackupIntegration, Test-BackupNetworkExists
    }
} catch { }
