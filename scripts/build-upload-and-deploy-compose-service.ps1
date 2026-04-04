[CmdletBinding(DefaultParameterSetName = "Deploy")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Deploy")]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true, ParameterSetName = "Init")]
    [string]$InitConfigPath,

    [Parameter(ParameterSetName = "Deploy")]
    [string]$Password,

    [Parameter(ParameterSetName = "Deploy")]
    [switch]$SkipBuild,

    [Parameter(ParameterSetName = "Deploy")]
    [switch]$ReuseArtifact,

    [Parameter(ParameterSetName = "Deploy")]
    [switch]$AcceptKey = $true
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[remote-compose-deploy] $Message"
}

function Get-ScriptRootPath {
    $PSScriptRoot
}

function Copy-TemplateConfig {
    param([string]$DestinationPath)

    $scriptRoot = Get-ScriptRootPath
    $templatePath = Join-Path (Split-Path -Parent $scriptRoot) "assets\deploy-config.template.json"
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Template config not found: $templatePath"
    }

    $resolvedDestination = [System.IO.Path]::GetFullPath($DestinationPath)
    $destinationDir = Split-Path -Parent $resolvedDestination
    if ($destinationDir -and -not (Test-Path -LiteralPath $destinationDir)) {
        New-Item -ItemType Directory -Path $destinationDir | Out-Null
    }

    if (Test-Path -LiteralPath $resolvedDestination) {
        Write-Step "Config file already exists at $resolvedDestination. Skipping initialization to prevent overwrite."
        return
    }

    Copy-Item -LiteralPath $templatePath -Destination $resolvedDestination
    Write-Step "Wrote starter config to $resolvedDestination"
}

function Ensure-PoshSsh {
    if (Get-Module -ListAvailable -Name Posh-SSH) {
        Import-Module Posh-SSH
        return
    }

    Write-Step "Installing Posh-SSH for current user"
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber | Out-Null
    Import-Module Posh-SSH
}

function Get-AbsolutePath {
    param(
        [string]$BaseDir,
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $PathValue))
}

function Get-PositiveIntSetting {
    param(
        $Value,
        [int]$DefaultValue
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) {
        return $DefaultValue
    }

    $parsedValue = 0
    if (-not [int]::TryParse("$Value", [ref]$parsedValue) -or $parsedValue -le 0) {
        return $DefaultValue
    }

    return $parsedValue
}

function Get-LatestWriteTime {
    param([string[]]$Paths)

    $latestWriteTime = $null
    foreach ($path in $Paths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            $candidate = (Get-Item -LiteralPath $path).LastWriteTime
            if ($null -eq $latestWriteTime -or $candidate -gt $latestWriteTime) {
                $latestWriteTime = $candidate
            }
        }
    }

    return $latestWriteTime
}

function Get-BuildLogTail {
    param(
        [string]$StdoutLogPath,
        [string]$StderrLogPath,
        [int]$TailLines
    )

    $sections = @()
    foreach ($entry in @(
        @{ Label = "stdout"; Path = $StdoutLogPath },
        @{ Label = "stderr"; Path = $StderrLogPath }
    )) {
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            continue
        }

        $lines = @(Get-Content -LiteralPath $entry.Path -Tail $TailLines -ErrorAction SilentlyContinue)
        if ($lines.Count -eq 0) {
            continue
        }

        $sections += "[build $($entry.Label)]"
        $sections += $lines
    }

    return $sections -join [Environment]::NewLine
}

function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }

    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Resolve-LocalArtifactPath {
    param(
        $Config,
        [string]$ConfigDir
    )

    if ([string]::IsNullOrWhiteSpace($Config.artifact.localPath)) {
        throw "artifact.localPath is required"
    }

    if ([System.IO.Path]::IsPathRooted($Config.artifact.localPath)) {
        return [System.IO.Path]::GetFullPath($Config.artifact.localPath)
    }

    if ($null -eq $Config.build -or [string]::IsNullOrWhiteSpace($Config.build.workdir)) {
        throw "artifact.localPath is relative, so build.workdir must be provided. Use an absolute artifact path or set build.workdir."
    }

    $artifactBaseDir = Get-AbsolutePath -BaseDir $ConfigDir -PathValue $Config.build.workdir
    return Get-AbsolutePath -BaseDir $artifactBaseDir -PathValue $Config.artifact.localPath
}

function Invoke-LocalBuild {
    param(
        $BuildConfig,
        [string]$BaseDir
    )

    if (-not $BuildConfig.enabled) {
        Write-Step "Build step disabled in config"
        return
    }

    $buildWorkdir = Get-AbsolutePath -BaseDir $BaseDir -PathValue $BuildConfig.workdir
    if (-not (Test-Path -LiteralPath $buildWorkdir)) {
        throw "Build workdir does not exist: $buildWorkdir"
    }

    $timeoutSec = Get-PositiveIntSetting -Value $BuildConfig.timeoutSec -DefaultValue 3600
    $idleTimeoutSec = Get-PositiveIntSetting -Value $BuildConfig.idleTimeoutSec -DefaultValue 300
    $heartbeatSec = Get-PositiveIntSetting -Value $BuildConfig.heartbeatSec -DefaultValue 20
    $logTailLines = Get-PositiveIntSetting -Value $BuildConfig.logTailLines -DefaultValue 20

    $logDir = Join-Path $buildWorkdir ".tmp\remote-compose-deploy"
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $stdoutLogPath = Join-Path $logDir "build-$timestamp.stdout.log"
    $stderrLogPath = Join-Path $logDir "build-$timestamp.stderr.log"

    Write-Step "Running local build in $buildWorkdir"
    Write-Step "Build log files: $stdoutLogPath , $stderrLogPath"

    $process = Start-Process -FilePath "cmd.exe" `
        -ArgumentList @("/d", "/c", $BuildConfig.command) `
        -WorkingDirectory $buildWorkdir `
        -RedirectStandardOutput $stdoutLogPath `
        -RedirectStandardError $stderrLogPath `
        -PassThru `
        -NoNewWindow

    $buildStartTime = Get-Date
    $lastHeartbeatTime = $buildStartTime.AddSeconds(-$heartbeatSec)
    $lastOutputTime = $buildStartTime

    try {
        while (-not $process.HasExited) {
            Start-Sleep -Seconds 2
            $process.Refresh()

            $now = Get-Date
            $latestWriteTime = Get-LatestWriteTime -Paths @($stdoutLogPath, $stderrLogPath)
            if ($null -ne $latestWriteTime -and $latestWriteTime -gt $lastOutputTime) {
                $lastOutputTime = $latestWriteTime
            }

            if (($now - $buildStartTime).TotalSeconds -ge $timeoutSec) {
                Stop-ProcessTree -Process $process
                $recentLogs = Get-BuildLogTail -StdoutLogPath $stdoutLogPath -StderrLogPath $stderrLogPath -TailLines $logTailLines
                throw "Build timed out after $timeoutSec seconds.`n$recentLogs"
            }

            if (($now - $lastOutputTime).TotalSeconds -ge $idleTimeoutSec) {
                Stop-ProcessTree -Process $process
                $recentLogs = Get-BuildLogTail -StdoutLogPath $stdoutLogPath -StderrLogPath $stderrLogPath -TailLines $logTailLines
                throw "Build produced no new output for $idleTimeoutSec seconds.`n$recentLogs"
            }

            if (($now - $lastHeartbeatTime).TotalSeconds -ge $heartbeatSec) {
                Write-Step "Build still running after $([int]($now - $buildStartTime).TotalSeconds) seconds"
                $recentLogs = Get-BuildLogTail -StdoutLogPath $stdoutLogPath -StderrLogPath $stderrLogPath -TailLines $logTailLines
                if (-not [string]::IsNullOrWhiteSpace($recentLogs)) {
                    Write-Host $recentLogs
                }
                $lastHeartbeatTime = $now
            }
        }
    }
    finally {
        $process.Refresh()
    }

    if ($process.ExitCode -ne 0) {
        $recentLogs = Get-BuildLogTail -StdoutLogPath $stdoutLogPath -StderrLogPath $stderrLogPath -TailLines $logTailLines
        throw "Build command failed with exit code $($process.ExitCode).`n$recentLogs"
    }

    Write-Step "Build completed successfully"
}

function Quote-BashArg {
    param([string]$Value)
    $escapedSingleQuote = "'" + '"' + "'" + '"' + "'"
    "'" + $Value.Replace("'", $escapedSingleQuote) + "'"
}

function New-BashCommand {
    param([string]$CommandText)
    "bash -lc " + (Quote-BashArg $CommandText)
}

function Get-UsefulRemoteLines {
    param([string]$Output)

    @(
        $Output -split "`r?`n" |
        ForEach-Object { [regex]::Replace($_, "\x1b\[[0-9;]*[A-Za-z]", "").Trim() } |
        Where-Object {
            $_ -and
            $_ -notmatch 'Executing external compose provider' -and
            $_ -notmatch '^>>>>' -and
            $_ -ne [char]0
        }
    )
}

function Invoke-Remote {
    param(
        [int]$SessionId,
        [string]$Command
    )

    $result = Invoke-SSHCommand -SessionId $SessionId -Command $Command
    $output = ""
    if ($null -ne $result.Output) {
        $output = ($result.Output -join [Environment]::NewLine).Trim()
    }

    [pscustomobject]@{
        ExitStatus = $result.ExitStatus
        Output = $output
    }
}

function Resolve-ComposeCommand {
    param(
        [int]$SessionId,
        [string]$ComposeWorkdir,
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        $quotedDir = Quote-BashArg $ComposeWorkdir
        $remoteCommand = New-BashCommand "cd $quotedDir && $candidate version >/dev/null 2>&1"
        $result = Invoke-Remote -SessionId $SessionId -Command $remoteCommand
        if ($result.ExitStatus -eq 0) {
            return $candidate
        }
    }

    throw "No compose command worked on the remote host. Checked: $($Candidates -join ', ')"
}

function Get-RemoteCredential {
    param(
        $RemoteConfig,
        [string]$PasswordOverride
    )

    $resolvedPassword = $PasswordOverride

    if ([string]::IsNullOrWhiteSpace($resolvedPassword) -and -not [string]::IsNullOrWhiteSpace($RemoteConfig.passwordEnvVar)) {
        $resolvedPassword = [Environment]::GetEnvironmentVariable($RemoteConfig.passwordEnvVar)
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPassword) -and -not [string]::IsNullOrWhiteSpace($RemoteConfig.password)) {
        $resolvedPassword = $RemoteConfig.password
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPassword)) {
        throw "No remote password available. Pass -Password, set remote.passwordEnvVar, or fill remote.password in config."
    }

    $securePassword = ConvertTo-SecureString $resolvedPassword -AsPlainText -Force
    return [System.Management.Automation.PSCredential]::new($RemoteConfig.username, $securePassword)
}

function Get-RemoteKeyString {
    param($RemoteConfig)

    if ([string]::IsNullOrWhiteSpace($RemoteConfig.keyStringEnvVar)) {
        return $null
    }

    $keyString = [Environment]::GetEnvironmentVariable($RemoteConfig.keyStringEnvVar)
    if ([string]::IsNullOrWhiteSpace($keyString)) {
        return $null
    }

    return $keyString -split "`r?`n"
}

function Get-SshConnectionOptions {
    param(
        $RemoteConfig,
        [string]$PasswordOverride,
        [bool]$AcceptHostKey
    )

    $options = @{}

    if (-not [string]::IsNullOrWhiteSpace($RemoteConfig.keyFile)) {
        $options.KeyFile = $RemoteConfig.keyFile
        return $options
    }

    $keyString = Get-RemoteKeyString -RemoteConfig $RemoteConfig
    if ($null -ne $keyString) {
        $options.KeyString = $keyString
        return $options
    }

    $options.Credential = Get-RemoteCredential -RemoteConfig $RemoteConfig -PasswordOverride $PasswordOverride
    return $options
}

function Resolve-DeploymentMode {
    param($Config)

    $hasDeploymentMode = $null -ne $Config.deployment -and $null -ne $Config.deployment.PSObject.Properties["mode"]
    $deploymentMode = ""

    if ($hasDeploymentMode -and -not [string]::IsNullOrWhiteSpace($Config.deployment.mode)) {
        $deploymentMode = "$($Config.deployment.mode)".Trim().ToLowerInvariant()
    }
    elseif ($null -ne $Config.repoSync -and -not [string]::IsNullOrWhiteSpace($Config.repoSync.workdir) -and [string]::IsNullOrWhiteSpace($Config.artifact.localPath)) {
        $deploymentMode = "repo-sync"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Config.artifact.localPath) -or -not [string]::IsNullOrWhiteSpace($Config.artifact.remotePath)) {
        $deploymentMode = "artifact"
    }

    switch ($deploymentMode) {
        "artifact" { return "artifact" }
        "repo-sync" { return "repo-sync" }
        "" { throw "deployment.mode is required. Set it to 'artifact' for local build and upload or 'repo-sync' for remote git pull." }
        default { throw "Unsupported deployment.mode '$deploymentMode'. Use 'artifact' or 'repo-sync'." }
    }
}

function Resolve-RepoSyncConfig {
    param($RepoSyncConfig)

    if ($null -eq $RepoSyncConfig) {
        throw "repoSync configuration is required when deployment.mode is 'repo-sync'."
    }

    if ([string]::IsNullOrWhiteSpace($RepoSyncConfig.workdir)) {
        throw "repoSync.workdir is required when deployment.mode is 'repo-sync'."
    }

    $pullCommand = if ([string]::IsNullOrWhiteSpace($RepoSyncConfig.pullCommand)) {
        "git pull --ff-only"
    }
    else {
        "$($RepoSyncConfig.pullCommand)".Trim()
    }

    [pscustomobject]@{
        Workdir = "$($RepoSyncConfig.workdir)".Trim()
        PullCommand = $pullCommand
    }
}

function Get-ComposeServices {
    param($ComposeConfig)

    $services = @()
    if ($null -eq $ComposeConfig) {
        return $services
    }

    foreach ($service in @($ComposeConfig.services)) {
        $serviceName = "$service".Trim()
        if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
            $services += $serviceName
        }
    }

    return $services
}

function Resolve-ComposeTarget {
    param($ComposeConfig)

    if ($null -eq $ComposeConfig) {
        throw "compose configuration is required"
    }

    $services = @(Get-ComposeServices -ComposeConfig $ComposeConfig)
    $hasTargetScope = $null -ne $ComposeConfig.PSObject.Properties["targetScope"]
    $targetScope = ""

    if ($hasTargetScope -and -not [string]::IsNullOrWhiteSpace($ComposeConfig.targetScope)) {
        $targetScope = "$($ComposeConfig.targetScope)".Trim().ToLowerInvariant()
    }
    elseif ($services.Count -gt 0) {
        $targetScope = "services"
    }

    switch ($targetScope) {
        "project" {
            return [pscustomobject]@{
                Scope = "project"
                Services = @()
            }
        }
        "services" {
            if ($services.Count -eq 0) {
                throw "compose.targetScope is 'services', but compose.services is empty. Set the exact service names to deploy."
            }

            return [pscustomobject]@{
                Scope = "services"
                Services = $services
            }
        }
        "" {
            throw "compose.targetScope is required when compose.services is empty. Set it to 'project' for the whole compose project or 'services' for specific services."
        }
        default {
            throw "Unsupported compose.targetScope '$targetScope'. Use 'project' or 'services'."
        }
    }
}

function Validate-Services {
    param(
        [int]$SessionId,
        [string]$ComposeWorkdir,
        [string]$ComposeCommand,
        [string[]]$Services
    )

    if ($Services.Count -eq 0) {
        throw "compose.services must contain at least one service when compose.targetScope is 'services'."
    }

    $quotedDir = Quote-BashArg $ComposeWorkdir
    $result = Invoke-Remote -SessionId $SessionId -Command (New-BashCommand "cd $quotedDir && $ComposeCommand config --services 2>&1")
    if ($result.ExitStatus -ne 0) {
        throw "Failed to list remote services. Output:`n$($result.Output)"
    }

    $availableServices = @(Get-UsefulRemoteLines -Output $result.Output)

    foreach ($service in $Services) {
        if ($service -notin $availableServices) {
            throw "Service '$service' not found in remote compose config. Available: $($availableServices -join ', ')"
        }
    }
}

function Upload-Artifact {
    param(
        [string]$RemoteHost,
        [int]$Port,
        [hashtable]$ConnectionOptions,
        [string]$LocalArtifactPath,
        [string]$RemoteArtifactPath,
        [bool]$AcceptHostKey,
        [int]$SessionId
    )

    $remoteDir = $RemoteArtifactPath -replace '/[^/]+$',''
    if ([string]::IsNullOrWhiteSpace($remoteDir)) {
        throw "Remote artifact path must include a directory: $RemoteArtifactPath"
    }

    $quotedDir = Quote-BashArg $remoteDir
    $mkdirResult = Invoke-Remote -SessionId $SessionId -Command (New-BashCommand "mkdir -p $quotedDir")
    if ($mkdirResult.ExitStatus -ne 0) {
        throw "Failed to create remote directory '$remoteDir'. Output:`n$($mkdirResult.Output)"
    }

    $uploadParams = @{
        ComputerName = $RemoteHost
        Port = $Port
        Path = $LocalArtifactPath
        Destination = $remoteDir
        NewName = [System.IO.Path]::GetFileName($RemoteArtifactPath)
        OperationTimeout = 0
    }

    foreach ($key in $ConnectionOptions.Keys) {
        $uploadParams[$key] = $ConnectionOptions[$key]
    }

    if ($AcceptHostKey) {
        $uploadParams.AcceptKey = $true
    }

    Set-SCPItem @uploadParams | Out-Null
}

function Invoke-RepoSync {
    param(
        [int]$SessionId,
        $RepoSyncConfig
    )

    $quotedDir = Quote-BashArg $RepoSyncConfig.Workdir
    $result = Invoke-Remote -SessionId $SessionId -Command (New-BashCommand "cd $quotedDir && $($RepoSyncConfig.PullCommand) 2>&1")
    if ($result.ExitStatus -ne 0) {
        throw "Remote repo sync failed. Output:`n$($result.Output)"
    }

    return $result.Output
}

function Invoke-HealthCheck {
    param(
        [int]$SessionId,
        $HealthCheckConfig
    )

    if ($null -eq $HealthCheckConfig -or -not $HealthCheckConfig.enabled) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($HealthCheckConfig.remoteCommand)) {
        $result = Invoke-Remote -SessionId $SessionId -Command (New-BashCommand $HealthCheckConfig.remoteCommand)
        if ($result.ExitStatus -ne 0) {
            throw "Remote health check command failed. Output:`n$($result.Output)"
        }
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($HealthCheckConfig.url)) {
        $timeoutSec = if ($HealthCheckConfig.timeoutSec) { [int]$HealthCheckConfig.timeoutSec } else { 15 }
        try {
            $response = Invoke-WebRequest -Uri $HealthCheckConfig.url -UseBasicParsing -TimeoutSec $timeoutSec
        }
        catch {
            throw "HTTP health check failed for $($HealthCheckConfig.url): $($_.Exception.Message)"
        }

        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "HTTP health check returned unexpected status $($response.StatusCode) for $($HealthCheckConfig.url)"
        }
        return
    }

    throw "healthCheck.enabled is true, but neither healthCheck.remoteCommand nor healthCheck.url was provided."
}

if ($PSCmdlet.ParameterSetName -eq "Init") {
    Copy-TemplateConfig -DestinationPath $InitConfigPath
    exit 0
}

Ensure-PoshSsh

$resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Config file not found: $resolvedConfigPath"
}

$configDir = Split-Path -Parent $resolvedConfigPath
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$deploymentMode = Resolve-DeploymentMode -Config $config
$localArtifactPath = $null
$repoSyncConfig = $null

switch ($deploymentMode) {
    "artifact" {
        $localArtifactPath = Resolve-LocalArtifactPath -Config $config -ConfigDir $configDir
        $reuseExistingArtifact = $ReuseArtifact
        if ($null -ne $config.artifact -and $null -ne $config.artifact.PSObject.Properties["reuseLatestArtifact"]) {
            $reuseExistingArtifact = $reuseExistingArtifact -or [bool]$config.artifact.reuseLatestArtifact
        }

        if ($SkipBuild) {
            Write-Step "Skipping build because -SkipBuild was provided"
        }
        elseif ($reuseExistingArtifact -and (Test-Path -LiteralPath $localArtifactPath)) {
            Write-Step "Reusing existing local artifact at $localArtifactPath"
        }
        else {
            if ($reuseExistingArtifact) {
                Write-Step "Requested artifact reuse, but local artifact was not found yet. Running build."
            }
            Invoke-LocalBuild -BuildConfig $config.build -BaseDir $configDir
        }

        if (-not (Test-Path -LiteralPath $localArtifactPath)) {
            throw "Local artifact not found: $localArtifactPath"
        }
    }
    "repo-sync" {
        if ($SkipBuild) {
            Write-Step "Ignoring -SkipBuild because deployment.mode is 'repo-sync'"
        }

        $repoSyncConfig = Resolve-RepoSyncConfig -RepoSyncConfig $config.repoSync
    }
}

$remotePort = if ($config.remote.port) { [int]$config.remote.port } else { 22 }
$acceptHostKey = [bool]$AcceptKey
$connectionOptions = Get-SshConnectionOptions -RemoteConfig $config.remote -PasswordOverride $Password -AcceptHostKey $acceptHostKey

Write-Step "Connecting to $($config.remote.host)"
$sessionParams = @{
    ComputerName = $config.remote.host
    Port = $remotePort
}
foreach ($key in $connectionOptions.Keys) {
    $sessionParams[$key] = $connectionOptions[$key]
}
if ($acceptHostKey) {
    $sessionParams.AcceptKey = $true
}

$session = New-SSHSession @sessionParams
try {
    $composeCandidates = @($config.compose.commandCandidates)
    if ($composeCandidates.Count -eq 0) {
        $composeCandidates = @("docker compose", "podman compose", "docker-compose", "podman-compose")
    }

    $composeTarget = Resolve-ComposeTarget -ComposeConfig $config.compose

    $composeCommand = Resolve-ComposeCommand -SessionId $session.SessionId -ComposeWorkdir $config.compose.workdir -Candidates $composeCandidates
    Write-Step "Detected compose command: $composeCommand"

    if ($composeTarget.Scope -eq "services") {
        Validate-Services -SessionId $session.SessionId -ComposeWorkdir $config.compose.workdir -ComposeCommand $composeCommand -Services $composeTarget.Services
    }

    $repoSyncOutput = ""
    if ($deploymentMode -eq "artifact") {
        Write-Step "Uploading artifact to $($config.artifact.remotePath)"
        Upload-Artifact -RemoteHost $config.remote.host -Port $remotePort -ConnectionOptions $connectionOptions -LocalArtifactPath $localArtifactPath -RemoteArtifactPath $config.artifact.remotePath -AcceptHostKey $acceptHostKey -SessionId $session.SessionId
    }
    else {
        Write-Step "Running remote repo sync in $($repoSyncConfig.Workdir)"
        $repoSyncOutput = Invoke-RepoSync -SessionId $session.SessionId -RepoSyncConfig $repoSyncConfig
    }

    $quotedDir = Quote-BashArg $config.compose.workdir
    $serviceList = ($composeTarget.Services | ForEach-Object { Quote-BashArg $_ }) -join " "
    $composeAction = if ([string]::IsNullOrWhiteSpace($config.compose.action)) { "rebuild" } else { "$($config.compose.action)".ToLowerInvariant() }
    $composeTargetArgs = if ($composeTarget.Scope -eq "services") { " $serviceList" } else { "" }
    switch ($composeAction) {
        "rebuild" {
            $deployCommand = New-BashCommand "cd $quotedDir && $composeCommand up -d --build$composeTargetArgs 2>&1"
        }
        "restart" {
            $deployCommand = New-BashCommand "cd $quotedDir && $composeCommand restart$composeTargetArgs 2>&1"
        }
        default {
            throw "Unsupported compose.action '$composeAction'. Use 'rebuild' or 'restart'."
        }
    }

    $upResult = Invoke-Remote -SessionId $session.SessionId -Command $deployCommand
    if ($upResult.ExitStatus -ne 0) {
        throw "Remote compose $composeAction failed. Output:`n$($upResult.Output)"
    }

    $psResult = Invoke-Remote -SessionId $session.SessionId -Command (New-BashCommand "cd $quotedDir && $composeCommand ps$composeTargetArgs 2>&1")
    if ($psResult.ExitStatus -ne 0) {
        throw "Remote compose ps failed. Output:`n$($psResult.Output)"
    }

    Invoke-HealthCheck -SessionId $session.SessionId -HealthCheckConfig $config.healthCheck

    Write-Step "Deployment completed"
    Write-Host ""
    Write-Host "Deployment mode: $deploymentMode"
    Write-Host "Compose command: $composeCommand"
    Write-Host "Compose action: $composeAction"
    Write-Host "Target scope: $($composeTarget.Scope)"
    if ($deploymentMode -eq "artifact") {
        Write-Host "Artifact: $localArtifactPath -> $($config.artifact.remotePath)"
    }
    else {
        Write-Host "Repo sync workdir: $($repoSyncConfig.Workdir)"
        Write-Host "Repo sync command: $($repoSyncConfig.PullCommand)"
        if (-not [string]::IsNullOrWhiteSpace($repoSyncOutput)) {
            Write-Host "Repo sync output:"
            Write-Host ((Get-UsefulRemoteLines -Output $repoSyncOutput) -join [Environment]::NewLine)
        }
    }
    if ($composeTarget.Scope -eq "services") {
        Write-Host "Services: $($composeTarget.Services -join ', ')"
    }
    else {
        Write-Host "Services: entire compose project"
    }
    Write-Host ((Get-UsefulRemoteLines -Output $psResult.Output) -join [Environment]::NewLine)
}
finally {
    if ($null -ne $session) {
        Remove-SSHSession -SessionId $session.SessionId | Out-Null
    }
}
