# menu_handlers.ps1
# PowerShell module for handling menu actions

function Get-EnvConfig {
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

function Deploy-Stack {
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }
    
    Write-Host "[DEPLOY] Deploying stack: $stackName" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-Path .env)) {
        Write-Host "[ERROR] .env file not found. Please create it first." -ForegroundColor Red
        return
    }
    
    docker stack deploy -c config-stack.yml $stackName
    
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
    $config = Get-EnvConfig
    $stackName = if ($config["STACK_NAME"]) { $config["STACK_NAME"] } else { "statechecker-server" }
    
    Write-Host "Which service logs do you want to view?" -ForegroundColor Yellow
    Write-Host "1) api" -ForegroundColor Gray
    Write-Host "2) check" -ForegroundColor Gray
    Write-Host "3) db" -ForegroundColor Gray
    Write-Host ""
    
    $logChoice = Read-Host "Select (1-3)"
    
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
        Default {
            Write-Host "[ERROR] Invalid selection" -ForegroundColor Yellow
        }
    }
}

function New-RequiredSecretsMenu {
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
    while ($true) {
        Write-Host ""
        Write-Host "Choose an option:" -ForegroundColor Yellow
        Write-Host "1) Deploy stack" -ForegroundColor Gray
        Write-Host "2) Remove stack" -ForegroundColor Gray
        Write-Host "3) Show stack status" -ForegroundColor Gray
        Write-Host "4) View service logs" -ForegroundColor Gray
        Write-Host "5) Check required secrets" -ForegroundColor Gray
        Write-Host "6) Create required secrets" -ForegroundColor Gray
        Write-Host "7) Create optional secrets (Telegram, Email)" -ForegroundColor Gray
        Write-Host "8) List all secrets" -ForegroundColor Gray
        Write-Host "9) Exit" -ForegroundColor Gray
        Write-Host ""
        
        $choice = Read-Host "Your choice (1-9)"
        
        switch ($choice) {
            "1" {
                Deploy-Stack
            }
            "2" {
                Remove-Stack
            }
            "3" {
                Show-StackStatus
            }
            "4" {
                Show-ServiceLogs
            }
            "5" {
                Test-RequiredSecrets
                Test-OptionalSecrets
            }
            "6" {
                New-RequiredSecretsMenu
            }
            "7" {
                New-OptionalSecretsMenu
            }
            "8" {
                Get-SecretList
            }
            "9" {
                Write-Host "Goodbye!" -ForegroundColor Cyan
                exit 0
            }
            Default {
                Write-Host "[ERROR] Invalid selection" -ForegroundColor Yellow
            }
        }
    }
}
