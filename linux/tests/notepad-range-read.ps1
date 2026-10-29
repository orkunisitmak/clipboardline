# Read-only consumer-fixture policy. Replacing all text can invalidate a UIA
# TextPatternRange between obtaining it and GetText; never reuse that range.
# https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/ui-automation-textpattern-overview
function Invoke-NotepadTextSnapshot {
  param([Parameter(Mandatory=$true)][scriptblock]$VerifyOwner,
        [Parameter(Mandatory=$true)][scriptblock]$Read,
        [scriptblock]$Pause={Start-Sleep -Milliseconds 30})
  for ($attempt=0;$attempt -lt 4;$attempt++) {
    # Identity failures are outside the retryable read and always fail closed.
    & $VerifyOwner
    try {
      $value=& $Read
    } catch {
      $cause=$_.Exception
      # Peel invocation transport only. A permission/security exception stays
      # fatal even if it happens to contain an ArgumentException underneath.
      while (($cause -is [System.Management.Automation.MethodInvocationException] -or
              $cause -is [System.Reflection.TargetInvocationException]) -and $null -ne $cause.InnerException) {
        $cause=$cause.InnerException
      }
      $invalidRange=$cause -is [System.ArgumentException] -or
        ($cause -is [System.Runtime.InteropServices.COMException] -and $cause.HResult -eq -2147024809)
      if (-not $invalidRange -or $attempt -eq 3) { throw }
      & $Pause
      continue
    }
    & $VerifyOwner
    return @{value=$value;attempts=($attempt+1)}
  }
}
