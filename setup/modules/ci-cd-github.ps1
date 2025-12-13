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

function Invoke-GitHubCICDHelper {
    Write-Host "🔧 GitHub Actions CI/CD Helper" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host "" 

    $remote = Get-GitHubCicdRepoRemoteUrl
    $web = ConvertTo-GitHubWebUrl -RemoteUrl $remote

    if ($web) {
        Write-Host "Repository (detected): $web" -ForegroundColor Gray
        Write-Host "Variables URL: ${web}/settings/variables/actions" -ForegroundColor Gray
        Write-Host "Secrets URL:   ${web}/settings/secrets/actions" -ForegroundColor Gray
    } else {
        Write-Host "Repository: (could not detect via git)" -ForegroundColor Yellow
    }

    Write-Host "" 
    $publicIp = Get-PublicIpAddress
    if ($publicIp) {
        Write-Host "Detected public IP (suggestion for SSH_HOST*): $publicIp" -ForegroundColor Gray
    } else {
        Write-Host "Public IP: (not detected)" -ForegroundColor Yellow
    }

    Write-Host "" 
    Write-Host "Which environment do you want to configure?" -ForegroundColor Yellow
    Write-Host "1) main" -ForegroundColor Gray
    Write-Host "2) dev" -ForegroundColor Gray
    Write-Host "3) both" -ForegroundColor Gray
    Write-Host "" 
    $envChoice = Read-Host "Your choice (1-3) [3]"
    if ([string]::IsNullOrWhiteSpace($envChoice)) { $envChoice = "3" }

    $defaultDeployPath = (Get-Location).Path

    $envFile = Join-Path (Get-Location).Path ".env"
    $defaultStackName = Get-EnvValueFromFile -FilePath $envFile -Key "STACK_NAME"
    if (-not $defaultStackName) {
        $defaultStackName = (Split-Path -Leaf (Get-Location).Path)
    }

    $defaultImageName = Get-EnvValueFromFile -FilePath $envFile -Key "IMAGE_NAME"

    $defaultStackFile = "swarm-stack.yml"
    if (Test-Path "swarm-stack.yml") {
        $defaultStackFile = "swarm-stack.yml"
    } elseif (Test-Path "config-stack.yml") {
        $defaultStackFile = "config-stack.yml"
    } elseif (Test-Path "docker-compose.yml") {
        $defaultStackFile = "docker-compose.yml"
    } else {
        $composeFiles = Get-ChildItem -Path (Get-Location).Path -Filter "docker-compose-*.yml" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($composeFiles) {
            $defaultStackFile = $composeFiles.Name
        }
    }

    $defaultSshHost = $publicIp
    $defaultSshPort = "22"

    if (-not (Test-Path $envFile)) {
        Write-Host "⚠️  .env not found in this folder. That's ok for CI/CD guidance, but STACK_NAME/IMAGE_NAME cannot be auto-detected." -ForegroundColor Yellow
    }

    if ($envChoice -eq "1" -or $envChoice -eq "3") {
        Write-Host "" 
        Write-Host "--- main environment ---" -ForegroundColor Cyan

        $deployPath = Read-HostDefault -Prompt "DEPLOY_PATH" -Default $defaultDeployPath
        $stackName = Read-HostDefault -Prompt "STACK_NAME" -Default $defaultStackName
        $stackFile = Read-HostDefault -Prompt "STACK_FILE" -Default $defaultStackFile
        $imageName = Read-HostDefault -Prompt "IMAGE_NAME" -Default $defaultImageName
        $sshHost = Read-HostDefault -Prompt "SSH_HOST" -Default $defaultSshHost
        $sshPort = Read-HostDefault -Prompt "SSH_PORT" -Default $defaultSshPort

        Show-GitHubActionsRequiredConfig -Suffix "" -DeployPath $deployPath -StackName $stackName -StackFile $stackFile -ImageName $imageName -SshHost $sshHost -SshPort $sshPort
    }

    if ($envChoice -eq "2" -or $envChoice -eq "3") {
        Write-Host "" 
        Write-Host "--- dev environment ---" -ForegroundColor Cyan

        $deployPathDev = Read-HostDefault -Prompt "DEPLOY_PATH_DEV" -Default $defaultDeployPath
        $stackNameDev = Read-HostDefault -Prompt "STACK_NAME_DEV" -Default ("{0}-dev" -f $defaultStackName)
        $stackFileDev = Read-HostDefault -Prompt "STACK_FILE_DEV" -Default $defaultStackFile
        $imageNameDev = Read-HostDefault -Prompt "IMAGE_NAME_DEV" -Default $defaultImageName
        $sshHostDev = Read-HostDefault -Prompt "SSH_HOST_DEV" -Default $defaultSshHost
        $sshPortDev = Read-HostDefault -Prompt "SSH_PORT_DEV" -Default $defaultSshPort

        Show-GitHubActionsRequiredConfig -Suffix "_DEV" -DeployPath $deployPathDev -StackName $stackNameDev -StackFile $stackFileDev -ImageName $imageNameDev -SshHost $sshHostDev -SshPort $sshPortDev
    }

    Write-Host "" 
    Write-Host "Server-side checklist (run on the target server):" -ForegroundColor Yellow
    Write-Host "  - Ensure the SSH user is allowed to run Docker (usually in the 'docker' group)" -ForegroundColor Gray
    Write-Host "  - Ensure the SSH user can write to DEPLOY_PATH (so the workflow can update .env)" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "Example commands (adjust to your setup):" -ForegroundColor Yellow
    Write-Host "  sudo usermod -aG docker <deploy-user>" -ForegroundColor Gray
    Write-Host "  sudo chown -R <deploy-user>:<deploy-user> <DEPLOY_PATH>" -ForegroundColor Gray
    Write-Host "" 
}

Export-ModuleMember -Function Invoke-GitHubCICDHelper
