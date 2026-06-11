<#
.SYNOPSIS
Updates an Azure DevOps pool name in many Git repositories.

.DESCRIPTION
The script reads repositories from an Azure DevOps organization, clones or fetches
them locally, checks src/main/azure/deploy.yml for an old pool name, and replaces
it with a new pool name only when the repository has exactly one remote branch
and that branch is main.

By default this script runs in dry-run mode. Use -Apply to commit and push.

.EXAMPLE
$env:AZDO_PAT = "your-pat"
.\Update-AzurePool.ps1 -Org "my-org" -OldPool "old pool" -NewPool "new pool"

.EXAMPLE
$env:AZDO_PAT = "your-pat"
.\Update-AzurePool.ps1 -Org "my-org" -Project "my-project" -OldPool "old pool" -NewPool "new pool" -Apply

.EXAMPLE
$env:AZDO_PAT = "your-pat"
.\Update-AzurePool.ps1 -Org "my-org" -Project "my-project" -Repo "my-repo" -OldPool "old pool" -NewPool "new pool" -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Org,

    [Parameter(Mandatory = $false)]
    [string]$Project,

    [Parameter(Mandatory = $false)]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [string]$OldPool,

    [Parameter(Mandatory = $true)]
    [string]$NewPool,

    [Parameter(Mandatory = $false)]
    [string]$WorkDir = ".\azdo-repos",

    [Parameter(Mandatory = $false)]
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:AZDO_PAT)) {
    throw "AZDO_PAT environment variable is required. The PAT needs Azure DevOps Code read/write permissions."
}

foreach ($command in @("git")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $command"
    }
}

$authBytes = [Text.Encoding]::ASCII.GetBytes(":$($env:AZDO_PAT)")
$authValue = [Convert]::ToBase64String($authBytes)
$headers = @{
    Authorization = "Basic $authValue"
    Accept        = "application/json"
}

$apiBase = "https://dev.azure.com/$Org"
$logDir = ".\logs"
$changedLog = Join-Path $logDir "changed.csv"
$skippedLog = Join-Path $logDir "skipped.csv"
$errorLog = Join-Path $logDir "errors.csv"

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Set-Content -LiteralPath $changedLog -Value "Project,Repo,Path,Mode"
Set-Content -LiteralPath $skippedLog -Value "Project,Repo,Reason,Details"
Set-Content -LiteralPath $errorLog -Value "Project,Repo,Reason,Details"

function Add-CsvRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Row
    )

    function Format-CsvValue {
        param([AllowNull()][object]$Value)

        $text = if ($null -eq $Value) { "" } else { [string]$Value }
        '"' + ($text -replace '"', '""') + '"'
    }

    if ($Path -eq $changedLog) {
        $values = @($Row.Project, $Row.Repo, $Row.Path, $Row.Mode)
    }
    else {
        $values = @($Row.Project, $Row.Repo, $Row.Reason, $Row.Details)
    }

    Add-Content -LiteralPath $Path -Value (($values | ForEach-Object { Format-CsvValue $_ }) -join ",")
}

function Invoke-AzDoGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $response = Invoke-WebRequest -Method Get -Uri $Uri -Headers $headers -UseBasicParsing
    $body = $response.Content | ConvertFrom-Json

    $continuationToken = $null
    if ($response.Headers -and $response.Headers.ContainsKey("x-ms-continuationtoken")) {
        $continuationToken = $response.Headers["x-ms-continuationtoken"] | Select-Object -First 1
    }

    [pscustomobject]@{
        Body              = $body
        ContinuationToken = $continuationToken
    }
}

function ConvertTo-UrlPart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    [Uri]::EscapeDataString($Value)
}

function Get-AzDoProjects {
    if (-not [string]::IsNullOrWhiteSpace($Project)) {
        return @($Project)
    }

    $projects = New-Object System.Collections.Generic.List[string]
    $token = $null

    do {
        $uri = "$apiBase/_apis/projects?api-version=7.1&`$top=100"
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $uri += "&continuationToken=$(ConvertTo-UrlPart $token)"
        }

        $page = Invoke-AzDoGet -Uri $uri
        foreach ($item in $page.Body.value) {
            $projects.Add([string]$item.name)
        }
        $token = $page.ContinuationToken
    } while (-not [string]::IsNullOrWhiteSpace($token))

    return $projects.ToArray()
}

function Get-AzDoRepositories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName
    )

    $repos = New-Object System.Collections.Generic.List[object]
    $encodedProject = ConvertTo-UrlPart $ProjectName
    $token = $null

    do {
        $uri = "$apiBase/$encodedProject/_apis/git/repositories?api-version=7.1"
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $uri += "&continuationToken=$(ConvertTo-UrlPart $token)"
        }

        $page = Invoke-AzDoGet -Uri $uri
        foreach ($item in $page.Body.value) {
            if (-not [string]::IsNullOrWhiteSpace($Repo) -and $item.name -ne $Repo) {
                continue
            }

            $repos.Add([pscustomobject]@{
                Name      = [string]$item.name
                RemoteUrl = [string]$item.remoteUrl
            })
        }
        $token = $page.ContinuationToken
    } while (-not [string]::IsNullOrWhiteSpace($token))

    return $repos.ToArray()
}

function ConvertTo-SafeDirectoryName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $safe = $Value -replace '[/:\s]', '_'
    $safe = $safe -replace '[^a-zA-Z0-9_.-]', ''
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "_"
    }
    return $safe
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git -c "http.extraheader=Authorization: Basic $authValue" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-GitNoAuth {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Test-GitQuiet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & git @Arguments *> $null
    return ($LASTEXITCODE -eq 0)
}

function Process-Repository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [Parameter(Mandatory = $true)]
        [string]$RepoName,

        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    $projectDir = ConvertTo-SafeDirectoryName $ProjectName
    $repoDirName = ConvertTo-SafeDirectoryName $RepoName
    $repoDir = Join-Path (Join-Path $WorkDir $projectDir) $repoDirName
    $deployFile = Join-Path $repoDir "src/main/azure/deploy.yml"

    Write-Host "Processing $ProjectName/$RepoName"

    New-Item -ItemType Directory -Force -Path (Split-Path $repoDir -Parent) | Out-Null

    if (Test-Path (Join-Path $repoDir ".git")) {
        Invoke-Git -Arguments @("-C", $repoDir, "fetch", "--prune", "origin") | Out-Null
    }
    else {
        Invoke-Git -Arguments @("clone", $RemoteUrl, $repoDir) | Out-Null
        Invoke-Git -Arguments @("-C", $repoDir, "fetch", "--prune", "origin") | Out-Null
    }

    $branches = Invoke-GitNoAuth -Arguments @(
        "-C", $repoDir,
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/remotes/origin"
    ) | Where-Object { $_ -ne "origin/HEAD" }

    $branches = @($branches)
    if ($branches.Count -ne 1 -or $branches[0] -ne "origin/main") {
        Add-CsvRow -Path $skippedLog -Row @{
            Project = $ProjectName
            Repo    = $RepoName
            Reason  = "not_single_main_branch"
            Details = ($branches -join " ")
        }
        return
    }

    Invoke-GitNoAuth -Arguments @("-C", $repoDir, "checkout", "-B", "main", "origin/main") | Out-Null

    $hasNoWorktreeChanges = Test-GitQuiet -Arguments @("-C", $repoDir, "diff", "--quiet")
    $hasNoStagedChanges = Test-GitQuiet -Arguments @("-C", $repoDir, "diff", "--cached", "--quiet")
    if (-not $hasNoWorktreeChanges -or -not $hasNoStagedChanges) {
        Add-CsvRow -Path $skippedLog -Row @{
            Project = $ProjectName
            Repo    = $RepoName
            Reason  = "dirty_worktree"
            Details = $repoDir
        }
        return
    }

    if (-not (Test-Path $deployFile)) {
        Add-CsvRow -Path $skippedLog -Row @{
            Project = $ProjectName
            Repo    = $RepoName
            Reason  = "missing_deploy_file"
            Details = "src/main/azure/deploy.yml"
        }
        return
    }

    $content = Get-Content -LiteralPath $deployFile -Raw
    if (-not $content.Contains($OldPool)) {
        Add-CsvRow -Path $skippedLog -Row @{
            Project = $ProjectName
            Repo    = $RepoName
            Reason  = "old_pool_not_found"
            Details = $OldPool
        }
        return
    }

    if (-not $Apply) {
        Add-CsvRow -Path $changedLog -Row @{
            Project = $ProjectName
            Repo    = $RepoName
            Path    = $deployFile
            Mode    = "dry-run"
        }
        return
    }

    $newContent = $content.Replace($OldPool, $NewPool)
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $deployFile), $newContent, $utf8NoBom)

    if (Test-GitQuiet -Arguments @("-C", $repoDir, "diff", "--quiet", "--", $deployFile)) {
        Add-CsvRow -Path $skippedLog -Row @{
            Project = $ProjectName
            Repo    = $RepoName
            Reason  = "no_effect_after_replace"
            Details = $deployFile
        }
        return
    }

    Invoke-GitNoAuth -Arguments @("-C", $repoDir, "add", $deployFile) | Out-Null
    Invoke-GitNoAuth -Arguments @("-C", $repoDir, "commit", "-m", "Update Azure DevOps pool name") | Out-Null
    Invoke-Git -Arguments @("-C", $repoDir, "push", "origin", "main") | Out-Null

    Add-CsvRow -Path $changedLog -Row @{
        Project = $ProjectName
        Repo    = $RepoName
        Path    = $deployFile
        Mode    = "updated"
    }
}

Write-Host "Mode: $(if ($Apply) { 'apply' } else { 'dry-run' })"
Write-Host "Logs: $logDir"

$processedCount = 0

foreach ($projectName in Get-AzDoProjects) {
    foreach ($repo in Get-AzDoRepositories -ProjectName $projectName) {
        try {
            $processedCount++
            Process-Repository -ProjectName $projectName -RepoName $repo.Name -RemoteUrl $repo.RemoteUrl
        }
        catch {
            Add-CsvRow -Path $errorLog -Row @{
                Project = $projectName
                Repo    = $repo.Name
                Reason  = "processing_failed"
                Details = $_.Exception.Message
            }
            Write-Warning "Failed $projectName/$($repo.Name): $($_.Exception.Message)"
        }
    }
}

if ($processedCount -eq 0 -and -not [string]::IsNullOrWhiteSpace($Repo)) {
    Write-Warning "No repository matched -Repo '$Repo'. Check the repository name and optional -Project filter."
}

Write-Host "Done."
Write-Host "Changed candidates / updated: $changedLog"
Write-Host "Skipped: $skippedLog"
Write-Host "Errors: $errorLog"
