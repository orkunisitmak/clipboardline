param([ValidateSet('Inspect','Trim')][string]$Mode='Inspect')
$ErrorActionPreference='Stop'
# No UI, executable download or third-party codec process. WinRT uses the
# installed Windows media stack on this non-window-owning MTA thread.
function Initialize-MediaRuntime {
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$null=[Windows.Media.Editing.MediaClip,Windows.Media.Editing,ContentType=WindowsRuntime]
$null=[Windows.Media.Editing.MediaComposition,Windows.Media.Editing,ContentType=WindowsRuntime]
$null=[Windows.Media.MediaProperties.MediaEncodingProfile,Windows.Media.MediaProperties,ContentType=WindowsRuntime]
$null=[Windows.Media.Transcoding.TranscodeFailureReason,Windows.Media.Transcoding,ContentType=WindowsRuntime]
$null=[Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
$null=[Windows.Graphics.Imaging.BitmapEncoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
$null=[Windows.Graphics.Imaging.ImageStream,Windows.Graphics.Imaging,ContentType=WindowsRuntime]

}

function Await-Operation($Operation,[Type]$ResultType,[Type]$ProgressType=$null){
  $genericCount=1;$parameterName='IAsyncOperation`1';if($ProgressType){$genericCount=2;$parameterName='IAsyncOperationWithProgress`2'}
  $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Length -eq $genericCount -and $_.GetParameters().Length -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq $parameterName
  } | Select-Object -First 1
  if(-not $method){throw 'Windows asynchronous media bridge is unavailable.'}
  $types=@($ResultType);if($ProgressType){$types+=@($ProgressType)}
  $task=$method.MakeGenericMethod([Type[]]$types).Invoke($null,@($Operation))
  try{
    # This helper is additionally killed by the owner after ten minutes or on
    # cancellation. Never block the Electron UI or focus helper on rendering.
    if(-not $task.Wait([TimeSpan]::FromMinutes(10))){$Operation.Cancel();throw 'Video operation timed out.'}
    return $task.GetAwaiter().GetResult()
  }finally{if($Operation.Status -eq [Windows.Foundation.AsyncStatus]::Started){$Operation.Cancel()}}
}
function Await-Action($Operation){
  $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {$_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Length -eq 1 -and $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'} | Select-Object -First 1
  if(-not $method){throw 'Windows asynchronous action bridge is unavailable.'}
  $task=$method.Invoke($null,@($Operation))
  if(-not $task.Wait([TimeSpan]::FromMinutes(10))){$Operation.Cancel();throw 'Video operation timed out.'}
  $null=$task.GetAwaiter().GetResult()
}
function Await-ProgressAction($Operation){
  $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Length -eq 1 -and $_.GetParameters().Length -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncActionWithProgress`1'} | Select-Object -First 1
  $task=$method.MakeGenericMethod([Type[]]@([double])).Invoke($null,@($Operation))
  if(-not $task.Wait([TimeSpan]::FromMinutes(10))){$Operation.Cancel();throw 'Video operation timed out.'}
  $null=$task.GetAwaiter().GetResult()
}
function Open-Clip([string]$File){
  $storage=Await-Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($File)) ([Windows.Storage.StorageFile])
  return Await-Operation ([Windows.Media.Editing.MediaClip]::CreateFromFileAsync($storage)) ([Windows.Media.Editing.MediaClip])
}
function Describe-Clip($Clip){
  $properties=$Clip.GetVideoEncodingProperties()
  if($Clip.OriginalDuration.TotalMilliseconds -le 0 -or $properties.Width -le 0 -or $properties.Height -le 0){throw 'The recording has no usable video track.'}
  # Raw WinRT collections are not ordinary PowerShell arrays. Its synthetic
  # Count property can report 1 for an opaque RCW, even when the view is empty.
  $audioCollection=[System.Collections.Generic.IReadOnlyCollection[Windows.Media.Editing.EmbeddedAudioTrack]]
  $audioCount=[int]$audioCollection.GetProperty('Count').GetValue($Clip.EmbeddedAudioTracks,$null)
  return @{durationMs=[double]$Clip.OriginalDuration.TotalMilliseconds;width=[int]$properties.Width;height=[int]$properties.Height;videoCodec=[string]$properties.Subtype;audioTracks=$audioCount}
}
function Insert-Clip($Composition,$Clip){
  # WinRT IVector<T> is projected as IList<T> in .NET, but PowerShell's raw
  # RCW binder does not expose its Add method. Invoke the declared IList<T>
  # Insert method through the typed interface rather than guessing ABI slots.
  # https://learn.microsoft.com/uwp/api/windows.foundation.collections.ivector-1
  $listType=[System.Collections.Generic.IList[Windows.Media.Editing.MediaClip]]
  $insert=$listType.GetMethod('Insert',[Type[]]@([int],[Windows.Media.Editing.MediaClip]))
  if(-not $insert){throw 'Windows media clip collection projection is unavailable.'}
  $null=$insert.Invoke($Composition.Clips,[object[]]@([int]0,$Clip))
}
function Write-Poster($Clip,[string]$Directory){
  $script:stage='PosterCompose'
  $composition=New-Object Windows.Media.Editing.MediaComposition
  $script:stage='PosterClipsAdd'
  Insert-Clip $composition $Clip
  $script:stage='PosterThumbnail'
  $stream=Await-Operation ($composition.GetThumbnailAsync([TimeSpan]::Zero,[int]320,[int]0,[Windows.Media.Editing.VideoFramePrecision]::NearestFrame)) ([Windows.Graphics.Imaging.ImageStream])
  try{
    $script:stage='PosterDecoder'
    $decoder=Await-Operation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $script:stage='PosterSoftwareBitmap'
    $bitmap=Await-Operation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    try{
      $script:stage='PosterCreatePNG'
      $folder=Await-Operation ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($Directory)) ([Windows.Storage.StorageFolder])
      $output=Await-Operation ($folder.CreateFileAsync('poster.png',[Windows.Storage.CreationCollisionOption]::FailIfExists)) ([Windows.Storage.StorageFile])
      $script:stage='PosterOpenOutput'
      $outputStream=Await-Operation ($output.OpenAsync([Windows.Storage.FileAccessMode]::ReadWrite)) ([Windows.Storage.Streams.IRandomAccessStream])
      try{
        $script:stage='PosterEncoder'
        $encoder=Await-Operation ([Windows.Graphics.Imaging.BitmapEncoder]::CreateAsync([Windows.Graphics.Imaging.BitmapEncoder]::PngEncoderId,$outputStream)) ([Windows.Graphics.Imaging.BitmapEncoder])
        $encoder.SetSoftwareBitmap($bitmap)
        $script:stage='PosterFlush'
        Await-Action ($encoder.FlushAsync())
      }finally{$outputStream.Dispose()}
    }finally{$bitmap.Dispose()}
  }finally{$stream.Dispose()}
}

try{
  $stage='Runtime'
  Initialize-MediaRuntime
  $stage='Input'
  $inputText=[Console]::In.ReadToEnd();if($inputText.Length -gt 20000){throw 'Invalid video request.'}
  $request=$inputText | ConvertFrom-Json
  $source=[IO.Path]::GetFullPath([string]$request.source)
  $directory=[IO.Path]::GetFullPath([string]$request.outputDirectory)
  if(-not [IO.Path]::IsPathRooted($source) -or -not [IO.Path]::IsPathRooted($directory) -or -not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $directory -PathType Container)){throw 'Recording is unavailable.'}
  if(([IO.Path]::GetExtension($source).ToLowerInvariant()) -notin @('.mov','.mp4')){throw 'Only MP4 and MOV recordings are supported.'}
  foreach($file in @($source,$directory)){if(([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Recording paths must not be links.'}}
  $stage='Decode';$clip=Open-Clip $source
  $original=Describe-Clip $clip
  $result=$original.Clone()
  if($Mode -eq 'Trim'){
    $stage='Trim'
    $start=[double]$request.startMs;$end=[double]$request.endMs
    if([double]::IsNaN($start) -or [double]::IsInfinity($start) -or [double]::IsNaN($end) -or [double]::IsInfinity($end) -or $start -lt 0 -or $end -gt ($original.durationMs+1) -or $end-$start -lt 50){throw 'Choose a nonempty trim interval inside the recording.'}
    $clip.TrimTimeFromStart=[TimeSpan]::FromMilliseconds($start)
    $clip.TrimTimeFromEnd=[TimeSpan]::FromMilliseconds([Math]::Max(0,$original.durationMs-$end))
    $composition=New-Object Windows.Media.Editing.MediaComposition
    $stage='TrimClipsAdd';Insert-Clip $composition $clip
    $folder=Await-Operation ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($directory)) ([Windows.Storage.StorageFolder])
    $output=Await-Operation ($folder.CreateFileAsync('trimmed.mp4',[Windows.Storage.CreationCollisionOption]::FailIfExists)) ([Windows.Storage.StorageFile])
    # Use a real H.264/AAC MP4 output while preserving source dimensions/rate.
    # Never write MP4 bytes under a MOV name or silently shrink a recording.
    # Composition rendering needs a complete encoder profile. Auto leaves
    # attributes unresolved on desktop hosts; start with explicit defaults,
    # then retain the recording's dimensions and timing below.
    $profile=[Windows.Media.MediaProperties.MediaEncodingProfile]::CreateMp4([Windows.Media.MediaProperties.VideoEncodingQuality]::HD720p)
    $profile.Audio=[Windows.Media.MediaProperties.AudioEncodingProperties]::CreateAac([uint32]44100,[uint32]2,[uint32]128000)
    # A video-only recording must remain video-only after trimming.
    if($original.audioTracks -eq 0){$profile.Audio=$null}
    $video=$clip.GetVideoEncodingProperties()
    $profile.Video.Width=$video.Width;$profile.Video.Height=$video.Height
    $profile.Video.FrameRate.Numerator=$video.FrameRate.Numerator;$profile.Video.FrameRate.Denominator=$video.FrameRate.Denominator
    $profile.Video.PixelAspectRatio.Numerator=1;$profile.Video.PixelAspectRatio.Denominator=1
    if($video.Bitrate -gt 0){$profile.Video.Bitrate=$video.Bitrate}
    $stage='TrimRender'
    $failure=Await-Operation ($composition.RenderToFileAsync($output,[Windows.Media.Editing.MediaTrimmingPreference]::Precise,$profile)) ([Windows.Media.Transcoding.TranscodeFailureReason]) ([double])
    if($failure -ne [Windows.Media.Transcoding.TranscodeFailureReason]::None){throw ('Windows could not encode this recording: '+$failure)}
    $stage='TrimReopen';$clip=Open-Clip ([IO.Path]::Combine($directory,'trimmed.mp4'))
    $result=Describe-Clip $clip
    if([Math]::Abs($result.durationMs-($end-$start)) -gt 150){throw 'The encoded trim duration did not match the selection.'}
    $result.trimmedFile='trimmed.mp4'
  }
  $stage='Poster';Write-Poster $clip $directory
  if($request.verifyAudio -eq $true -and $result.audioTracks -gt 0){
    $stage='AudioVerify'
    # Native acceptance can decode the real audio to PCM and inspect the tone;
    # ordinary import/trim never creates this additional derived file.
    $audioSource=$source;if($Mode -eq 'Trim'){$audioSource=[IO.Path]::Combine($directory,'trimmed.mp4')}
    $storage=Await-Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($audioSource)) ([Windows.Storage.StorageFile])
    $folder=Await-Operation ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($directory)) ([Windows.Storage.StorageFolder])
    $audio=Await-Operation ($folder.CreateFileAsync('audio.wav',[Windows.Storage.CreationCollisionOption]::FailIfExists)) ([Windows.Storage.StorageFile])
    $transcoder=New-Object Windows.Media.Transcoding.MediaTranscoder
    $transcoder.HardwareAccelerationEnabled=$false
    $transcoder.AlwaysReencode=$true
    $profile=[Windows.Media.MediaProperties.MediaEncodingProfile]::CreateWav([Windows.Media.MediaProperties.AudioEncodingQuality]::High)
    $profile.Audio=[Windows.Media.MediaProperties.AudioEncodingProperties]::CreatePcm([uint32]44100,[uint32]1,[uint32]16)
    $prepared=Await-Operation ($transcoder.PrepareFileTranscodeAsync($storage,$audio,$profile)) ([Windows.Media.Transcoding.PrepareTranscodeResult])
    if(-not $prepared.CanTranscode){throw ('Native audio verification could not decode the recording: '+$prepared.FailureReason)}
    Await-ProgressAction ($prepared.TranscodeAsync())
    $result.audioFile='audio.wav'
  }
  $result.posterFile='poster.png';$result.ok=$true;$result.engine='Windows.Media.Editing'
  [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress))
}catch{
  # Paths and private file names never appear in normal errors or logs.
  $message='Windows could not decode or process this MP4/MOV recording. Its codec may not be installed, or the file may be incomplete.'
  $known=$_.Exception.Message
  if($known -match '^(Choose a nonempty|Video operation timed out|Only MP4|Windows could not encode|The encoded trim duration|The recording has no usable)'){$message=$known}
  $failure=$_.Exception;while($failure.InnerException){$failure=$failure.InnerException}
  $errorId=([string]$_.FullyQualifiedErrorId -replace '[^A-Za-z0-9_.:,-]',' ');if($errorId.Length -gt 180){$errorId=$errorId.Substring(0,180)}
  [Console]::Out.WriteLine((@{ok=$false;error=$message;code='MEDIA_UNSUPPORTED_OR_FAILED';stage=$stage;hresult=$failure.HResult;exceptionType=$failure.GetType().FullName;errorId=$errorId;scriptLine=$_.InvocationInfo.ScriptLineNumber} | ConvertTo-Json -Compress))
  exit 1
}
