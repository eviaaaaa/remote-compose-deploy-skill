[CmdletBinding()]
param(
    [string]$Module,
    [string]$Env,
    [string]$ConfigPath,
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ConfigDir = "deploy-configs",
    [string]$Password,
    [switch]$ListConfigs,
    [switch]$Init,
    [switch]$SkipBuild,
    [switch]$ReuseArtifact,
    [switch]$AcceptKey = $true
)

$ErrorActionPreference = "Stop"

function Resolve-ProjectPath {
    param(
        [string]$BasePath,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return [System.IO.Path]::GetFullPath($BasePath)
    }

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        return [System.IO.Path]::GetFullPath($RelativePath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $RelativePath))
}

function Get-ResolvedConfigDir {
    Resolve-ProjectPath -BasePath $ProjectRoot -RelativePath $ConfigDir
}

function Get-ConfigFiles {
    param([string]$ResolvedConfigDir)

    if (-not (Test-Path -LiteralPath $ResolvedConfigDir)) {
        return @()
    }

    @(Get-ChildItem -LiteralPath $ResolvedConfigDir -Filter "*.json" -File | Sort-Object Name)
}

function Write-ConfigList {
    param([System.IO.FileInfo[]]$ConfigFiles)

    if ($ConfigFiles.Count -eq 0) {
        Write-Host "No deployment configs found."
        return
    }

    Write-Host "Available deployment configs:"
    foreach ($file in $ConfigFiles) {
        Write-Host " - $($file.Name)"
    }
}

function Resolve-SingleConfigOrNull {
    param([System.IO.FileInfo[]]$ConfigFiles)

    if ($ConfigFiles.Count -eq 1) {
        return $ConfigFiles[0].FullName
    }

    return $null
}

function Resolve-ConfigPathFromModuleEnv {
    param(
        [string]$ResolvedConfigDir,
        [string]$ModuleName,
        [string]$EnvironmentName
    )

    Join-Path $ResolvedConfigDir ("{0}-{1}.json" -f $ModuleName.Trim(), $EnvironmentName.Trim())
}

function Get-MatchingConfigFilesForModule {
    param(
        [string]$ResolvedConfigDir,
        [string]$ModuleName
    )

    if ([string]::IsNullOrWhiteSpace($ModuleName) -or -not (Test-Path -LiteralPath $ResolvedConfigDir)) {
        return @()
    }

    @(Get-ChildItem -LiteralPath $ResolvedConfigDir -Filter "$($ModuleName.Trim())-*.json" -File | Sort-Object Name)
}

function Get-EnvNameFromConfigFile {
    param(
        [string]$ModuleName,
        [System.IO.FileInfo]$ConfigFile
    )

    $prefix = "$($ModuleName.Trim())-"
    if (-not $ConfigFile.BaseName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $ConfigFile.BaseName.Substring($prefix.Length)
}

$resolvedConfigDir = Get-ResolvedConfigDir

if ($ListConfigs) {
    Write-ConfigList -ConfigFiles (Get-ConfigFiles -ResolvedConfigDir $resolvedConfigDir)
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    if ($Init -and ([string]::IsNullOrWhiteSpace($Module) -or [string]::IsNullOrWhiteSpace($Env))) {
        throw "Provide both -Module and -Env, or use -ConfigPath, when running with -Init."
    }

    if ([string]::IsNullOrWhiteSpace($Module)) {
        $configFiles = Get-ConfigFiles -ResolvedConfigDir $resolvedConfigDir
        $singleConfigPath = Resolve-SingleConfigOrNull -ConfigFiles $configFiles
        if (-not [string]::IsNullOrWhiteSpace($singleConfigPath)) {
            $ConfigPath = $singleConfigPath
        }
        else {
            Write-ConfigList -ConfigFiles $configFiles
            throw "Module is required. Provide -Module and -Env, or use -ConfigPath."
        }
    }

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        if ([string]::IsNullOrWhiteSpace($Env)) {
            $moduleConfigs = Get-MatchingConfigFilesForModule -ResolvedConfigDir $resolvedConfigDir -ModuleName $Module
            if ($moduleConfigs.Count -eq 1) {
                $ConfigPath = $moduleConfigs[0].FullName
            }
            elseif ($moduleConfigs.Count -gt 1) {
                Write-Host "Multiple environments found for module '$Module':"
                foreach ($configFile in $moduleConfigs) {
                    $envName = Get-EnvNameFromConfigFile -ModuleName $Module -ConfigFile $configFile
                    if ([string]::IsNullOrWhiteSpace($envName)) {
                        Write-Host " - $($configFile.Name)"
                    }
                    else {
                        Write-Host " - $envName ($($configFile.Name))"
                    }
                }
                throw "Environment is required when multiple configs exist for module '$Module'."
            }
            else {
                throw "No deployment config found for module '$Module'. Provide -Env and use -Init to create one."
            }
        }
        else {
            $ConfigPath = Resolve-ConfigPathFromModuleEnv -ResolvedConfigDir $resolvedConfigDir -ModuleName $Module -EnvironmentName $Env
        }
    }
}
else {
    $ConfigPath = Resolve-ProjectPath -BasePath $ProjectRoot -RelativePath $ConfigPath
}

$runnerScript = Join-Path $PSScriptRoot "build-upload-and-deploy-compose-service.ps1"
if (-not (Test-Path -LiteralPath $runnerScript)) {
    throw "Deploy runner script not found: $runnerScript"
}

if ($Init) {
    & $runnerScript -InitConfigPath $ConfigPath
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Deployment config not found: $ConfigPath. Re-run with -Init to create it."
}

$invokeParams = @{
    ConfigPath = $ConfigPath
    AcceptKey = [bool]$AcceptKey
}

if ($PSBoundParameters.ContainsKey("Password")) {
    $invokeParams.Password = $Password
}

if ($SkipBuild) {
    $invokeParams.SkipBuild = $true
}

if ($ReuseArtifact) {
    $invokeParams.ReuseArtifact = $true
}

& $runnerScript @invokeParams
exit $LASTEXITCODE
