<#
.SYNOPSIS
    Tests for PrinterDriverLib.ps1. Changes nothing on the PC: no driver is installed.

.DESCRIPTION
    Covers search helpers, vendor matching, the https/host allow-list, digital-signature checks,
    zip-slip protection, embedded-CAB unpacking, .inf parsing and the Microsoft Update Catalog.
    The catalog tests use the live website, so a result can change over time. Pass -Offline to skip them.
    Real driver installs (which need administrator rights) were tested by hand; see the README.

.EXAMPLE
    .\tests\Test-PrinterDriverLib.ps1
    .\tests\Test-PrinterDriverLib.ps1 -Offline
#>
param([switch]$Offline)
$global:LogSink = { param($t) }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'PrinterDriverLib.ps1')
$ErrorActionPreference = 'Continue'
$global:LogSink = { param($t) }
$script:pass = 0; $script:fail = @()
function T([string]$name, [scriptblock]$body) {
    try { $r = & $body; if ($r -eq $false) { throw 'assertion false' }; $script:pass++ ; Write-Host "PASS $name" -ForegroundColor Green }
    catch { $script:fail += "$name :: $($_.Exception.Message)"; Write-Host "FAIL $name :: $($_.Exception.Message)" -ForegroundColor Red }
}
function Throws([scriptblock]$b, [string]$pattern) {
    try { & $b | Out-Null } catch { if ($_.Exception.Message -match $pattern) { return $true } else { throw "wrong error: $($_.Exception.Message)" } }
    throw 'did not throw'
}
$tmp = Join-Path $env:TEMP ('pdtest_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null

# ---- helpers
T 'Get-Words splits/trims'           { (Get-Words '  LaserJet   M404 ').Count -eq 2 }
T 'Get-Words empty'                  { (Get-Words '   ').Count -eq 0 }
T 'Test-AllWords case-insens'        { Test-AllWords 'HP LaserJet Pro' @('laserjet','PRO') }
T 'Test-AllWords missing word'       { -not (Test-AllWords 'HP LaserJet' @('laserjet','M404')) }
T 'Test-AllWords regex chars literal'{ -not (Test-AllWords 'abc' @('.*')) }

# ---- vendors
T 'Get-Vendors = 3'                  { @(Get-Vendors).Count -eq 3 }
T 'Find-Vendor Canon'                { (Find-Vendor 'Canon MF445dw').Name -eq 'Canon' }
T 'Find-Vendor pixma->Canon'         { (Find-Vendor 'PIXMA G3010').Name -eq 'Canon' }
T 'Find-Vendor EcoTank->Epson'       { (Find-Vendor 'EcoTank L3150').Name -eq 'Epson' }
T 'Find-Vendor HL-L2350->Brother'    { (Find-Vendor 'HL-L2350DW').Name -eq 'Brother' }
T 'Find-Vendor HP -> none'           { $null -eq (Find-Vendor 'HP LaserJet M404') }
T 'Test-AllowedHost ph.canon'        { Test-AllowedHost 'ph.canon' }
T 'Test-AllowedHost sub.epson.com'   { Test-AllowedHost 'download.epson.com' }
T 'Test-AllowedHost evil-suffix'     { -not (Test-AllowedHost 'evilcanon.com') }
T 'Test-AllowedHost canon.com.evil'  { -not (Test-AllowedHost 'canon.com.evil.com') }
T 'Test-AllowedHost google'          { -not (Test-AllowedHost 'google.com') }
T 'Get-VendorSearchUrl'              { (Get-VendorSearchUrl (Find-Vendor 'Canon') 'Canon MF445dw') -match '^https://www\.google\.com/search\?q=Canon%20MF445dw.*site%3Aph\.canon$' }
T 'Get-VendorSearchUrl injection'    { $u = Get-VendorSearchUrl (Find-Vendor 'Canon') 'x&evil=1 #y'; ($u -notmatch '&evil') -and ($u -match '%26evil') }
T 'Open-VendorPage rejects http'     { Throws { Open-VendorPage 'http://example.com' } 'non-https' }

# ---- input validation
T 'Add-NetworkPrinter bad IP'        { Throws { Add-NetworkPrinter 'X' '1.1.1.1; calc' } 'not a valid' }
T 'Add-NetworkPrinter bad IP 2'      { Throws { Add-NetworkPrinter 'X' '$(calc)' } 'not a valid' }
T 'Install-FromPackage http'         { Throws { Install-FromPackage 'http://ph.canon/x.exe' @() } 'Only https' }
T 'Install-FromPackage bad host'     { Throws { Install-FromPackage 'https://evil.example.com/x.exe' @() } 'not a known' }
T 'Install-FromPackage host-suffix'  { Throws { Install-FromPackage 'https://canon.com.evil.com/x.exe' @() } 'not a known' }
T 'Install-FromPackage missing file' { Throws { Install-FromPackage 'C:\nope\nothing.exe' @() } 'File not found' }
$txt = Join-Path $tmp 'a.txt'; 'x' | Set-Content $txt
T 'Install-FromPackage bad ext'      { Throws { Install-FromPackage $txt @() } 'Unsupported file type' }
T 'Install-FromPackage quoted path'  { Throws { Install-FromPackage "`"$txt`"" @() } 'Unsupported file type' }
T 'Search-All empty'                 { Throws { Search-All '   ' } 'No printer name' }

# ---- signatures
$unsigned = Join-Path $tmp 'unsigned.exe'; 'MZ' | Set-Content $unsigned
T 'Signature: unsigned rejected'     { Throws { Assert-TrustedSignature $unsigned } 'no valid digital signature' }
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (Test-Path $chrome) { T 'Signature: valid but untrusted signer rejected (Chrome/Google)' { Throws { Assert-TrustedSignature $chrome } 'not a trusted publisher' } }
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (Test-Path $edge) { T 'Signature: Microsoft Corporation accepted' { (Assert-TrustedSignature $edge) -match 'Microsoft Corporation' } }
T 'Signature: tampered copy rejected' {
    if (-not (Test-Path $edge)) { return $true }
    $c = Join-Path $tmp 'tampered.exe'; Copy-Item $edge $c; $fs=[IO.File]::OpenWrite($c); $fs.Seek(1000,'Begin')|Out-Null; $fs.WriteByte(0x41); $fs.Dispose()
    Throws { Assert-TrustedSignature $c } 'no valid digital signature|not a trusted'
}

# ---- zip handling
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function New-Zip($path, $entries) {
    $fs = [IO.File]::Create($path); $z = New-Object IO.Compression.ZipArchive($fs, 'Create')
    foreach ($k in $entries.Keys) { $e = $z.CreateEntry($k); $w = New-Object IO.StreamWriter($e.Open()); $w.Write($entries[$k]); $w.Dispose() }
    $z.Dispose(); $fs.Dispose()
}
$evil = Join-Path $tmp 'evil.zip'; New-Zip $evil @{ '..\..\zipslip_pwned.txt' = 'x'; 'ok.txt' = 'y' }
T 'Expand-ZipSafe blocks zip-slip' {
    $d = Join-Path $tmp 'ze'; New-Item -ItemType Directory $d | Out-Null
    $r = Throws { Expand-ZipSafe $evil $d } 'Unsafe path'
    $r -and -not (Test-Path (Join-Path $tmp '..\zipslip_pwned.txt')) -and -not (Test-Path (Join-Path $env:TEMP 'zipslip_pwned.txt'))
}
$inf = @'
[Version]
Signature="$Windows NT$"
[Manufacturer]
%Acme%=Acme,NTamd64
[Acme.NTamd64]
%Mod1%=Install1, ACME\PRINTERX100
"Acme X200 Series"=Install2, ACME\PRINTERX200
%Mod3%=Install3, ACME\OTHER
[Strings]
Acme="Acme Corp"
Mod1="Acme X100 Laser"
Mod3="Acme Z999"
'@
$good = Join-Path $tmp 'good.zip'; New-Zip $good @{ 'drv\acme.inf' = $inf; 'drv\readme.txt' = 'hi' }
T 'Expand-ZipSafe extracts' { $d = Join-Path $tmp 'zg'; New-Item -ItemType Directory $d | Out-Null; Expand-ZipSafe $good $d; Test-HasInf $d }
$noinf = Join-Path $tmp 'noinf.zip'; New-Zip $noinf @{ 'a.txt' = 'x' }
T 'Install-FromPackage zip w/o inf' { Throws { Install-FromPackage $noinf @('x') } 'No driver \(\.inf\) files' }
T 'Test-HasInf false'               { -not (Test-HasInf (Join-Path $tmp 'ze')) }

# ---- inf parsing
$infPath = Join-Path $tmp 'acme.inf'; Set-Content $infPath $inf
T 'Get-InfModels %Name% subst'      { 'Acme X100 Laser' -in @(Get-InfModels $infPath @('X100')) }
T 'Get-InfModels quoted literal'    { 'Acme X200 Series' -in @(Get-InfModels $infPath @('X200')) }
T 'Get-InfModels filter excludes'   { @(Get-InfModels $infPath @('X100','X200')).Count -eq 0 }
T 'Get-InfModels no manufacturer'   { 'Acme Corp' -notin @(Get-InfModels $infPath @('Acme')) }
T 'Get-QuotedNames'                 { 'Acme X200 Series' -in @(Get-QuotedNames $infPath @('X200')) }

# ---- embedded CAB carving (build a real CAB with makecab, bury it in junk)
$cabSrc = Join-Path $tmp 'cabsrc'; New-Item -ItemType Directory $cabSrc | Out-Null; Set-Content (Join-Path $cabSrc "pkg.inf") $inf; Set-Content (Join-Path $cabSrc "pkg.cat") "cat"
$ddf = Join-Path $tmp 'x.ddf'; Set-Content $ddf ".OPTION EXPLICIT`r`n.Set CabinetNameTemplate=x.cab`r`n.Set DiskDirectoryTemplate=$tmp`r`n.Set Cabinet=on`r`n.Set Compress=on`r`n`"$cabSrc\pkg.inf`" pkg.inf`r`n`"$cabSrc\pkg.cat`" pkg.cat"
Push-Location $tmp; makecab /F $ddf | Out-Null; Pop-Location
$cab = Join-Path $tmp 'x.cab'
T 'makecab produced cab'            { Test-Path $cab }
$blob = Join-Path $tmp 'fake_installer.exe'
$junk = New-Object byte[] 300000; (New-Object Random 5).NextBytes($junk)
$bytes = $junk + [IO.File]::ReadAllBytes($cab) + $junk; [IO.File]::WriteAllBytes($blob, $bytes)
T 'Expand-EmbeddedCabs finds inf'   { $d = Join-Path $tmp 'ec'; New-Item -ItemType Directory $d | Out-Null; Expand-EmbeddedCabs $blob $d; Test-HasInf $d }
T 'Expand-EmbeddedCabs none -> throws' { $d = Join-Path $tmp 'ec2'; New-Item -ItemType Directory $d | Out-Null; Throws { Expand-EmbeddedCabs $unsigned $d } 'no embedded CAB' }
T 'Expand-Installer tiers (zip fails, cab ok)' { $w = Join-Path $tmp 'ei'; New-Item -ItemType Directory $w | Out-Null; $r = Expand-Installer $blob $w; [bool]$r -and (Test-HasInf $r) }

if (-not $Offline) {
    # ---- catalog (network, throttled)
    $real = @{}
    foreach ($q in 'Lexmark MX410','HP LaserJet M404','Canon MF445dw','zzzzqq xx') { try { $real[$q] = @(Search-Catalog $q (Get-Words $q)) } catch { $real[$q] = $_ }; Start-Sleep -Milliseconds 1500 }
    T 'Catalog Lexmark: only Win10/11 printer rows' { $real['Lexmark MX410'].Count -gt 0 -and @($real['Lexmark MX410'] | ? { $_.Os -notmatch 'Windows (10|11)' }).Count -eq 0 }
    T 'Catalog HP fallback rows'         { $real['HP LaserJet M404'].Count -gt 0 -and $real['HP LaserJet M404'][0].Detail -match 'model not in title' }
    T 'Catalog HP rows are Win10/11'     { @($real['HP LaserJet M404'] | ? { $_.Os -notmatch 'Windows (10|11)' }).Count -eq 0 }
    T 'Catalog junk -> 0'                { $real['zzzzqq xx'].Count -eq 0 }
    T 'Catalog Canon -> 0 (no throw)'    { $real['Canon MF445dw'] -is [array] -and $real['Canon MF445dw'].Count -eq 0 }
    T 'Catalog ids are GUIDs'            { @($real['Lexmark MX410'] | ? { $_.Id -notmatch '^[0-9a-f\-]{36}$' }).Count -eq 0 }

    # ---- Search-All end to end
    $a = @(Search-All 'Canon MF445dw'); Start-Sleep 1
    T 'Search-All Canon has Vendor row last' { $a[-1].Source -eq 'Vendor' -and $a[-1].Id -match '^https://www\.google\.com/' }
    $b = @(Search-All 'Kyocera FS-1040'); Start-Sleep 1
    T 'Search-All Kyocera: catalog rows, no vendor row' { $b.Count -gt 0 -and @($b | ? Source -eq 'Vendor').Count -eq 0 }
    $c = @(Search-All 'qqqzzz nothing'); Start-Sleep 1
    T 'Search-All nonsense -> empty'     { $c.Count -eq 0 }

    # ---- catalog download path: link retrieval only (no install) for a Lexmark row
    T 'Catalog DownloadDialog returns microsoft/windowsupdate link' {
        $id = $real['Lexmark MX410'][0].Id
        $body = @{ updateIDs = '[{"size":0,"languages":"","uidInfo":"' + $id + '","updateID":"' + $id + '"}]' }
        $page = Invoke-WebRequest -UseBasicParsing -Method Post -Body $body -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'
        $urls = @([regex]::Matches($page.Content, "\.url\s*=\s*['""]([^'""]+)['""]") | % { $_.Groups[1].Value })
        Write-Host "     link: $($urls[0])"
        $urls.Count -gt 0 -and (([uri]$urls[0]).Host -match '(^|\.)(windowsupdate|microsoft)\.com$')
    }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n==== passed: $script:pass  failed: $($script:fail.Count)"
$script:fail | % { Write-Host "  - $_" -ForegroundColor Red }
if ($script:fail.Count) { exit 1 }
