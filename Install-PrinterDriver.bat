@echo off
rem Double-click this file to open the printer driver installer window.
rem (For the command-line version, run Install-PrinterDriver.ps1 in PowerShell.)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Install-PrinterDriver-GUI.ps1"
