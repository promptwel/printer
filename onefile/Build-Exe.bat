@echo off
rem Builds PrinterDriverInstaller.exe from PrinterDriverInstaller.ps1 + Launcher.cs.
rem Uses the C# compiler that is already part of Windows (.NET Framework). Nothing to install.
setlocal
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo Could not find the .NET Framework compiler at:
  echo   %CSC%
  pause
  exit /b 1
)
"%CSC%" /nologo /target:winexe /platform:x64 /out:"%~dp0PrinterDriverInstaller.exe" /resource:"%~dp0PrinterDriverInstaller.ps1",payload.ps1 /reference:System.dll "%~dp0Launcher.cs"
if errorlevel 1 (
  echo.
  echo BUILD FAILED. Send me the messages above.
  pause
  exit /b 1
)
echo.
echo Done: PrinterDriverInstaller.exe is ready in this folder. Double-click it.
pause
