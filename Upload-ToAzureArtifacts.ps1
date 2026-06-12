<#
.SYNOPSIS
    Lädt ein WAR/JAR/ZIP File in einen Azure DevOps Artifacts Maven Feed hoch.

.PARAMETER Organization
    Azure DevOps Organisation (z.B. "mycompany")

.PARAMETER Feed
    Name des Artifacts Feed (z.B. "vendor-libs")

.PARAMETER GroupId
    Maven Group ID (z.B. "com.vendor" → wird zu "com/vendor")

.PARAMETER ArtifactId
    Maven Artifact ID (z.B. "vendor-app")

.PARAMETER Version
    Version des Artifacts (z.B. "1.0.0")

.PARAMETER FilePath
    Pfad zur lokalen Datei (z.B. "C:\Downloads\vendor-app-1.0.0.war")

.PARAMETER Packaging
    Dateiendung/Packaging-Typ (Standard: "war")

.PARAMETER PatToken
    Azure DevOps Personal Access Token mit Packaging Read & Write Berechtigung

.EXAMPLE
    .\Upload-ToAzureArtifacts.ps1 `
        -Organization "mycompany" `
        -Feed "vendor-libs" `
        -GroupId "com.vendor" `
        -ArtifactId "vendor-app" `
        -Version "1.0.0" `
        -FilePath "C:\Downloads\vendor-app-1.0.0.war" `
        -PatToken "xxxxxxxxxxxxxxxxxxxx"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$Feed,

    [Parameter(Mandatory = $true)]
    [string]$GroupId,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactId,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $false)]
    [string]$Packaging = "war",

    [Parameter(Mandatory = $true)]
    [string]$PatToken
)

# --- Validierung ---
if (-not (Test-Path $FilePath)) {
    Write-Error "Datei nicht gefunden: $FilePath"
    exit 1
}

# GroupId-Punkte in Slashes umwandeln (Maven-Konvention)
$groupPath = $GroupId.Replace(".", "/")

# Dateiname im Repository
$remoteFileName = "$ArtifactId-$Version.$Packaging"

# Auth Header aufbauen
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PatToken"))
$headers = @{
    Authorization  = "Basic $base64Auth"
    "Content-Type" = "application/octet-stream"
}

# Upload URL zusammenbauen
$uploadUrl = "https://pkgs.dev.azure.com/$Organization/_apis/packaging/feeds/$Feed/maven/$groupPath/$ArtifactId/$Version/$remoteFileName/content?api-version=7.1-preview.1"

Write-Host ""
Write-Host "=== Azure DevOps Artifacts Upload ===" -ForegroundColor Cyan
Write-Host "Organisation : $Organization"
Write-Host "Feed         : $Feed"
Write-Host "Artifact     : $GroupId:$ArtifactId:$Version"
Write-Host "Datei        : $FilePath"
Write-Host "Upload URL   : $uploadUrl"
Write-Host ""

try {
    Write-Host "Uploading..." -ForegroundColor Yellow
    $response = Invoke-RestMethod `
        -Uri $uploadUrl `
        -Method PUT `
        -Headers $headers `
        -InFile $FilePath `
        -ErrorAction Stop

    Write-Host "Upload erfolgreich!" -ForegroundColor Green
    Write-Host "Artifact verfügbar unter: https://dev.azure.com/$Organization/_artifacts/feed/$Feed"
}
catch {
    Write-Error "Upload fehlgeschlagen: $_"
    Write-Host "HTTP Status: $($_.Exception.Response.StatusCode)" -ForegroundColor Red
    exit 1
}
