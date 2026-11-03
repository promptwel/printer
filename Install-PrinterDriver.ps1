<#
.SYNOPSIS
    Search for a printer by name, then download and silently install its driver.

.DESCRIPTION
    Looks for the printer in three places, in this order:
      1. Drivers already installed on this PC
      2. Drivers built into Windows (ntprint.inf)
      3. The Microsoft Update Catalog (official, Microsoft-signed driver packages)

    You pick a result, and the script installs it with no wizard / Next / Accept clicks.
    Downloaded files must carry a valid Microsoft digital signature or they are NOT installed.

.PARAMETER Name
    Printer name to search for, e.g. "HP LaserJet Pro M404". Prompted if omitted.

.PARAMETER PrinterIP
    Optional. If given, also creates a network printer at this IP using the new driver.

.PARAMETER Yes
    Don't ask questions: take the first result.

.PARAMETER NoPause
    Don't wait for Enter at the end (useful when running from another script).

.EXAMPLE
    .\Install-PrinterDriver.ps1 "Brother HL-L2350DW"

.EXAMPLE
    .\Install-PrinterDriver.ps1 "Canon MF445dw" -PrinterIP 192.168.1.50 -Yes
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Name,
    [string]$PrinterIP,
    [switch]$Yes,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --------------------------------------------------------------------------
# Admin check - ask for elevation ONCE, instead of once per installer.
# --------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Name)      { $argList += @('-Name', "`"$Name`"") }
    if ($PrinterIP) { $argList += @('-PrinterIP', "`"$PrinterIP`"") }
    if ($Yes)       { $argList += '-Yes' }
    if ($NoPause)   { $argList += '-NoPause' }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs
    exit
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Test-AllWords([string]$Text, [string[]]$Words) {
    foreach ($w in $Words) {
        if ($Text.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Get-QuotedNames([string]$InfPath, [string[]]$Words) {
    # Printer model names appear as quoted strings in driver .inf files.
    $found = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in (Select-String -Path $InfPath -Pattern '"([^"]+)"' -AllMatches)) {
        foreach ($m in $line.Matches) {
            $v = $m.Groups[1].Value.Trim()
            if ($v.Length -ge 3 -and (Test-AllWords $v $Words)) { [void]$found.Add($v) }
        }
    }
    return @($found)
}

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

# --------------------------------------------------------------------------
# Search sources
# --------------------------------------------------------------------------
function Search-Installed([string[]]$Words) {
    Get-PrinterDriver -ErrorAction SilentlyContinue |
        Where-Object { Test-AllWords $_.Name $Words } |
        ForEach-Object {
            [pscustomobject]@{ Source = 'Installed'; Title = $_.Name; Id = $_.Name; Detail = 'already on this PC' }
        }
}

function Search-Inbox([string[]]$Words) {
    $inf = Join-Path $env:windir 'INF\ntprint.inf'
    if (-not (Test-Path $inf)) { return }
    Get-QuotedNames $inf $Words | ForEach-Object {
        [pscustomobject]@{ Source = 'Windows'; Title = $_; Id = $_; Detail = 'built into Windows' }
    }
}

function Search-Catalog([string]$Query, [string[]]$Words) {
    $url  = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($Query)
    $html = (Invoke-WebRequest -UseBasicParsing -Uri $url).Content

    $rows = [regex]::Matches($html, '(?is)<tr[^>]+id=["'']([0-9a-f\-]{36})_R\d+["''][^>]*>(.*?)</tr>')
    $results = foreach ($row in $rows) {
        $cells = @([regex]::Matches($row.Groups[2].Value, '(?is)<td[^>]*>(.*?)</td>') | ForEach-Object {
            $t = [regex]::Replace($_.Groups[1].Value, '<[^>]+>', ' ')
            ([System.Net.WebUtility]::HtmlDecode($t) -replace '\s+', ' ').Trim()
        })
        if ($cells.Count -lt 7) { continue }
        $title = $cells[1]
        if ($cells[3] -notmatch 'Driver') { continue }
        if (-not (Test-AllWords $title $Words)) { continue }

        $date = [datetime]::MinValue
        [void][datetime]::TryParseExact($cells[4], 'M/d/yyyy',
            [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$date)

        [pscustomobject]@{
            Source = 'Catalog'
            Title  = $title
            Id     = $row.Groups[1].Value
            Detail = "$($cells[4]), $($cells[6])"
            Date   = $date
        }
    }
    $results | Sort-Object Date -Descending | Select-Object -First 15
}

# --------------------------------------------------------------------------
# Install paths
# --------------------------------------------------------------------------
function Install-FromWindows([string]$Model) {
    Write-Step "Installing built-in driver '$Model'"
    Add-PrinterDriver -Name $Model
    return $Model
}

function Install-FromCatalog($Item, [string[]]$Words) {
    $work = Join-Path $env:TEMP ("PrinterDriver_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        Write-Step "Getting download link for: $($Item.Title)"
        $guid = $Item.Id
        $body = @{ updateIDs = '[{"size":0,"languages":"","uidInfo":"' + $guid + '","updateID":"' + $guid + '"}]' }
        $page = Invoke-WebRequest -UseBasicParsing -Method Post -Body $body `
            -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'
        $urls = @([regex]::Matches($page.Content, "\.url\s*=\s*['""]([^'""]+)['""]") |
            ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($urls.Count -eq 0) { throw 'The catalog did not return a download link.' }

        $cabs = @()
        foreach ($u in $urls) {
            # Only ever download from Microsoft's own hosts.
            $h = ([uri]$u).Host
            if ($h -notmatch '(^|\.)(windowsupdate|microsoft)\.com$') {
                Write-Warning "Skipping non-Microsoft host: $h"; continue
            }
            $file = Join-Path $work ([IO.Path]::GetFileName(([uri]$u).AbsolutePath))
            Write-Step "Downloading $([IO.Path]::GetFileName($file))"
            Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $file
            $cabs += $file
        }
        if ($cabs.Count -eq 0) { throw 'Nothing was downloaded.' }

        Write-Step 'Verifying Microsoft digital signature'
        foreach ($c in $cabs) {
            $sig = Get-AuthenticodeSignature -FilePath $c
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
                throw "Signature check FAILED for $([IO.Path]::GetFileName($c)) ($($sig.Status)). Not installing."
            }
        }
        Write-Host 'Signature OK.'

        Write-Step 'Extracting and installing driver package'
        $dir = Join-Path $work 'extracted'
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($c in $cabs) { & expand.exe $c -F:* $dir | Out-Null }

        & pnputil.exe /add-driver (Join-Path $dir '*.inf') /subdirs /install | Out-Host
        if ($LASTEXITCODE -notin 0, 3010) {
            Write-Warning "pnputil exited with code $LASTEXITCODE (continuing)."
        }

        Write-Step 'Registering printer driver'
        $installed = @()
        foreach ($inf in Get-ChildItem -Path $dir -Filter *.inf -Recurse) {
            foreach ($model in Get-QuotedNames $inf.FullName $Words) {
                try {
                    Add-PrinterDriver -Name $model -InfPath $inf.FullName
                    Write-Host "  Registered: $model" -ForegroundColor Green
                    $installed += $model
                } catch { <# not every quoted string is a model name #> }
            }
        }
        if ($installed.Count -eq 0) {
            Write-Warning ("The driver package was installed into the Windows driver store, but no model " +
                "matching '$($Words -join ' ')' could be registered by name. Plug in the printer " +
                "or use Settings > Printers > Add device; Windows will now find the driver itself.")
        }
        return $installed
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Add-NetworkPrinter([string]$DriverName, [string]$IP) {
    Write-Step "Creating network printer at $IP"
    $port = "IP_$IP"
    if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $port -PrinterHostAddress $IP
    }
    Add-Printer -Name $DriverName -DriverName $DriverName -PortName $port
    Write-Host "Printer '$DriverName' added on $port." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
try {
    if (-not $Name) { $Name = Read-Host 'Printer name to search for (e.g. HP LaserJet M404)' }
    $Words = @($Name -split '\s+' | Where-Object { $_ })
    if ($Words.Count -eq 0) { throw 'No printer name given.' }

    Write-Step "Searching for '$Name'"
    $results = @()
    $results += Search-Installed $Words
    $results += Search-Inbox $Words | Where-Object { $_.Title -notin $results.Title }
    try   { $results += Search-Catalog $Name $Words }
    catch { Write-Warning "Microsoft Update Catalog search failed: $($_.Exception.Message)" }

    $results = @($results)
    if ($results.Count -eq 0) {
        throw "No driver found for '$Name'. Try fewer words (e.g. 'LaserJet M404'), or check the vendor's website."
    }

    for ($i = 0; $i -lt $results.Count; $i++) {
        '{0,3}. [{1}] {2}  ({3})' -f ($i + 1), $results[$i].Source, $results[$i].Title, $results[$i].Detail
    }

    $choice = 1
    if (-not $Yes -and $results.Count -gt 1) {
        $in = Read-Host "`nPick a number (Enter = 1, q = quit)"
        if ($in -eq 'q') { return }
        if ($in) { $choice = [int]$in }
    }
    if ($choice -lt 1 -or $choice -gt $results.Count) { throw 'Invalid choice.' }
    $pick = $results[$choice - 1]

    $driverNames = switch ($pick.Source) {
        'Installed' { Write-Host "Driver '$($pick.Title)' is already installed."; @($pick.Title) }
        'Windows'   { @(Install-FromWindows $pick.Title) }
        'Catalog'   { @(Install-FromCatalog $pick $Words) }
    }

    if ($PrinterIP -and $driverNames.Count -gt 0) {
        Add-NetworkPrinter $driverNames[0] $PrinterIP
    }

    Write-Host "`nDone." -ForegroundColor Green
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    $global:LASTEXITCODE = 1
}
finally {
    if (-not $NoPause) { Read-Host "`nPress Enter to close" | Out-Null }
}
