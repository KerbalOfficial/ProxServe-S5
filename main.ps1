# ProxServe-S5 Tray Launcher

$global:name         = "ProxServe-S5"
$global:launchStart  = Get-Date
$global:sessionStart = $null
$global:retryCount   = 0

# ---------- Single-instance mutex ----------
$mutexName  = "Global\$global:name"
$createdNew = $false
try { $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew) } catch { $createdNew = $false }
if (-not $createdNew) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Another $global:name instance is already running.", $global:name,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    exit 0
}

# ---------- Config file setup ----------
$cfgDir  = Join-Path $env:APPDATA $global:name
$cfgPath = Join-Path $cfgDir 'config.ini'
if (-not (Test-Path $cfgDir)) { New-Item -Path $cfgDir -ItemType Directory | Out-Null }
if (-not (Test-Path $cfgPath)) {
@"
PROXY_IP=127.0.0.1
PROXY_PORT=22

DYNAMIC_PORT=1080
MAX_TRIES=10
MAX_WAIT=0
SSH_USERNAME=$env:USERNAME
# leave SSH_KEYFILE blank to use ssh defaults
SSH_KEYFILE=
"@ | Set-Content -Path $cfgPath -Encoding UTF8
}

# ---------- Parse config ----------
$cfg = @{}
Get-Content -Path $cfgPath -ErrorAction SilentlyContinue | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)\s*$') {
            $cfg[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
}

# ---------- Apply config with normalization and defaults ----------
$dport = if ($cfg.ContainsKey('DYNAMIC_PORT')) { try { [int]$cfg['DYNAMIC_PORT'] } catch { 1080 } } else { 1080 }
$port  = if ($cfg.ContainsKey('PROXY_PORT'))   { try { [int]$cfg['PROXY_PORT'] } catch { 8022 } } else { 8022 }
$ip    = if ($cfg.ContainsKey('PROXY_IP'))     { $cfg['PROXY_IP'] } else { '192.168.1.127' }

# MAX_TRIES: blank or 0 = unlimited; otherwise int; default 10
if ($cfg.ContainsKey('MAX_TRIES')) {
    if ([string]::IsNullOrWhiteSpace($cfg['MAX_TRIES'])) { $maxTries = 0 }
    else { try { $maxTries = [int]$cfg['MAX_TRIES'] } catch { $maxTries = 10 } }
} else { $maxTries = 10 }

# SSH_USERNAME: blank -> $env:USERNAME
if ($cfg.ContainsKey('SSH_USERNAME')) {
    $user = if ([string]::IsNullOrWhiteSpace($cfg['SSH_USERNAME'])) { $env:USERNAME } else { $cfg['SSH_USERNAME'] }
} else { $user = $env:USERNAME }

# SSH_KEYFILE: optional; only add -i if present and non-blank
$key = if ($cfg.ContainsKey('SSH_KEYFILE')) { $cfg['SSH_KEYFILE'] } else { $null }
if ([string]::IsNullOrWhiteSpace($key)) { $key = $null }

# MAX_WAIT: seconds; 0 = unlimited (no forced kill)
$maxWait = if ($cfg.ContainsKey('MAX_WAIT')) { try { [int]$cfg['MAX_WAIT'] } catch { 0 } } else { 0 }

# ---------- UI assemblies ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- Shared stop signal (cross-runspace) ----------
$global:stopSignal = New-Object System.Threading.ManualResetEvent($false)

# ---------- NotifyIcon + menu ----------
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon    = [System.Drawing.SystemIcons]::Application
$notifyIcon.Visible = $true
$notifyIcon.Text    = $global:name

$menu   = New-Object System.Windows.Forms.ContextMenuStrip
$status = New-Object System.Windows.Forms.ToolStripMenuItem("Status")
$exit   = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")

$menu.Items.Add($status)
$menu.Items.Add($exit)
$notifyIcon.ContextMenuStrip = $menu

# ---------- Status window handler ----------
$status.Add_Click({
    $local_ip       = $ip
    $local_port     = $port
    $local_dport    = $dport
    $local_user     = $user
    $local_key      = $key
    $local_maxWait  = $maxWait
    $local_maxTries = $maxTries

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$global:name Status"
    $form.Size = New-Object System.Drawing.Size(520,320)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.Dock = 'Fill'
    $box.ScrollBars = 'Vertical'
    $box.Font = New-Object System.Drawing.Font("Consolas", 10)
    $form.Controls.Add($box)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000

    $timer.Add_Tick({
        try {
            $uptime     = (Get-Date) - $global:launchStart
            $sessUptime = if ($global:sessionStart) { (Get-Date) - $global:sessionStart } else { [TimeSpan]::Zero }
            $keyInfo    = if ($local_key) { $local_key } else { "default (ssh-agent/keys)" }
            $pidVal     = if ($global:childProc -ne $null -and -not $global:childProc.HasExited) { $global:childProc.Id } else { "N/A" }

            $lines = @()
            $lines += "🌐 Connected to:     $($local_ip):$($local_port)"
            $lines += "🛜 Forwarding to:    127.0.0.1:$($local_dport)"
            $lines += "👤 SSH user:         $($local_user)"
            $lines += "🔑 SSH Keyfile:      $($keyInfo)"
            $lines += "⏳ Max wait:         $($local_maxWait)s"
            $lines += ""
            $lines += ("⏱️ Launcher Uptime:  {0:hh\:mm\:ss}" -f $uptime)
            $lines += ("⏰ Last updated:     {0}" -f (Get-Date).ToString("MM/dd/yyyy HH:mm:ss"))

            $box.Text = [String]::Join([Environment]::NewLine, $lines)
        } catch {
            $box.Text = "Status error: $($_.Exception.Message)"
        }
    })

    $form.Add_FormClosing({ $timer.Stop(); $timer.Dispose() })
    $timer.Start()
    $form.ShowDialog() | Out-Null
})

# ---------- Globals for child process ----------
$global:stop       = $false     # remains UI-thread local; use stopSignal for cross-runspace
$global:psInstance = $null
$global:psHandle   = $null
$global:childProc  = $null

# ---------- Exit handler ----------
function StopProxy {
    try { $notifyIcon.Icon = [System.Drawing.SystemIcons]::Error; $notifyIcon.Text = "$($global:name) - exiting..." } catch {}

    $global:stop = $true

    if ($global:psHandle -ne $null) {
        try {
            if (-not $global:psHandle.AsyncWaitHandle.WaitOne(200)) {
                try { $global:psInstance.Stop() } catch {}
            }
            try { $global:psInstance.EndInvoke($global:psHandle) } catch {}
        } catch {}
        try { $global:psInstance.Dispose() } catch {}
    }

    if ($global:childProc -ne $null) {
        try {
            if (-not $global:childProc.HasExited) {
                $global:childProc.Kill()
                $global:childProc.WaitForExit(1000) | Out-Null
            }
        } catch {}
    }

    try { Get-Process -Name ssh -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() } } catch {}
    try { $notifyIcon.Visible = $false; $notifyIcon.Dispose() } catch {}
    [System.Windows.Forms.Application]::ExitThread()
}

$exit.Add_Click({ StopProxy })

# ---------- Background runspace ----------
$ps = [powershell]::Create()
$ps.AddScript({
    param($name, $port, $dport, $ip, $notifyIcon, $maxTries, $user, $key, $maxWait, $stopSignal)

    while ($true) {
        # if stop was signaled, exit
        if ($stopSignal.WaitOne(0)) { break }

        if ($maxTries -ne 0 -and $global:retryCount -ge $maxTries) {
            try {
                $notifyIcon.Icon = [System.Drawing.SystemIcons]::Error
                $notifyIcon.Text = "$($name) - reached max tries"
                $notifyIcon.ShowBalloonTip(3000, $name, "Failed: reached maximum tries ($maxTries). Quitting in 5s...", [System.Windows.Forms.ToolTipIcon]::Error)
            } catch {}

            # signal stop to UI thread and cooldown after 5 seconds
            Start-Sleep -Seconds 5
            $stopSignal.Set()
            break
        }

        # increment global retry counter (runspace-local)
        $global:retryCount++

        try {
            $notifyIcon.Icon = [System.Drawing.SystemIcons]::Warning
            $notifyIcon.Text = "$($name) - starting (attempt $($global:retryCount))..."
        } catch {}

        try {
            $args = @("-ND", $dport, "-p", $port, "$user@$ip")
            if ($key) { $args += @("-i", $key) }

            $proc = Start-Process ssh -ArgumentList $args -WindowStyle Hidden -PassThru
            $global:childProc    = $proc
            $global:sessionStart = Get-Date
        } catch {
            $global:childProc    = $null
            $global:sessionStart = $null
        }

        Start-Sleep -Seconds 1

        if ($global:childProc -ne $null -and -not $global:childProc.HasExited) {
            try {
                $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
                $notifyIcon.Text = "$($name) - running"
            } catch {}
        }

        # Monitor loop with configurable MAX_WAIT
        $i = 0
        while ($global:childProc -ne $null -and -not $global:childProc.HasExited -and -not $stopSignal.WaitOne(0)) {
            Start-Sleep -Seconds 1
            $i++
            if ($maxWait -gt 0 -and $i -ge $maxWait) {
                try { $global:childProc.Kill() } catch {}
                break
            }
        }

        if ($stopSignal.WaitOne(0) -and $global:childProc -ne $null) {
            try { if (-not $global:childProc.HasExited) { $global:childProc.Kill() } } catch {}
        }

        # only clear childProc when reconnecting
        if (-not $stopSignal.WaitOne(0)) {
            $global:childProc    = $null
            $global:sessionStart = $null
            try {
                $notifyIcon.Icon = [System.Drawing.SystemIcons]::Warning
                $notifyIcon.Text = "$($name) - reconnecting..."
            } catch {}
            Start-Sleep -Seconds 1
        }
    }

}).AddArgument($global:name).AddArgument($port).AddArgument($dport).AddArgument($ip).AddArgument($notifyIcon).AddArgument($maxTries).AddArgument($user).AddArgument($key).AddArgument($maxWait).AddArgument($global:stopSignal) | Out-Null

$global:psInstance = $ps
$global:psHandle   = $ps.BeginInvoke()

# ---------- UI stop watcher (timer) ----------
$exitTimer = New-Object System.Windows.Forms.Timer
$exitTimer.Interval = 500
$exitTimer.Add_Tick({
    if ($global:stopSignal.WaitOne(0)) {
        $exitTimer.Stop()
        StopProxy
    }
})
$exitTimer.Start()

# ---------- Run message loop ----------
[System.Windows.Forms.Application]::Run()

# ---------- Cleanup ----------
try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {}
