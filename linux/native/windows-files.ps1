$ErrorActionPreference='Stop'
try {
 Add-Type -AssemblyName System.Windows.Forms
 $payload=[Console]::In.ReadToEnd()|ConvertFrom-Json
 $files=@($payload.files)
 if($files.Count -lt 1 -or $files.Count -gt 1000){throw 'Invalid file selection.'}
 $paths=New-Object System.Collections.Specialized.StringCollection
 foreach($file in $files){
  if(-not [IO.Path]::IsPathRooted($file)){throw 'A copied file is unavailable.'}
  $item=Get-Item -LiteralPath $file
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A copied file is unavailable.'}
  [void]$paths.Add($item.FullName)
 }
 $data=New-Object System.Windows.Forms.DataObject
 $data.SetFileDropList($paths)
 if($payload.text){$data.SetText([string]$payload.text,[System.Windows.Forms.TextDataFormat]::UnicodeText)}
 $marker=$null
 try {
  if($payload.marker){$marker=New-Object IO.MemoryStream(,[Convert]::FromBase64String($payload.marker));$data.SetData('ClipBoardLine.Internal.v1',$marker)}
  [System.Windows.Forms.Clipboard]::SetDataObject($data,$true,5,100)
 }finally{if($marker){$marker.Dispose()}}
 @{ok=$true;count=$files.Count}|ConvertTo-Json -Compress
}catch{@{ok=$false;error='Windows could not copy the selected files.'}|ConvertTo-Json -Compress;exit 1}
