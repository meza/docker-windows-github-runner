$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$securityProtocolSettingsOriginal = [System.Net.ServicePointManager]::SecurityProtocol

try {
    [System.Net.ServicePointManager]::SecurityProtocol = 3072 -bor 768 -bor 192 -bor 48
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
finally {
    [System.Net.ServicePointManager]::SecurityProtocol = $securityProtocolSettingsOriginal
}
