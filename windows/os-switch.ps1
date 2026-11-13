# os-switch for Windows: use the real Linux installation from inside Windows.
#
#   os-switch.ps1 install      set everything up (run as administrator)
#   os-switch.ps1 attach       hand the Linux disks to WSL, start Linux, show the tray icon
#   os-switch.ps1 detach       stop Linux and give the disks back
#   os-switch.ps1 linux        stop Linux cleanly, then restart the machine into Linux
#   os-switch.ps1 start-menu   (re)create the Start menu entries for Linux programs
#   os-switch.ps1 status       show what is set up and running
#   os-switch.ps1 uninstall    remove everything again
#
# Linux is only started when it was shut down. If it is hibernated, nothing is
# mounted: a frozen session breaks when its disks change underneath it.
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    # install: disk numbers to use instead of the detected ones.
    [int[]]$Disks,
    # install: the Alpine "minirootfs" archive, if it should not be downloaded.
    [string]$RootFs,
    # install: also put "Back to Linux" on the desktop.
    [switch]$DesktopShortcut,
    # attach: no tray icon; return once Linux runs (for scripts and tests).
    [switch]$NoTray
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Distro = 'os-switch'
$InstallDir = Join-Path $env:ProgramFiles 'os-switch'
$DataDir = Join-Path $env:ProgramData 'os-switch'
$ConfigFile = Join-Path $DataDir 'config.json'
$AttachTask = 'os-switch attach'
$LinuxTask = 'os-switch back to linux'
$MenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Linux'
$IconDir = Join-Path $env:LOCALAPPDATA 'os-switch\icons'
$Helper = '/usr/local/bin/os-switch-wsl'
# GPT partition types that mean "Linux": generic data, root (x86-64), home, LVM.
$LinuxPartitions = @(
    '{0fc63daf-8483-4772-8e79-3d69d8477de4}', '{4f68bce3-e8cd-4db1-96e7-fbcaf984b709}',
    '{933ac7e1-2eb4-4f13-b844-0e14e2aef915}', '{e6d6d379-f507-44c2-a23c-238f2a3df928}'
)
$RootFsUrl = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.2-x86_64.tar.gz'
$RootFsSha256 = '412454ed98025ad9cd910d13f3d448b184e81502baa83180e89f98d0f13674be'

# The few texts people see, in the languages of the Linux side.
$Texts = @{
    en = @{
        back = 'Back to Linux'; running = 'Linux is running'; refresh = 'Update Linux programs'
        hibernated = 'Linux is hibernated. Its programs are available after Linux was shut down or restarted into Windows.'
        failed = 'Linux did not start. Run "os-switch.ps1 status" in PowerShell for details.'
        confirm = 'Close all Linux programs and restart into Linux?'
    }
    de = @{
        back = 'Zurück zu Linux'; running = 'Linux läuft'; refresh = 'Linux-Programme aktualisieren'
        hibernated = 'Linux ist im Ruhezustand. Seine Programme gibt es wieder, wenn Linux heruntergefahren oder nach Windows neu gestartet wurde.'
        failed = 'Linux ist nicht gestartet. Details zeigt "os-switch.ps1 status" in der PowerShell.'
        confirm = 'Alle Linux-Programme schließen und nach Linux neu starten?'
    }
    pt = @{
        back = 'Voltar ao Linux'; running = 'O Linux está em execução'; refresh = 'Atualizar programas do Linux'
        hibernated = 'O Linux está hibernado. Os programas ficam disponíveis depois de desligar o Linux ou reiniciar para o Windows.'
        failed = 'O Linux não iniciou. Execute "os-switch.ps1 status" no PowerShell para detalhes.'
        confirm = 'Fechar todos os programas do Linux e reiniciar no Linux?'
    }
    es = @{
        back = 'Volver a Linux'; running = 'Linux está en ejecución'; refresh = 'Actualizar programas de Linux'
        hibernated = 'Linux está hibernado. Sus programas estarán disponibles cuando Linux se haya apagado o reiniciado hacia Windows.'
        failed = 'Linux no se inició. Ejecuta "os-switch.ps1 status" en PowerShell para ver detalles.'
        confirm = '¿Cerrar todos los programas de Linux y reiniciar en Linux?'
    }
    fr = @{
        back = 'Retour à Linux'; running = 'Linux est en cours d''exécution'; refresh = 'Mettre à jour les programmes Linux'
        hibernated = 'Linux est en hibernation. Ses programmes seront disponibles après l''arrêt de Linux ou un redémarrage vers Windows.'
        failed = 'Linux n''a pas démarré. Lancez « os-switch.ps1 status » dans PowerShell pour les détails.'
        confirm = 'Fermer tous les programmes Linux et redémarrer sous Linux ?'
    }
}
function Get-Text([string]$Key) {
    $lang = (Get-UICulture).TwoLetterISOLanguageName
    if (-not $Texts.ContainsKey($lang)) { $lang = 'en' }
    $Texts[$lang][$Key]
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) { throw 'This needs an administrator PowerShell.' }
}

# Run a command in the helper distribution; returns its output, sets $LASTEXITCODE.
function Invoke-Linux {
    # --exec: no shell in between, so arguments arrive exactly as given.
    & wsl.exe -d $Distro -u root --exec @args
}

# C:\Users\me -> /mnt/c/Users/me, the way WSL shows Windows drives.
function ConvertTo-LinuxPath([string]$Path) {
    '/mnt/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

function Get-Config {
    if (-not (Test-Path $ConfigFile)) { throw "Not set up yet. Run: os-switch.ps1 install" }
    Get-Content $ConfigFile -Raw | ConvertFrom-Json
}

# Disks that hold Linux partitions and that Windows does not start from.
function Find-LinuxDisks {
    Get-Disk | Where-Object {
        -not $_.IsBoot -and -not $_.IsSystem -and
        (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
            Where-Object { $LinuxPartitions -contains $_.GptType })
    }
}

# Disks are remembered by their unique id: numbers change between starts.
function Resolve-Disks {
    $wanted = (Get-Config).disks
    Get-Disk | Where-Object { $wanted -contains $_.UniqueId -and -not $_.IsBoot -and -not $_.IsSystem }
}

function Get-Wslg {
    # wslg.exe starts a Linux program without a console window. Where it is
    # depends on how WSL was installed.
    $found = @((Join-Path $env:ProgramFiles 'WSL\wslg.exe'), (Join-Path $env:SystemRoot 'System32\wslg.exe')) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { throw 'wslg.exe not found. Is WSL installed?' }
    $found
}

function Install-Distro {
    if ((& wsl.exe --list --quiet) -contains $Distro) { return }
    $archive = $RootFs
    if (-not $archive) {
        $archive = Join-Path $DataDir 'alpine-minirootfs.tar.gz'
        if (-not (Test-Path $archive)) {
            Write-Host "Downloading the helper system (Alpine Linux, 3 MB)..."
            Invoke-WebRequest -Uri $RootFsUrl -OutFile $archive -UseBasicParsing
        }
        if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $RootFsSha256) {
            Remove-Item $archive
            throw "The downloaded helper system does not match its checksum."
        }
    }
    & wsl.exe --import $Distro (Join-Path $DataDir 'distro') $archive --version 2
    if ($LASTEXITCODE -ne 0) { throw 'wsl --import failed.' }
}

function Install-LinuxScript {
    $source = ConvertTo-LinuxPath (Join-Path $InstallDir 'wsl\os-switch-wsl')
    Invoke-Linux /bin/sh -c "tr -d '\r' < '$source' > $Helper && chmod 755 $Helper"
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the Linux part into the helper system.' }
}

# A task that runs elevated, so that using it never shows a prompt.
function Register-ElevatedTask([string]$Name, [string]$Arguments, [switch]$AtLogOn) {
    $script = Join-Path $InstallDir 'os-switch.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" $Arguments"
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    $task = @{ TaskName = $Name; Action = $action; Principal = $principal; Settings = $settings; Force = $true }
    if ($AtLogOn) { $task.Trigger = New-ScheduledTaskTrigger -AtLogOn -User $user }
    Register-ScheduledTask @task | Out-Null
}

function New-BackShortcut([string]$Folder) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $Folder ((Get-Text back) + '.lnk')))
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $link.Arguments = "/run /tn `"$LinuxTask`""
    $link.WindowStyle = 7 # minimized: no console window flashing up
    $link.IconLocation = (Get-Wslg) + ',0'
    $link.Description = Get-Text back
    $link.Save()
}

function Install-All {
    Assert-Admin
    & wsl.exe --status *> $null
    if ($LASTEXITCODE -ne 0 -and -not (Get-Command wslg.exe -ErrorAction SilentlyContinue) -and
        -not (Test-Path (Join-Path $env:ProgramFiles 'WSL\wsl.exe'))) {
        throw 'WSL is not installed. Run "wsl --install --no-distribution", restart, and try again.'
    }

    New-Item -ItemType Directory -Force $InstallDir, $DataDir, (Join-Path $InstallDir 'wsl') | Out-Null
    if ($PSScriptRoot -ne $InstallDir) {
        Copy-Item (Join-Path $PSScriptRoot 'os-switch.ps1') $InstallDir -Force
        Copy-Item (Join-Path $PSScriptRoot 'wsl\os-switch-wsl') (Join-Path $InstallDir 'wsl') -Force
    }

    $found = if ($Disks) { Get-Disk -Number $Disks } else { Find-LinuxDisks }
    if (-not $found) { throw 'No disk with Linux partitions found (other than the one Windows starts from).' }
    foreach ($disk in $found) {
        Write-Host ("Linux disk: {0}  {1}  {2:N0} GB" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB))
    }
    @{ disks = @($found | ForEach-Object UniqueId) } | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8

    Install-Distro
    Install-LinuxScript

    Register-ElevatedTask $AttachTask 'attach' -AtLogOn
    Register-ElevatedTask $LinuxTask 'linux'
    New-Item -ItemType Directory -Force $MenuDir | Out-Null
    New-BackShortcut $MenuDir
    if ($DesktopShortcut) { New-BackShortcut ([Environment]::GetFolderPath('Desktop')) }

    Write-Host 'Installed. Starting Linux now...'
    Start-ScheduledTask -TaskName $AttachTask
}

# Attach the disks and start Linux. Returns the helper's exit code:
# 0 running, 3 hibernated (nothing mounted), anything else failed.
function Start-Linux {
    Assert-Admin
    foreach ($disk in Resolve-Disks) {
        # Fails when the disk is attached already; the helper decides what counts.
        & wsl.exe --mount "\\.\PHYSICALDRIVE$($disk.Number)" --bare *> $null
    }
    Invoke-Linux $Helper start | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0) { Dismount-Disks }
    $code
}

function Dismount-Disks {
    foreach ($disk in Resolve-Disks) {
        & wsl.exe --unmount "\\.\PHYSICALDRIVE$($disk.Number)" *> $null
    }
}

function Stop-Linux {
    Assert-Admin
    Invoke-Linux $Helper stop | Out-Host
    & wsl.exe --terminate $Distro *> $null
    Dismount-Disks
}

function Update-StartMenu {
    New-Item -ItemType Directory -Force $MenuDir, $IconDir | Out-Null
    $iconTarget = ConvertTo-LinuxPath $IconDir
    $shell = New-Object -ComObject WScript.Shell
    $wslg = Get-Wslg
    $kept = @((Get-Text back) + '.lnk')
    foreach ($line in (Invoke-Linux $Helper apps $iconTarget)) {
        $id, $name, $icon = $line -split "`t"
        if (-not $id -or -not $name) { continue }
        # The suffix tells them apart from Windows programs of the same name.
        $file = ($name -replace '[\\/:*?"<>|]', ' ').Trim() + ' (Linux).lnk'
        $link = $shell.CreateShortcut((Join-Path $MenuDir $file))
        $link.TargetPath = $wslg
        $link.Arguments = "-d $Distro -u root --shell-type none -- $Helper launch $id"
        $link.Description = "$name (Linux)"
        if ($icon) { $link.IconLocation = (Join-Path $IconDir $icon) }
        $link.Save()
        $kept += $file
    }
    # Entries of programs that were uninstalled in Linux.
    Get-ChildItem $MenuDir -Filter *.lnk | Where-Object { $kept -notcontains $_.Name } | Remove-Item
    Write-Host "$($kept.Count - 1) Linux programs in the Start menu."
}

# The sign-in task: start Linux, then stay in the notification area. The tray
# icon also keeps this process alive, and with it the one that keeps WSL from
# stopping an "idle" Linux whose only activity is background services.
function Start-Session {
    $code = Start-Linux
    if ($code -eq 0) {
        try { Update-StartMenu } catch { Write-Warning "Start menu entries were not updated: $_" }
    } else {
        # No entries that cannot start; they come back with the next successful start.
        Get-ChildItem $MenuDir -Filter '* (Linux).lnk' -ErrorAction SilentlyContinue | Remove-Item
    }
    if ($NoTray) { return $code }

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $keepAlive = $null
    if ($code -eq 0) {
        $keepAlive = Start-Process wsl.exe -WindowStyle Hidden -PassThru `
            -ArgumentList "-d $Distro -u root --exec /bin/sleep 2147483647"
    }
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Wslg))
    $state = if ($code -eq 0) { Get-Text running } elseif ($code -eq 3) { Get-Text hibernated } else { Get-Text failed }
    $tray.Text = $state.Substring(0, [Math]::Min(63, $state.Length))
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $back = $menu.Items.Add((Get-Text back))
    $back.add_Click({
            $answer = [System.Windows.Forms.MessageBox]::Show((Get-Text confirm), 'os-switch', 'OKCancel', 'Question')
            if ($answer -eq 'OK') { Start-ScheduledTask -TaskName $LinuxTask }
        })
    if ($code -eq 0) {
        $refresh = $menu.Items.Add((Get-Text refresh))
        $refresh.add_Click({ try { Update-StartMenu } catch { } })
    }
    $tray.ContextMenuStrip = $menu
    $tray.Visible = $true
    if ($code -ne 0) { $tray.ShowBalloonTip(15000, 'os-switch', $state, 'Warning') }
    try {
        [System.Windows.Forms.Application]::Run()
    } finally {
        $tray.Dispose()
        if ($keepAlive -and -not $keepAlive.HasExited) { $keepAlive.Kill() }
    }
    $code
}

# Windows only kills WSL when it restarts. Stop Linux properly first, so its
# services shut down and its filesystems are unmounted.
function Restart-ToLinux {
    Stop-Linux
    Stop-ScheduledTask -TaskName $AttachTask -ErrorAction SilentlyContinue
    & shutdown.exe /r /t 0
}

function Show-Status {
    $installed = Test-Path $ConfigFile
    Write-Host "Set up:        $installed"
    if (-not $installed) { return }
    foreach ($disk in Resolve-Disks) {
        Write-Host ("Linux disk:    {0}  {1}" -f $disk.Number, $disk.FriendlyName)
    }
    $state = (Invoke-Linux $Helper status 2>$null)
    Write-Host "Linux in WSL:  $state"
    $count = @(Get-ChildItem $MenuDir -Filter '* (Linux).lnk' -ErrorAction SilentlyContinue).Count
    Write-Host "Start menu:    $count programs"
    $task = Get-ScheduledTask -TaskName $AttachTask -ErrorAction SilentlyContinue
    Write-Host "Sign-in task:  $(if ($task) { $task.State } else { 'missing' })"
}

function Uninstall-All {
    Assert-Admin
    if (Test-Path $ConfigFile) { Stop-Linux }
    foreach ($name in $AttachTask, $LinuxTask) {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
    & wsl.exe --unregister $Distro *> $null
    $desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) ((Get-Text back) + '.lnk')
    Remove-Item $desktopLink, $MenuDir, (Split-Path $IconDir), $DataDir, $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Removed. The Linux installation itself was not changed.'
}

switch ($Command) {
    'install' { Install-All }
    'attach' { exit (Start-Session) }
    'detach' { Stop-Linux; Stop-ScheduledTask -TaskName $AttachTask -ErrorAction SilentlyContinue }
    'linux' { Restart-ToLinux }
    'start-menu' { Update-StartMenu }
    'status' { Show-Status }
    'uninstall' { Uninstall-All }
    default { throw "Unknown command: $Command. See the top of this file." }
}
