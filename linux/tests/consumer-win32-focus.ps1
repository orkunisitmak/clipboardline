$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ConsumerForeground {
 [StructLayout(LayoutKind.Sequential)] public struct POINT {public int x,y;}
 [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {public int size;public uint flags;public IntPtr active,focus,capture,menuOwner,moveSize,caret;public int left,top,right,bottom;}
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
 [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window,uint flags);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window,out uint owner);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool GetGUIThreadInfo(uint thread,ref GUITHREADINFO info);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr window,StringBuilder title,int maximum);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
}
'@
function Owned-Window($window,$request) {
 if($window -eq [IntPtr]::Zero){throw 'No owned browser window at this point.'}
 $owner=[uint32]0;$thread=[ConsumerForeground]::GetWindowThreadProcessId($window,[ref]$owner)
 if($thread -eq 0 -or $owner -ne [int]$request.pid){throw 'The pointer/foreground belongs to another process.'}
 if($request.window -and $window.ToInt64().ToString() -ne [string]$request.window){throw 'The owned browser HWND changed.'}
 $executable=[Diagnostics.Process]::GetProcessById($owner).MainModule.FileName
 if(-not [string]::Equals($executable,[string]$request.executable,[StringComparison]::OrdinalIgnoreCase)){throw 'The owned browser executable differs.'}
 $title=New-Object Text.StringBuilder 512
 [void][ConsumerForeground]::GetWindowText($window,$title,512)
 if(-not $title.ToString().StartsWith([string]$request.title,[StringComparison]::Ordinal)){throw 'The window is not the synthetic consumer fixture.'}
 return @{window=$window.ToInt64().ToString();owner=[int]$owner;thread=$thread;executable=$executable;title=$title.ToString()}
}
# Initialize only Win32 APIs before either browser starts. No accessibility
# assembly, provider, field-value query or programmatic focus API is used.
[Console]::WriteLine('{"ready":true}')
while($null -ne ($line=[Console]::ReadLine())) {
 try {
  $request=$line|ConvertFrom-Json
  if($request.action -notin @('click','snapshot') -or [int]$request.pid -le 0 -or -not $request.executable -or -not $request.title){throw 'Invalid owned foreground request.'}
  if($request.action -eq 'click'){
   $point=New-Object ConsumerForeground+POINT;$point.x=[int]$request.x;$point.y=[int]$request.y
   $under=[ConsumerForeground]::GetAncestor([ConsumerForeground]::WindowFromPoint($point),2)
   [void](Owned-Window $under $request)
   if(-not [ConsumerForeground]::SetCursorPos($point.x,$point.y)){throw 'Windows rejected the fixture pointer position.'}
   [ConsumerForeground]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[ConsumerForeground]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
   $sent=Owned-Window $under $request;$sent.Remove('thread');$sent.pointerSent=$true
   [Console]::WriteLine(($sent|ConvertTo-Json -Compress));continue
  }
  $window=[ConsumerForeground]::GetForegroundWindow();$result=Owned-Window $window $request
  $gui=New-Object ConsumerForeground+GUITHREADINFO;$gui.size=[Runtime.InteropServices.Marshal]::SizeOf($gui)
  if(-not [ConsumerForeground]::GetGUIThreadInfo($result.thread,[ref]$gui)){throw 'The native keyboard focus query failed.'}
  $focusOwner=[uint32]0;[void][ConsumerForeground]::GetWindowThreadProcessId($gui.focus,[ref]$focusOwner)
  $result.Remove('thread');$result.focus=$gui.focus.ToInt64().ToString();$result.focusOwner=[int]$focusOwner
  [Console]::WriteLine(($result|ConvertTo-Json -Compress))
 }catch{[Console]::WriteLine((@{error=$_.Exception.Message}|ConvertTo-Json -Compress))}
}
