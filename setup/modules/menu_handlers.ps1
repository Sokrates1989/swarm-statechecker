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

function Update-StackImages {
    <#
    .SYNOPSIS
    Updates Swarm service images for api/check and/or web.

    .DESCRIPTION
    Pulls the requested image tag and updates the running Swarm services.
    Persists updated tags back to the local .env file.

    .OUTPUTS
    System.Void
    #>
    $config = Get-EnvConfig
    Set-ProcessEnvFromConfig -Config $config

    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }

    $imageName = if ($config["IMAGE_NAME"]) { $config["IMAGE_NAME"] } else { "" }
    $imageTag = if ($config["IMAGE_VERSION"]) { $config["IMAGE_VERSION"] } else { "latest" }

    $webImageName = if ($config["WEB_IMAGE_NAME"]) { $config["WEB_IMAGE_NAME"] } else { "" }
    $webImageTag = if ($config["WEB_IMAGE_VERSION"]) { $config["WEB_IMAGE_VERSION"] } else { "latest" }

    Write-Host "" 
    Write-Host "[UPDATE] Update Image Version" -ForegroundColor Cyan
    Write-Host "" 
    Write-Host ("1) API/CHECK image ({0}:{1})" -f $imageName, $imageTag) -ForegroundColor Gray
    Write-Host ("2) WEB image ({0}:{1})" -f $webImageName, $webImageTag) -ForegroundColor Gray
    Write-Host "3) Back" -ForegroundColor Gray
    Write-Host "" 

    $choice = Read-Host "Your choice (1-3)"
    switch ($choice) {
        "1" {
            $newTag = Read-Host "Enter new API/CHECK image tag [$imageTag]"
            if ([string]::IsNullOrWhiteSpace($newTag)) { $newTag = $imageTag }

            Write-Host "" 
            Write-Host ("Pulling: {0}:{1}" -f $imageName, $newTag) -ForegroundColor Gray
            try { docker pull "${imageName}:$newTag" 2>$null | Out-Null } catch {}

            Write-Host "" 
            Write-Host "Updating services..." -ForegroundColor Gray
            try { docker service update --image "${imageName}:$newTag" "${stackName}_api" 2>$null | Out-Null } catch {}
            try { docker service update --image "${imageName}:$newTag" "${stackName}_check" 2>$null | Out-Null } catch {}

            Update-EnvValue -EnvFile ".env" -Key "IMAGE_VERSION" -Value $newTag | Out-Null

            Write-Host "" 
            Write-Host ("[OK] Update initiated. Monitor with: docker stack services {0}" -f $stackName) -ForegroundColor Green
        }
        "2" {
            $newTag = Read-Host "Enter new WEB image tag [$webImageTag]"
            if ([string]::IsNullOrWhiteSpace($newTag)) { $newTag = $webImageTag }

            Write-Host "" 
            Write-Host ("Pulling: {0}:{1}" -f $webImageName, $newTag) -ForegroundColor Gray
            try { docker pull "${webImageName}:$newTag" 2>$null | Out-Null } catch {}

            Write-Host "" 
            Write-Host "Updating service..." -ForegroundColor Gray
            try { docker service update --image "${webImageName}:$newTag" "${stackName}_web" 2>$null | Out-Null } catch {}

            Update-EnvValue -EnvFile ".env" -Key "WEB_IMAGE_VERSION" -Value $newTag | Out-Null

            Write-Host "" 
            Write-Host ("[OK] Update initiated. Monitor with: docker stack services {0}" -f $stackName) -ForegroundColor Green
        }
        Default { return }
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
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }

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

function Convert-RenderedStackToNoProxy {
    <#
    .SYNOPSIS
    Converts a rendered stack YAML to a no-proxy variant.

    .DESCRIPTION
    Removes Traefik network + labels and exposes direct ports for web + phpMyAdmin.

    .PARAMETER StackFile
    Path to the rendered stack YAML (usually .stack-deploy-temp.yml).

    .OUTPUTS
    System.Boolean
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StackFile
    )

    if (-not (Test-Path $StackFile)) {
        Write-Host "[ERROR] Rendered stack file not found: $StackFile" -ForegroundColor Red
        return $false
    }

    $webPort = $env:WEB_PORT
    if ([string]::IsNullOrWhiteSpace($webPort)) { $webPort = "8080" }

    $pmaPort = $env:PHPMYADMIN_PORT
    if ([string]::IsNullOrWhiteSpace($pmaPort)) { $pmaPort = "8081" }

    $lines = Get-Content $StackFile -ErrorAction SilentlyContinue

    $out = New-Object System.Collections.Generic.List[string]

    $section = ""
    $currentService = ""
    $webHasPorts = $false
    $pmaHasPorts = $false

    $inNetworksSection = $false
    $skipTraefikNetworkBlock = $false
    $skipTraefikNetworkIndent = 0

    $inLabelsBlock = $false
    $labelsIndent = 0
    $labelsBuffer = New-Object System.Collections.Generic.List[string]

    $getIndentLength = {
        param([string]$Line)
        $m = [regex]::Match($Line, '^(\s*)')
        return $m.Groups[1].Value.Length
    }

    $flushLabelsBuffer = {
        param([System.Collections.Generic.List[string]]$Output)

        if (-not $inLabelsBlock) { return }

        $kept = @()
        foreach ($l in $labelsBuffer) {
            if ($l -match '^\s*-\s*traefik\.'){ continue }
            $kept += $l
        }

        if ($kept.Count -gt 0) {
            $indentSpaces = ' ' * $labelsIndent
            $Output.Add("${indentSpaces}labels:")
            foreach ($l in $kept) { $Output.Add($l) }
        }

        $labelsBuffer.Clear()
        $inLabelsBlock = $false
        $labelsIndent = 0
    }

    $addPortsIfMissing = {
        param([System.Collections.Generic.List[string]]$Output)
        if ($section -ne "services") { return }

        if ($currentService -eq "web" -and -not $webHasPorts) {
            $Output.Add("    ports:")
            $Output.Add('      - "' + $webPort + ':80"')
            $webHasPorts = $true
        }
        if ($currentService -eq "phpmyadmin" -and -not $pmaHasPorts) {
            $Output.Add("    ports:")
            $Output.Add('      - "' + $pmaPort + ':80"')
            $pmaHasPorts = $true
        }
    }

    foreach ($line in $lines) {
        $indent = & $getIndentLength $line

        if ($skipTraefikNetworkBlock) {
            if ($indent -le $skipTraefikNetworkIndent -and $line -match '^\s*\S') {
                $skipTraefikNetworkBlock = $false
            } else {
                continue
            }
        }

        if ($inLabelsBlock) {
            if ($indent -le $labelsIndent -and $line -match '^\s*\S') {
                & $flushLabelsBuffer $out
            } else {
                $labelsBuffer.Add($line)
                continue
            }
        }

        if ($line -match '^services:\s*$') {
            $section = "services"
            $currentService = ""
            $out.Add($line)
            continue
        }

        if ($line -match '^networks:\s*$') {
            & $addPortsIfMissing $out
            $section = "networks"
            $currentService = ""
            $inNetworksSection = $true
            $out.Add($line)
            continue
        }

        if ($line -match '^secrets:\s*$') {
            & $addPortsIfMissing $out
            $section = "secrets"
            $currentService = ""
            $inNetworksSection = $false
            $out.Add($line)
            continue
        }

        if ($inNetworksSection -and $line -match '^\s{2}traefik:\s*$') {
            $skipTraefikNetworkBlock = $true
            $skipTraefikNetworkIndent = $indent
            continue
        }

        if ($line -match '^\s*-\s*traefik\s*$') { continue }

        if ($section -eq "services" -and $line -match '^\s{2}([A-Za-z0-9_.-]+):\s*$') {
            & $addPortsIfMissing $out

            $currentService = $matches[1]
            $webHasPorts = $false
            $pmaHasPorts = $false
            $out.Add($line)
            continue
        }

        if ($section -eq "services" -and $currentService -eq "web" -and $line -match '^\s{4}ports:\s*$') {
            $webHasPorts = $true
        }
        if ($section -eq "services" -and $currentService -eq "phpmyadmin" -and $line -match '^\s{4}ports:\s*$') {
            $pmaHasPorts = $true
        }

        if ($section -eq "services" -and ($currentService -eq "web" -or $currentService -eq "phpmyadmin") -and -not ($currentService -eq "web" -and $webHasPorts) -and -not ($currentService -eq "phpmyadmin" -and $pmaHasPorts) -and $line -match '^\s{4}deploy:\s*$') {
            & $addPortsIfMissing $out
        }

        if ($section -eq "services" -and $line -match '^\s{6}labels:\s*$') {
            $inLabelsBlock = $true
            $labelsIndent = $indent
            $labelsBuffer.Clear()
            continue
        }

        $out.Add($line)
    }

    if ($inLabelsBlock) {
        & $flushLabelsBuffer $out
    }

    & $addPortsIfMissing $out

    try {
        $out | Set-Content -Path $StackFile -Encoding utf8
        return $true
    } catch {
        Write-Host "[ERROR] Failed to write transformed stack file: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
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

function Invoke-StackDeploy {
    <#
    .SYNOPSIS
    Deploys the stack using config-stack.yml with env-variable substitution.
    #>
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }
    
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

    $stackFile = "config-stack.yml"
    $envFile = ".env"
    $tempConfig = ".stack-deploy-temp.yml"

    $renderExit = 1
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        $composeSupportsEnvFile = $false
        try {
            $helpText = docker-compose --help 2>$null
            if ($helpText -match '--env-file') { $composeSupportsEnvFile = $true }
        } catch {
        }

        if ((Test-Path $envFile) -and $composeSupportsEnvFile) {
            docker-compose -f $stackFile --env-file $envFile config | Out-File -FilePath $tempConfig -Encoding utf8
        } else {
            docker-compose -f $stackFile config | Out-File -FilePath $tempConfig -Encoding utf8
        }
        $renderExit = $LASTEXITCODE
    } else {
        docker compose version 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[WARN] Neither docker-compose nor 'docker compose' is available. Deploying raw stack file (env substitution may be incomplete)." -ForegroundColor Yellow
            docker stack deploy -c $stackFile $stackName
            return
        }

        if (Test-Path $envFile) {
            docker compose -f $stackFile --env-file $envFile config | Out-File -FilePath $tempConfig -Encoding utf8
        } else {
            docker compose -f $stackFile config | Out-File -FilePath $tempConfig -Encoding utf8
        }
        $renderExit = $LASTEXITCODE
    }

    if ($renderExit -ne 0) {
        Write-Host "[ERROR] Failed to render config-stack.yml via docker-compose" -ForegroundColor Red
        Remove-Item $tempConfig -ErrorAction SilentlyContinue
        return
    }

    $proxyType = if ($config["PROXY_TYPE"]) { $config["PROXY_TYPE"] } else { "traefik" }
    if ($proxyType -eq "none") {
        Write-Host "[INFO] PROXY_TYPE=none: deploying without Traefik (direct ports)" -ForegroundColor Gray
        if (-not (Convert-RenderedStackToNoProxy -StackFile $tempConfig)) {
            Remove-Item $tempConfig -ErrorAction SilentlyContinue
            return
        }
    }

    docker stack deploy -c $tempConfig $stackName
    Remove-Item $tempConfig -ErrorAction SilentlyContinue
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "[OK] Stack deployed: $stackName" -ForegroundColor Green
        Write-Host ""
        Write-Host "Stack services:" -ForegroundColor Cyan
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
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }
    
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
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }
    
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
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }
    
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
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }

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
    
    if (-not (Test-SecretExists -SecretName "STATECHECKER_SERVER_AUTHENTICATION_TOKEN")) {
        $createAuth = Read-Host "Create STATECHECKER_SERVER_AUTHENTICATION_TOKEN? (Y/n)"
        if ($createAuth -ne "n" -and $createAuth -ne "N") {
            New-DockerSecret -SecretName "STATECHECKER_SERVER_AUTHENTICATION_TOKEN" -Description "API authentication token"
        }
    }
    
    if (-not (Test-SecretExists -SecretName "STATECHECKER_SERVER_DB_ROOT_USER_PW")) {
        $createRoot = Read-Host "Create STATECHECKER_SERVER_DB_ROOT_USER_PW? (Y/n)"
        if ($createRoot -ne "n" -and $createRoot -ne "N") {
            New-DockerSecret -SecretName "STATECHECKER_SERVER_DB_ROOT_USER_PW" -Description "MySQL root password"
        }
    }
    
    if (-not (Test-SecretExists -SecretName "STATECHECKER_SERVER_DB_USER_PW")) {
        $createUser = Read-Host "Create STATECHECKER_SERVER_DB_USER_PW? (Y/n)"
        if ($createUser -ne "n" -and $createUser -ne "N") {
            New-DockerSecret -SecretName "STATECHECKER_SERVER_DB_USER_PW" -Description "MySQL user password"
        }
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
    
    $createTelegram = Read-Host "Create Telegram bot token secret? (y/N)"
    if ($createTelegram -match "^[Yy]$") {
        New-DockerSecret -SecretName "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN" -Description "Telegram bot token"
    }
    
    $createEmail = Read-Host "Create Email password secret? (y/N)"
    if ($createEmail -match "^[Yy]$") {
        New-DockerSecret -SecretName "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD" -Description "Email SMTP password"
    }
}

function Show-MainMenu {
    <#
    .SYNOPSIS
    Main interactive menu loop.
    #>
    while ($true) {
        $menuNext = 1
        $MENU_DEPLOY = $menuNext; $menuNext++
        $MENU_REMOVE = $menuNext; $menuNext++
        $MENU_STATUS = $menuNext; $menuNext++
        $MENU_HEALTH = $menuNext; $menuNext++
        $MENU_LOGS = $menuNext; $menuNext++

        $MENU_UPDATE_IMAGE = $menuNext; $menuNext++
        $MENU_SCALE = $menuNext; $menuNext++

        $MENU_SECRETS_CHECK = $menuNext; $menuNext++
        $MENU_SECRETS_CREATE_REQUIRED = $menuNext; $menuNext++
        $MENU_SECRETS_FROM_FILE = $menuNext; $menuNext++
        $MENU_SECRETS_CREATE_OPTIONAL = $menuNext; $menuNext++
        $MENU_SECRETS_LIST = $menuNext; $menuNext++

        $MENU_TOGGLE_PHPMYADMIN = $menuNext; $menuNext++

        $MENU_CICD = $menuNext; $menuNext++

        $MENU_EXIT = $menuNext

        Write-Host "" 
        Write-Host "================ Main Menu ================" -ForegroundColor Yellow
        Write-Host "" 
        Write-Host "Deployment:" -ForegroundColor Yellow
        Write-Host "  $MENU_DEPLOY) Deploy stack" -ForegroundColor Gray
        Write-Host "  $MENU_REMOVE) Remove stack" -ForegroundColor Gray
        Write-Host "  $MENU_STATUS) Show stack status" -ForegroundColor Gray
        Write-Host "  $MENU_HEALTH) Health check" -ForegroundColor Gray
        Write-Host "  $MENU_LOGS) View service logs" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "Management:" -ForegroundColor Yellow
        Write-Host "  $MENU_UPDATE_IMAGE) Update image version" -ForegroundColor Gray
        Write-Host "  $MENU_SCALE) Scale services" -ForegroundColor Gray
        Write-Host "  $MENU_TOGGLE_PHPMYADMIN) Toggle phpMyAdmin (enable/disable)" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "Secrets:" -ForegroundColor Yellow
        Write-Host "  $MENU_SECRETS_CHECK) Check required secrets" -ForegroundColor Gray
        Write-Host "  $MENU_SECRETS_CREATE_REQUIRED) Create required secrets" -ForegroundColor Gray
        Write-Host "  $MENU_SECRETS_FROM_FILE) Create secrets from secrets.env file" -ForegroundColor Gray
        Write-Host "  $MENU_SECRETS_CREATE_OPTIONAL) Create optional secrets (Telegram, Email)" -ForegroundColor Gray
        Write-Host "  $MENU_SECRETS_LIST) List all secrets" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "CI/CD:" -ForegroundColor Yellow
        Write-Host "  $MENU_CICD) GitHub Actions CI/CD helper" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "  $MENU_EXIT) Exit" -ForegroundColor Gray
        Write-Host "" 

        $choice = Read-Host "Your choice (1-$MENU_EXIT)"

        switch ($choice) {
            "$MENU_DEPLOY" { Invoke-StackDeploy }
            "$MENU_REMOVE" { Remove-Stack }
            "$MENU_STATUS" { Show-StackStatus }
            "$MENU_HEALTH" {
                $config = Get-EnvConfig
                Set-ProcessEnvFromConfig -Config $config
                $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }
                $proxyType = if ($config["PROXY_TYPE"]) { $config["PROXY_TYPE"] } else { "traefik" }
                Test-DeploymentHealth -StackName $stackName -ProxyType $proxyType -WaitSeconds 10 | Out-Null
            }
            "$MENU_LOGS" { Show-ServiceLogs }
            "$MENU_UPDATE_IMAGE" { Update-StackImages }
            "$MENU_SCALE" { Set-ServiceScale }
            "$MENU_SECRETS_CHECK" { Test-RequiredSecrets; Test-OptionalSecrets }
            "$MENU_SECRETS_CREATE_REQUIRED" { New-RequiredSecretsMenu }
            "$MENU_SECRETS_FROM_FILE" { New-SecretsFromFile -SecretsFile "secrets.env" -TemplateFile "setup\secrets.env.template" | Out-Null }
            "$MENU_SECRETS_CREATE_OPTIONAL" { New-OptionalSecretsMenu }
            "$MENU_SECRETS_LIST" { Get-SecretList }
            "$MENU_TOGGLE_PHPMYADMIN" { Invoke-PhpMyAdminToggle }
            "$MENU_CICD" { Invoke-GitHubCICDHelper }
            "$MENU_EXIT" { Write-Host "Goodbye!" -ForegroundColor Cyan; exit 0 }
            Default { Write-Host "[ERROR] Invalid selection" -ForegroundColor Yellow }
        }
    }
}

try {
    if ($null -ne $ExecutionContext.SessionState.Module) {
        Export-ModuleMember -Function Get-EnvConfig, Update-EnvValue, Set-ProcessEnvFromConfig, Invoke-StackDeploy, Remove-Stack, Show-StackStatus, Show-ServiceLogs, Invoke-PhpMyAdminToggle, New-RequiredSecretsMenu, New-OptionalSecretsMenu, Update-StackImages, Set-ServiceScale, Show-MainMenu
    }
} catch {
}
