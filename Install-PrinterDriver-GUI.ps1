<#
.SYNOPSIS
    Window version: type a printer name, pick a result, click Install.
#>
[CmdletBinding()]
param()

$lib = Join-Path $PSScriptRoot 'PrinterDriverLib.ps1'
. $lib

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

$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Location = '12,335'; $txtLog.Size = '720,205'; $txtLog.Multiline = $true; $txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'; $txtLog.Font = New-Object Drawing.Font('Consolas', 9)
$txtLog.Anchor = 'Top,Bottom,Left,Right'

$bar = New-Object Windows.Forms.ProgressBar
$bar.Location = '12,550'; $bar.Size = '720,18'; $bar.Style = 'Marquee'; $bar.Anchor = 'Bottom,Left,Right'
$bar.Visible = $false

$form.Controls.AddRange(@($lblName, $txtSearch, $btnSearch, $lv, $lblIP, $txtIP, $btnInstall, $txtLog, $bar))
$form.AcceptButton = $btnSearch

# ---------------------------------------------------------------- background work
# Work runs in a separate runspace so the window never freezes.
$global:LogQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:Job = $null

function Add-LogText([string]$Text) {
    $txtLog.AppendText($Text + [Environment]::NewLine)
}

function Set-Busy([bool]$Busy) {
    $bar.Visible = $Busy
    $btnSearch.Enabled = -not $Busy
    $btnInstall.Enabled = (-not $Busy) -and ($lv.SelectedItems.Count -gt 0)
    $txtSearch.Enabled = -not $Busy
    $form.UseWaitCursor = $Busy
}

function Start-Work([string]$Kind, [string]$Script, [object[]]$Arguments) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('LogQueue', $global:LogQueue)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $runner = {
        param($Lib, $Body, $ArgList)
        . $Lib
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

function Invoke-Install {
    if ($lv.SelectedItems.Count -eq 0) { return }
    $pick  = $lv.SelectedItems[0].Tag
    $words = Get-Words $txtSearch.Text
    $ip    = $txtIP.Text.Trim()

    $msg = "Install '$($pick.Title)'?"
    if ($ip) { $msg += "`n`nA network printer will also be created at $ip." }
    if ([Windows.Forms.MessageBox]::Show($msg, $form.Text, 'OKCancel', 'Question') -ne 'OK') { return }

    Start-Work 'install' 'param($Pick, $Words, $IP) Install-Selected $Pick $Words $IP' @($pick, $words, $ip)
}

$btnSearch.Add_Click({ Invoke-Search })
$btnInstall.Add_Click({ Invoke-Install })
$lv.Add_SelectedIndexChanged({ $btnInstall.Enabled = ($null -eq $script:Job) -and ($lv.SelectedItems.Count -gt 0) })
$lv.Add_DoubleClick({ if ($btnInstall.Enabled) { Invoke-Install } })
$form.Add_FormClosing({ $timer.Stop() })

Add-LogText 'Type a printer name (e.g. "LaserJet M404"), click Search, pick a result, then click Install.'
[void]$form.ShowDialog()
