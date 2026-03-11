[CmdletBinding()]
param(
    [switch]$AsJson,
    [switch]$NoWrite
)

# Keep this strict so bad data or typos fail immediately instead of being silently ignored.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Central map for Ninja field names so we only update one place if names ever change.
$FieldMap = @{
    ReleaseDate  = "biosReleaseDate"   # type: date
    Version      = "biosVersion"       # type: text
    Manufacturer = "biosManufacturer"  # type: text
    SerialNumber = "biosSerialNumber"  # type: text
}

function Test-IsNullOrWhiteSpace {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return $true
    }
    return ($Value.Trim().Length -eq 0)
}

function Sanitize-Text {
    param(
        [AllowNull()]
        [string]$Value,
        [int]$MaxLen = 128
    )

    if (Test-IsNullOrWhiteSpace -Value $Value) {
        return ""
    }

    # Trim and strip control chars; hidden chars often cause write/verify mismatches.
    $text = $Value.Trim()
    $text = $text -replace "[\x00-\x1F\x7F]", ""

    if ($text.Length -gt $MaxLen) {
        $text = $text.Substring(0, $MaxLen)
    }

    return $text
}

function Convert-BiosReleaseDate {
    param(
        [Parameter(Mandatory=$true)]
        [object]$ReleaseDate
    )

    if ($ReleaseDate -is [datetime]) {
        return [datetime]$ReleaseDate
    }

    $raw = [string]$ReleaseDate
    if (Test-IsNullOrWhiteSpace -Value $raw) {
        return $null
    }

    # Handle WMI DMTF date format first because Win32_BIOS often returns this shape.
    # Example: 20240515000000.000000+000
    if ($raw -match "^\d{14}\.\d{6}[\+\-]\d{3}$") {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($raw)
    }

    try {
        return [datetime]::Parse($raw)
    }
    catch {
        return $null
    }
}

function Get-BiosInfo {
    # Prefer CIM, but keep WMI fallback for older hosts that don't have CIM cmdlets.
    if (Get-Command -Name "Get-CimInstance" -ErrorAction SilentlyContinue) {
        return Get-CimInstance Win32_BIOS
    }
    if (Get-Command -Name "Get-WmiObject" -ErrorAction SilentlyContinue) {
        return Get-WmiObject Win32_BIOS
    }
    throw "Neither Get-CimInstance nor Get-WmiObject is available."
}

function Set-NinjaCustomField {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FieldName,
        [Parameter(Mandatory = $true)]
        [string]$FieldValue
    )

    # Ninja helper cmdlets are injected by the agent at runtime.
    # If they're missing, this endpoint can't write custom fields in this context.
    if (-not (Get-Command -Name "Ninja-Property-Set" -ErrorAction SilentlyContinue)) {
        throw "Ninja-Property-Set not available (running outside Ninja agent)."
    }

    # Retry a few times because set/get can fail briefly when the local Ninja CLI is busy.
    $maxAttempts = 3
    $lastError = ""
    $isDateField = ($FieldName -eq $FieldMap.ReleaseDate)

    function Test-ValueMatches {
        param(
            [string]$Expected,
            [string]$Actual,
            [bool]$TreatAsDate
        )

        # Text fields compare directly.
        if (-not $TreatAsDate) {
            return ($Actual -eq $Expected)
        }

        # Empty date is valid when BIOS release date isn't available on the endpoint.
        if ((Test-IsNullOrWhiteSpace -Value $Expected) -and (Test-IsNullOrWhiteSpace -Value $Actual)) {
            return $true
        }

        $expectedDate = $null
        $actualDate = $null
        try { $expectedDate = [datetime]::Parse($Expected) } catch {}
        try { $actualDate = [datetime]::Parse($Actual) } catch {}

        # Ninja may read date fields back as Unix epoch seconds; normalize before comparing.
        if (-not $actualDate -and $Actual -match "^\d{9,12}$") {
            try {
                $epoch = [int64]$Actual
                $actualDate = [datetimeoffset]::FromUnixTimeSeconds($epoch).UtcDateTime
            }
            catch {}
        }
        if ($expectedDate -and $actualDate) {
            # Compare date only; formatting/timezone differences are common in read-back values.
            return ($expectedDate.Date -eq $actualDate.Date)
        }
        return ($Actual -eq $Expected)
    }

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $setText = ""
        $hasCliError = $false

        try {
            $setOutput = @(Ninja-Property-Set $FieldName $FieldValue 2>&1 | ForEach-Object { [string]$_ })
            $setText = ($setOutput -join " ")
            $hasCliError = ($setText -match "Failed to start ninjarmm-cli") -or ($setText -match "Cannot access a disposed object")
        }
        catch {
            $setText = [string]$_.Exception.Message
            $hasCliError = ($setText -match "Failed to start ninjarmm-cli") -or ($setText -match "Cannot access a disposed object")
            if (-not $hasCliError) {
                throw
            }
        }

        $lastError = $setText

        if (-not $hasCliError) {
            $canVerify = Get-Command -Name "Ninja-Property-Get" -ErrorAction SilentlyContinue
            if ($canVerify) {
                $readBack = @(Ninja-Property-Get $FieldName 2>&1 | ForEach-Object { [string]$_ })
                $readBackText = ($readBack -join " ").Trim()
                if (Test-ValueMatches -Expected "$FieldValue" -Actual $readBackText -TreatAsDate:$isDateField) {
                    return
                }
                # Keep mismatch details so job history is useful when troubleshooting.
                $lastError = "Verification mismatch for '$FieldName'. Expected='$FieldValue' Actual='$readBackText'"
            }
            else {
                # Some runtimes allow set without a reliable get; treat that as best-effort success.
                return
            }
        }

        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 2
        }
    }

    throw "Ninja-Property-Set failed for field '$FieldName' after $maxAttempts attempts. Last error: $lastError"
}

try {
    $bios = Get-BiosInfo
    $release = Convert-BiosReleaseDate -ReleaseDate $bios.ReleaseDate

    # Build values exactly in the shape expected by the target custom fields.
    $payload = [pscustomobject]@{
        biosReleaseDate = if ($release) { $release.ToString("yyyy-MM-dd") } else { "" }
        biosVersion = Sanitize-Text -Value ([string]$bios.SMBIOSBIOSVersion) -MaxLen 128
        biosManufacturer = Sanitize-Text -Value ([string]$bios.Manufacturer) -MaxLen 128
        biosSerialNumber = Sanitize-Text -Value ([string]$bios.SerialNumber) -MaxLen 128
    }

    # -NoWrite is useful for testing collection logic without touching custom fields.
    if (-not $NoWrite) {
        Set-NinjaCustomField -FieldName $FieldMap.ReleaseDate -FieldValue ([string]$payload.biosReleaseDate)
        Set-NinjaCustomField -FieldName $FieldMap.Version -FieldValue ([string]$payload.biosVersion)
        Set-NinjaCustomField -FieldName $FieldMap.Manufacturer -FieldValue ([string]$payload.biosManufacturer)
        Set-NinjaCustomField -FieldName $FieldMap.SerialNumber -FieldValue ([string]$payload.biosSerialNumber)
    }

    if ($AsJson) {
        if (Get-Command -Name "ConvertTo-Json" -ErrorAction SilentlyContinue) {
            $payload | ConvertTo-Json -Depth 3
        }
        else {
            # PowerShell 2 fallback for legacy servers.
            $json = '{' +
                '"biosReleaseDate":"' + (($payload.biosReleaseDate -replace '"', '\"')) + '",' +
                '"biosVersion":"' + (($payload.biosVersion -replace '"', '\"')) + '",' +
                '"biosManufacturer":"' + (($payload.biosManufacturer -replace '"', '\"')) + '",' +
                '"biosSerialNumber":"' + (($payload.biosSerialNumber -replace '"', '\"')) + '"' +
                '}'
            Write-Output $json
        }
    }
    else {
        $payload
    }
}
catch {
    # Keep final error concise so it is easy to spot in Ninja activity logs.
    Write-Error "Failed to collect/write BIOS fields: $($_.Exception.Message)"
    exit 1
}
