<#
.SYNOPSIS
    Window version: type a printer name, pick a result, click Install.
#>
[CmdletBinding()]
param()

# ---- embedded settings (vendors.json) ----
$global:VendorJsonText = @'
{
  "Canon": {
    "keywords": ["canon", "pixma", "imageclass", "imagerunner", "selphy"],
    "supportUrl": "https://www.usa.canon.com/support",
    "publishers": ["Canon Inc"],
    "hosts": ["canon.com", "canon.ca", "canon.jp", "canon.co.uk", "canon-europe.com", "canon.com.au", "c-wss.com"]
  },
  "Epson": {
    "keywords": ["epson", "ecotank", "workforce"],
    "supportUrl": "https://epson.com/support",
    "publishers": ["SEIKO EPSON CORPORATION"],
    "hosts": ["epson.com", "epson.ca", "epson.net", "epson.co.uk", "epson.eu", "epson-europe.com", "epson.com.au"]
  },
  "Brother": {
    "keywords": ["brother", "hl-", "dcp-", "mfc-"],
    "supportUrl": "https://support.brother.com/",
    "publishers": ["Brother Industries"],
    "hosts": ["brother.com", "brother-usa.com", "brother.ca", "brother.co.uk", "brother.eu"]
  }
}
'@

# ---- embedded shared library (PrinterDriverLib.ps1) ----
$LibBlock = {
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
if (-not $global:PrinterLibDir) { $global:PrinterLibDir = $PSScriptRoot }

# Reads vendors.json from the tool's folder if present; otherwise uses the copy embedded in the
# single-file build ($global:VendorJsonText).
function Get-Vendors {
    $text = $null
    if ($global:PrinterLibDir) {
        $path = Join-Path $global:PrinterLibDir 'vendors.json'
        if (Test-Path $path) { $text = Get-Content -Raw -Path $path }
    }
    if (-not $text) { $text = $global:VendorJsonText }
    if (-not $text) { return @() }
    $json = $text | ConvertFrom-Json
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

function Test-HasInf([string]$Dir) {
    [bool](Get-ChildItem -Path $Dir -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Unzip with built-in .NET (no 7-Zip). Refuses entries that would land outside $Dest.
function Expand-ZipSafe([string]$Zip, [string]$Dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Dest).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($e in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Dest $e.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe path inside archive: $($e.FullName)"
            }
            if ([string]::IsNullOrEmpty($e.Name)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }
            New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    }
    finally { $archive.Dispose() }
}

# Many vendor .exe installers are self-extractors with one or more CAB archives packed inside.
# Find them by their header, cut them out, and unpack them with Windows' built-in expand.exe.
function Expand-EmbeddedCabs([string]$File, [string]$Dest) {
    if (-not ('PkgCarver' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
public static class PkgCarver {
    public static int CarveCabs(string src, string outDir) {
        int count = 0;
        using (FileStream fs = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            long len = fs.Length;
            byte[] buf = new byte[1 << 20];
            List<long> hits = new List<long>();
            long pos = 0;
            while (pos < len) {
                fs.Position = pos;
                int read = fs.Read(buf, 0, buf.Length);
                if (read <= 0) break;
                for (int i = 0; i + 4 <= read; i++) {
                    if (buf[i] == 0x4D && buf[i+1] == 0x53 && buf[i+2] == 0x43 && buf[i+3] == 0x46) hits.Add(pos + i);
                }
                if (pos + read >= len) break;
                pos += read - 3;
            }
            long lastEnd = 0;
            byte[] hdr = new byte[36];
            foreach (long h in hits) {
                if (h < lastEnd || h + 36 > len) continue;
                fs.Position = h;
                if (fs.Read(hdr, 0, 36) < 36) continue;
                uint reserved = BitConverter.ToUInt32(hdr, 4);
                uint size = BitConverter.ToUInt32(hdr, 8);
                if (reserved != 0 || hdr[24] != 3 || hdr[25] != 1) continue;
                if (size < 36 || h + size > len) continue;
                string path = Path.Combine(outDir, "embedded_" + (count + 1) + ".cab");
                fs.Position = h;
                using (FileStream o = new FileStream(path, FileMode.Create, FileAccess.Write)) {
                    long remaining = size;
                    byte[] cp = new byte[1 << 16];
                    while (remaining > 0) {
                        int n = fs.Read(cp, 0, (int)Math.Min((long)cp.Length, remaining));
                        if (n <= 0) break;
                        o.Write(cp, 0, n);
                        remaining -= n;
                    }
                }
                lastEnd = h + size;
                count++;
            }
        }
        return count;
    }
}
'@
    }
    $n = [PkgCarver]::CarveCabs($File, $Dest)
    if ($n -eq 0) { throw 'no embedded CAB archives found' }
    foreach ($cab in Get-ChildItem -Path $Dest -Filter 'embedded_*.cab') {
        $sub = Join-Path $Dest ([IO.Path]::GetFileNameWithoutExtension($cab.Name))
        New-Item -ItemType Directory -Path $sub | Out-Null
        & expand.exe $cab.FullName -F:* $sub | Out-Null
    }
}

# Last unpacking resort: 7-Zip. If missing, install it once through Windows Package Manager (winget),
# which checks the package hash itself.
function Expand-With7Zip([string]$File, [string]$Dest) {
    $sevenZip = Get-SevenZip
    if (-not $sevenZip) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) { throw '7-Zip is not installed and winget is not available' }
        Write-Log '    installing 7-Zip (free) with Windows Package Manager...'
        & $winget.Source install --id 7zip.7zip -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $sevenZip = Get-SevenZip
        if (-not $sevenZip) { throw 'could not install 7-Zip' }
    }
    & $sevenZip x -y "-o$Dest" $File | Out-Null
}

# Try to get the driver (.inf) files out of a vendor .exe, from cheapest/safest method to heaviest.
# Returns the folder holding them, or $null if the installer can't be unpacked.
function Expand-Installer([string]$File, [string]$Work) {
    $tiers = @(
        @{ Label = 'as a zip archive';          Action = { param($f, $d) Expand-ZipSafe $f $d } },
        @{ Label = 'by finding embedded CABs';  Action = { param($f, $d) Expand-EmbeddedCabs $f $d } },
        @{ Label = 'with 7-Zip';                Action = { param($f, $d) Expand-With7Zip $f $d } }
    )
    $n = 0
    foreach ($t in $tiers) {
        $n++
        $d = Join-Path $Work "unpack$n"
        New-Item -ItemType Directory -Path $d | Out-Null
        Write-Log "  Trying to unpack $($t.Label)..."
        try { & $t.Action $File $d } catch { Write-Log "    not possible: $($_.Exception.Message)" }
        if (Test-HasInf $d) { Write-Log "  Unpacked $($t.Label)." 'Green'; return $d }
    }
    return $null
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
# Supports .exe .msi .cab .zip. Pulls the driver (.inf) files out of the package (built-in Windows
# tools first, 7-Zip only if needed) and installs just those, silently. Only if that is impossible
# does it run the vendor installer normally.
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
        $dir = $null
        switch ($ext) {
            '.zip' {
                $dir = Join-Path $work 'unpack'
                New-Item -ItemType Directory -Path $dir | Out-Null
                Expand-ZipSafe $file $dir
            }
            '.cab' {
                $dir = Join-Path $work 'unpack'
                New-Item -ItemType Directory -Path $dir | Out-Null
                & expand.exe $file -F:* $dir | Out-Null
            }
            '.msi' {
                $dir = Join-Path $work 'unpack'
                New-Item -ItemType Directory -Path $dir | Out-Null
                Start-Process msiexec.exe -ArgumentList @('/a', "`"$file`"", '/qn', "TARGETDIR=`"$dir`"") -Wait
            }
            '.exe' { $dir = Expand-Installer $file $work }
        }

        $hasInf = $dir -and (Test-HasInf $dir)
        if ($hasInf) {
            Write-Step 'Installing driver (no installer wizard)'
            return Install-DriverFolder $dir $Words
        }

        if ($ext -eq '.zip' -or $ext -eq '.cab') { throw 'No driver (.inf) files found inside the package.' }

        Write-Log 'This installer cannot be unpacked automatically (it uses a private format). Running the vendor installer normally as a last resort; you will need to click through it.' 'Yellow'
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
}
$lib = $LibBlock.ToString()
. $LibBlock

# Ask for administrator rights once, up front.
if (-not (Test-Admin)) {
    Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Hide the black console window behind the GUI.
try {
    Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
'@
    [void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)
} catch { }

# ---------------------------------------------------------------- UI
$form = New-Object Windows.Forms.Form
$form.Text = 'Printer Driver Installer'
$form.ClientSize = New-Object Drawing.Size(744, 580)
$form.MinimumSize = New-Object Drawing.Size(640, 520)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 9)

$lblName = New-Object Windows.Forms.Label
$lblName.Text = 'Printer name:'; $lblName.Location = '12,17'; $lblName.AutoSize = $true

$txtSearch = New-Object Windows.Forms.TextBox
$txtSearch.Location = '100,13'; $txtSearch.Size = '520,24'; $txtSearch.Anchor = 'Top,Left,Right'

$btnSearch = New-Object Windows.Forms.Button
$btnSearch.Text = 'Search'; $btnSearch.Location = '630,11'; $btnSearch.Size = '102,28'; $btnSearch.Anchor = 'Top,Right'

$lv = New-Object Windows.Forms.ListView
$lv.Location = '12,50'; $lv.Size = '720,230'; $lv.Anchor = 'Top,Left,Right'
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
[void]$lv.Columns.Add('Source', 80)
[void]$lv.Columns.Add('Printer / driver', 440)
[void]$lv.Columns.Add('Details', 180)

$lblIP = New-Object Windows.Forms.Label
$lblIP.Text = 'Network printer IP (optional):'; $lblIP.Location = '12,297'; $lblIP.AutoSize = $true; $lblIP.Anchor = 'Top,Left'

$txtIP = New-Object Windows.Forms.TextBox
$txtIP.Location = '200,293'; $txtIP.Size = '150,24'; $txtIP.Anchor = 'Top,Left'

$btnInstall = New-Object Windows.Forms.Button
$btnInstall.Text = 'Install selected driver'; $btnInstall.Location = '522,289'; $btnInstall.Size = '210,34'
$btnInstall.Anchor = 'Top,Right'; $btnInstall.Enabled = $false

$lblPkg = New-Object Windows.Forms.Label
$lblPkg.Text = 'Driver file or link:'; $lblPkg.Location = '12,342'; $lblPkg.AutoSize = $true

$txtPkg = New-Object Windows.Forms.TextBox
$txtPkg.Location = '130,338'; $txtPkg.Size = '385,24'; $txtPkg.Anchor = 'Top,Left,Right'

$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = 'Browse...'; $btnBrowse.Location = '523,336'; $btnBrowse.Size = '90,28'; $btnBrowse.Anchor = 'Top,Right'

$btnPkg = New-Object Windows.Forms.Button
$btnPkg.Text = 'Install file/link'; $btnPkg.Location = '620,336'; $btnPkg.Size = '112,28'; $btnPkg.Anchor = 'Top,Right'

$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Location = '12,380'; $txtLog.Size = '720,160'; $txtLog.Multiline = $true; $txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'; $txtLog.Font = New-Object Drawing.Font('Consolas', 9)
$txtLog.Anchor = 'Top,Bottom,Left,Right'

$bar = New-Object Windows.Forms.ProgressBar
$bar.Location = '12,550'; $bar.Size = '720,18'; $bar.Style = 'Marquee'; $bar.Anchor = 'Bottom,Left,Right'
$bar.Visible = $false

$form.Controls.AddRange(@($lblName, $txtSearch, $btnSearch, $lv, $lblIP, $txtIP, $btnInstall, $lblPkg, $txtPkg, $btnBrowse, $btnPkg, $txtLog, $bar))
$form.AcceptButton = $btnSearch

# ---------------------------------------------------------------- background work
# Work runs in a separate runspace so the window never freezes.
$global:LogSink = { param($t) $txtLog.AppendText(([string]$t) + [Environment]::NewLine) }
$global:LogQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:Job = $null

function Add-LogText([string]$Text) {
    $txtLog.AppendText($Text + [Environment]::NewLine)
}

function Set-Busy([bool]$Busy) {
    $bar.Visible = $Busy
    $btnSearch.Enabled = -not $Busy
    $btnInstall.Enabled = (-not $Busy) -and ($lv.SelectedItems.Count -gt 0)
    $btnPkg.Enabled = -not $Busy
    $btnBrowse.Enabled = -not $Busy
    $txtSearch.Enabled = -not $Busy
    $form.UseWaitCursor = $Busy
}

function Start-Work([string]$Kind, [string]$Script, [object[]]$Arguments) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('LogQueue', $global:LogQueue)
    $rs.SessionStateProxy.SetVariable('VendorJsonText', $global:VendorJsonText)
    $rs.SessionStateProxy.SetVariable('PrinterLibDir', $global:PrinterLibDir)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $runner = {
        param($Lib, $Body, $ArgList)
        . ([scriptblock]::Create($Lib))
        $global:LogSink = { param($t) $global:LogQueue.Enqueue([string]$t) }
        try   { & ([scriptblock]::Create($Body)) @ArgList }
        catch { Write-Log "ERROR: $($_.Exception.Message)" 'Red' }
    }
    [void]$ps.AddScript($runner.ToString()).AddArgument($lib).AddArgument($Script).AddArgument($Arguments)

    $script:Job = [pscustomobject]@{ Kind = $Kind; PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
    Set-Busy $true
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $line = $null
    while ($global:LogQueue.TryDequeue([ref]$line)) { Add-LogText $line }

    if ($script:Job -and $script:Job.Handle.IsCompleted) {
        $job = $script:Job
        $script:Job = $null
        $output = @($job.PS.EndInvoke($job.Handle))
        $job.PS.Dispose(); $job.RS.Dispose()
        while ($global:LogQueue.TryDequeue([ref]$line)) { Add-LogText $line }

        if ($job.Kind -eq 'search') {
            $lv.Items.Clear()
            foreach ($r in $output) {
                if (-not $r.Title) { continue }
                $item = New-Object Windows.Forms.ListViewItem($r.Source)
                [void]$item.SubItems.Add($r.Title)
                [void]$item.SubItems.Add($r.Detail)
                $item.Tag = $r
                [void]$lv.Items.Add($item)
            }
            if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true }
        }
        Set-Busy $false
        Update-InstallButton
    }
})
$timer.Start()

# ---------------------------------------------------------------- actions
function Invoke-Search {
    $name = $txtSearch.Text.Trim()
    if (-not $name) { [void][Windows.Forms.MessageBox]::Show('Type a printer name first.', $form.Text); return }
    $lv.Items.Clear()
    Start-Work 'search' 'param($Name) Search-All $Name' @($name)
}

function Update-InstallButton {
    $btnInstall.Enabled = ($null -eq $script:Job) -and ($lv.SelectedItems.Count -gt 0)
    $isVendor = ($lv.SelectedItems.Count -gt 0) -and ($lv.SelectedItems[0].Tag.Source -eq 'Vendor')
    $btnInstall.Text = if ($isVendor) { 'Open vendor download page' } else { 'Install selected driver' }
}

function Invoke-InstallFromFile {
    $src = $txtPkg.Text.Trim().Trim('"')
    if (-not $src) { [void][Windows.Forms.MessageBox]::Show('Choose a downloaded driver file, or paste a vendor download link.', $form.Text); return }
    $words = Get-Words $txtSearch.Text
    $ip    = $txtIP.Text.Trim()
    $msg = "Install the driver from:`n$src"
    if ($words.Count -eq 0) { $msg += "`n`nTip: type the printer model in 'Printer name' first so it can be registered by name." }
    if ($ip) { $msg += "`n`nA network printer will also be created at $ip." }
    if ([Windows.Forms.MessageBox]::Show($msg, $form.Text, 'OKCancel', 'Question') -ne 'OK') { return }
    Start-Work 'install' 'param($Src, $Words, $IP) Install-DriverPackage $Src $Words $IP' @($src, $words, $ip)
}

function Invoke-Install {
    if ($lv.SelectedItems.Count -eq 0) { return }
    $pick  = $lv.SelectedItems[0].Tag
    if ($pick.Source -eq 'Vendor') {
        try { Open-VendorPage $pick.Id } catch { Add-LogText "ERROR: $($_.Exception.Message)" }
        return
    }
    $words = Get-Words $txtSearch.Text
    $ip    = $txtIP.Text.Trim()

    $msg = "Install '$($pick.Title)'?"
    if ($ip) { $msg += "`n`nA network printer will also be created at $ip." }
    if ([Windows.Forms.MessageBox]::Show($msg, $form.Text, 'OKCancel', 'Question') -ne 'OK') { return }

    Start-Work 'install' 'param($Pick, $Words, $IP) Install-Selected $Pick $Words $IP' @($pick, $words, $ip)
}

$btnSearch.Add_Click({ Invoke-Search })
$btnInstall.Add_Click({ Invoke-Install })
$lv.Add_SelectedIndexChanged({ Update-InstallButton })
$btnPkg.Add_Click({ Invoke-InstallFromFile })
$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Driver packages (*.exe;*.msi;*.cab;*.zip)|*.exe;*.msi;*.cab;*.zip|All files (*.*)|*.*'
    $dlg.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
    if ($dlg.ShowDialog() -eq 'OK') { $txtPkg.Text = $dlg.FileName }
})
$lv.Add_DoubleClick({ if ($btnInstall.Enabled) { Invoke-Install } })
$form.Add_FormClosing({ $timer.Stop() })

Add-LogText 'Type a printer name (e.g. "LaserJet M404"), click Search, pick a result, then click Install.'
Add-LogText 'Canon / Epson / Brother not found? Pick the vendor page, download the Windows driver, then use "Install file/link".'
[void]$form.ShowDialog()
