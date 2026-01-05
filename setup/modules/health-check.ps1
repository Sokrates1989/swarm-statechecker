# health-check.ps1
# Deployment health check helpers for Swarm Statechecker.

function Get-StackServiceList {
    <#
    .SYNOPSIS
    Gets service names for a stack.

    .PARAMETER StackName
    Name of the stack.

    .OUTPUTS
    System.String[]
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StackName
    )

    $services = @()
    try {
        $services = docker service ls --filter "label=com.docker.stack.namespace=$StackName" --format "{{.Name}}" 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
    } catch {
        return @()
    }

    return @($services | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Show-RecentLogsAllServices {
    <#
    .SYNOPSIS
    Prints recent logs for all services in a stack.

    .PARAMETER StackName
    Name of the stack.

    .PARAMETER Since
    Docker logs since value (e.g. 10m).

    .PARAMETER Tail
    Number of lines to tail.

    .OUTPUTS
    System.Void
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StackName,
        [string]$Since = "10m",
        [int]$Tail = 200
    )

    $services = Get-StackServiceList -StackName $StackName
    if ($services.Count -eq 0) {
        Write-Host "[WARN] No services found for stack: $StackName" -ForegroundColor Yellow
        return
    }

    foreach ($svc in $services) {
        Write-Host "" 
        Write-Host "===== $svc =====" -ForegroundColor Cyan
        try {
            docker service logs --since $Since --tail $Tail $svc 2>$null
        } catch {
        }
    }
}

function Test-DeploymentHealth {
    <#
    .SYNOPSIS
    Runs a simple deployment health check for the stack.

    .PARAMETER StackName
    Name of the stack.

    .PARAMETER ProxyType
    Proxy type (traefik|none).

    .PARAMETER WaitSeconds
    Seconds to wait before checking.

    .PARAMETER LogsSince
    Docker logs since value (e.g. 10m).

    .PARAMETER LogsTail
    Number of lines to tail.

    .OUTPUTS
    System.Boolean
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StackName,
        [string]$ProxyType = "traefik",
        [int]$WaitSeconds = 0,
        [string]$LogsSince = "10m",
        [int]$LogsTail = 200
    )

    Write-Host "" 
    Write-Host "[HEALTH] Deployment Health Check" -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host "" 

    if ($WaitSeconds -gt 0) {
        Write-Host "[WAIT] Waiting ${WaitSeconds}s for services to initialize..." -ForegroundColor Gray
        Start-Sleep -Seconds $WaitSeconds
        Write-Host "" 
    }

    Write-Host "[STATUS] Stack services:" -ForegroundColor Cyan
    docker stack services $StackName 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Stack '$StackName' not found" -ForegroundColor Red
        return $false
    }

    Write-Host "" 
    Write-Host "[TASKS] Service tasks:" -ForegroundColor Cyan
    docker stack ps $StackName --format "table {{.Name}}\t{{.CurrentState}}\t{{.Error}}" 2>$null

    $failed = 0
    try {
        $states = docker stack ps $StackName --format "{{.CurrentState}}" 2>$null
        $failed = @($states | Where-Object { $_ -match 'Failed|Rejected' }).Count
    } catch {
        $failed = 0
    }

    if ($failed -gt 0) {
        Write-Host "" 
        Write-Host "[WARN] $failed task(s) have failed" -ForegroundColor Yellow
        Write-Host "       Check logs via the logs menu or: docker service logs ${StackName}_api" -ForegroundColor Yellow
    }

    Write-Host "" 
    Write-Host "[ENDPOINTS]" -ForegroundColor Cyan

    if ($ProxyType -eq "none") {
        $apiPort = if ($env:API_PORT) { $env:API_PORT } else { "8787" }
        $webPort = if ($env:WEB_PORT) { $env:WEB_PORT } else { "8080" }
        $pmaPort = if ($env:PHPMYADMIN_PORT) { $env:PHPMYADMIN_PORT } else { "8081" }
        $pmaReplicas = if ($env:PHPMYADMIN_REPLICAS) { $env:PHPMYADMIN_REPLICAS } else { "0" }

        Write-Host "API:  http://localhost:$apiPort" -ForegroundColor Gray
        Write-Host "WEB:  http://localhost:$webPort" -ForegroundColor Gray
        if ($pmaReplicas -ne "0") {
            Write-Host "PMA:  http://localhost:$pmaPort" -ForegroundColor Gray
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($env:API_URL)) { Write-Host "API:  https://$($env:API_URL)" -ForegroundColor Gray }
        if (-not [string]::IsNullOrWhiteSpace($env:WEB_URL)) { Write-Host "WEB:  https://$($env:WEB_URL)" -ForegroundColor Gray }

        $pmaReplicas = if ($env:PHPMYADMIN_REPLICAS) { $env:PHPMYADMIN_REPLICAS } else { "0" }
        if ($pmaReplicas -ne "0" -and -not [string]::IsNullOrWhiteSpace($env:PHPMYADMIN_URL)) {
            Write-Host "PMA:  https://$($env:PHPMYADMIN_URL)" -ForegroundColor Gray
        }
    }

    Write-Host "" 
    Write-Host "[LOGS] Recent logs (since=$LogsSince, tail=$LogsTail)" -ForegroundColor Cyan
    Show-RecentLogsAllServices -StackName $StackName -Since $LogsSince -Tail $LogsTail

    Write-Host "" 
    Write-Host "[OK] Health check complete" -ForegroundColor Green
    return $true
}

if ($null -ne $ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Get-StackServiceList, Show-RecentLogsAllServices, Test-DeploymentHealth
}
