param([Parameter(Mandatory=$true)][string]$Config)
$ErrorActionPreference='Stop'
$configuration=[System.IO.File]::ReadAllText($Config)|ConvertFrom-Json
$state=@{status='starting';sourceProcessId=$configuration.sourceProcessId;installer=$configuration.installer}
function Write-State {
  $temporary=$configuration.output+'.tmp'
  [System.IO.File]::WriteAllText($temporary,($state|ConvertTo-Json -Compress -Depth 5))
  [System.IO.File]::Copy($temporary,$configuration.output,$true)
}
try {
  if ($configuration.sourceProcessId -le 0 -or -not [System.IO.Path]::IsPathRooted([string]$configuration.installer)) { throw 'Invalid owned installer observer configuration.' }
  $state.status='waiting';Write-State
  $deadline=[DateTime]::UtcNow.AddSeconds(45)
  $row=$null
  do {
    $row=Get-CimInstance Win32_Process -Filter ('ParentProcessId='+[int]$configuration.sourceProcessId)|Where-Object {$_.ExecutablePath -eq [string]$configuration.installer}|Select-Object -First 1
    if ($null -eq $row) { Start-Sleep -Milliseconds 100 }
  } while ($null -eq $row -and [DateTime]::UtcNow -lt $deadline)
  if ($null -eq $row) { throw 'No exact installer child of the candidate process was observed.' }
  $state.processId=[int]$row.ProcessId;$state.commandLine=[string]$row.CommandLine;$state.executablePath=[string]$row.ExecutablePath;$state.createdAt=[DateTime]::UtcNow.ToString('o');$state.status='running';Write-State
  $process=Get-Process -Id $row.ProcessId -ErrorAction Stop
  $state.hasExited=$process.WaitForExit(180000)
  if ($state.hasExited) { $state.exitCode=$process.ExitCode;$state.status='exited' } else { $state.status='still-running' }
} catch { $state.status='failed';$state.error=$_.Exception.Message }
Write-State
