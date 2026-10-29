$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'notepad-range-read.ps1')
function Require([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
$script:reads=0;$script:owners=0;$script:pauses=0
$result=Invoke-NotepadTextSnapshot -VerifyOwner {$script:owners++} -Pause {$script:pauses++} -Read {
  $script:reads++
  if ($script:reads -eq 1) { $oldRange='old';[void]$oldRange.Substring(99) }
  return @{text='actual replacement';selectedText='';foreground=$true;editorFocused=$true}
}
Require ($script:reads -eq 2 -and $script:owners -eq 3 -and $script:pauses -eq 1) 'Retry did not reacquire and revalidate the entire snapshot.'
Require ($result.attempts -eq 2 -and $result.value.text -ceq 'actual replacement') 'Retry did not return the newly read actual text.'
$script:reads=0;$script:pauses=0;$failed=$false
try { Invoke-NotepadTextSnapshot -VerifyOwner {} -Pause {$script:pauses++} -Read {$script:reads++;throw [System.Runtime.InteropServices.COMException]::new('Invalid text range',-2147024809)} } catch {$failed=$true}
Require ($failed -and $script:reads -eq 4 -and $script:pauses -eq 3) 'Persistent E_INVALIDARG must fail after exactly four reads.'
$script:reads=0;$script:pauses=0;$failed=$false
try { Invoke-NotepadTextSnapshot -VerifyOwner {} -Pause {$script:pauses++} -Read {$script:reads++;throw [System.UnauthorizedAccessException]::new('Denied')} } catch {$failed=$true}
Require ($failed -and $script:reads -eq 1 -and $script:pauses -eq 0) 'A non-range provider failure was retried.'
$script:reads=0;$script:pauses=0;$failed=$false
try { Invoke-NotepadTextSnapshot -VerifyOwner {} -Pause {$script:pauses++} -Read {$script:reads++;throw [System.UnauthorizedAccessException]::new('Denied',[System.ArgumentException]::new('Inner range detail'))} } catch {$failed=$true}
Require ($failed -and $script:reads -eq 1 -and $script:pauses -eq 0) 'An outer permission failure must not become retryable through its inner exception.'
$script:reads=0;$failed=$false
try { Invoke-NotepadTextSnapshot -VerifyOwner {throw [System.ArgumentException]::new('Owned editor changed')} -Read {$script:reads++;return 'unrelated text'} } catch {$failed=$true}
Require ($failed -and $script:reads -eq 0) 'A different owner must fail before reading any content.'
$script:reads=0;$script:owners=0;$failed=$false
try { Invoke-NotepadTextSnapshot -VerifyOwner {$script:owners++;if($script:owners -eq 2){throw 'Owner changed after read'}} -Read {$script:reads++;return 'read before identity change'} } catch {$failed=$true}
Require ($failed -and $script:reads -eq 1 -and $script:owners -eq 2) 'A changed post-read owner must never yield a snapshot.'
Write-Output 'PASS fresh Notepad UIA snapshot retry policy: transient, bounded, permissions and ownership'
