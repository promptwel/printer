# Printer driver auto-installer (Windows)

Type a printer name, pick a result, and the driver is downloaded and installed with
no Next / Accept clicks.

## Use

Double-click **`Install-PrinterDriver.bat`**. A window opens:

1. Type the printer name (e.g. `LaserJet M404`) and click **Search**.
2. Click the result you want.
3. (Optional) type the printer's IP address if it's a network printer.
4. Click **Install selected driver**.

You get **one** administrator (UAC) prompt when the window opens, and that's all.

Command-line version (same engine):

```powershell
.\Install-PrinterDriver.ps1 "Canon MF445dw" -PrinterIP 192.168.1.50 -Yes
```

Files: `Install-PrinterDriver-GUI.ps1` (window), `Install-PrinterDriver.ps1` (command line),
`PrinterDriverLib.ps1` (shared search/install code), `vendors.json` (vendor settings).
Keep all of them in the same folder.

## Canon, Epson and Brother

If you search for a Canon / Epson / Brother printer, the list ends with an extra row:
**"<Vendor> download page for '<your model>'"**. For these brands:

1. Select that row and click **Open page & auto-install**. Your browser opens a search for your model,
   limited to the vendor's support site, and the tool starts watching your Downloads folder (15 min,
   **Stop watching** cancels).
2. Download the Windows driver in the browser.
3. When the download finishes the tool picks it up, checks it is signed by the real vendor, unpacks
   the driver files and installs them, with no installer wizard.

Auto-install handles `.exe`, `.msi` and `.cab` only. A `.zip` has no signature, so use **Browse...**
and **Install file/link** for it (or for a file you downloaded earlier). Command line:
`.\Install-PrinterDriver.ps1 "Brother HL-L2350DW" -Package "C:\Users\you\Downloads\driver.exe"`

Notes:
- It does **not** click through the vendors' websites for you. Those sites change often and have no
  public search, so you pick and download the file; the tool does everything after that.
- Vendor `.exe` installers are unpacked with the lightest method that works, in this order:
  1. as a zip archive (built into Windows, no extra software),
  2. by finding CAB archives packed inside the `.exe` (also built into Windows),
  3. with 7-Zip. If it isn't installed, the tool installs it once, silently, through Windows
     Package Manager (`winget`), which verifies the download itself.

  Whichever works first is used, and then only the driver files are installed, with no wizard.
  Only if none of them can open the installer (some vendors use a private format) does the tool run
  the vendor's own installer, and then you have to click through it.
- Trusted signers, allowed download sites and each vendor's support page (set to the Philippines) are in `vendors.json`. Edit the `supportUrl` lines for another country.

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

## One file / one exe

The `onefile/` folder has everything merged into a single script, plus a way to make a single `.exe`:

- `onefile/PrinterDriverInstaller.ps1`: the whole tool in **one file** (right-click, Run with PowerShell).
- `onefile/Build-Exe.bat` + `Launcher.cs`: double-click `Build-Exe.bat` once to produce
  **`PrinterDriverInstaller.exe`** (the script is embedded inside it). It uses the compiler that
  already ships with Windows, so there is nothing to install. Keep the three files together while building.

The exe asks for administrator rights once, unpacks the script into `C:\ProgramData` (a folder normal
users can't modify), runs it, and deletes it again when you close the window.

Rebuild the single script after changing the sources: `python3 tools/build_single.py`.

Note: an unsigned `.exe` will usually make Windows SmartScreen (and sometimes antivirus) show a warning.
Click **More info > Run anyway**. Removing the warning needs a paid code-signing certificate.
