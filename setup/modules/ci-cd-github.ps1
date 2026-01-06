function Get-GitHubCicdRepoRemoteUrl {
    try {
        $url = git remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $url) {
            return $url.Trim()
        }
    } catch {
    }

    return ""
}

function ConvertTo-GitHubWebUrl {
    param(
        [string]$RemoteUrl
    )

    if (-not $RemoteUrl) {
        return ""
    }

    $url = $RemoteUrl.Trim()

    if ($url -match '^git@github.com:') {
        $url = "https://github.com/" + $url.Substring("git@github.com:".Length)
    }

    if ($url -match '^https?://github.com/') {
        if ($url.EndsWith(".git")) {
            $url = $url.Substring(0, $url.Length - 4)
        }
        return $url
    }

    return $url
}

function Get-PublicIpAddress {
    try {
        $ip = Invoke-RestMethod -Uri "https://api.ipify.org" -Method Get -TimeoutSec 8 -ErrorAction Stop
        if ($ip) {
            return ($ip.ToString()).Trim()
        }
    } catch {
    }

    return ""
}

function Get-EnvValueFromFile {
    param(
        [string]$FilePath,
        [string]$Key
    )

    if (-not (Test-Path $FilePath)) {
        return ""
    }

    try {
        $line = Get-Content $FilePath -ErrorAction Stop | Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
        if (-not $line) {
            return ""
        }
        return (($line -split "=", 2)[1]).Trim().Trim('"')
    } catch {
        return ""
    }
}

function Read-HostDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )

    $input = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($input)) {
        return $Default
    }

    return $input
}

function Show-GitHubActionsRequiredConfig {
    param(
        [string]$Suffix,
        [string]$DeployPath,
        [string]$StackName,
        [string]$StackFile,
        [string]$ImageName,
        [string]$SshHost,
        [string]$SshPort
    )

    Write-Host "" 
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host "GitHub Actions configuration" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host "" 

    Write-Host "Repository Variables (Settings -> Secrets and variables -> Actions -> Variables):" -ForegroundColor Yellow
    Write-Host "  IMAGE_NAME${Suffix}=$ImageName" -ForegroundColor Gray
    Write-Host "  STACK_NAME${Suffix}=$StackName" -ForegroundColor Gray
    Write-Host "  STACK_FILE${Suffix}=$StackFile" -ForegroundColor Gray
    Write-Host "  DEPLOY_PATH${Suffix}=$DeployPath" -ForegroundColor Gray

    Write-Host "" 
    Write-Host "Repository Secrets (Settings -> Secrets and variables -> Actions -> Secrets):" -ForegroundColor Yellow
    Write-Host "  SSH_HOST${Suffix}=$SshHost" -ForegroundColor Gray
    Write-Host "  SSH_PORT${Suffix}=$SshPort" -ForegroundColor Gray
    Write-Host "  SSH_USER${Suffix}=<deploy-user>" -ForegroundColor Gray
    Write-Host "  SSH_PRIVATE_KEY${Suffix}=<private key for deploy-user>" -ForegroundColor Gray
    Write-Host "  DOCKER_USERNAME${Suffix}=<registry username>" -ForegroundColor Gray
    Write-Host "  DOCKER_PASSWORD${Suffix}=<registry password/token>" -ForegroundColor Gray
}

function Show-GitHubEnvHeader {
    param([string]$EnvName)
    Write-Host "`n--- $EnvName environment ---" -ForegroundColor Cyan
}

function Prompt-GitHubEnvConfig {
    param(
        [string]$Suffix,
        [hashtable]$Defaults
    )
    $config = @{}
    $config.DeployPath = Read-HostDefault -Prompt "DEPLOY_PATH$Suffix" -Default $Defaults.DeployPath
    $config.StackName = Read-HostDefault -Prompt "STACK_NAME$Suffix" -Default $Defaults.StackName
    $config.StackFile = Read-HostDefault -Prompt "STACK_FILE$Suffix" -Default $Defaults.StackFile
    $config.ImageName = Read-HostDefault -Prompt "IMAGE_NAME$Suffix" -Default $Defaults.ImageName
    $config.SshHost = Read-HostDefault -Prompt "SSH_HOST$Suffix" -Default $Defaults.SshHost
    $config.SshPort = Read-HostDefault -Prompt "SSH_PORT$Suffix" -Default $Defaults.SshPort
    return $config
}

function Invoke-GitHubCICDHelper {
    Write-Host "GitHub Actions CI/CD Helper`n==============================`n" -ForegroundColor Cyan

    $remote = Get-GitHubCicdRepoRemoteUrl
    $web = ConvertTo-GitHubWebUrl -RemoteUrl $remote
    if ($web) {
        Write-Host "Repository (detected): $web" -ForegroundColor Gray
        Write-Host "Variables URL: ${web}/settings/variables/actions" -ForegroundColor Gray
        Write-Host "Secrets URL:   ${web}/settings/secrets/actions" -ForegroundColor Gray
    } else {
        Write-Host "Repository: (could not detect via git)" -ForegroundColor Yellow
    }

    $publicIp = Get-PublicIpAddress
    if ($publicIp) { Write-Host "`nDetected public IP (suggestion for SSH_HOST*): $publicIp" -ForegroundColor Gray }
    else { Write-Host "`nPublic IP: (not detected)" -ForegroundColor Yellow }

    Write-Host "`nWhich environment do you want to configure?`n1) main`n2) dev`n3) both`n" -ForegroundColor Yellow
    $envChoice = Read-Host "Your choice (1-3) [3]"
    if ([string]::IsNullOrWhiteSpace($envChoice)) { $envChoice = "3" }

    $envFile = Join-Path (Get-Location).Path ".env"
    $defaults = @{
        DeployPath = (Get-Location).Path
        StackName = Get-EnvValueFromFile -FilePath $envFile -Key "STACK_NAME" -or (Split-Path -Leaf (Get-Location).Path)
        ImageName = Get-EnvValueFromFile -FilePath $envFile -Key "IMAGE_NAME"
        StackFile = if (Test-Path "swarm-stack.yml") { "swarm-stack.yml" } else { "docker-compose.yml" }
        SshHost = $publicIp
        SshPort = "22"
    }

    if (-not (Test-Path $envFile)) { Write-Host "[WARN] .env not found. STACK_NAME/IMAGE_NAME cannot be auto-detected." -ForegroundColor Yellow }

    if ($envChoice -eq "1" -or $envChoice -eq "3") {
        Show-GitHubEnvHeader -EnvName "main"
        $cfg = Prompt-GitHubEnvConfig -Suffix "" -Defaults $defaults
        Show-GitHubActionsRequiredConfig -Suffix "" -DeployPath $cfg.DeployPath -StackName $cfg.StackName -StackFile $cfg.StackFile -ImageName $cfg.ImageName -SshHost $cfg.SshHost -SshPort $cfg.SshPort
    }

    if ($envChoice -eq "2" -or $envChoice -eq "3") {
        Show-GitHubEnvHeader -EnvName "dev"
        $devDefaults = $defaults.Clone(); $devDefaults.StackName = "{0}-dev" -f $defaults.StackName
        $cfg = Prompt-GitHubEnvConfig -Suffix "_DEV" -Defaults $devDefaults
        Show-GitHubActionsRequiredConfig -Suffix "_DEV" -DeployPath $cfg.DeployPath -StackName $cfg.StackName -StackFile $cfg.StackFile -ImageName $cfg.ImageName -SshHost $cfg.SshHost -SshPort $cfg.SshPort
    }

    Write-Host "`nServer-side checklist:`n  - Ensure SSH user is in docker group`n  - Ensure SSH user can write to DEPLOY_PATH`n" -ForegroundColor Yellow
}

try {
    if ($null -ne $ExecutionContext.SessionState.Module) {
        Export-ModuleMember -Function Invoke-GitHubCICDHelper
    }
} catch {
}
