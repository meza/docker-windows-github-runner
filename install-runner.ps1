$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($env:RUNNER_VERSION)) {
    throw 'RUNNER_VERSION must be set.'
}

$runnerArchive = 'actions-runner.zip'
$runnerUrl = "https://github.com/actions/runner/releases/download/v$env:RUNNER_VERSION/actions-runner-win-x64-$env:RUNNER_VERSION.zip"

Invoke-WebRequest -Uri $runnerUrl -OutFile $runnerArchive
Expand-Archive -Path $runnerArchive -DestinationPath . -Force
Remove-Item $runnerArchive -Force
