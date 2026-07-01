$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$entrypoint = Join-Path $repoRoot 'entrypoint.ps1'

function Invoke-EntrypointDebug {
    param(
        [hashtable] $Environment
    )

    $assignments = @(
        '$ErrorActionPreference = "Stop"'
        'Get-ChildItem Env: | Where-Object { $_.Name -in @("ACCESS_TOKEN","APP_ID","APP_PRIVATE_KEY","APP_LOGIN","RUNNER_TOKEN","RUNNER_NAME","RUNNER_NAME_PREFIX","RANDOM_RUNNER_SUFFIX","RUNNER_SCOPE","ORG_NAME","ENTERPRISE_NAME","LABELS","RUNNER_LABELS","REPO_URL","RUNNER_WORKDIR","RUNNER_GROUP","GITHUB_HOST","GITHUB_API_HOST","GITHUB_API_PATH","DISABLE_AUTOMATIC_DEREGISTRATION","CONFIGURED_ACTIONS_RUNNER_FILES_DIR","EPHEMERAL","DISABLE_AUTO_UPDATE","NO_DEFAULT_LABELS","DEBUG_ONLY","DEBUG_OUTPUT","UNSET_CONFIG_VARS") } | ForEach-Object { Remove-Item "Env:\$($_.Name)" }'
    )

    foreach ($key in $Environment.Keys) {
        $value = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string] $Environment[$key])
        $assignments += "`$env:$key = '$value'"
    }

    $assignments += "& '$entrypoint'"
    $command = $assignments -join '; '

    $output = & pwsh -NoLogo -NoProfile -Command $command 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Entrypoint debug command failed with exit code $LASTEXITCODE.`n$output"
    }

    return $output -join "`n"
}

function Assert-Contains {
    param(
        [string] $Text,
        [string] $Expected
    )

    if (-not $Text.Contains($Expected)) {
        throw "Expected output to contain '$Expected'.`nActual output:`n$Text"
    }
}

function Assert-NotContains {
    param(
        [string] $Text,
        [string] $Unexpected
    )

    if ($Text.Contains($Unexpected)) {
        throw "Expected output not to contain '$Unexpected'.`nActual output:`n$Text"
    }
}

$scripts = @('entrypoint.ps1', 'install-choco.ps1', 'install-runner.ps1')
foreach ($script in $scripts) {
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content (Join-Path $repoRoot $script) -Raw), [ref] $errors) | Out-Null
    if ($errors) {
        throw "PowerShell parse errors in $script.`n$($errors | Out-String)"
    }
}

$repoOutput = Invoke-EntrypointDebug @{
    DEBUG_ONLY = 'true'
    RUNNER_SCOPE = 'repo'
    REPO_URL = 'https://github.com/example-owner/example-repo'
    RUNNER_TOKEN = 'example'
    DISABLE_AUTO_UPDATE = 'false'
}
Assert-Contains $repoOutput 'DEBUG_ONLY: .\config.cmd'
Assert-Contains $repoOutput '--url https://github.com/example-owner/example-repo'
Assert-Contains $repoOutput '--token example'
Assert-Contains $repoOutput 'GitHub API base URL: https://api.github.com'
Assert-NotContains $repoOutput '--disableupdate'

$gheOutput = Invoke-EntrypointDebug @{
    DEBUG_ONLY = 'true'
    RUNNER_SCOPE = 'org'
    ORG_NAME = 'example-org'
    RUNNER_TOKEN = 'example'
    GITHUB_HOST = 'github.example.com'
    GITHUB_API_HOST = 'api.github.example.com'
    GITHUB_API_PATH = '/api/v3'
}
Assert-Contains $gheOutput '--url https://github.example.com/example-org'
Assert-Contains $gheOutput 'GitHub API base URL: https://api.github.example.com/api/v3'

$ephemeralOutput = Invoke-EntrypointDebug @{
    DEBUG_ONLY = 'true'
    RUNNER_SCOPE = 'enterprise'
    ENTERPRISE_NAME = 'example-enterprise'
    RUNNER_TOKEN = 'example'
    EPHEMERAL = 'true'
    NO_DEFAULT_LABELS = 'true'
    DISABLE_AUTO_UPDATE = 'true'
}
Assert-Contains $ephemeralOutput '--url https://github.com/enterprises/example-enterprise'
Assert-Contains $ephemeralOutput '--ephemeral'
Assert-Contains $ephemeralOutput '--no-default-labels'
Assert-Contains $ephemeralOutput '--disableupdate'

Write-Output 'Entrypoint tests passed.'
