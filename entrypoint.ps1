$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RunnerConfigured = $false
$script:RunnerRemoved = $false

function Test-Truthy {
    param([string] $Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value.ToLowerInvariant() -ne 'false'
}

function Normalize-Host {
    param([string] $HostName)

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return 'github.com'
    }

    return $HostName -replace '^https?://', '' -replace '/$', ''
}

function Normalize-ApiPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq '/') {
        return ''
    }

    $normalized = '/' + $Path.Trim('/')
    return $normalized
}

function Get-GitHubApiBaseUrl {
    param([string] $GitHubHost)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_API_HOST)) {
        $apiHost = Normalize-Host $env:GITHUB_API_HOST
        $apiPath = Normalize-ApiPath $(if ($env:GITHUB_API_PATH) { $env:GITHUB_API_PATH } else { '/api/v3' })
        return "https://$apiHost$apiPath"
    }

    if ($GitHubHost -eq 'github.com') {
        $apiPath = Normalize-ApiPath $(if ($env:GITHUB_API_PATH) { $env:GITHUB_API_PATH } else { '/' })
        return "https://api.github.com$apiPath"
    }

    $apiPath = Normalize-ApiPath $(if ($env:GITHUB_API_PATH) { $env:GITHUB_API_PATH } else { '/api/v3' })
    return "https://$GitHubHost$apiPath"
}

function Get-RandomSuffix {
    return ((New-Guid).Guid -replace '-', '').Substring(0, 13)
}

function Get-RunnerName {
    if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_NAME)) {
        return $env:RUNNER_NAME
    }

    $prefix = if ($null -ne $env:RUNNER_NAME_PREFIX) { $env:RUNNER_NAME_PREFIX } else { 'github-runner' }

    if ((Test-Truthy $env:RANDOM_RUNNER_SUFFIX) -or [string]::IsNullOrWhiteSpace($env:RANDOM_RUNNER_SUFFIX)) {
        return "$prefix-$(Get-RandomSuffix)"
    }

    $hostName = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return $hostName
    }

    return "$prefix-$hostName"
}

function Get-RunnerScope {
    $scope = if ([string]::IsNullOrWhiteSpace($env:RUNNER_SCOPE)) { 'repo' } else { $env:RUNNER_SCOPE.ToLowerInvariant() }

    if ($scope.StartsWith('org')) {
        return 'org'
    }

    if ($scope.StartsWith('ent')) {
        return 'enterprise'
    }

    return 'repo'
}

function Get-RepositoryParts {
    param([string] $RepoUrl)

    if ($RepoUrl -notmatch '^https://[^/]+/([^/]+)/([^/]+?)/?$') {
        throw "REPO_URL must look like https://github.com/owner/repo. Received: $RepoUrl"
    }

    return @{
        Owner = $Matches[1]
        Repo = $Matches[2]
    }
}

function Get-ScopeConfiguration {
    param(
        [string] $Scope,
        [string] $GitHubHost,
        [string] $ApiBaseUrl
    )

    switch ($Scope) {
        'org' {
            if ([string]::IsNullOrWhiteSpace($env:ORG_NAME)) {
                throw 'ORG_NAME is required when RUNNER_SCOPE is org.'
            }

            return @{
                ConfigUrl = "https://$GitHubHost/$env:ORG_NAME"
                TokenUrl = "$ApiBaseUrl/orgs/$env:ORG_NAME/actions/runners/registration-token"
                AppLogin = if ($env:APP_LOGIN) { $env:APP_LOGIN } else { $env:ORG_NAME }
            }
        }
        'enterprise' {
            if ([string]::IsNullOrWhiteSpace($env:ENTERPRISE_NAME)) {
                throw 'ENTERPRISE_NAME is required when RUNNER_SCOPE is enterprise.'
            }

            return @{
                ConfigUrl = "https://$GitHubHost/enterprises/$env:ENTERPRISE_NAME"
                TokenUrl = "$ApiBaseUrl/enterprises/$env:ENTERPRISE_NAME/actions/runners/registration-token"
                AppLogin = $env:APP_LOGIN
            }
        }
        default {
            if ([string]::IsNullOrWhiteSpace($env:REPO_URL)) {
                throw 'REPO_URL is required when RUNNER_SCOPE is repo.'
            }

            $repo = Get-RepositoryParts $env:REPO_URL
            return @{
                ConfigUrl = $env:REPO_URL.TrimEnd('/')
                TokenUrl = "$ApiBaseUrl/repos/$($repo.Owner)/$($repo.Repo)/actions/runners/registration-token"
                AppLogin = if ($env:APP_LOGIN) { $env:APP_LOGIN } else { $repo.Owner }
            }
        }
    }
}

function ConvertTo-Base64Url {
    param([byte[]] $Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-PemPrivateKey {
    param([string] $PrivateKey)

    $normalizedKey = $PrivateKey.Replace('\n', "`n")
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($normalizedKey)
    return $rsa
}

function New-GitHubAppJwt {
    param(
        [string] $AppId,
        [string] $PrivateKey
    )

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = @{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
    $payload = @{
        iat = $now - 60
        exp = $now + 540
        iss = [int64] $AppId
    } | ConvertTo-Json -Compress

    $encodedHeader = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))
    $encodedPayload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload))
    $unsignedJwt = "$encodedHeader.$encodedPayload"
    $rsa = ConvertFrom-PemPrivateKey $PrivateKey

    try {
        $signature = $rsa.SignData(
            [Text.Encoding]::UTF8.GetBytes($unsignedJwt),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    }
    finally {
        $rsa.Dispose()
    }

    return "$unsignedJwt.$(ConvertTo-Base64Url $signature)"
}

function Get-GitHubAppAccessToken {
    param(
        [string] $ApiBaseUrl,
        [string] $AppLogin
    )

    if ([string]::IsNullOrWhiteSpace($env:APP_ID) -or [string]::IsNullOrWhiteSpace($env:APP_PRIVATE_KEY) -or [string]::IsNullOrWhiteSpace($AppLogin)) {
        throw 'APP_ID, APP_PRIVATE_KEY, and APP_LOGIN or an inferable app login are required for GitHub App authentication.'
    }

    $jwt = New-GitHubAppJwt -AppId $env:APP_ID -PrivateKey $env:APP_PRIVATE_KEY
    $headers = @{
        Accept = 'application/vnd.github.v3+json'
        Authorization = "Bearer $jwt"
    }

    $installations = Invoke-RestMethod -Uri "$ApiBaseUrl/app/installations" -Method Get -Headers $headers
    $installation = $installations | Where-Object { $_.account.login -eq $AppLogin -and $_.app_id -eq [int64] $env:APP_ID } | Select-Object -First 1

    if ($null -eq $installation) {
        throw "No GitHub App installation found for login '$AppLogin'."
    }

    $tokenResponse = Invoke-RestMethod -Uri $installation.access_tokens_url -Method Post -Headers $headers -ContentType 'application/json'
    return $tokenResponse.token
}

function Get-RegistrationToken {
    param(
        [string] $TokenUrl,
        [string] $ApiBaseUrl,
        [string] $AppLogin
    )

    $hasAppAuth = -not [string]::IsNullOrWhiteSpace($env:APP_ID) -or -not [string]::IsNullOrWhiteSpace($env:APP_PRIVATE_KEY) -or -not [string]::IsNullOrWhiteSpace($env:APP_LOGIN)
    $hasPatAuth = -not [string]::IsNullOrWhiteSpace($env:ACCESS_TOKEN)
    $hasManualToken = -not [string]::IsNullOrWhiteSpace($env:RUNNER_TOKEN)

    if ($hasAppAuth -and ($hasPatAuth -or $hasManualToken)) {
        throw 'GitHub App authentication is mutually exclusive with ACCESS_TOKEN and RUNNER_TOKEN.'
    }

    if ($hasAppAuth) {
        $env:ACCESS_TOKEN = Get-GitHubAppAccessToken -ApiBaseUrl $ApiBaseUrl -AppLogin $AppLogin
        $hasPatAuth = $true
    }

    if ($hasPatAuth) {
        Write-Host 'Obtaining runner registration token.'
        $headers = @{
            Accept = 'application/vnd.github.v3+json'
            Authorization = "token $env:ACCESS_TOKEN"
        }
        $tokenResponse = Invoke-RestMethod -Uri $TokenUrl -Method Post -Headers $headers -ContentType 'application/json'
        return $tokenResponse.token
    }

    if ($hasManualToken) {
        return $env:RUNNER_TOKEN
    }

    throw 'ACCESS_TOKEN, RUNNER_TOKEN, or GitHub App authentication is required.'
}

function Unset-ConfigurationVariables {
    $names = @(
        'ACCESS_TOKEN',
        'APP_ID',
        'APP_PRIVATE_KEY',
        'APP_LOGIN',
        'RUNNER_TOKEN',
        'RUNNER_NAME',
        'RUNNER_NAME_PREFIX',
        'RANDOM_RUNNER_SUFFIX',
        'RUNNER_SCOPE',
        'ORG_NAME',
        'ENTERPRISE_NAME',
        'LABELS',
        'RUNNER_LABELS',
        'REPO_URL',
        'RUNNER_WORKDIR',
        'RUNNER_GROUP',
        'GITHUB_HOST',
        'GITHUB_API_HOST',
        'GITHUB_API_PATH',
        'DISABLE_AUTOMATIC_DEREGISTRATION',
        'CONFIGURED_ACTIONS_RUNNER_FILES_DIR',
        'EPHEMERAL',
        'DISABLE_AUTO_UPDATE',
        'NO_DEFAULT_LABELS',
        'DEBUG_ONLY',
        'DEBUG_OUTPUT',
        'UNSET_CONFIG_VARS'
    )

    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
}

function Copy-RunnerReuseFiles {
    param([string] $ConfiguredRunnerFilesDir)

    if (-not (Test-Path -LiteralPath $ConfiguredRunnerFilesDir)) {
        New-Item -ItemType Directory -Path $ConfiguredRunnerFilesDir -Force | Out-Null
        return
    }

    Write-Host "Copying configured runner files from $ConfiguredRunnerFilesDir."
    Copy-Item -Path (Join-Path $ConfiguredRunnerFilesDir '*') -Destination (Get-Location) -Recurse -Force
}

function Save-RunnerReuseFiles {
    param([string] $ConfiguredRunnerFilesDir)

    if ([string]::IsNullOrWhiteSpace($ConfiguredRunnerFilesDir)) {
        return
    }

    if (-not (Test-Truthy $env:DISABLE_AUTOMATIC_DEREGISTRATION)) {
        throw 'DISABLE_AUTOMATIC_DEREGISTRATION must be true when CONFIGURED_ACTIONS_RUNNER_FILES_DIR is set.'
    }

    New-Item -ItemType Directory -Path $ConfiguredRunnerFilesDir -Force | Out-Null
    $itemsToCopy = @('.credentials', '.credentials_rsaparams', '.env', '.path', '.runner', 'svc.sh')
    foreach ($item in $itemsToCopy) {
        if (Test-Path -LiteralPath $item) {
            Copy-Item -LiteralPath $item -Destination $ConfiguredRunnerFilesDir -Force
        }
    }

    if (Test-Path -LiteralPath '_diag') {
        Copy-Item -LiteralPath '_diag' -Destination $ConfiguredRunnerFilesDir -Recurse -Force
    }
}

function Configure-Runner {
    param(
        [string] $ConfigUrl,
        [string] $RunnerToken,
        [string] $RunnerName,
        [string] $RunnerWorkDir,
        [string] $Labels,
        [string] $RunnerGroup
    )

    $arguments = @(
        '--unattended',
        '--replace',
        '--url', $ConfigUrl,
        '--token', $RunnerToken,
        '--name', $RunnerName,
        '--work', $RunnerWorkDir,
        '--labels', $Labels,
        '--runnergroup', $RunnerGroup
    )

    if (Test-Truthy $env:EPHEMERAL) {
        Write-Host 'Ephemeral runner mode is enabled.'
        $arguments += '--ephemeral'
    }

    if (Test-Truthy $env:DISABLE_AUTO_UPDATE) {
        Write-Host 'Runner auto update is disabled.'
        $arguments += '--disableupdate'
    }

    if (Test-Truthy $env:NO_DEFAULT_LABELS) {
        Write-Host 'Default runner labels are disabled.'
        $arguments += '--no-default-labels'
    }

    if (Test-Truthy $env:DEBUG_ONLY) {
        Write-Host "DEBUG_ONLY: .\config.cmd $($arguments -join ' ')"
        return
    }

    & .\config.cmd @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Runner configuration failed with exit code $LASTEXITCODE."
    }

    $script:RunnerConfigured = $true
}

function Remove-Runner {
    param([string] $RunnerToken)

    if ($script:RunnerRemoved -or -not $script:RunnerConfigured -or (Test-Truthy $env:DISABLE_AUTOMATIC_DEREGISTRATION)) {
        return
    }

    $script:RunnerRemoved = $true
    Write-Host 'Removing runner registration.'
    & .\config.cmd remove --unattended --token $RunnerToken
}

$gitHubHost = Normalize-Host $(if ($env:GITHUB_HOST) { $env:GITHUB_HOST } else { 'github.com' })
$apiBaseUrl = Get-GitHubApiBaseUrl $gitHubHost
$runnerScope = Get-RunnerScope
$scopeConfiguration = Get-ScopeConfiguration -Scope $runnerScope -GitHubHost $gitHubHost -ApiBaseUrl $apiBaseUrl
$runnerName = Get-RunnerName
$runnerWorkDir = if ($env:RUNNER_WORKDIR) { $env:RUNNER_WORKDIR } else { "C:\_work\$runnerName" }
$labels = if ($env:RUNNER_LABELS) { $env:RUNNER_LABELS } elseif ($env:LABELS) { $env:LABELS } else { 'default' }
$runnerGroup = if ($env:RUNNER_GROUP) { $env:RUNNER_GROUP } else { 'Default' }
$configuredRunnerFilesDir = $env:CONFIGURED_ACTIONS_RUNNER_FILES_DIR

try {
    if (-not [string]::IsNullOrWhiteSpace($configuredRunnerFilesDir)) {
        Write-Host 'Runner reuse is enabled.'
        Copy-RunnerReuseFiles $configuredRunnerFilesDir
    }
    else {
        Write-Host 'Runner reuse is disabled.'
        if (Test-Path -LiteralPath '.runner') {
            Remove-Item -LiteralPath '.runner' -Force
        }
    }

    if (Test-Path -LiteralPath '.runner') {
        Write-Host 'Runner is already configured.'
        $script:RunnerConfigured = $true
        $runnerToken = $env:RUNNER_TOKEN
    }
    else {
        $runnerToken = Get-RegistrationToken -TokenUrl $scopeConfiguration.TokenUrl -ApiBaseUrl $apiBaseUrl -AppLogin $scopeConfiguration.AppLogin
        Configure-Runner -ConfigUrl $scopeConfiguration.ConfigUrl -RunnerToken $runnerToken -RunnerName $runnerName -RunnerWorkDir $runnerWorkDir -Labels $labels -RunnerGroup $runnerGroup
    }

    Save-RunnerReuseFiles $configuredRunnerFilesDir

    if (Test-Truthy $env:UNSET_CONFIG_VARS) {
        Unset-ConfigurationVariables
    }

    if ((Test-Truthy $env:DEBUG_ONLY) -or (Test-Truthy $env:DEBUG_OUTPUT)) {
        Write-Host ''
        Write-Host "Runner scope: $runnerScope"
        Write-Host "Runner name: $runnerName"
        Write-Host "Runner workdir: $runnerWorkDir"
        Write-Host "Labels: $labels"
        Write-Host "Runner group: $runnerGroup"
        Write-Host "GitHub host: $gitHubHost"
        Write-Host "GitHub API base URL: $apiBaseUrl"
        Write-Host "Disable automatic deregistration: $env:DISABLE_AUTOMATIC_DEREGISTRATION"
        Write-Host "No default labels: $env:NO_DEFAULT_LABELS"
    }

    if (-not (Test-Truthy $env:DEBUG_ONLY)) {
        if ($args.Count -gt 0) {
            $runnerCommand = $args[0]
            $runnerArguments = @($args | Select-Object -Skip 1)
            & $runnerCommand @runnerArguments
        }
        else {
            & .\run.cmd
        }
    }
}
finally {
    if ($runnerToken) {
        Remove-Runner $runnerToken
    }
}
