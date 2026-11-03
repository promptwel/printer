@echo off
rem Double-click this file to search for and install a printer driver.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-PrinterDriver.ps1" %*
