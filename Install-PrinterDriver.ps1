<#
.SYNOPSIS
    Command-line version: search for a printer by name, then download and silently install its driver.
    (Prefer Install-PrinterDriver-GUI.ps1 / Install-PrinterDriver.bat for the window version.)

.PARAMETER Name
    Printer name to search for, e.g. "HP LaserJet Pro M404". Prompted if omitted.

.PARAMETER PrinterIP
    Optional. If given, also creates a network printer at this IP using the new driver.

.PARAMETER Package
    Skip the search and install a driver you downloaded from Canon / Epson / Brother:
    a local file (.exe .msi .cab .zip) or an https link on a vendor site.
    Put the printer model in -Name so it can be registered by name.

.PARAMETER Yes
    Don't ask questions: take the first result.

.PARAMETER NoPause
    Don't wait for Enter at the end.

.EXAMPLE
    .\Install-PrinterDriver.ps1 "Canon MF445dw" -PrinterIP 192.168.1.50 -Yes

.EXAMPLE
    .\Install-PrinterDriver.ps1 "Brother HL-L2350DW" -Package "$env:USERPROFILE\Downloads\Y16E_C1-hostm-K1.EXE"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Name,
    [string]$PrinterIP,
    [string]$Package,
    [switch]$Yes,
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'PrinterDriverLib.ps1')

if (-not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Name)      { $argList += @('-Name', "`"$Name`"") }
    if ($PrinterIP) { $argList += @('-PrinterIP', "`"$PrinterIP`"") }
    if ($Package)   { $argList += @('-Package', "`"$Package`"") }
    if ($Yes)       { $argList += '-Yes' }
    if ($NoPause)   { $argList += '-NoPause' }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs
    exit
}

try {
    if ($Package) {
        Install-DriverPackage $Package (Get-Words $Name) $PrinterIP
        return
    }
    if (-not $Name) { $Name = Read-Host 'Printer name to search for (e.g. HP LaserJet M404)' }
    $Words   = Get-Words $Name
    $results = @(Search-All $Name)
    if ($results.Count -eq 0) { return }

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

    Install-Selected $results[$choice - 1] $Words $PrinterIP
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if (-not $NoPause) { Read-Host "`nPress Enter to close" | Out-Null }
}
