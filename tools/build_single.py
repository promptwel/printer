#!/usr/bin/env python3
"""Merge the GUI script, shared library and vendors.json into ONE self-contained PowerShell file.

    python3 tools/build_single.py   ->   onefile/PrinterDriverInstaller.ps1
"""
import json, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
gui = (root / 'Install-PrinterDriver-GUI.ps1').read_text()
lib = (root / 'PrinterDriverLib.ps1').read_text()
vendors = (root / 'vendors.json').read_text().strip()
json.loads(vendors)  # must be valid

assert "\n'@" not in vendors and "@'" not in vendors

# 1) Replace "load the library file" with "library embedded as a script block".
old_load = "$lib = Join-Path $PSScriptRoot 'PrinterDriverLib.ps1'\n. $lib\n"
new_load = (
    "# ---- embedded settings (vendors.json) ----\n"
    "$global:VendorJsonText = @'\n" + vendors + "\n'@\n\n"
    "# ---- embedded shared library (PrinterDriverLib.ps1) ----\n"
    "$LibBlock = {\n" + lib.rstrip('\n') + "\n}\n"
    "$lib = $LibBlock.ToString()\n"
    ". $LibBlock\n"
)
assert old_load in gui
out = gui.replace(old_load, new_load)

# 2) The background runspace must load the library from text, not from a file path,
#    and needs the same settings variables.
old = "        . $Lib\n"
assert old in out
out = out.replace(old, "        . ([scriptblock]::Create($Lib))\n")

old = "    $rs.SessionStateProxy.SetVariable('LogQueue', $global:LogQueue)\n"
assert old in out
out = out.replace(old, old +
    "    $rs.SessionStateProxy.SetVariable('VendorJsonText', $global:VendorJsonText)\n"
    "    $rs.SessionStateProxy.SetVariable('PrinterLibDir', $global:PrinterLibDir)\n")

dest = root / 'onefile' / 'PrinterDriverInstaller.ps1'
dest.parent.mkdir(exist_ok=True)
dest.write_text(out)
print(f'wrote {dest} ({len(out):,} bytes)')
