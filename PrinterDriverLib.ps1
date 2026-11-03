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
    $vendor  = Find-Vendor $Name
    if ($results.Count -eq 0 -and -not $vendor) {
        Write-Log "No driver found for '$Name'. Try fewer words (e.g. 'LaserJet M404'), or check the vendor's website." 'Yellow'
    } elseif ($results.Count -eq 0) {
        Write-Log "Nothing for '$Name' in Windows or Microsoft's catalog. Use the $($vendor.Name) download page below." 'Yellow'
    } else {
        Write-Log "Found $($results.Count) result(s)." 'Green'
    }
    if ($vendor) {
        $results += [pscustomobject]@{
            Source = 'Vendor'
            Title  = "$($vendor.Name) official download page (opens in your browser)"
            Id     = $vendor.SupportUrl
            Detail = 'then use "Install file/link"'
        }
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

        return Install-DriverFolder $dir $Words
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

# --------------------------------------------------------------------------
# Vendors (Canon / Epson / Brother) - settings live in vendors.json
# --------------------------------------------------------------------------
$global:PrinterLibDir = $PSScriptRoot

function Get-Vendors {
    $path = Join-Path $global:PrinterLibDir 'vendors.json'
    if (-not (Test-Path $path)) { return @() }
    $json = Get-Content -Raw -Path $path | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) {
        [pscustomobject]@{
            Name       = $p.Name
            Keywords   = @($p.Value.keywords)
            SupportUrl = $p.Value.supportUrl
            Publishers = @($p.Value.publishers)
            Hosts      = @($p.Value.hosts)
        }
    }
}

function Find-Vendor([string]$Name) {
    foreach ($v in Get-Vendors) {
        foreach ($k in $v.Keywords) {
            if ($Name.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $v }
        }
    }
}

function Test-AllowedHost([string]$HostName) {
    foreach ($v in Get-Vendors) {
        foreach ($d in $v.Hosts) {
            if ($HostName -eq $d -or $HostName.EndsWith(".$d")) { return $true }
        }
    }
    return $false
}

# Opens a web page in the user's normal (non-admin) browser. Going through explorer.exe avoids
# starting the browser with administrator rights.
function Open-VendorPage([string]$Url) {
    if ($Url -notmatch '^https://') { throw 'Refusing to open a non-https link.' }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $Url
    Write-Log "Opened $Url in your browser."
    Write-Log 'Find your model, download the Windows driver, then use "Install file/link" with the downloaded file.'
}

# The file must have a valid digital signature from Microsoft or one of the vendors in vendors.json.
function Assert-TrustedSignature([string]$File) {
    $sig = Get-AuthenticodeSignature -FilePath $File
    if ($sig.Status -ne 'Valid') {
        throw "'$([IO.Path]::GetFileName($File))' has no valid digital signature ($($sig.Status)). Not installing."
    }
    $subject = $sig.SignerCertificate.Subject
    $cn = [regex]::Match($subject, 'CN=(?:"([^"]+)"|([^,]+))')
    $signer = if ($cn.Groups[1].Success) { $cn.Groups[1].Value } else { $cn.Groups[2].Value.Trim() }

    $trusted = @('Microsoft Corporation') + @(Get-Vendors | ForEach-Object { $_.Publishers })
    foreach ($t in $trusted) {
        if ($t -and $signer -match ('^' + [regex]::Escape($t) + '(\W|$)')) { return $signer }
    }
    throw ("'$([IO.Path]::GetFileName($File))' is signed by '$signer', which is not a trusted publisher. " +
           "Not installing. (If you trust them, add the name to vendors.json.)")
}

function Get-SevenZip {
    $c = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") {
        if ($p -and (Test-Path $p)) { return $p }
    }
}

# Printer model names from a driver .inf (handles %Name% string substitution).
function Get-InfModels([string]$InfPath, [string[]]$Words) {
    $lines = Get-Content -Path $InfPath
    $strings = @{}
    $section = ''
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+?)\]') { $section = $Matches[1]; continue }
        if ($section -like 'Strings*' -and $l -match '^\s*([^;=\s]+)\s*=\s*"?(.*?)"?\s*(;.*)?$') {
            $strings[$Matches[1]] = $Matches[2]
        }
    }
    $found = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $section = ''
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+?)\]') { $section = $Matches[1]; continue }
        if ($section -match '^(Strings|Version|Manufacturer|SourceDisks|DestinationDirs|ControlFlags)') { continue }
        if ($l -match '^\s*(?:%([^%]+)%|"([^"]+)")\s*=\s*[^\s,;]+\s*,') {
            $name = if ($Matches[1]) { $strings[$Matches[1]] } else { $Matches[2] }
            if ($name -and (Test-AllWords $name $Words)) { [void]$found.Add($name.Trim()) }
        }
    }
    return @($found)
}

# Add every .inf under $Dir to the Windows driver store, then register the matching printer models.
function Install-DriverFolder([string]$Dir, [string[]]$Words) {
    $out  = & pnputil.exe /add-driver (Join-Path $Dir '*.inf') /subdirs /install 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Log $out.Trim()
    if ($code -notin 0, 3010) { Write-Log "WARNING: pnputil exited with code $code (continuing)." 'Yellow' }

    $installed = @()
    if ($Words.Count -eq 0) {
        Write-Log 'Driver added to the Windows driver store. (Type the printer model in the search box to also register it by name.)' 'Yellow'
        return $installed
    }
    Write-Step 'Registering printer driver'
    foreach ($inf in Get-ChildItem -Path $Dir -Filter *.inf -Recurse) {
        foreach ($model in Get-InfModels $inf.FullName $Words) {
            try {
                Add-PrinterDriver -Name $model -InfPath $inf.FullName
                Write-Log "  Registered: $model" 'Green'
                $installed += $model
            } catch { <# not every listed name can be registered #> }
        }
    }
    if ($installed.Count -eq 0) {
        Write-Log ("WARNING: The driver was added to the Windows driver store, but no model matching " +
            "'$($Words -join ' ')' could be registered by name. Plug in the printer or use " +
            "Settings > Printers > Add device; Windows will now find the driver itself.") 'Yellow'
    }
    return $installed
}

# Install a driver the user downloaded from Canon / Epson / Brother (local file, or https link).
# Supports .exe .msi .cab .zip. Tries to pull the driver (.inf) files out of the package and
# install just those, silently. If that isn't possible it runs the vendor installer normally.
function Install-FromPackage([string]$Source, [string[]]$Words) {
    $work = Join-Path $env:TEMP ("PrinterDriver_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $Source = $Source.Trim().Trim('"')
        if ($Source -match '^https?://') {
            $uri = [uri]$Source
            if ($uri.Scheme -ne 'https') { throw 'Only https links are allowed.' }
            if (-not (Test-AllowedHost $uri.Host)) {
                throw "'$($uri.Host)' is not a known Canon / Epson / Brother download site. (Add it to vendors.json if you trust it.)"
            }
            $leaf = [IO.Path]::GetFileName($uri.AbsolutePath)
            if (-not $leaf) { $leaf = 'driver.bin' }
            $file = Join-Path $work $leaf
            Write-Step "Downloading $leaf from $($uri.Host)"
            Invoke-WebRequest -UseBasicParsing -Uri $Source -OutFile $file -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        } else {
            if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "File not found: $Source" }
            $file = (Resolve-Path -LiteralPath $Source).Path
        }

        $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($ext -notin '.exe', '.msi', '.cab', '.zip') { throw "Unsupported file type '$ext' (use .exe, .msi, .cab or .zip)." }

        if ($ext -eq '.zip') {
            Write-Log 'A .zip has no digital signature to check; Windows still refuses unsigned drivers.' 'Yellow'
        } else {
            Write-Step 'Verifying digital signature'
            $signer = Assert-TrustedSignature $file
            Write-Log "Signature OK (signed by $signer)." 'Green'
        }

        Write-Step 'Extracting driver files'
        $dir = Join-Path $work 'extracted'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $extracted = $true
        switch ($ext) {
            '.zip' { Expand-Archive -LiteralPath $file -DestinationPath $dir -Force }
            '.cab' { & expand.exe $file -F:* $dir | Out-Null }
            '.msi' { Start-Process msiexec.exe -ArgumentList @('/a', "`"$file`"", '/qn', "TARGETDIR=`"$dir`"") -Wait }
            '.exe' {
                $7z = Get-SevenZip
                if ($7z) { & $7z x -y "-o$dir" $file | Out-Null }
                else { $extracted = $false; Write-Log '7-Zip not found (free from 7-zip.org); it lets this tool unpack vendor installers silently.' 'Yellow' }
            }
        }

        $hasInf = $extracted -and (Get-ChildItem -Path $dir -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($hasInf) {
            Write-Step 'Installing driver (no installer wizard)'
            return Install-DriverFolder $dir $Words
        }

        if ($ext -eq '.zip' -or $ext -eq '.cab') { throw 'No driver (.inf) files found inside the package.' }

        Write-Log 'Could not unpack this installer. Running the vendor installer instead; you will need to click through it.' 'Yellow'
        if ($ext -eq '.msi') { Start-Process msiexec.exe -ArgumentList @('/i', "`"$file`"") -Wait }
        else                 { Start-Process -FilePath $file -Wait }
        return @()
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-DriverPackage([string]$Source, [string[]]$Words, [string]$PrinterIP) {
    $names = @(Install-FromPackage $Source $Words | Where-Object { $_ })
    if ($PrinterIP -and $names.Count -gt 0) { Add-NetworkPrinter $names[0] $PrinterIP }
    Write-Log "`nDone." 'Green'
}

# Install one search result, optionally creating a network printer.
function Install-Selected($Pick, [string[]]$Words, [string]$PrinterIP) {
    $driverNames = switch ($Pick.Source) {
        'Installed' { Write-Log "Driver '$($Pick.Title)' is already installed."; @($Pick.Title) }
        'Windows'   { @(Install-FromWindows $Pick.Title) }
        'Catalog'   { @(Install-FromCatalog $Pick $Words) }
        'Vendor'    { Open-VendorPage $Pick.Id; @() }
    }
    $driverNames = @($driverNames | Where-Object { $_ })
    if ($PrinterIP -and @($driverNames).Count -gt 0) {
        Add-NetworkPrinter @($driverNames)[0] $PrinterIP
    }
    Write-Log "`nDone." 'Green'
}
