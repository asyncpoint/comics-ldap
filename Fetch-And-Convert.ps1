# Fetch-And-Convert.ps1
# Downloads DC and Marvel character CSVs from GitHub and converts them to
# LDIF files using the shared logic in ConvertTo-LDIF.ps1.
#
# All LDIF generation logic lives in ConvertTo-LDIF.ps1.
# This script handles downloading, orchestration, and writing final output.
#
# Usage:
#   .\Fetch-And-Convert.ps1
#   .\Fetch-And-Convert.ps1 -Password "MySecret1!" -Verbose
#   .\Fetch-And-Convert.ps1 -Target ActiveDirectory -OutputDir ".\ldif"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("OpenLDAP", "ActiveDirectory")]
    [string]$Target = "OpenLDAP",

    [Parameter(Mandatory = $false)]
    [string]$RootDN = "dc=comics,dc=ldap",

    [Parameter(Mandatory = $false)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [string]$Password = "P@ssw0rd"
)

# -- Dot-source ConvertTo-LDIF.ps1 to load all shared functions ---------------
# The dot-source loads only functions since CsvPath is not provided, so the standalone execution block inside ConvertTo-LDIF.ps1 is skipped.
# $PSScriptRoot is empty when a script is run via certain hosts (ISE, dot-source from prompt); fall back to the directory of the current invocation.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
Write-Verbose "scriptDir: $scriptDir"
if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path $scriptDir "ldifs" }
Write-Verbose "OutputDir: $OutputDir"

$converterScript = Join-Path $scriptDir "Helper.ps1"
if (-not (Test-Path $converterScript)) {
    Write-Error "ConvertTo-LDIF.ps1 not found at: $converterScript"
    Write-Error "Both scripts must be in the same directory."
    exit 1
}

. $converterScript
Write-Verbose "Loaded shared functions from $converterScript"

# -- Source CSV files to download ---------------------------------------------
$sources = @(
    @{ Publisher = "dc"; CsvFile = "dc-wikia-data.csv"; Url = "https://raw.githubusercontent.com/fivethirtyeight/data/master/comic-characters/dc-wikia-data.csv"; LdifFile = "01-dc-users.ldif" },
    @{ Publisher = "marvel"; CsvFile = "marvel-wikia-data.csv"; Url = "https://raw.githubusercontent.com/fivethirtyeight/data/master/comic-characters/marvel-wikia-data.csv"; LdifFile = "02-marvel-users.ldif" }
)

# -- Group nesting map --------------------------------------------------------
# Parent group -> list of subgroup names that are its members.
# Characters are added only to subgroups; parent groups reference subgroups.
# This creates a two-level nested group structure:
#   heroes -> [ dc-heroes, marvel-heroes ]
#   dc-heroes -> [ uid=batman, uid=superman, ... ]
# A recursive LDAP group lookup resolves batman as member of both.
$groupNesting = @{
    "heroes"   = @("dc-heroes", "marvel-heroes")
    "villains" = @("dc-villains", "marvel-villains")
    "neutral"  = @("dc-neutral", "marvel-neutral")
    "living"   = @("dc-living", "marvel-living")
    "deceased" = @("dc-deceased", "marvel-deceased")
}

Write-Verbose "I am here 1 - $OutputDir"
# =============================================================================
# MAIN
# =============================================================================
if (-not (Test-Path -Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Host "Created output directory: $OutputDir" -ForegroundColor Cyan
}

Write-Verbose "I am here 2"
$utf8NoBOM = New-Object System.Text.UTF8Encoding $false
$GroupsDN = "ou=groups,$RootDN"
$allGroupMembers = @{}   # merged across both publishers
$grandTotal = 0
$grandProcessed = 0

Write-Host ""
Write-Host "=============================================" -ForegroundColor DarkGray
Write-Host " Comics LDIF Generator"                       -ForegroundColor White
Write-Host " Target    : $Target"                         -ForegroundColor Cyan
Write-Host " Root DN   : $RootDN"                         -ForegroundColor Cyan
Write-Host " Output    : $OutputDir"                      -ForegroundColor Cyan
Write-Host " Functions : ConvertTo-LDIF.ps1"              -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor DarkGray
Write-Host ""

foreach ($source in $sources) {
    $publisher = $source.Publisher
    $url = $source.Url
    $ldifFile = $source.LdifFile
    $localCsv = Join-Path $scriptDir $source.CsvFile -Verbose
    $publisherDN = "ou=$publisher,ou=users,$RootDN"
    $outputPath = Join-Path $OutputDir $ldifFile

    # -- Cache check: skip download if local file exists and size matches ------
    # A HEAD request fetches only headers (no body), so it is fast.
    # If Content-Length is absent or the HEAD itself fails, download anyway.
    $needsDownload = $true
    if (Test-Path -LiteralPath $localCsv) {
        Write-Host "[$($publisher.ToUpper())] Local CSV found, checking size..." -ForegroundColor Cyan
        try {
            $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -ErrorAction Stop
            $remoteSize = if ($head.Headers.ContainsKey('Content-Length')) { [long]$head.Headers['Content-Length'] } else { -1 }
            $localSize = (Get-Item -LiteralPath $localCsv).Length
            if ($remoteSize -gt 0 -and $localSize -eq $remoteSize) {
                Write-Host "[$($publisher.ToUpper())] Cache hit - local file matches remote size ($localSize bytes). Skipping download." -ForegroundColor Green
                $needsDownload = $false
            }
            else {
                Write-Host "[$($publisher.ToUpper())] Size mismatch (local=$localSize remote=$remoteSize). Re-downloading." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "[$($publisher.ToUpper())] HEAD request failed: $_. Will re-download."
        }
    }

    if ($needsDownload) {
        Write-Host "[$($publisher.ToUpper())] Downloading CSV..." -ForegroundColor Cyan
        Write-Verbose "  URL: $url"
        Write-Verbose "  Destination: $localCsv"
        try {
            Invoke-WebRequest -Uri $url -OutFile $localCsv -UseBasicParsing -ErrorAction Stop
            Write-Host "[$($publisher.ToUpper())] Download complete." -ForegroundColor Green
        }
        catch {
            Write-Warning "[$($publisher.ToUpper())] Download failed: $_"
            continue
        }
    }

    # -- Parse CSV with Import-Csv (RFC 4180 correct) --------------------------
    try {
        $rows = Read-CsvRows -Path $localCsv
        Write-Host "[$($publisher.ToUpper())] Loaded $($rows.Count) rows from $($source.CsvFile)." -ForegroundColor Green
    }
    catch {
        Write-Warning "[$($publisher.ToUpper())] Failed to parse CSV: $_"
        continue
    }

    # -- Convert using shared function from ConvertTo-LDIF.ps1 ----------------
    Write-Host "[$($publisher.ToUpper())] Converting to LDIF..." -ForegroundColor Cyan

    $result = Convert-CsvToLdif `
        -Rows        $rows `
        -Publisher   $publisher `
        -PublisherDN $publisherDN `
        -GroupsDN    $GroupsDN `
        -Target      $Target `
        -Password    $Password

    # -- Write users LDIF file ------------------------------------------------
    [System.IO.File]::WriteAllText($outputPath, $result.LdifContent, $utf8NoBOM)

    # -- Merge group members into master collection ---------------------------
    foreach ($gDN in $result.GroupMembers.Keys) {
        if (-not $allGroupMembers.ContainsKey($gDN)) {
            $allGroupMembers[$gDN] = [System.Collections.Generic.List[string]]::new()
        }
        $allGroupMembers[$gDN].AddRange($result.GroupMembers[$gDN])
    }

    $grandTotal += $result.TotalRows
    $grandProcessed += $result.Processed

    Write-Host "[$($publisher.ToUpper())] Done." -ForegroundColor Green
    Write-Host "  Total rows  : $($result.TotalRows)"  -ForegroundColor Cyan
    Write-Host "  Processed   : $($result.Processed)"  -ForegroundColor Green
    Write-Host "  Skipped     : $($result.Skipped)"    -ForegroundColor Yellow
    Write-Host "  Failed      : $($result.Failed)"     -ForegroundColor $(if ($result.Failed -gt 0) { "Red" } else { "Green" })
    Write-Host "  Output      : $outputPath"           -ForegroundColor Green

    if ($result.FailedRows.Count -gt 0) {
        Write-Host "  Failed rows:" -ForegroundColor Red
        foreach ($entry in $result.FailedRows) { Write-Host "    $entry" -ForegroundColor Red }
    }
    Write-Host ""
}

# -- Write group membership LDIF (03-groups-membership.ldif) ------------------
# Two sections:
#   Section 1 - Add user members to publisher subgroups (dc-heroes etc.)
#   Section 2 - Add subgroup DNs as members of parent groups (heroes etc.)
$nl = "`n"   # LF-only - CRLF corrupts LDIF on Linux
$groupsPath = Join-Path $OutputDir "03-groups-membership.ldif"
$gSb = [System.Text.StringBuilder]::new()
[void]$gSb.Append("version: 1$nl$nl")

# Section 1: user members -> publisher subgroups
[void]$gSb.Append("# ---------------------------------------------------------$nl")
[void]$gSb.Append("# Section 1: Add characters to their publisher subgroups$nl")
[void]$gSb.Append("# ---------------------------------------------------------$nl$nl")

foreach ($gDN in ($allGroupMembers.Keys | Sort-Object)) {
    $members = $allGroupMembers[$gDN]
    if ($members.Count -eq 0) { continue }

    [void]$gSb.Append("dn: $gDN$nl")
    [void]$gSb.Append("changetype: modify$nl")
    [void]$gSb.Append("add: uniqueMember$nl")
    foreach ($m in $members) { [void]$gSb.Append("uniqueMember: $m$nl") }
    [void]$gSb.Append("-$nl$nl")
}

# Section 2: subgroup DNs -> parent groups (nested group wiring)
[void]$gSb.Append("# ---------------------------------------------------------$nl")
[void]$gSb.Append("# Section 2: Wire subgroups as members of parent groups$nl")
[void]$gSb.Append("# e.g. cn=dc-heroes becomes a uniqueMember of cn=heroes$nl")
[void]$gSb.Append("# Applications doing recursive group lookup will resolve$nl")
[void]$gSb.Append("# batman -> dc-heroes -> heroes automatically.$nl")
[void]$gSb.Append("# ---------------------------------------------------------$nl$nl")

foreach ($parentGroup in ($groupNesting.Keys | Sort-Object)) {
    $parentDN = "cn=$parentGroup,$GroupsDN"
    $subGroups = $groupNesting[$parentGroup]

    [void]$gSb.Append("dn: $parentDN$nl")
    [void]$gSb.Append("changetype: modify$nl")
    [void]$gSb.Append("add: uniqueMember$nl")
    foreach ($sub in $subGroups) {
        [void]$gSb.Append("uniqueMember: cn=$sub,$GroupsDN$nl")
    }
    [void]$gSb.Append("-$nl$nl")
}

[System.IO.File]::WriteAllText($groupsPath, $gSb.ToString(), $utf8NoBOM)

# -- Summary ------------------------------------------------------------------
Write-Host "[GROUPS] Written: $groupsPath" -ForegroundColor Green
Write-Host ""
Write-Host "  Subgroup memberships:" -ForegroundColor Cyan
foreach ($gDN in ($allGroupMembers.Keys | Sort-Object)) {
    Write-Host "    $($allGroupMembers[$gDN].Count) members -> $gDN" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  Parent group nesting:" -ForegroundColor Cyan
foreach ($p in ($groupNesting.Keys | Sort-Object)) {
    Write-Host "    cn=$p <- $($groupNesting[$p] -join ', ')" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor DarkGray
Write-Host " COMPLETE"                                    -ForegroundColor White
Write-Host " Total records : $grandTotal"                  -ForegroundColor Cyan
Write-Host " Total written : $grandProcessed"             -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. docker compose down -v" -ForegroundColor Yellow
Write-Host "  2. docker compose up -d"  -ForegroundColor Yellow
Write-Host "  3. Open http://localhost:8080" -ForegroundColor Yellow
