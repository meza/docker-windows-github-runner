ARG SERVERCORE_VERSION="ltsc2025"
ARG RUNNER_VERSION="2.335.1"

FROM mcr.microsoft.com/windows/servercore:${SERVERCORE_VERSION}

SHELL ["powershell", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ARG RUNNER_VERSION
ENV RUNNER_VERSION=${RUNNER_VERSION}
ENV AGENT_TOOLSDIRECTORY="C:\\hostedtoolcache"

WORKDIR C:\\actions-runner

COPY install-choco.ps1 .
RUN .\\install-choco.ps1; Remove-Item .\\install-choco.ps1 -Force

RUN choco install -y --no-progress \
    git \
    git-lfs \
    gh \
    powershell-core \
    docker-cli \
    python \
    nodejs-lts \
    awscli \
    yq

RUN choco install -y --no-progress visualstudio2022buildtools --package-parameters "'--quiet --norestart --add Microsoft.VisualStudio.Workload.VisualStudioExtensionBuildTools --add Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools --add Microsoft.NetCore.Component.SDK --add Microsoft.Net.Component.4.8.TargetingPack'"

RUN [Environment]::SetEnvironmentVariable('Path', $env:Path + ';C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\MSBuild\\Current\\Bin', 'Machine'); \
    New-Item -ItemType Directory -Path $env:AGENT_TOOLSDIRECTORY -Force | Out-Null

COPY install-runner.ps1 .
RUN .\\install-runner.ps1; Remove-Item .\\install-runner.ps1 -Force

COPY entrypoint.ps1 .

ENTRYPOINT ["pwsh.exe", "-NoLogo", "-NoProfile", "-File", ".\\entrypoint.ps1"]
CMD [".\\run.cmd"]
