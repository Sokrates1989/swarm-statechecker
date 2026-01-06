# menu_handlers.ps1
# PowerShell module for handling menu actions

function Get-EnvConfig {
    <#
    .SYNOPSIS
    Reads key/value pairs from .env into a hashtable.
    #>
    if (Test-Path .env) {
        $envContent = Get-Content .env -ErrorAction SilentlyContinue
        $config = @{}
        foreach ($line in $envContent) {
            if ($line -match '^([^#=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim().Trim('"')
                $config[$key] = $value
            }
        }
        return $config
    }
    return @{}
}

function Update-EnvValue {
    <#
    .SYNOPSIS
    Updates (or inserts) a KEY=VALUE pair in a dotenv file.

    .OUTPUTS
    System.Boolean
    #>
    param(
        [Parameter(Mandatory=$true)][string]$EnvFile,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
    )

    try {
        $lines = @()
        if (Test-Path $EnvFile) {
            $lines = Get-Content $EnvFile -ErrorAction SilentlyContinue
        }

        $pattern = "^$([Regex]::Escape($Key))="
        $found = $false
        $out = foreach ($l in $lines) {
            if ($l -match $pattern) {
                $found = $true
                "$Key=$Value"
            } else {
                $l
            }
        }

        if (-not $found) {
            $out = @($out) + "$Key=$Value"
        }

        $out | Set-Content $EnvFile -Encoding utf8
        return $true
    } catch {
        Write-Host "[ERROR] Failed to update env file: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Update-StackImageService {
    <#
    .SYNOPSIS
        Pulls image and updates a specific Swarm service.
    #>
    param(
        [string]$ImageName,
        [string]$ImageTag,
        [string[]]$ServiceNames,
        [string]$EnvKey,
        [string]$StackName
    )

    Write-Host "`nPulling: ${ImageName}:$ImageTag" -ForegroundColor Gray
    try { docker pull "${ImageName}:$ImageTag" 2>$null | Out-Null } catch {}

    Write-Host "`nUpdating services..." -ForegroundColor Gray
    foreach ($svc in $ServiceNames) {
        try { docker service update --image "${ImageName}:$ImageTag" "${StackName}_$svc" 2>$null | Out-Null } catch {}
    }

    Update-EnvValue -EnvFile ".env" -Key $EnvKey -Value $ImageTag | Out-Null
    Write-Host "[OK] Update initiated. Monitor with: docker stack services $StackName" -ForegroundColor Green
}

function Update-StackImages {
    <#
    .SYNOPSIS
    Updates Swarm service images for api/check and/or web.
    #>
    $config = Get-EnvConfig
    Set-ProcessEnvFromConfig -Config $config

    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker" }
    $imgName = $config["IMAGE_NAME"]; $imgTag = $config["IMAGE_VERSION"]
    $webName = $config["WEB_IMAGE_NAME"]; $webTag = $config["WEB_IMAGE_VERSION"]

    Write-Host "`n[UPDATE] Update Image Version`n" -ForegroundColor Cyan
    Write-Host "1) API/CHECK image ($imgName:$imgTag)" -ForegroundColor Gray
    Write-Host "2) WEB image ($webName:$webTag)" -ForegroundColor Gray
    Write-Host "3) Back`n" -ForegroundColor Gray

    $choice = Read-Host "Your choice (1-3)"
    switch ($choice) {
        "1" {
            $newTag = Read-Host "Enter new API/CHECK image tag [$imgTag]"
            Update-StackImageService -ImageName $imgName -ImageTag ($newTag -or $imgTag) -ServiceNames @("api","check") -EnvKey "IMAGE_VERSION" -StackName $stackName
        }
        "2" {
            $newTag = Read-Host "Enter new WEB image tag [$webTag]"
            Update-StackImageService -ImageName $webName -ImageTag ($newTag -or $webTag) -ServiceNames @("web") -EnvKey "WEB_IMAGE_VERSION" -StackName $stackName
        }
    }
}

function Set-ServiceScale {
    <#
    .SYNOPSIS
    Scales selected stack services and persists replica env vars.

    .OUTPUTS
    System.Void
    #>
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker" }

    Write-Host "" 
    Write-Host "[SCALE] Scale Services" -ForegroundColor Cyan
    Write-Host "" 
    Write-Host "1) api" -ForegroundColor Gray
    Write-Host "2) check" -ForegroundColor Gray
    Write-Host "3) web" -ForegroundColor Gray
    Write-Host "4) phpmyadmin" -ForegroundColor Gray
    Write-Host "5) Back" -ForegroundColor Gray
    Write-Host "" 

    $choice = Read-Host "Your choice (1-5)"
    if ($choice -eq "5") { return }

    $replicas = Read-Host "Number of replicas"
    if ([string]::IsNullOrWhiteSpace($replicas)) {
        Write-Host "[ERROR] Replicas cannot be empty" -ForegroundColor Red
        return
    }

    switch ($choice) {
        "1" {
            try { docker service scale "${stackName}_api=$replicas" 2>$null | Out-Null } catch {}
            Update-EnvValue -EnvFile ".env" -Key "API_REPLICAS" -Value $replicas | Out-Null
        }
        "2" {
            try { docker service scale "${stackName}_check=$replicas" 2>$null | Out-Null } catch {}
            Update-EnvValue -EnvFile ".env" -Key "CHECK_REPLICAS" -Value $replicas | Out-Null
        }
        "3" {
            try { docker service scale "${stackName}_web=$replicas" 2>$null | Out-Null } catch {}
            Update-EnvValue -EnvFile ".env" -Key "WEB_REPLICAS" -Value $replicas | Out-Null
        }
        "4" {
            try { docker service scale "${stackName}_phpmyadmin=$replicas" 2>$null | Out-Null } catch {}
            Update-EnvValue -EnvFile ".env" -Key "PHPMYADMIN_REPLICAS" -Value $replicas | Out-Null
        }
        Default { Write-Host "[ERROR] Invalid selection" -ForegroundColor Yellow }
    }
}

function Get-YamlLineIndent {
    param([string]$Line)
    $m = [regex]::Match($Line, '^(\s*)')
    return $m.Groups[1].Value.Length
}

function Flush-LabelsBuffer {
    param(
        [System.Collections.Generic.List[string]]$Output,
        [System.Collections.Generic.List[string]]$LabelsBuffer,
        [int]$LabelsIndent,
        [ref][bool]$InLabelsBlock
    )

    if (-not $InLabelsBlock.Value) { return }

    $kept = @()
    foreach ($l in $LabelsBuffer) {
        if ($l -match '^\s*-\s*traefik\.') { continue }
        $kept += $l
    }

    if ($kept.Count -gt 0) {
        $indentSpaces = ' ' * $LabelsIndent
        $Output.Add("${indentSpaces}labels:")
        foreach ($l in $kept) { $Output.Add($l) }
    }

    $LabelsBuffer.Clear()
    $InLabelsBlock.Value = $false
}

function Add-PortsIfMissing {
    param(
        [System.Collections.Generic.List[string]]$Output,
        [string]$Section,
        [string]$CurrentService,
        [ref][bool]$ApiHasPorts,
        [ref][bool]$WebHasPorts,
        [ref][bool]$PmaHasPorts,
        [string]$ApiPort,
        [string]$WebPort,
        [string]$PmaPort
    )
    if ($Section -ne "services") { return }

    if ($CurrentService -eq "api" -and -not $ApiHasPorts.Value) {
        $Output.Add("    ports:")
        $Output.Add('      - "' + $ApiPort + ':' + $ApiPort + '"')
        $ApiHasPorts.Value = $true
    }
    if ($CurrentService -eq "web" -and -not $WebHasPorts.Value) {
        $Output.Add("    ports:")
        $Output.Add('      - "' + $WebPort + ':80"')
        $WebHasPorts.Value = $true
    }
    if ($CurrentService -eq "phpmyadmin" -and -not $PmaHasPorts.Value) {
        $Output.Add("    ports:")
        $Output.Add('      - "' + $PmaPort + ':80"')
        $PmaHasPorts.Value = $true
    }
}

function Convert-RenderedStackToNoProxy {
    <#
    .SYNOPSIS
    Converts a rendered stack YAML to a no-proxy variant.
    #>
    param([Parameter(Mandatory = $true)][string]$StackFile)

    if (-not (Test-Path $StackFile)) {
        Write-Host "[ERROR] Rendered stack file not found: $StackFile" -ForegroundColor Red
        return $false
    }

    $apiPort = if ($env:API_PORT) { $env:API_PORT } else { "8787" }
    $webPort = if ($env:WEB_PORT) { $env:WEB_PORT } else { "8080" }
    $pmaPort = if ($env:PHPMYADMIN_PORT) { $env:PHPMYADMIN_PORT } else { "8081" }

    $lines = Get-Content $StackFile -ErrorAction SilentlyContinue
    $out = New-Object System.Collections.Generic.List[string]

    $state = @{
        Section = ""; CurrentService = ""; ApiHasPorts = $false; WebHasPorts = $false; PmaHasPorts = $false;
        InNetworksSection = $false; SkipTraefikNetworkBlock = $false; SkipTraefikNetworkIndent = 0;
        InLabelsBlock = $false; LabelsIndent = 0;
        LabelsBuffer = New-Object System.Collections.Generic.List[string]
    }

    foreach ($line in $lines) {
        $indent = Get-YamlLineIndent -Line $line

        if ($state.SkipTraefikNetworkBlock) {
            if ($indent -le $state.SkipTraefikNetworkIndent -and $line -match '^\s*\S') { $state.SkipTraefikNetworkBlock = $false }
            else { continue }
        }

        if ($state.InLabelsBlock) {
            if ($indent -le $state.LabelsIndent -and $line -match '^\s*\S') {
                $refInLabels = [ref]$state.InLabelsBlock
                Flush-LabelsBuffer -Output $out -LabelsBuffer $state.LabelsBuffer -LabelsIndent $state.LabelsIndent -InLabelsBlock $refInLabels
            } else {
                $state.LabelsBuffer.Add($line); continue
            }
        }

        if ($line -match '^services:\s*$') { $state.Section = "services"; $state.CurrentService = ""; $out.Add($line); continue }
        if ($line -match '^networks:\s*$') {
            Add-PortsIfMissing -Output $out -Section $state.Section -CurrentService $state.CurrentService -ApiHasPorts ([ref]$state.ApiHasPorts) -WebHasPorts ([ref]$state.WebHasPorts) -PmaHasPorts ([ref]$state.PmaHasPorts) -ApiPort $apiPort -WebPort $webPort -PmaPort $pmaPort
            $state.Section = "networks"; $state.CurrentService = ""; $state.InNetworksSection = $true; $out.Add($line); continue
        }
        if ($line -match '^secrets:\s*$') {
            Add-PortsIfMissing -Output $out -Section $state.Section -CurrentService $state.CurrentService -ApiHasPorts ([ref]$state.ApiHasPorts) -WebHasPorts ([ref]$state.WebHasPorts) -PmaHasPorts ([ref]$state.PmaHasPorts) -ApiPort $apiPort -WebPort $webPort -PmaPort $pmaPort
            $state.Section = "secrets"; $state.CurrentService = ""; $state.InNetworksSection = $false; $out.Add($line); continue
        }

        if ($state.InNetworksSection -and $line -match '^\s{2}traefik:\s*$') { $state.SkipTraefikNetworkBlock = $true; $state.SkipTraefikNetworkIndent = $indent; continue }
        if ($line -match '^\s*-\s*traefik\s*$') { continue }

        if ($state.Section -eq "services" -and $line -match '^\s{2}([A-Za-z0-9_.-]+):\s*$') {
            Add-PortsIfMissing -Output $out -Section $state.Section -CurrentService $state.CurrentService -ApiHasPorts ([ref]$state.ApiHasPorts) -WebHasPorts ([ref]$state.WebHasPorts) -PmaHasPorts ([ref]$state.PmaHasPorts) -ApiPort $apiPort -WebPort $webPort -PmaPort $pmaPort
            $state.CurrentService = $matches[1]; $state.ApiHasPorts = $false; $state.WebHasPorts = $false; $state.PmaHasPorts = $false; $out.Add($line); continue
        }

        if ($state.Section -eq "services" -and $state.CurrentService -eq "api" -and $line -match '^\s{4}ports:\s*$') { $state.ApiHasPorts = $true }
        if ($state.Section -eq "services" -and $state.CurrentService -eq "web" -and $line -match '^\s{4}ports:\s*$') { $state.WebHasPorts = $true }
        if ($state.Section -eq "services" -and $state.CurrentService -eq "phpmyadmin" -and $line -match '^\s{4}ports:\s*$') { $state.PmaHasPorts = $true }

        if ($state.Section -eq "services" -and ($state.CurrentService -eq "api" -or $state.CurrentService -eq "web" -or $state.CurrentService -eq "phpmyadmin") -and $line -match '^\s{4}deploy:\s*$') {
            Add-PortsIfMissing -Output $out -Section $state.Section -CurrentService $state.CurrentService -ApiHasPorts ([ref]$state.ApiHasPorts) -WebHasPorts ([ref]$state.WebHasPorts) -PmaHasPorts ([ref]$state.PmaHasPorts) -ApiPort $apiPort -WebPort $webPort -PmaPort $pmaPort
        }

        if ($state.Section -eq "services" -and $line -match '^\s{6}labels:\s*$') { $state.InLabelsBlock = $true; $state.LabelsIndent = $indent; $state.LabelsBuffer.Clear(); continue }

        $out.Add($line)
    }

    if ($state.InLabelsBlock) { $refInLabels = [ref]$state.InLabelsBlock; Flush-LabelsBuffer -Output $out -LabelsBuffer $state.LabelsBuffer -LabelsIndent $state.LabelsIndent -InLabelsBlock $refInLabels }
    Add-PortsIfMissing -Output $out -Section $state.Section -CurrentService $state.CurrentService -ApiHasPorts ([ref]$state.ApiHasPorts) -WebHasPorts ([ref]$state.WebHasPorts) -PmaHasPorts ([ref]$state.PmaHasPorts) -ApiPort $apiPort -WebPort $webPort -PmaPort $pmaPort

    try { $out | Set-Content -Path $StackFile -Encoding utf8; return $true }
    catch { Write-Host "[ERROR] Failed to write transformed stack file: $($_.Exception.Message)" -ForegroundColor Red; return $false }
}

function Set-ProcessEnvFromConfig {
    <#
    .SYNOPSIS
    Loads values from a hashtable into the current process environment.

    .DESCRIPTION
    Docker Compose variable substitution for swarm stacks requires environment
    variables to be available at deploy time. This helper ensures .env values
    are exported for the docker-compose config rendering step.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config
    )

    foreach ($key in $Config.Keys) {
        $value = $Config[$key]
        if ($null -ne $value) {
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

Import-Module "$setupDir\modules\data-dirs.ps1" -Force

function Invoke-EnsureDataDirsBeforeDeploy {
    <#
    .SYNOPSIS
        Ensures DATA_ROOT directories are prepared before deployment.
    #>
    if (-not (Test-Path .env)) { return $true }

    $config = Get-EnvConfig
    $dataRoot = $config["DATA_ROOT"]
    if ([string]::IsNullOrWhiteSpace($dataRoot)) { return $true }

    $projectRoot = (Get-Location).Path
    return (Initialize-DataRoot -DataRoot $dataRoot -ProjectRoot $projectRoot)
}

function Get-ComposeCommand {
    <#
    .SYNOPSIS
        Detects available docker-compose command.
    #>
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        return "docker-compose"
    } elseif (Get-Command "docker compose" -ErrorAction SilentlyContinue) {
        # Note: Get-Command might not find "docker compose" as it's a subcommand
        return "docker compose"
    }
    
    # Fallback check via version
    try {
        docker compose version | Out-Null
        if ($LASTEXITCODE -eq 0) { return "docker compose" }
    } catch {}

    return $null
}

function Invoke-RenderStackConfig {
    <#
    .SYNOPSIS
        Renders swarm-stack.yml using docker compose config.
    #>
    param(
        [string]$ComposeCmd,
        [string]$EnvFile,
        [string]$StackFile,
        [string]$OutputFile
    )

    $composeSupportsEnvFile = $false
    try {
        $helpText = & $ComposeCmd --help 2>$null
        if ($helpText -match '--env-file') { $composeSupportsEnvFile = $true }
    } catch {}

    if ((Test-Path $EnvFile) -and $composeSupportsEnvFile) {
        & $ComposeCmd -f $StackFile --env-file $EnvFile config | Out-File -FilePath $OutputFile -Encoding utf8
    } else {
        & $ComposeCmd -f $StackFile config | Out-File -FilePath $OutputFile -Encoding utf8
    }
    return $LASTEXITCODE
}

function Invoke-StackDeploy {
    <#
    .SYNOPSIS
    Deploys the stack using swarm-stack.yml with env-variable substitution.
    #>
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker" }
    
    Write-Host "[DEPLOY] Deploying stack: $stackName" -ForegroundColor Cyan
    Write-Host ""
    $proxyTypeInfo = if ($config["PROXY_TYPE"]) { $config["PROXY_TYPE"] } else { "traefik" }
    Write-Host "[WARN] Make sure you have:" -ForegroundColor Yellow
    Write-Host "   - Created Docker secrets"
    if ($proxyTypeInfo -eq "traefik") {
        Write-Host "   - Configured your domain DNS (Traefik mode)"
        Write-Host "   - Set API_URL / PHPMYADMIN_URL / WEB_URL to real hostnames"
    } else {
        Write-Host "   - Set WEB_PORT / PHPMYADMIN_PORT for localhost access (no-proxy mode)"
    }
    Write-Host ""
    
    if (-not (Test-Path .env)) {
        Write-Host "[ERROR] .env file not found. Please create it first." -ForegroundColor Red
        return
    }
    
    Set-ProcessEnvFromConfig -Config $config

    $telegramEnabled = if ($config.ContainsKey("TELEGRAM_ENABLED")) { $config["TELEGRAM_ENABLED"] } else { "false" }
    $emailEnabled = if ($config.ContainsKey("EMAIL_ENABLED")) { $config["EMAIL_ENABLED"] } else { "false" }

    if ($telegramEnabled -ne "true" -and -not (Test-SecretExists -SecretName "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN")) {
        Write-Host "[INFO] TELEGRAM_ENABLED=false and secret missing; creating placeholder secret STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN" -ForegroundColor Gray
        try { "DISABLED" | docker secret create STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN - 2>$null | Out-Null } catch {}
    }

    if ($emailEnabled -ne "true" -and -not (Test-SecretExists -SecretName "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD")) {
        Write-Host "[INFO] EMAIL_ENABLED=false and secret missing; creating placeholder secret STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD" -ForegroundColor Gray
        try { "DISABLED" | docker secret create STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD - 2>$null | Out-Null } catch {}
    }

    if (-not (Test-SecretExists -SecretName "STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON")) {
        Write-Host "[INFO] Google Drive secret missing; creating placeholder secret STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON" -ForegroundColor Gray
        try { "{}" | docker secret create STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON - 2>$null | Out-Null } catch {}
    }

    $stackFile = "swarm-stack.yml"
    $envFile = ".env"
    $tempConfig = ".stack-deploy-temp.yml"

    $composeCmd = Get-ComposeCommand
    if ($null -eq $composeCmd) {
        Write-Host "[WARN] Neither docker-compose nor 'docker compose' is available. Deploying raw stack file." -ForegroundColor Yellow
        docker stack deploy -c $stackFile $stackName
        return
    }

    $renderExit = Invoke-RenderStackConfig -ComposeCmd $composeCmd -EnvFile $envFile -StackFile $stackFile -OutputFile $tempConfig

    if ($renderExit -ne 0) {
        Write-Host "[ERROR] Failed to render $stackFile via $composeCmd" -ForegroundColor Red
        Remove-Item $tempConfig -ErrorAction SilentlyContinue
        return
    }

    if ($config["PROXY_TYPE"] -eq "none") {
        Write-Host "[INFO] PROXY_TYPE=none: deploying without Traefik (direct ports)" -ForegroundColor Gray
        if (-not (Convert-RenderedStackToNoProxy -StackFile $tempConfig)) {
            Remove-Item $tempConfig -ErrorAction SilentlyContinue
            return
        }
    }

    docker stack deploy -c $tempConfig $stackName
    Remove-Item $tempConfig -ErrorAction SilentlyContinue
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n[OK] Stack deployed: $stackName" -ForegroundColor Green
        Write-Host "`nStack services:" -ForegroundColor Cyan
        docker stack services $stackName
    } else {
        Write-Host "[ERROR] Failed to deploy stack" -ForegroundColor Red
    }
}

function Remove-Stack {
    <#
    .SYNOPSIS
    Removes the deployed stack.
    #>
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker" }
    
    Write-Host "[REMOVE] Removing stack: $stackName" -ForegroundColor Yellow
    docker stack rm $stackName
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Stack removed: $stackName" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Failed to remove stack" -ForegroundColor Red
    }
}

function Show-StackStatus {
    <#
    .SYNOPSIS
    Prints docker stack services for the current stack.
    #>
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker" }
    
    Write-Host "Stack status: $stackName" -ForegroundColor Cyan
    Write-Host ""
    docker stack services $stackName 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Stack not found or not running" -ForegroundColor Yellow
    }
}

function Show-ServiceLogs {
    <#
    .SYNOPSIS
    Interactive log viewer for selected services.
    #>
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker" }
    
    Write-Host "Which service logs do you want to view?" -ForegroundColor Yellow
    Write-Host "1) api" -ForegroundColor Gray
    Write-Host "2) check" -ForegroundColor Gray
    Write-Host "3) web" -ForegroundColor Gray
    Write-Host "4) db" -ForegroundColor Gray
    Write-Host "5) All services" -ForegroundColor Gray
    Write-Host ""
    
    $logChoice = Read-Host "Select (1-5)"
    
    switch ($logChoice) {
        "1" {
            docker service logs "${stackName}_api" -f
        }
        "2" {
            docker service logs "${stackName}_check" -f
        }
        "3" {
            docker service logs "${stackName}_web" -f
        }
        "4" {
            docker service logs "${stackName}_db" -f
        }
        "5" {
            $services = docker service ls --filter "label=com.docker.stack.namespace=$stackName" --format "{{.Name}}" 2>$null
            if (-not $services) {
                Write-Host "Stack not found or no services running" -ForegroundColor Yellow
            } else {
                foreach ($svc in $services) {
                    Write-Host "" 
                    Write-Host "===== $svc =====" -ForegroundColor Cyan
                    docker service logs --tail 50 $svc 2>$null
                }
            }
        }
        Default {
            Write-Host "[ERROR] Invalid selection" -ForegroundColor Yellow
        }
    }
}

function Invoke-PhpMyAdminToggle {
    <#
    .SYNOPSIS
    Enables/disables phpMyAdmin by scaling its service to 1 or 0 replicas.
    #>
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker" }

    $svcName = "${stackName}_phpmyadmin"
    docker service inspect $svcName 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "phpMyAdmin service not found. Make sure the stack is deployed." -ForegroundColor Yellow
        return
    }

    $current = docker service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' $svcName 2>$null
    $currentInt = 0
    [int]::TryParse($current, [ref]$currentInt) | Out-Null

    $newReplicas = 0
    if ($currentInt -eq 0) { $newReplicas = 1 }

    Write-Host "Scaling ${svcName} from $currentInt to $newReplicas replicas..." -ForegroundColor Yellow
    docker service scale "${svcName}=$newReplicas"

    Update-EnvValue -EnvFile ".env" -Key "PHPMYADMIN_REPLICAS" -Value $newReplicas | Out-Null

    if ($newReplicas -eq 0) {
        Write-Host "phpMyAdmin is now DISABLED." -ForegroundColor Yellow
    } else {
        $url = ""
        if (Test-Path .env) {
            $match = Select-String -Path .env -Pattern '^PHPMYADMIN_URL=' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) { $url = ($match.Line -split '=', 2)[1].Trim(' ', '"') }
        }

        $proxyType = if ($config["PROXY_TYPE"]) { $config["PROXY_TYPE"] } else { "traefik" }
        if ($proxyType -eq "none") {
            $pmaPort = if ($config["PHPMYADMIN_PORT"]) { $config["PHPMYADMIN_PORT"] } else { "8081" }
            Write-Host "phpMyAdmin is now ENABLED. Access it via http://localhost:$pmaPort" -ForegroundColor Green
        } elseif ($url) {
            Write-Host "phpMyAdmin is now ENABLED. Access it via https://$url" -ForegroundColor Green
        } else {
            Write-Host "phpMyAdmin is now ENABLED." -ForegroundColor Green
        }
    }
}

function New-RequiredSecretsMenu {
    <#
    .SYNOPSIS
    Interactive creator for required Docker secrets.
    #>
    Write-Host ""
    Write-Host "Create required secrets" -ForegroundColor Cyan
    Write-Host ""
    
    $labelAuth = if (Test-SecretExists -SecretName "STATECHECKER_SERVER_AUTHENTICATION_TOKEN") { "Recreate" } else { "Create" }
    $createAuth = Read-Host "$labelAuth STATECHECKER_SERVER_AUTHENTICATION_TOKEN? (y/N)"
    if ($createAuth -match '^[Yy]$') {
        $null = New-DockerSecret -SecretName "STATECHECKER_SERVER_AUTHENTICATION_TOKEN" -Description "API authentication token"
    }

    $labelRoot = if (Test-SecretExists -SecretName "STATECHECKER_SERVER_DB_ROOT_USER_PW") { "Recreate" } else { "Create" }
    $createRoot = Read-Host "$labelRoot STATECHECKER_SERVER_DB_ROOT_USER_PW? (y/N)"
    if ($createRoot -match '^[Yy]$') {
        $null = New-DockerSecret -SecretName "STATECHECKER_SERVER_DB_ROOT_USER_PW" -Description "MySQL root password"
    }

    $labelUser = if (Test-SecretExists -SecretName "STATECHECKER_SERVER_DB_USER_PW") { "Recreate" } else { "Create" }
    $createUser = Read-Host "$labelUser STATECHECKER_SERVER_DB_USER_PW? (y/N)"
    if ($createUser -match '^[Yy]$') {
        $null = New-DockerSecret -SecretName "STATECHECKER_SERVER_DB_USER_PW" -Description "MySQL user password"
    }
}

function New-OptionalSecretsMenu {
    <#
    .SYNOPSIS
    Interactive creator for optional Docker secrets.
    #>
    Write-Host ""
    Write-Host "Create optional secrets" -ForegroundColor Cyan
    Write-Host ""
    
    $config = Get-EnvConfig
    $telegramEnabled = if ($config.ContainsKey("TELEGRAM_ENABLED")) { $config["TELEGRAM_ENABLED"] } else { "false" }
    $emailEnabled = if ($config.ContainsKey("EMAIL_ENABLED")) { $config["EMAIL_ENABLED"] } else { "false" }

    if ($telegramEnabled -eq "true") {
        $createTelegram = Read-Host "Create Telegram bot token secret? (y/N)"
        if ($createTelegram -match "^[Yy]$") {
            $null = New-DockerSecret -SecretName "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN" -Description "Telegram bot token"
        }
    } else {
        Write-Host "[INFO] TELEGRAM_ENABLED=false: skipping Telegram secret prompt" -ForegroundColor Gray
    }

    if ($emailEnabled -eq "true") {
        $createEmail = Read-Host "Create Email password secret? (y/N)"
        if ($createEmail -match "^[Yy]$") {
            $null = New-DockerSecret -SecretName "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD" -Description "Email SMTP password"
        }
    } else {
        Write-Host "[INFO] EMAIL_ENABLED=false: skipping Email secret prompt" -ForegroundColor Gray
    }
}

function Show-MainMenuText {
    <#
    .SYNOPSIS
        Prints the main menu options.
    #>
    param([int]$MENU_EXIT)

    Write-Host "" 
    Write-Host "================ Main Menu ================" -ForegroundColor Yellow
    Write-Host "" 
    Write-Host "Deployment:" -ForegroundColor Yellow
    Write-Host "  1) Deploy stack" -ForegroundColor Gray
    Write-Host "  2) Remove stack" -ForegroundColor Gray
    Write-Host "  3) Show stack status" -ForegroundColor Gray
    Write-Host "  4) Health check" -ForegroundColor Gray
    Write-Host "  5) View service logs" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "Management:" -ForegroundColor Yellow
    Write-Host "  6) Update image version" -ForegroundColor Gray
    Write-Host "  7) Scale services" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "Secrets:" -ForegroundColor Yellow
    Write-Host "  8) Check required secrets" -ForegroundColor Gray
    Write-Host "  9) Create required secrets" -ForegroundColor Gray
    Write-Host "  10) Create secrets from secrets.env file" -ForegroundColor Gray
    Write-Host "  11) Create optional secrets (Telegram, Email)" -ForegroundColor Gray
    Write-Host "  12) List all secrets" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "Setup:" -ForegroundColor Yellow
    Write-Host "  13) Re-run setup wizard" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "Extras:" -ForegroundColor Yellow
    Write-Host "  14) Toggle phpMyAdmin (enable/disable)" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "CI/CD:" -ForegroundColor Yellow
    Write-Host "  15) GitHub Actions CI/CD helper" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "  $MENU_EXIT) Exit" -ForegroundColor Gray
    Write-Host "" 
}

function Handle-MenuChoice {
    <#
    .SYNOPSIS
        Dispatches menu choices to appropriate functions.
    #>
    param(
        [string]$Choice,
        [int]$MENU_EXIT,
        [string]$setupDir
    )

    switch ($Choice) {
        "1" {
            Write-Host "[DEPLOY] Deploying stack..." -ForegroundColor Cyan
            if (-not (Invoke-EnsureDataDirsBeforeDeploy)) { return }
            Invoke-StackDeploy
        }
        "2" { Remove-Stack }
        "3" { Show-StackStatus }
        "4" {
            $config = Get-EnvConfig
            Set-ProcessEnvFromConfig -Config $config
            $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker" }
            $proxyType = if ($config["PROXY_TYPE"]) { $config["PROXY_TYPE"] } else { "traefik" }
            Test-DeploymentHealth -StackName $stackName -ProxyType $proxyType -WaitSeconds 10 | Out-Null
        }
        "5" { Show-ServiceLogs }
        "6" { Update-StackImages }
        "7" { Set-ServiceScale }
        "8" { Test-RequiredSecrets; Test-OptionalSecrets }
        "9" { New-RequiredSecretsMenu }
        "10" { New-SecretsFromFile -SecretsFile "secrets.env" -TemplateFile "setup\secrets.env.template" | Out-Null }
        "11" { New-OptionalSecretsMenu }
        "12" { Get-SecretList }
        "13" {
            $wizardPath = Join-Path $setupDir "setup-wizard.ps1"
            if (Test-Path $wizardPath) { & $wizardPath }
            else { Write-Host "[ERROR] Setup wizard not found: $wizardPath" -ForegroundColor Red }
        }
        "14" { Invoke-PhpMyAdminToggle }
        "15" { Invoke-GitHubCICDHelper }
        "$MENU_EXIT" { Write-Host "Goodbye!" -ForegroundColor Cyan; exit 0 }
        Default { Write-Host "[ERROR] Invalid selection" -ForegroundColor Yellow }
    }
}

function Show-MainMenu {
    <#
    .SYNOPSIS
    Main interactive menu loop.
    #>
    while ($true) {
        $MENU_EXIT = 16
        Show-MainMenuText -MENU_EXIT $MENU_EXIT
        $choice = Read-Host "Your choice (1-$MENU_EXIT)"
        Handle-MenuChoice -Choice $choice -MENU_EXIT $MENU_EXIT -setupDir $setupDir
    }
}

try {
    if ($null -ne $ExecutionContext.SessionState.Module) {
        Export-ModuleMember -Function Get-EnvConfig, Update-EnvValue, Set-ProcessEnvFromConfig, Invoke-StackDeploy, Remove-Stack, Show-StackStatus, Show-ServiceLogs, Invoke-PhpMyAdminToggle, New-RequiredSecretsMenu, New-OptionalSecretsMenu, Update-StackImages, Set-ServiceScale, Show-MainMenu
    }
} catch {
}
