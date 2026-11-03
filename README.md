# Printer driver auto-installer (Windows)

Type a printer name, pick a result, and the driver is downloaded and installed with
no Next / Accept clicks.

## Use

Double-click `Install-PrinterDriver.bat`, or from PowerShell:

```powershell
.\Install-PrinterDriver.ps1 "HP LaserJet M404"
.\Install-PrinterDriver.ps1 "Canon MF445dw" -PrinterIP 192.168.1.50 -Yes   # also add the network printer
```

You'll get **one** administrator (UAC) prompt, and that's all.

## Where it looks (in order)

1. Drivers already installed on the PC
2. Drivers built into Windows
3. Microsoft Update Catalog (official Microsoft-signed driver packages)

## Safety

- Downloads only from `*.windowsupdate.com` / `*.microsoft.com`.
- Refuses to install any file without a valid Microsoft digital signature.

## Limits

- Only finds drivers Microsoft publishes. A few models (some Canon/Epson/Brother, newer
  models) exist only on the vendor's site; the script will say "No driver found" for those.
  Vendor-specific lookups can be added later.
- Searches work best with short names ("LaserJet M404", not the full marketing name).
- USB printers: once the driver is installed, plug the printer in and Windows finishes setup.
- Parsing the Update Catalog web page is unofficial, so Microsoft changing that page could break the
  catalog search. The installed/built-in sources are unaffected.
