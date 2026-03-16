## ============================================================================
# Roblox PowerShell External
# Project Repository: https://github.com/SkidedMemory/Roblox-PowerShell-External
#
# Description:
# A PowerShell-based external tool that interacts with the Roblox process
# to modify client-side values such as WalkSpeed, JumpPower, and Field of View.
#
# Features:
# - Memory read/write using native Windows APIs
# - Dynamic offset fetching from web API
# - Real-time console interface
# - WalkSpeed / JumpPower / FOV modification
#
# Disclaimer:
# This project is provided for educational and research purposes. I only made this for testing purposes I'm not responsible if you use it to cause harm
# ============================================================================
$sig = @"
using System;
using System.Runtime.InteropServices;
public class Raw {
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint a, bool b, uint c);
    [DllImport("ntdll.dll")] public static extern int NtReadVirtualMemory(IntPtr h, IntPtr b, byte[] bu, uint s, out uint r);
    [DllImport("ntdll.dll")] public static extern int NtWriteVirtualMemory(IntPtr h, IntPtr b, byte[] bu, uint s, out uint w);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateToolhelp32Snapshot(uint f, uint i);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool Module32FirstW(IntPtr s, IntPtr e);
}
"@
Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue

# ============================================================================
# Feature Toggle States (ON/OFF)
# ============================================================================
$T_Walk = $false  # WalkSpeed modification toggle
$T_Jump = $false  # JumpPower modification toggle
$T_FOV = $false   # Field of View modification toggle

# ============================================================================
# Feature Values (Default Settings)
# ============================================================================
$V_Walk = 16.0    # Default walk speed
$V_Jump = 50.0    # Default jump power
$V_FOV = 70.0     # Default field of view

# ============================================================================
# Memory Offsets - Dynamically loaded from web API
# These offsets point to specific memory locations in Roblox's process
# ============================================================================
$Off = @{
    VE=0x775E8D0   # VisualEngine pointer
    V1=0x700       # VisualEngine to DataModel offset 1
    V2=0x1C0       # VisualEngine to DataModel offset 2
    Ch=0x70        # Children pointer
    Ce=0x8         # Children end pointer
    Nm=0xB0        # Name offset
    LP=0x130       # LocalPlayer offset
    WS=0x178       # Workspace offset
    CC=0x460       # Camera offset
    CD=0x18        # ClassDescriptor offset
    CN=0x8         # ClassName offset
    FV=0x160       # Field of View offset
    WSV=0x1D4      # WalkSpeed value offset
    WSC=0x3C0      # WalkSpeed check offset
    JP=0x1B0       # JumpPower offset
}

# ============================================================================
# Function: Load Offsets from Web API
# Dynamically fetches the latest offsets from the remote server
# ============================================================================
function Update-Offsets {
    try {
        Write-Host "  [*] Fetching latest offsets from API..." -ForegroundColor Cyan
        $response = Invoke-RestMethod -Uri "https://offsets.ntgetwritewatch.workers.dev/offsets.json" -Method Get -TimeoutSec 5
        if ($response) {
            # Update offsets with values from API
            $Off.VE = [Convert]::ToInt64($response.VisualEnginePointer, 16)
            $Off.V1 = [Convert]::ToInt64($response.VisualEngineToDataModel1, 16)
            $Off.V2 = [Convert]::ToInt64($response.VisualEngineToDataModel2, 16)
            $Off.Ch = [Convert]::ToInt64($response.Children, 16)
            $Off.Ce = [Convert]::ToInt64($response.ChildrenEnd, 16)
            $Off.Nm = [Convert]::ToInt64($response.Name, 16)
            $Off.LP = [Convert]::ToInt64($response.LocalPlayer, 16)
            $Off.WS = [Convert]::ToInt64($response.Workspace, 16)
            $Off.CC = [Convert]::ToInt64($response.Camera, 16)
            $Off.CD = [Convert]::ToInt64($response.ClassDescriptor, 16)
            $Off.CN = [Convert]::ToInt64($response.ClassDescriptorToClassName, 16)
            $Off.FV = [Convert]::ToInt64($response.FOV, 16)
            $Off.WSV = [Convert]::ToInt64($response.WalkSpeed, 16)
            $Off.WSC = [Convert]::ToInt64($response.WalkSpeedCheck, 16)
            $Off.JP = [Convert]::ToInt64($response.JumpPower, 16)
            Write-Host "  [+] Offsets updated successfully!" -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "  [!] Failed to fetch offsets, using defaults" -ForegroundColor Yellow
        return $false
    }
    return $false
}

# ============================================================================
# Function: Get Base Address
# Retrieves the base address of the main module in the target process
# ============================================================================
function get-baseraw($id) {
    $snap = [Raw]::CreateToolhelp32Snapshot(0x18, $id)
    if ($snap -eq -1) { return 0 }
    $pEntry = [Runtime.InteropServices.Marshal]::AllocHGlobal(1080)
    for($i=0; $i -lt 1080; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($pEntry, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt32($pEntry, 0, 1080)
    $res = 0
    if ([Raw]::Module32FirstW($snap, $pEntry)) { $res = [Runtime.InteropServices.Marshal]::ReadIntPtr($pEntry, 24).ToInt64() }
    [Runtime.InteropServices.Marshal]::FreeHGlobal($pEntry)
    [Raw]::CloseHandle($snap) | Out-Null
    return $res
}

# ============================================================================
# Memory Reading Functions
# These functions read different data types from the target process memory
# ============================================================================

# Read raw bytes from memory
function Get-Mem ($h, $a, $s=8) {
    $b = New-Object byte[] $s; $r = [uint32]0
    [Raw]::NtReadVirtualMemory($h, [IntPtr]$a, $b, [uint32]$s, [ref]$r) | Out-Null
    return $b
}

# Read a pointer (8 bytes) from memory
function Get-MemPtr ($h, $a) { 
    if ($a -lt 0x1000000) { return 0 }
    return [BitConverter]::ToInt64((Get-Mem $h $a 8), 0) 
}

# Read an integer (4 bytes) from memory
function Get-MemInt ($h, $a) { 
    if ($a -lt 0x1000000) { return 0 }
    return [BitConverter]::ToInt32((Get-Mem $h $a 4), 0) 
}

# Read a string from memory
function Get-MemStr ($h, $a) {
    $l = Get-MemInt $h ($a + 0x18)
    if ($l -le 0 -or $l -gt 64) { return "" }
    $ptr = if ($l -ge 16) { Get-MemPtr $h $a } else { $a }
    return [System.Text.Encoding]::UTF8.GetString((Get-Mem $h $ptr $l)).Split("`0")[0]
}

# ============================================================================
# Memory Writing Functions
# These functions write data to the target process memory
# ============================================================================

# Write a float value to memory
function Set-MemFloat ($h, $a, $v) {
    $b = [BitConverter]::GetBytes([float]$v); $w = [uint32]0
    [Raw]::NtWriteVirtualMemory($h, [IntPtr]$a, $b, 4, [ref]$w) | Out-Null
}

# ============================================================================
# Global Variables
# ============================================================================
$lastRefresh = 0
$lpn = "None"
$humFound = $false
$base = 0
$offsetsUpdated = $false

# ============================================================================
# Console Setup - Banks Branding
# ============================================================================
$Host.UI.RawUI.WindowTitle = "Roblox PowerShell External - Created by Banks"
$Host.UI.RawUI.BackgroundColor = "Black"
$Host.UI.RawUI.ForegroundColor = "Cyan"
Clear-Host
[Console]::CursorVisible = $false

# ============================================================================
# Splash Screen - Banks Branding
# ============================================================================
function Show-SplashScreen {
    Clear-Host
    Write-Host "  ════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "     ROBLOX POWERSHELL EXTERNAL" -ForegroundColor Yellow -NoNewline
    Write-Host " - " -NoNewline -ForegroundColor White
    Write-Host "CREATED BY BANKS" -ForegroundColor Green
    Write-Host "  ════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  [!] WARNING: DO NOT REMOVE CREDITS TO BANKS" -ForegroundColor Red
    Write-Host "  [!] This script is property of Banks" -ForegroundColor Red
    Write-Host ""
    Write-Host "  [*] Loading offsets from API..." -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    
    # Update offsets on startup
    $script:offsetsUpdated = Update-Offsets
    Start-Sleep -Seconds 1
    
    Write-Host "  [*] Initializing..." -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    Clear-Host
}

# Show splash screen on startup
Show-SplashScreen

# ============================================================================
# Main Loop - Process Memory Operations
# This loop continuously monitors and modifies Roblox process memory
# ============================================================================
while ($true) {
    # Handle keyboard input for menu controls
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true).KeyChar
        switch ($key) {
            "1" { $T_Walk = !$T_Walk }
            "2" { $T_Jump = !$T_Jump }
            "3" { $T_FOV = !$T_FOV }
            "4" { 
                [Console]::CursorVisible = $true
                $V_Walk = [float](Read-Host "`n[?] Enter WalkSpeed Value")
                [Console]::CursorVisible = $false
                Clear-Host 
            }
            "5" { 
                [Console]::CursorVisible = $true
                $V_Jump = [float](Read-Host "`n[?] Enter JumpPower Value")
                [Console]::CursorVisible = $false
                Clear-Host 
            }
            "6" { 
                [Console]::CursorVisible = $true
                $V_FOV = [float](Read-Host "`n[?] Enter FOV Value")
                [Console]::CursorVisible = $false
                Clear-Host 
            }
            "r" { 
                # Refresh offsets from API
                $script:offsetsUpdated = Update-Offsets
                Start-Sleep -Milliseconds 500
            }
            "x" { 
                Write-Host "`n  [*] Exiting... Thanks for using Banks' External!" -ForegroundColor Cyan
                Start-Sleep -Seconds 1
                exit 
            }
        }
        $lastRefresh = 0
    }

    # ========================================================================
    # Find Roblox Process
    # ========================================================================
    $p = Get-Process "RobloxPlayerBeta" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        # Open process handle with full access rights
        $h = [Raw]::OpenProcess(0x1F0FFF, $false, $p.Id)
        if ($h) {
            # Get base address of the main module
            $base = get-baseraw $p.Id
            if ($base -gt 0) {
                # Navigate through memory structure to find DataModel
                # VisualEngine -> DataModel chain
                $ve = Get-MemPtr $h ($base + $Off.VE)
                $v1 = Get-MemPtr $h ($ve + $Off.V1)
                $dm = Get-MemPtr $h ($v1 + $Off.V2)
                
                if ($dm) {
                    # Get Workspace from DataModel
                    $work = Get-MemPtr $h ($dm + $Off.WS)
                    
                    # ============================================================
                    # Field of View Modification
                    # ============================================================
                    if ($T_FOV) {
                        $cam = Get-MemPtr $h ($work + $Off.CC)
                        if ($cam) { 
                            # Convert degrees to radians for FOV
                            Set-MemFloat $h ($cam + $Off.FV) ($V_FOV * [Math]::PI / 180.0) 
                        }
                    }
                    
                    # ============================================================
                    # Find Players Service
                    # ============================================================
                    $ps = 0
                    $cp = Get-MemPtr $h ($dm + $Off.Ch)
                    $cur = Get-MemPtr $h $cp
                    $end = Get-MemPtr $h ($cp + $Off.Ce)
                    
                    while ($cur -gt 0 -and $cur -lt $end) {
                        $c = Get-MemPtr $h $cur
                        if ((Get-MemStr $h (Get-MemPtr $h ($c + $Off.Nm))) -eq "Players") { 
                            $ps = $c
                            break 
                        }
                        $cur += 0x10
                    }
                    
                    if ($ps) {
                        # Get LocalPlayer from Players service
                        $lp = Get-MemPtr $h ($ps + $Off.LP)
                        $lpn = Get-MemStr $h (Get-MemPtr $h ($lp + $Off.Nm))
                        
                        # ========================================================
                        # Find Player Character
                        # ========================================================
                        $char = 0
                        $cp = Get-MemPtr $h ($work + $Off.Ch)
                        $cur = Get-MemPtr $h $cp
                        $end = Get-MemPtr $h ($cp + $Off.Ce)
                        
                        while ($cur -gt 0 -and $cur -lt $end) {
                            $c = Get-MemPtr $h $cur
                            if ((Get-MemStr $h (Get-MemPtr $h ($c + $Off.Nm))) -eq $lpn) { 
                                $char = $c
                                break 
                            }
                            $cur += 0x10
                        }
                        
                        if ($char) {
                            # ====================================================
                            # Find Humanoid Object
                            # ====================================================
                            $hum = 0
                            $cp = Get-MemPtr $h ($char + $Off.Ch)
                            $cur = Get-MemPtr $h $cp
                            $end = Get-MemPtr $h ($cp + $Off.Ce)
                            
                            while ($cur -gt 0 -and $cur -lt $end) {
                                $c = Get-MemPtr $h $cur
                                $cd = Get-MemPtr $h ($c + $Off.CD)
                                if ($cd -and (Get-MemStr $h (Get-MemPtr $h ($cd + $Off.CN))) -eq "Humanoid") { 
                                    $hum = $c
                                    break 
                                }
                                $cur += 0x10
                            }
                            
                            if ($hum) {
                                $humFound = $true
                                
                                # ================================================
                                # Apply WalkSpeed Modification
                                # ================================================
                                if ($T_Walk) { 
                                    Set-MemFloat $h ($hum + $Off.WSV) $V_Walk
                                    Set-MemFloat $h ($hum + $Off.WSC) $V_Walk
                                }
                                
                                # ================================================
                                # Apply JumpPower Modification
                                # ================================================
                                if ($T_Jump) { 
                                    Set-MemFloat $h ($hum + $Off.JP) $V_Jump
                                }
                            } else {
                                $humFound = $false
                            }
                        }
                    }
                }
            }
            # Close process handle
            [Raw]::CloseHandle($h) | Out-Null
        }
    }

    # ========================================================================
    # Update UI Display (Refreshed every 100ms)
    # ========================================================================
    if ((Get-Date).Ticks -gt $lastRefresh) {
        # Determine status text and colors for each feature
        if ($T_Walk) { $wTxt = "ENABLED "; $wCol = "Green" } else { $wTxt = "DISABLED"; $wCol = "Red" }
        if ($T_Jump) { $jTxt = "ENABLED "; $jCol = "Green" } else { $jTxt = "DISABLED"; $jCol = "Red" }
        if ($T_FOV)  { $fTxt = "ENABLED "; $fCol = "Green" } else { $fTxt = "DISABLED"; $fCol = "Red" }
        if ($humFound) { $hTxt = "CONNECTED"; $hCol = "Green" } else { $hTxt = "NOT FOUND"; $hCol = "Red" }
        if ($offsetsUpdated) { $oTxt = "UPDATED"; $oCol = "Green" } else { $oTxt = "DEFAULT"; $oCol = "Yellow" }

        # Reset cursor to top-left for smooth UI update
        [Console]::SetCursorPosition(0,0)
        
        # ====================================================================
        # Header - Banks Branding
        # ====================================================================
        Write-Host " ╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
        Write-Host " ║" -NoNewline -ForegroundColor Magenta
        Write-Host "         ROBLOX POWERSHELL EXTERNAL - BY BANKS         " -NoNewline -ForegroundColor Cyan
        Write-Host "║" -ForegroundColor Magenta
        Write-Host " ╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
        
        # ====================================================================
        # Process Information
        # ====================================================================
        Write-Host "`n  [*] PROCESS STATUS" -ForegroundColor Yellow
        Write-Host "  ───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        
        Write-Host "  [+] Process     : " -NoNewline -ForegroundColor Cyan
        if ($p -and $base -gt 0) {
            Write-Host "RobloxPlayerBeta (PID: $($p.Id))".PadRight(35) -ForegroundColor Green
        } else {
            Write-Host "Not Found".PadRight(35) -ForegroundColor Red
        }

        Write-Host "  [+] Base Address: " -NoNewline -ForegroundColor Cyan
        if ($base -gt 0) {
            Write-Host "0x$($base.ToString('X'))".PadRight(35) -ForegroundColor Yellow
        } else {
            Write-Host "0x0".PadRight(35) -ForegroundColor DarkGray
        }
        
        Write-Host "  [+] Player Name : " -NoNewline -ForegroundColor Cyan
        Write-Host "$lpn".PadRight(35) -ForegroundColor White
        
        Write-Host "  [+] Humanoid    : " -NoNewline -ForegroundColor Cyan
        Write-Host "$hTxt".PadRight(35) -ForegroundColor $hCol
        
        Write-Host "  [+] Offsets     : " -NoNewline -ForegroundColor Cyan
        Write-Host "$oTxt".PadRight(35) -ForegroundColor $oCol

        # ====================================================================
        # Feature Status
        # ====================================================================
        Write-Host "`n  [*] FEATURES" -ForegroundColor Yellow
        Write-Host "  ───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        
        Write-Host "  [1] WalkSpeed   : " -NoNewline -ForegroundColor White
        Write-Host "$wTxt" -NoNewline -ForegroundColor $wCol
        Write-Host " (Value: $V_Walk)".PadRight(20) -ForegroundColor Gray
        
        Write-Host "  [2] JumpPower   : " -NoNewline -ForegroundColor White
        Write-Host "$jTxt" -NoNewline -ForegroundColor $jCol
        Write-Host " (Value: $V_Jump)".PadRight(20) -ForegroundColor Gray
        
        Write-Host "  [3] FieldOfView : " -NoNewline -ForegroundColor White
        Write-Host "$fTxt" -NoNewline -ForegroundColor $fCol
        Write-Host " (Value: $V_FOV)".PadRight(20) -ForegroundColor Gray
        
        # ====================================================================
        # Controls Menu
        # ====================================================================
        Write-Host "`n  [*] CONTROLS" -ForegroundColor Yellow
        Write-Host "  ───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  [1-3] Toggle Features   [4-6] Set Values   [R] Refresh Offsets   [X] Exit" -ForegroundColor White
        
        # Update refresh timer
        $lastRefresh = (Get-Date).AddMilliseconds(100).Ticks
    }
    
    # Small delay to prevent CPU overload
    Start-Sleep -m 20
}