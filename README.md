# docker-windows-github-runner

Windows Server 2025 container image for GitHub Actions self-hosted runners.

The project starts from the Windows runner approach in
[tiobe/docker-github-runner-windows](https://github.com/tiobe/docker-github-runner-windows)
and adopts the runtime configuration model from
[myoung34/docker-github-actions-runner](https://github.com/myoung34/docker-github-actions-runner)
where that model applies to Windows containers.

## What this image provides

The image runs the official GitHub Actions runner on
`mcr.microsoft.com/windows/servercore:ltsc2025`. It installs a practical Windows
toolchain for build jobs:

- Git and Git LFS
- GitHub CLI
- PowerShell 7
- Docker CLI
- Python
- Node.js LTS
- AWS CLI
- yq
- Visual Studio 2022 Build Tools with MSBuild

The default runner version is `2.335.1`, which is the latest GitHub Actions
runner release confirmed during this implementation on 2026-07-01. GitHub
rolls runner versions out progressively, so you can override the build argument
when your organization or enterprise expects a different version.

## Build

Build on a Windows container host that can run Windows Server 2025 containers.
Windows container host and image versions must be compatible.

```powershell
docker build `
  --build-arg SERVERCORE_VERSION=ltsc2025 `
  --build-arg RUNNER_VERSION=2.335.1 `
  -t docker-windows-github-runner:2025 .
```

## Run a repository runner

Use `ACCESS_TOKEN` when you want the container to request a short-lived runner
registration token at startup.

```powershell
docker run --rm `
  -e RUNNER_SCOPE=repo `
  -e REPO_URL=https://github.com/example-owner/example-repo `
  -e ACCESS_TOKEN=<github-token> `
  docker-windows-github-runner:2025
```

`ACCESS_TOKEN` must have permission to create self-hosted runner registration
tokens for the selected repository, organization, or enterprise.

## Run an organization runner

```powershell
docker run --rm `
  -e RUNNER_SCOPE=org `
  -e ORG_NAME=example-org `
  -e ACCESS_TOKEN=<github-token> `
  docker-windows-github-runner:2025
```

## Run an enterprise runner

```powershell
docker run --rm `
  -e RUNNER_SCOPE=enterprise `
  -e ENTERPRISE_NAME=example-enterprise `
  -e ACCESS_TOKEN=<github-token> `
  docker-windows-github-runner:2025
```

## GitHub Enterprise hosts

Set `GITHUB_HOST` for GitHub Enterprise Server. The API defaults to
`https://<GITHUB_HOST>/api/v3`.

```powershell
docker run --rm `
  -e GITHUB_HOST=github.example.com `
  -e RUNNER_SCOPE=org `
  -e ORG_NAME=example-org `
  -e ACCESS_TOKEN=<github-token> `
  docker-windows-github-runner:2025
```

Set `GITHUB_API_HOST` and `GITHUB_API_PATH` when the API host differs from the
web host.

## GitHub App authentication

GitHub App authentication is supported with `APP_ID`, `APP_PRIVATE_KEY`, and
`APP_LOGIN`. Do not set `ACCESS_TOKEN` or `RUNNER_TOKEN` at the same time.

```powershell
docker run --rm `
  -e RUNNER_SCOPE=org `
  -e ORG_NAME=example-org `
  -e APP_ID=<app-id> `
  -e APP_PRIVATE_KEY="<pem-private-key>" `
  -e APP_LOGIN=example-org `
  docker-windows-github-runner:2025
```

For repository and organization runners, `APP_LOGIN` is inferred from
`REPO_URL` or `ORG_NAME` when it is not set. Enterprise runners must set it
explicitly when using GitHub App authentication.

## Configuration

### Runner identity

`RUNNER_NAME` sets the exact runner name. When it is not set, the entrypoint
uses `RUNNER_NAME_PREFIX` plus a random suffix. `RUNNER_NAME_PREFIX` defaults to
`github-runner`.

Set `RANDOM_RUNNER_SUFFIX=false` to use the Windows computer name instead of a
random suffix.

### Labels and groups

`LABELS` or `RUNNER_LABELS` sets the comma-separated runner labels. The default
is `default`.

`RUNNER_GROUP` sets the GitHub runner group. The default is `Default`.

Set `NO_DEFAULT_LABELS=true` to pass `--no-default-labels` to GitHub's runner
configuration command.

### Runner lifecycle

`EPHEMERAL=true` configures the runner with GitHub's `--ephemeral` mode.

`DISABLE_AUTO_UPDATE=true` configures the runner with `--disableupdate`.

`DISABLE_AUTOMATIC_DEREGISTRATION=true` prevents the entrypoint from removing
the runner registration when the container exits.

### Work directory

`RUNNER_WORKDIR` sets the runner work directory. The default is
`C:\_work\<runner-name>`.

Runners sharing a host should not share a work directory.

### Reusing configured runner files

`CONFIGURED_ACTIONS_RUNNER_FILES_DIR` points at a directory that stores runner
configuration files between container starts. Set
`DISABLE_AUTOMATIC_DEREGISTRATION=true` with this mode so the saved files do not
refer to a deregistered runner.

### Secret cleanup

`UNSET_CONFIG_VARS=true` removes runner configuration environment variables
from the process environment before the runner command starts. This reduces
accidental exposure to workflows, but environment variables are still not a
safe secret boundary for untrusted workflows.

## Debugging configuration

`DEBUG_ONLY=true` prints the configuration command and selected settings without
registering or starting the runner.

```powershell
docker run --rm `
  -e DEBUG_ONLY=true `
  -e RUNNER_SCOPE=repo `
  -e REPO_URL=https://github.com/example-owner/example-repo `
  -e RUNNER_TOKEN=example `
  docker-windows-github-runner:2025
```

`DEBUG_OUTPUT=true` prints the selected settings and still starts the runner.

## Windows-specific limits

The Linux upstream supports Docker daemon startup, non-root execution, Unix
socket ownership adjustments, and Linux user/group controls. Those controls are
not implemented here because they do not map cleanly to Windows Server Core
containers.

The image installs the Docker CLI. Running Docker commands from a Windows
container still depends on the host Docker setup and supported Windows
container isolation mode.

## Development checks

PowerShell parser checks can be run without building the image:

```powershell
$errors = $null
[System.Management.Automation.PSParser]::Tokenize((Get-Content .\entrypoint.ps1 -Raw), [ref] $errors) | Out-Null
if ($errors) { $errors | Format-List; exit 1 }
```

Build verification requires a Windows container host that can run
`mcr.microsoft.com/windows/servercore:ltsc2025`.
