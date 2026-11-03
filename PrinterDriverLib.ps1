# Shared logic for Install-PrinterDriver.ps1 (command line) and
# Install-PrinterDriver-GUI.ps1 (window). Dot-source this file; don't run it directly.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# If $global:LogSink is set (the GUI does this), log lines go there. Otherwise to the console.
function Write-Log([string]$Text, [string]$Color = 'Gray') {
    if ($global:LogSink) { & $global:LogSink $Text }
    else { Write-Host $Text -ForegroundColor $Color }
}

function Write-Step([string]$Text) { Write-Log "`n==> $Text" 'Cyan' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Words([string]$Name) {
    @($Name -split '\s+' | Where-Object { $_ })
}

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

# Search everywhere. Returns an array of result objects (possibly empty).
function Search-All([string]$Name) {
    $Words = Get-Words $Name
    if ($Words.Count -eq 0) { throw 'No printer name given.' }

    Write-Step "Searching for '$Name'"
    $results = @()
    $results += Search-Installed $Words
    $results += Search-Inbox $Words | Where-Object { $_.Title -notin $results.Title }
    try   { $results += Search-Catalog $Name $Words }
    catch { Write-Log "WARNING: Microsoft Update Catalog search failed: $($_.Exception.Message)" 'Yellow' }

    $results = @($results)
    if ($results.Count -eq 0) {
        Write-Log "No driver found for '$Name'. Try fewer words (e.g. 'LaserJet M404'), or check the vendor's website." 'Yellow'
    } else {
        Write-Log "Found $($results.Count) result(s)." 'Green'
    }
    return $results
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
                Write-Log "WARNING: skipping non-Microsoft host: $h" 'Yellow'; continue
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
        Write-Log 'Signature OK.' 'Green'

        Write-Step 'Extracting and installing driver package'
        $dir = Join-Path $work 'extracted'
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($c in $cabs) { & expand.exe $c -F:* $dir | Out-Null }

        $out  = & pnputil.exe /add-driver (Join-Path $dir '*.inf') /subdirs /install 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Log $out.Trim()
        if ($code -notin 0, 3010) { Write-Log "WARNING: pnputil exited with code $code (continuing)." 'Yellow' }

        Write-Step 'Registering printer driver'
        $installed = @()
        foreach ($inf in Get-ChildItem -Path $dir -Filter *.inf -Recurse) {
            foreach ($model in Get-QuotedNames $inf.FullName $Words) {
                try {
                    Add-PrinterDriver -Name $model -InfPath $inf.FullName
                    Write-Log "  Registered: $model" 'Green'
                    $installed += $model
                } catch { <# not every quoted string is a model name #> }
            }
        }
        if ($installed.Count -eq 0) {
            Write-Log ("WARNING: The driver package was installed into the Windows driver store, but no model " +
                "matching '$($Words -join ' ')' could be registered by name. Plug in the printer " +
                "or use Settings > Printers > Add device; Windows will now find the driver itself.") 'Yellow'
        }
        return $installed
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Add-NetworkPrinter([string]$DriverName, [string]$IP) {
    if ($IP -notmatch '^[A-Za-z0-9\.\-:]+$') { throw "'$IP' is not a valid IP address or host name." }
    Write-Step "Creating network printer at $IP"
    $port = "IP_$IP"
    if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $port -PrinterHostAddress $IP
    }
    Add-Printer -Name $DriverName -DriverName $DriverName -PortName $port
    Write-Log "Printer '$DriverName' added on $port." 'Green'
}

# Install one search result, optionally creating a network printer.
function Install-Selected($Pick, [string[]]$Words, [string]$PrinterIP) {
    $driverNames = switch ($Pick.Source) {
        'Installed' { Write-Log "Driver '$($Pick.Title)' is already installed."; @($Pick.Title) }
        'Windows'   { @(Install-FromWindows $Pick.Title) }
        'Catalog'   { @(Install-FromCatalog $Pick $Words) }
    }
    if ($PrinterIP -and @($driverNames).Count -gt 0) {
        Add-NetworkPrinter @($driverNames)[0] $PrinterIP
    }
    Write-Log "`nDone." 'Green'
}
