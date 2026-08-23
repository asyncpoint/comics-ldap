
# =============================================================================
# HELPER: Read-CsvRows
# Uses Import-Csv for correct RFC 4180 parsing (quoted fields, embedded commas,
# escaped double-quotes). Returns [PSCustomObject[]].
# =============================================================================
function Read-CsvRows {
    param(
        [Parameter(Mandatory)][string] $Path
    )

    # Import-Csv with UTF8 encoding strips BOM automatically when present.
    # -ErrorAction Stop ensures any parse failure surfaces immediately.
    # Wrap in @() so .Count is always defined - Import-Csv returns a bare
    # PSCustomObject (not an array) when the CSV has exactly one data row.
    $rows = @(Import-Csv -Path $Path -Encoding UTF8 -ErrorAction Stop)

    if ($rows.Count -eq 0) {
        throw "CSV file contains no data rows: $Path"
    }

    # Validate required column exists
    $firstRow = $rows[0]
    if ($null -eq $firstRow.PSObject.Properties['name']) {
        $headers = ($firstRow.PSObject.Properties.Name) -join ', '
        throw "Required column 'name' not found. Headers found: $headers"
    }

    return $rows
}

# =============================================================================
# HELPER: Escape-DnValue
# Escapes a string for safe use as an RDN attribute value per RFC 4514 S2.4.
# Uses [string]::Replace() (literal) throughout - no regex interpretation.
# =============================================================================
function Escape-DnValue {
    param([Parameter(Mandatory)][string] $Value)

    # Reject values containing NUL - they cannot be represented in a DN.
    if ($Value.Contains([char]0)) {
        throw "DN value contains a NUL character, which is not permitted in LDAP DNs."
    }

    # 1. Backslash must be escaped first (it is the escape character itself).
    $v = $Value.Replace('\', '\\')

    # 2. RFC 4514 special characters.
    $v = $v.Replace(',', '\,')
    $v = $v.Replace('+', '\+')
    $v = $v.Replace('=', '\=')
    $v = $v.Replace('<', '\<')
    $v = $v.Replace('>', '\>')
    $v = $v.Replace(';', '\;')
    $v = $v.Replace('"', '\"')

    # 3. Leading '#' is interpreted as a hex-encoded BER value - escape it.
    if ($v.StartsWith('#')) { $v = '\#' + $v.Substring(1) }

    # 4. Leading space.
    if ($v.StartsWith(' ')) { $v = '\ ' + $v.Substring(1) }

    # 5. Trailing space.
    if ($v.EndsWith(' ') -and $v.Length -gt 1) {
        $v = $v.Substring(0, $v.Length - 1) + '\ '
    }

    return $v
}

# =============================================================================
# HELPER: Encode-LdifValue
# Returns ': value' for safe strings or ':: <base64>' per RFC 2849 S6.1
# when the value contains characters that are not safe in plain LDIF.
#
# Encodes when ANY of the following is true:
#   - starts with SPACE (U+0020), COLON (:), or LESS-THAN-SIGN (<)
#   - ends with SPACE (trailing space is stripped by some parsers)
#   - contains any octet outside the safe set: TAB, LF, CR, 0x20-0x7E
#   - contains NUL (0x00) - rejected outright as LDAP does not allow it
# =============================================================================
function Encode-LdifValue {
    param([Parameter(Mandatory)][string] $AttributeValue)

    # NUL bytes cannot appear in LDIF at all.
    if ($AttributeValue.Contains([char]0)) {
        throw "Attribute value contains a NUL byte, which is not permitted in LDIF."
    }

    $needsBase64 = $false

    # Leading unsafe characters.
    if ($AttributeValue.Length -gt 0) {
        $first = $AttributeValue[0]
        if ($first -eq ' ' -or $first -eq ':' -or $first -eq '<') {
            $needsBase64 = $true
        }
    }

    # Trailing space.
    if (-not $needsBase64 -and $AttributeValue.EndsWith(' ')) {
        $needsBase64 = $true
    }

    # Non-printable / non-ASCII characters (outside TAB=0x09, LF=0x0A, CR=0x0D, 0x20-0x7E).
    if (-not $needsBase64) {
        foreach ($ch in $AttributeValue.ToCharArray()) {
            $cp = [int]$ch
            if ($cp -ne 0x09 -and $cp -ne 0x0A -and $cp -ne 0x0D -and
                ($cp -lt 0x20 -or $cp -gt 0x7E)) {
                $needsBase64 = $true
                break
            }
        }
    }

    if ($needsBase64) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($AttributeValue)
        $encoded = [Convert]::ToBase64String($bytes)
        return ":: $encoded"
    }

    return ": $AttributeValue"
}

# =============================================================================
# HELPER: Sanitise-Uid
# Produces a safe LDAP uid: lowercase letters (a-z), digits (0-9), underscore (_).
# Spaces become underscores. All other characters are stripped.
# Returns $null when the result is shorter than 3 characters.
# =============================================================================
function Sanitise-Uid {
    param([Parameter(Mandatory)][string] $Value)

    # Lowercase, remove spaces that follow a dot (e.g. "Mr. Freeze" -> "Mr.Freeze"),
    # then replace all remaining spaces with underscores.
    $s = $Value.ToLowerInvariant()
    $s = [System.Text.RegularExpressions.Regex]::Replace($s, '\.\s+', '.')
    $s = $s.Replace(' ', '_')

    # Keep only a-z, 0-9, underscore, hyphen, dot.
    $s = [System.Text.RegularExpressions.Regex]::Replace($s, '[^a-z0-9_\-\.]', '')

    # Collapse multiple consecutive underscores to one.
    $s = [System.Text.RegularExpressions.Regex]::Replace($s, '_+', '_')

    # Strip leading/trailing underscores.
    $s = $s.Trim('_')

    if ($s.Length -lt 2) { return $null }

    return $s
}

# =============================================================================
# HELPER: Get-AlignGroups / Get-AliveGroups
# Map CSV column values to publisher-specific subgroup names.
# Characters are added ONLY to subgroups; parent groups (heroes, villains...)
# are wired to subgroup DNs in 03-groups-membership.ldif (Section 2).
# =============================================================================
function Get-AlignGroup {
    param([string]$Align, [string]$Publisher)
    switch ($Align) {
        "Good Characters" { return "$Publisher-heroes" }
        "Bad Characters" { return "$Publisher-villains" }
        "Neutral Characters" { return "$Publisher-neutral" }
        default { return $null }
    }
}

function Get-AliveGroup {
    param([string]$Alive, [string]$Publisher)
    switch ($Alive) {
        "Living Characters" { return "$Publisher-living" }
        "Deceased Characters" { return "$Publisher-deceased" }
        default { return $null }
    }
}

# =============================================================================
# CORE: Convert-CsvToLdif
#
# Accepts pre-parsed rows from Import-Csv (PSCustomObject[]) and converts
# them to LDIF content plus group membership data.
#
# Parameters:
#   Rows         [PSCustomObject[]]  Pre-parsed CSV rows via Read-CsvRows
#   Publisher    string              "dc" or "marvel"
#   PublisherDN  string              e.g. "ou=dc,ou=users,dc=comics,dc=com"
#   GroupsDN     string              e.g. "ou=groups,dc=comics,dc=com"
#   Target       string              "OpenLDAP" or "ActiveDirectory"
#   Password     string              Plain-text password for all entries
#
# Returns hashtable:
#   LdifContent  string                           Ready to write to .ldif
#   GroupMembers hashtable<string, List<string>>  groupDN -> member DNs
#   TotalRows    int
#   Processed    int
#   Skipped      int
#   Failed       int
#   FailedRows   List<string>                     Human-readable failure log
# =============================================================================
function Convert-CsvToLdif {
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject[]] $Rows,
        [Parameter(Mandatory = $true)] [string] $Publisher,
        [Parameter(Mandatory = $true)] [string] $PublisherDN,
        [Parameter(Mandatory = $true)] [string] $GroupsDN,
        [Parameter(Mandatory = $true)] [string] $Target,
        [Parameter(Mandatory = $true)] [string] $Password
    )

    # LF-only line endings - CRLF corrupts LDIF on Linux.
    $nl = "`n"
    $sb = [System.Text.StringBuilder]::new()
    $failedRows = [System.Collections.Generic.List[string]]::new()
    $groupMembers = @{}
    $usedUids = @{}

    [void]$sb.Append("version: 1$nl$nl")

    $totalRows = $Rows.Count
    $processed = 0
    $skipped = 0
    $failed = 0
    $rowNum = 1

    foreach ($row in $Rows) {
        $rowNum++

        try {
            # 1. Extract name
            $nameProp = $row.PSObject.Properties['name']
            if ($null -eq $nameProp) { $skipped++; continue }
            $fullName = ($nameProp.Value -as [string]).Trim()
            if ([string]::IsNullOrWhiteSpace($fullName)) { $skipped++; continue }

            # 2. Strip trailing universe/continuity suffixes, then split
            #    "Hero (Real Name) (Earth-616)" -> strip last (...) if more than one set
            #    exists, repeat until only one set remains or none.
            #    e.g. "Rogue (Anna Marie) (Earth-616)" -> "Rogue (Anna Marie)"
            #         "Flash (Barry Allen) (New Earth)" -> "Flash (Barry Allen)"
            $stripped = $fullName.Trim()
            $parenMatches = [System.Text.RegularExpressions.Regex]::Matches($stripped, '\([^)]*\)')
            while ($parenMatches.Count -ge 2) {
                $last = $parenMatches[$parenMatches.Count - 1]
                $stripped = $stripped.Substring(0, $last.Index).TrimEnd()
                $parenMatches = [System.Text.RegularExpressions.Regex]::Matches($stripped, '\([^)]*\)')
            }

            if ($stripped -match '^(.+?)\s*\((.+)\)\s*$') {
                $heroName = $Matches[1].Trim()
                $realName = $Matches[2].Trim()
            }
            else {
                $heroName = $stripped
                $realName = $stripped
            }


            # Remove double-quote characters - in this dataset they mark nicknames
            # e.g. James "Logan" Howlett. Quotes are not valid in LDIF attribute
            # values without base64 encoding, and the nickname is not useful data.
            # Collapse any double-spaces left behind after removal.
            $heroName = [System.Text.RegularExpressions.Regex]::Replace($heroName.Replace('"', '').Replace('\', ''), '\s{2,}', ' ').Trim()
            $realName = [System.Text.RegularExpressions.Regex]::Replace($realName.Replace('"', '').Replace('\', ''), '\s{2,}', ' ').Trim()

            if ([string]::IsNullOrWhiteSpace($heroName)) { throw "Empty hero name from: '$fullName'" }
            if ([string]::IsNullOrWhiteSpace($realName)) { throw "Empty real name from: '$fullName'" }

            # 3. Build safe UID (a-z 0-9 _ only, min 2 chars)
            $baseUid = Sanitise-Uid -Value $heroName
            if ($null -eq $baseUid) { throw "Cannot derive a usable UID (min 2 chars) from '$heroName'" }

            # Resolve collisions: append _2, _3, ...
            $uidRDN = $baseUid
            if ($usedUids.ContainsKey($uidRDN)) {
                $suffix = 2
                while ($usedUids.ContainsKey("${baseUid}_${suffix}")) { $suffix++ }
                $uidRDN = "${baseUid}_${suffix}"
                Write-Warning "  Row $rowNum : UID collision '$baseUid' -> assigned '$uidRDN'"
            }
            $usedUids[$uidRDN] = $true

            # 4. sn = last word of real name
            $snParts = @($realName.Split(' ') | Where-Object { $_ -ne '' })
            $sn = if ($snParts.Count -gt 0) { $snParts[-1] } else { $realName }

            # 5. Read ALIGN / ALIVE columns safely
            $alignProp = $row.PSObject.Properties['ALIGN']
            $aliveProp = $row.PSObject.Properties['ALIVE']
            $align = if ($null -ne $alignProp) { ($alignProp.Value -as [string]).Trim() } else { '' }
            $alive = if ($null -ne $aliveProp) { ($aliveProp.Value -as [string]).Trim() } else { '' }

            # 6. Build LDIF entry
            if ($Target -eq 'ActiveDirectory') {
                $quotedPw = '"' + $Password + '"'
                $utf16leEnc = [System.Text.Encoding]::GetEncoding('utf-16-le')
                $encodedPass = [Convert]::ToBase64String($utf16leEnc.GetBytes($quotedPw))
                $escapedCN = Escape-DnValue -Value $realName
                $userDN = "CN=$escapedCN,$PublisherDN"
                [void]$sb.Append("dn: $userDN$nl")
                [void]$sb.Append("objectClass: user$nl")
                [void]$sb.Append("cn$(Encode-LdifValue -AttributeValue $realName)$nl")
                [void]$sb.Append("sn$(Encode-LdifValue -AttributeValue $sn)$nl")
                [void]$sb.Append("sAMAccountName: $uidRDN$nl")
                [void]$sb.Append("unicodePwd:: $encodedPass$nl")
            }
            else {
                $userDN = "uid=$uidRDN,$PublisherDN"
                [void]$sb.Append("dn: $userDN$nl")
                [void]$sb.Append("objectClass: inetOrgPerson$nl")
                [void]$sb.Append("uid$(Encode-LdifValue -AttributeValue $heroName)$nl")
                [void]$sb.Append("cn$(Encode-LdifValue -AttributeValue $realName)$nl")
                [void]$sb.Append("sn$(Encode-LdifValue -AttributeValue $sn)$nl")
                [void]$sb.Append("userPassword: $Password$nl")
            }
            [void]$sb.Append("$nl")
            $processed++

            # 7. Collect group memberships (publisher subgroups only)
            $alignGroup = Get-AlignGroup -Align $align -Publisher $Publisher
            $aliveGroup = Get-AliveGroup -Alive $alive -Publisher $Publisher
            foreach ($groupName in @($alignGroup, $aliveGroup)) {
                if ([string]::IsNullOrEmpty($groupName)) { continue }
                $gDN = "cn=$groupName,$GroupsDN"
                if (-not $groupMembers.ContainsKey($gDN)) {
                    $groupMembers[$gDN] = [System.Collections.Generic.List[string]]::new()
                }
                $groupMembers[$gDN].Add($userDN)
            }

            Write-Verbose "  Row $rowNum : OK | uid=$uidRDN | cn=$realName | align=$align | alive=$alive"
        }
        catch {
            $failed++
            $errNameProp = $row.PSObject.Properties['name']
            $errNameVal = if ($null -ne $errNameProp) { $errNameProp.Value } else { '<missing>' }
            $msg = "Row $rowNum : $($_.Exception.Message) | name=$errNameVal"
            $failedRows.Add($msg)
            Write-Warning "  $msg"
        }
    }

    return @{
        LdifContent  = $sb.ToString()
        GroupMembers = $groupMembers
        TotalRows    = $totalRows
        Processed    = $processed
        Skipped      = $skipped
        Failed       = $failed
        FailedRows   = $failedRows
    }
}
