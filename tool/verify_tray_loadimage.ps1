Add-Type @'
using System;
using System.Runtime.InteropServices;
public class TrayLoadProbe {
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr LoadImage(IntPtr hinst, string lpszName, uint uType, int cx, int cy, uint fuLoad);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool DestroyIcon(IntPtr hIcon);
  [DllImport("kernel32.dll")]
  public static extern uint GetLastError();
}
'@

$png = 'E:\work\learning time computer\assets\icons\tray_icon.png'
$ico = 'E:\work\learning time computer\assets\icons\tray_icon.ico'

# IMAGE_ICON=1, LR_LOADFROMFILE=0x10, 16x16 (GetSystemMetrics(SM_CXSMICON))
$h1 = [TrayLoadProbe]::LoadImage([IntPtr]::Zero, $png, 1, 16, 16, 0x10)
Write-Host ("PNG -> handle=" + $h1 + "  err=" + [TrayLoadProbe]::GetLastError())
if ($h1 -ne [IntPtr]::Zero) { [TrayLoadProbe]::DestroyIcon($h1) | Out-Null }

$h2 = [TrayLoadProbe]::LoadImage([IntPtr]::Zero, $ico, 1, 16, 16, 0x10)
Write-Host ("ICO -> handle=" + $h2 + "  err=" + [TrayLoadProbe]::GetLastError())
if ($h2 -ne [IntPtr]::Zero) { [TrayLoadProbe]::DestroyIcon($h2) | Out-Null }
