# ConvertTo-LDIF.ps1
# All LDIF generation logic lives here.
# Can be used in two ways:
#
#   1. Standalone - convert a single local CSV file:
#        .\ConvertTo-LDIF.ps1 -CsvPath "dc-wikia-data.csv"
#        .\ConvertTo-LDIF.ps1 -CsvPath "marvel-wikia-data.csv" -Target ActiveDirectory
#        .\ConvertTo-LDIF.ps1 -CsvPath "dc-wikia-data.csv" -Verbose
#
#   2. Dot-sourced by Fetch-And-Convert.ps1 to share functions only:
#        . .\ConvertTo-LDIF.ps1     (no -CsvPath = no execution, functions only)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $CsvPath,
    [Parameter(Mandatory = $false)] [ValidateSet("OpenLDAP", "ActiveDirectory")] [string] $Target = "OpenLDAP",
    [Parameter(Mandatory = $false)] [string] $RootDN = "dc=comics,dc=ldap",
    [Parameter(Mandatory = $false)] [string] $OutputDir,
    [Parameter(Mandatory = $false)] [string] $Password = "P@ssw0rd"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. $PSScriptRoot\Helper.ps1
# =============================================================================
# STANDALONE EXECUTION
# Only runs when -CsvPath is provided directly.
# When dot-sourced by Fetch-And-Convert.ps1, CsvPath is empty so this is skipped.
# =============================================================================
if (-not [string]::IsNullOrWhiteSpace($CsvPath)) {

    # -- Resolve paths --------------------------------------------------------
    if (-not (Test-Path -LiteralPath $CsvPath)) {
        Write-Error "CSV file not found: $CsvPath"; exit 1
    }
    $resolvedCsv = (Resolve-Path -LiteralPath $CsvPath).Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedCsv)

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $OutputDir = Split-Path -Parent $resolvedCsv
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # -- Detect publisher from filename ---------------------------------------
    if ($baseName -imatch 'dc') { $publisher = 'dc' }
    elseif ($baseName -imatch 'marvel') { $publisher = 'marvel' }
    else {
        Write-Error "Cannot detect publisher from '$baseName'. Filename must contain 'dc' or 'marvel'."
        exit 1
    }

    $publisherDN = "ou=$publisher,ou=users,$RootDN"
    $groupsDN = "ou=groups,$RootDN"
    $usersOut = Join-Path $OutputDir "$baseName-$Target.ldif"
    $groupsOut = Join-Path $OutputDir "$baseName-groups-$Target.ldif"
    $utf8NoBOM = New-Object System.Text.UTF8Encoding $false

    Write-Host ""
    Write-Host "-------------------------------------" -ForegroundColor DarkGray
    Write-Host " Publisher : $publisher"               -ForegroundColor Cyan
    Write-Host " Target    : $Target"                  -ForegroundColor Cyan
    Write-Host " Base DN   : $publisherDN"             -ForegroundColor Cyan
    Write-Host " Output    : $OutputDir"               -ForegroundColor Cyan
    Write-Host "-------------------------------------" -ForegroundColor DarkGray

    # -- Read CSV via Import-Csv ----------------------------------------------
    try { $rows = Read-CsvRows -Path $resolvedCsv }
    catch { Write-Error "Failed to read CSV: $_"; exit 1 }

    # -- Convert --------------------------------------------------------------
    $result = Convert-CsvToLdif `
        -Rows        $rows `
        -Publisher   $publisher `
        -PublisherDN $publisherDN `
        -GroupsDN    $groupsDN `
        -Target      $Target `
        -Password    $Password

    # -- Write users LDIF (BOM-free UTF-8, LF line endings) -------------------
    [System.IO.File]::WriteAllText($usersOut, $result.LdifContent, $utf8NoBOM)

    # -- Write group membership LDIF ------------------------------------------
    $nl = "`n"
    $gSb = [System.Text.StringBuilder]::new()
    [void]$gSb.Append("version: 1$nl$nl")

    foreach ($gDN in ($result.GroupMembers.Keys | Sort-Object)) {
        $members = $result.GroupMembers[$gDN]
        if ($members.Count -eq 0) { continue }
        [void]$gSb.Append("dn: $gDN$nl")
        [void]$gSb.Append("changetype: modify$nl")
        [void]$gSb.Append("add: uniqueMember$nl")
        foreach ($m in $members) { [void]$gSb.Append("uniqueMember: $m$nl") }
        [void]$gSb.Append("-$nl$nl")
    }
    [System.IO.File]::WriteAllText($groupsOut, $gSb.ToString(), $utf8NoBOM)

    # -- Summary --------------------------------------------------------------
    Write-Host ""
    Write-Host "-------------------------------------" -ForegroundColor DarkGray
    Write-Host (" Total rows  : {0}" -f $result.TotalRows)  -ForegroundColor Cyan
    Write-Host (" Processed   : {0}" -f $result.Processed)  -ForegroundColor Green
    Write-Host (" Skipped     : {0}" -f $result.Skipped)    -ForegroundColor Yellow
    $failColour = if ($result.Failed -gt 0) { 'Red' } else { 'Green' }
    Write-Host (" Failed      : {0}" -f $result.Failed)     -ForegroundColor $failColour
    Write-Host (" Users LDIF  : $usersOut")                  -ForegroundColor Green
    Write-Host (" Groups LDIF : $groupsOut")                 -ForegroundColor Green
    Write-Host "-------------------------------------" -ForegroundColor DarkGray

    if ($result.FailedRows.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed rows (not written to LDIF):" -ForegroundColor Red
        foreach ($entry in $result.FailedRows) { Write-Host "  $entry" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Correct the above rows in '$resolvedCsv' and re-run." -ForegroundColor Yellow
    }

    Write-Host ""
    if ($Target -eq "ActiveDirectory") {
        Write-Host "To import into Active Directory:" -ForegroundColor Yellow
        Write-Host "  ldifde -i -f `"$usersOut`" -s <DomainController>" -ForegroundColor Yellow
    }
    else {
        Write-Host "To import into OpenLDAP:" -ForegroundColor Yellow
        Write-Host "  ldapadd -x -H ldap://localhost -D `"cn=admin,$RootDN`" -W -f `"$usersOut`"" -ForegroundColor Yellow
    }
}
