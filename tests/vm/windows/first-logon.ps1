# First logon in the test VM: an SSH server, so the tests can drive Windows.
$ErrorActionPreference = 'Stop'
$media = Split-Path -Parent $MyInvocation.MyCommand.Path
Start-Transcript C:\first-logon.log
Expand-Archive (Join-Path $media 'OpenSSH-Win64.zip') 'C:\Program Files' -Force
Rename-Item 'C:\Program Files\OpenSSH-Win64' 'OpenSSH'
& 'C:\Program Files\OpenSSH\install-sshd.ps1'
New-Item -ItemType Directory -Force C:\ProgramData\ssh | Out-Null
Copy-Item (Join-Path $media 'id.pub') C:\ProgramData\ssh\administrators_authorized_keys
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force
Set-Service sshd -StartupType Automatic
Start-Service sshd
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
Stop-Transcript
