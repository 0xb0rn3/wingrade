# wingrade

Windows 8.1 -> Windows 10 unattended upgrade bootstrapper. Snapshots, suspends what's competing with setup.exe, upgrades silently, restores state after. Built for Windows 8.1 (build 6.3.x) specifically, refuses to run on anything else.

## Quick start

Run as Administrator on the target 8.1 box. Old TLS defaults on 8.1 kill the fetch against GitHub unless TLS1.2 is forced first, so that's baked in below:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; &([scriptblock]::Create((irm 'https://raw.githubusercontent.com/0xb0rn3/wingrade/main/wingrade.ps1'))) -NoReboot
```


```powershell for direct download 
&([scriptblock]::Create((irm 'https://raw.githubusercontent.com/0xb0rn3/wingrade/main/wingrade.ps1'))) -IsoUrl 'https://software.download.prss.microsoft.com/dbazure/Win10_22H2_EnglishInternational_x64v1.iso?t=b8852cb3-95f7-4fad-8a72-05b2ad6286d6&P1=1784842988&P2=602&P3=2&P4=WXG3U2T0LOzR3sNVPC%2fJUHCSfT7inCZ5qjeoxMW%2bL3AkDWIuql3qSgMn1hD2VH%2bx7thqF2q71gmT5HAbRwA9UQL85gs3aBoxFB2T7uedjWqztAc9dEpXJp708tLh8WdbYtoqb8EvWaI6GisBDEQfoQPzz6x0qK72%2fxqFCw5wY%2fIPKal3TqJLvq9cdocaUWYdtiMTRa8SzRE7MAztF%2flLXpLzOBCp4oAZoOnuieEBgCn694FDRSqROraFMcRw2SkmWWYfN7M6fE1g2agcU3Mn%2btU0cQ2kaWIH6KyjvoybeuavxrKiFrr3R7lxjGDvSXzqw2dzRIEVL%2fGuGTbRPjaRMA%3d%3d' -NoReboot
```

Drop `-NoReboot` to let it auto-restart and finish the upgrade on its own.

## What it does

- Confirms the OS is Windows 8.1 (6.3.x) before touching anything, hard exit otherwise
- Checks admin rights, 20GB free disk, internet, pending-reboot state, BitLocker status, AV presence
- Creates a System Restore point, exports `HKLM\SYSTEM` and `HKLM\SOFTWARE`, dumps a driver manifest
- Stops services fighting setup.exe for I/O and network (wuauserv, BITS, SysMain, WSearch, DiagTrack, etc.) and disables the WU scheduled tasks that'd restart them
- Never touches remote-access tooling (TeamViewer, AnyDesk, VNC, RDP, Chrome Remote Desktop), excluded from suspension no matter what
- Detects an active remote session and warns before any reboot, with a longer delay so you have time to bail
- Resolves a Win10 ISO (direct URL, Microsoft's download-connector flow, or falls back to Media Creation Tool), mounts it, runs `setup.exe /auto upgrade /quiet /noreboot`
- Restores every suspended service and task on exit, success or failure

## Requirements

- Windows 8.1, build 6.3.x (script checks and refuses anything else)
- PowerShell 4.0+ (native on 8.1)
- Administrator
- ~20GB free disk
- Internet access

## Parameters

| Flag | Default | Does |
|---|---|---|
| `-Arch` | auto | x64 or x86 |
| `-IsoUrl` | - | Direct ISO URL, skips the Microsoft download-connector scrape entirely |
| `-SkipCompatCheck` | off | Bypasses setup.exe's compat gating (`/Compat IgnoreWarning`) |
| `-NoReboot` | off | Stages the upgrade, doesn't auto-restart |
| `-NoServiceSuspend` | off | Skips service suspension, not recommended, leaves WU competing for I/O |
| `-NoSnapshot` | off | Skips the restore point/registry/driver backup step |
| `-UnattendPath` | - | Custom unattend.xml to inject (domain/AD scenarios) |
| `-LogPath` | `C:\wingrade` | Log directory |
| `-TimeoutMinutes` | 120 | Max wait on setup.exe before giving up monitoring |

## Known issue: SSL/TLS error on the fetch

Windows 8.1's PowerShell defaults to SSL3/TLS1.0. GitHub's raw content requires TLS1.2+, so a bare `irm` against this repo fails the handshake before it gets anything. The one-liner above forces TLS1.2 first, that's the fix, and it holds for the rest of that PowerShell session so the script's own web calls (connectivity check, ISO resolution) are covered too.

If it still fails on a box that's never taken a Windows Update (stale root certs), run this and open a fresh PowerShell session before retrying:

```powershell
reg add "HKLM\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" /v SchUseStrongCrypto /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319" /v SchUseStrongCrypto /t REG_DWORD /d 1 /f
```

## Author

wingrade by 0xb0rn3 (ig: theehiv3)
