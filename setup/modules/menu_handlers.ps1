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

function Deploy-Stack {
    <#
    .SYNOPSIS
    Deploys the stack using config-stack.yml with env-variable substitution.
    #>
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }
    
    Write-Host "[DEPLOY] Deploying stack: $stackName" -ForegroundColor Cyan
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
    Write-Host "3) db" -ForegroundColor Gray
    Write-Host "4) All services" -ForegroundColor Gray
    Write-Host ""
    
    $logChoice = Read-Host "Select (1-4)"
    
    switch ($logChoice) {
        "1" {
            docker service logs "${stackName}_api" -f
        }
        "2" {
            docker service logs "${stackName}_check" -f
        }
        "3" {
            docker service logs "${stackName}_db" -f
        }
        "4" {
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

function Toggle-PhpMyAdmin {
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

        if ($url) {
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
        $MENU_LOGS = $menuNext; $menuNext++

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
        Write-Host "  $MENU_LOGS) View service logs" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "Secrets:" -ForegroundColor Yellow
        Write-Host "  $MENU_SECRETS_CHECK) Check required secrets" -ForegroundColor Gray
        Write-Host "  $MENU_SECRETS_CREATE_REQUIRED) Create required secrets" -ForegroundColor Gray
        Write-Host "  $MENU_SECRETS_FROM_FILE) Create secrets from secrets.env file" -ForegroundColor Gray
        Write-Host "  $MENU_SECRETS_CREATE_OPTIONAL) Create optional secrets (Telegram, Email)" -ForegroundColor Gray
        Write-Host "  $MENU_SECRETS_LIST) List all secrets" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "Management:" -ForegroundColor Yellow
        Write-Host "  $MENU_TOGGLE_PHPMYADMIN) Toggle phpMyAdmin (enable/disable)" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "CI/CD:" -ForegroundColor Yellow
        Write-Host "  $MENU_CICD) GitHub Actions CI/CD helper" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "  $MENU_EXIT) Exit" -ForegroundColor Gray
        Write-Host "" 

        $choice = Read-Host "Your choice (1-$MENU_EXIT)"

        switch ($choice) {
            "$MENU_DEPLOY" { Deploy-Stack }
            "$MENU_REMOVE" { Remove-Stack }
            "$MENU_STATUS" { Show-StackStatus }
            "$MENU_LOGS" { Show-ServiceLogs }
            "$MENU_SECRETS_CHECK" { Test-RequiredSecrets; Test-OptionalSecrets }
            "$MENU_SECRETS_CREATE_REQUIRED" { New-RequiredSecretsMenu }
            "$MENU_SECRETS_FROM_FILE" { New-SecretsFromFile -SecretsFile "secrets.env" -TemplateFile "setup\secrets.env.template" | Out-Null }
            "$MENU_SECRETS_CREATE_OPTIONAL" { New-OptionalSecretsMenu }
            "$MENU_SECRETS_LIST" { Get-SecretList }
            "$MENU_TOGGLE_PHPMYADMIN" { Toggle-PhpMyAdmin }
            "$MENU_CICD" { Invoke-GitHubCICDHelper }
            "$MENU_EXIT" { Write-Host "Goodbye!" -ForegroundColor Cyan; exit 0 }
            Default { Write-Host "[ERROR] Invalid selection" -ForegroundColor Yellow }
        }
    }
}

Export-ModuleMember -Function Get-EnvConfig, Update-EnvValue, Set-ProcessEnvFromConfig, Deploy-Stack, Remove-Stack, Show-StackStatus, Show-ServiceLogs, Toggle-PhpMyAdmin, New-RequiredSecretsMenu, New-OptionalSecretsMenu, Show-MainMenu
