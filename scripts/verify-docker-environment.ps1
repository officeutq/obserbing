[CmdletBinding()]
param(
  [ValidatePattern("^[a-z0-9][a-z0-9_-]+$")]
  [string]$ProjectName = "obserbing-verification-$PID",

  [ValidateRange(1024, 65535)]
  [int]$RailsPort = 31079,

  [ValidateRange(1024, 65535)]
  [int]$PostgresPort = 55479
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$originalLocation = Get-Location
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runtimeImage = "$ProjectName-backend:verification"

function Write-Step {
  param([string]$Message)

  Write-Host "`n==> $Message"
}

function Invoke-Native {
  param(
    [string]$FilePath,
    [string[]]$Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath failed with exit code $LASTEXITCODE"
  }
}

function Invoke-DevelopmentCompose {
  param([string[]]$Arguments)

  Invoke-Native -FilePath "docker" -Arguments (@(
      "compose",
      "-p", $ProjectName,
      "--env-file", ".env.example"
    ) + $Arguments)
}

function Get-RuntimeServices {
  param(
    [string]$EnvironmentFile,
    [string]$ComposeFile
  )

  $services = & docker compose --env-file $EnvironmentFile -f $ComposeFile config --services
  if ($LASTEXITCODE -ne 0) {
    throw "Compose validation failed for $ComposeFile"
  }

  return @($services)
}

function Assert-MarkdownLinks {
  param([string[]]$Files)

  $linkPattern = [regex]'\[[^\]]+\]\((?!https?://|#)([^)]+)\)'

  foreach ($file in $Files) {
    $baseDirectory = Split-Path -Parent $file
    if ([string]::IsNullOrEmpty($baseDirectory)) {
      $baseDirectory = "."
    }

    $content = Get-Content -LiteralPath $file -Raw -Encoding utf8
    foreach ($match in $linkPattern.Matches($content)) {
      $target = $match.Groups[1].Value.Split("#", 2)[0]
      $target = [System.Uri]::UnescapeDataString($target)
      $resolvedTarget = Join-Path $baseDirectory $target

      if (-not (Test-Path -LiteralPath $resolvedTarget)) {
        throw "Broken local Markdown link in ${file}: $target"
      }
    }
  }
}

Set-Location $repositoryRoot

# Use deterministic verification-only values instead of inheriting a developer's .env.
$env:POSTGRES_DB = "obserbing_verification_development"
$env:POSTGRES_TEST_DB = "obserbing_verification_test"
$env:POSTGRES_INIT_DB = "postgres"
$env:POSTGRES_USER = "obserbing_verification"
$env:POSTGRES_PASSWORD = "verification-only-not-a-secret"
$env:POSTGRES_PORT = $PostgresPort.ToString()
$env:RAILS_PORT = $RailsPort.ToString()
$env:RAILS_MAX_THREADS = "5"

try {
  Write-Step "Validate version and configuration contracts"
  if ((Get-Content backend/.ruby-version -Raw).Trim() -ne "ruby-4.0.6") {
    throw "backend/.ruby-version does not declare Ruby 4.0.6"
  }

  $gemfile = Get-Content backend/Gemfile -Raw -Encoding utf8
  if ($gemfile -notmatch 'gem "rails", "8\.1\.3\.1"') {
    throw "backend/Gemfile does not pin Rails 8.1.3.1"
  }

  $developmentCompose = Get-Content compose.yml -Raw -Encoding utf8
  if ($developmentCompose -notmatch 'pgvector/pgvector:0\.8\.1-pg18-bookworm') {
    throw "compose.yml does not pin the expected PostgreSQL / pgvector image"
  }

  $stagingServices = Get-RuntimeServices -EnvironmentFile ".env.staging.example" -ComposeFile "compose.staging.yml"
  $productionServices = Get-RuntimeServices -EnvironmentFile ".env.production.example" -ComposeFile "compose.production.yml"
  if (($stagingServices -join "`n").Trim() -ne "backend") {
    throw "staging must contain only the backend service"
  }
  if (($productionServices -join "`n").Trim() -ne "backend") {
    throw "production must contain only the backend service"
  }

  Write-Step "Build the development image and create fresh databases"
  Invoke-DevelopmentCompose -Arguments @("build", "backend")
  Invoke-DevelopmentCompose -Arguments @("up", "-d", "db")
  Invoke-DevelopmentCompose -Arguments @("run", "--rm", "backend", "bin/rails", "db:create")
  Invoke-DevelopmentCompose -Arguments @("run", "--rm", "backend", "bin/rails", "db:migrate")

  Write-Step "Verify PostgreSQL and pgvector"
  $environmentResult = & docker compose -p $ProjectName --env-file .env.example run --rm backend bin/rails environment:verify
  if ($LASTEXITCODE -ne 0) {
    throw "Rails environment verification failed"
  }
  $environmentText = $environmentResult -join "`n"
  Write-Host $environmentText
  if ($environmentText -notmatch 'postgresql_server_version=18\.') {
    throw "PostgreSQL is not version 18.x"
  }
  if ($environmentText -notmatch 'pgvector_available_version=0\.8\.1') {
    throw "pgvector 0.8.1 is not available"
  }

  Write-Step "Start Rails and verify the health endpoint"
  Invoke-DevelopmentCompose -Arguments @("up", "-d", "backend")
  $healthy = $false
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing "http://localhost:$RailsPort/up" -TimeoutSec 2
      if ($response.StatusCode -eq 200) {
        $healthy = $true
        break
      }
    } catch {
      # Rails may still be preparing the database.
    }
    Start-Sleep -Seconds 2
  }
  if (-not $healthy) {
    Invoke-DevelopmentCompose -Arguments @("logs", "backend")
    throw "Rails health endpoint did not return HTTP 200"
  }

  Write-Step "Run tests, lint, security, and dependency audits"
  Invoke-DevelopmentCompose -Arguments @("run", "--rm", "backend", "bin/rails", "db:test:prepare")
  Invoke-DevelopmentCompose -Arguments @("run", "--rm", "backend", "bin/rails", "test")
  Invoke-DevelopmentCompose -Arguments @("run", "--rm", "backend", "bin/rubocop")
  Invoke-DevelopmentCompose -Arguments @("run", "--rm", "backend", "bin/brakeman", "--no-pager")
  Invoke-DevelopmentCompose -Arguments @("run", "--rm", "backend", "bin/bundler-audit")
  Invoke-DevelopmentCompose -Arguments @("run", "--rm", "backend", "bin/importmap", "audit")

  Write-Step "Build and inspect the production image"
  Invoke-Native -FilePath "docker" -Arguments @(
    "build", "--target", "production", "-t", $runtimeImage, "backend"
  )
  Invoke-Native -FilePath "docker" -Arguments @(
    "run", "--rm", "--entrypoint", "sh", $runtimeImage, "-c",
    "test ! -e /rails/.env && test ! -e /rails/config/master.key && test ! -e /rails/docs && test ! -e /rails/poc"
  )

  $imageEnvironment = & docker image inspect $runtimeImage --format '{{json .Config.Env}}'
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect the production image"
  }
  if ($imageEnvironment -match 'DATABASE_URL|RAILS_MASTER_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|verification-only-not-a-secret') {
    throw "Secret-like values or variable names were baked into the production image ENV"
  }

  Write-Step "Check tracked files and common secret signatures"
  $trackedFiles = & git ls-files
  if ($LASTEXITCODE -ne 0) {
    throw "Could not enumerate tracked files"
  }
  $forbiddenTrackedFiles = @($trackedFiles | Where-Object {
      $leaf = Split-Path -Leaf $_
      $isEnvironmentFile = $leaf -eq ".env" -or ($leaf.StartsWith(".env.") -and -not $leaf.EndsWith(".example"))
      $isRailsKey = $_ -match '(^|/)config/master\.key$' -or $_ -match '(^|/)config/credentials/[^/]+\.key$'
      $isEnvironmentFile -or $isRailsKey
    })
  if ($forbiddenTrackedFiles.Count -gt 0) {
    throw "Forbidden environment or Rails key files are tracked: $($forbiddenTrackedFiles -join ', ')"
  }

  $secretPattern = 'AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
  $secretMatches = & git grep -n -I -E $secretPattern -- .
  $grepExitCode = $LASTEXITCODE
  if ($grepExitCode -eq 0) {
    throw "A common secret signature was found in tracked content: $($secretMatches -join '; ')"
  }
  if ($grepExitCode -ne 1) {
    throw "Secret signature scan failed with exit code $grepExitCode"
  }

  Write-Step "Check documentation links"
  $markdownFiles = @(
    "README.md",
    "docs/README.md"
  )
  $markdownFiles += @(Get-ChildItem docs/development -Filter "*.md" | ForEach-Object { $_.FullName })
  Assert-MarkdownLinks -Files $markdownFiles

  Write-Host "`nRails / Docker integrated verification succeeded."
} finally {
  Write-Step "Clean verification-only containers and volumes"
  $verificationErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  & docker compose -p $ProjectName --env-file .env.example down --volumes --remove-orphans 2>&1 | Out-Null
  & docker image rm "$ProjectName-backend:latest" $runtimeImage 2>&1 | Out-Null
  $ErrorActionPreference = $verificationErrorActionPreference
  Set-Location $originalLocation
}
