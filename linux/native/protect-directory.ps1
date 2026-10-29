param([Parameter(Mandatory=$true)][string]$Directory,[switch]$Check)
$ErrorActionPreference='Stop'
$current=[System.Security.Principal.WindowsIdentity]::GetCurrent().User
if(-not $Check){
  if(-not [System.IO.Directory]::Exists($Directory)){throw 'The application data directory is unavailable.'}
  # Keep the directory's existing owner/group. Reassigning ownership can require
  # a privilege even when the user may safely change this owned directory's DACL.
  $acl=Get-Acl -LiteralPath $Directory
  $acl.SetAccessRuleProtection($true,$false)
  foreach($existing in @($acl.Access)){[void]$acl.RemoveAccessRuleSpecific($existing)}
  $inherit=[System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
  foreach($sid in @($current.Value,'S-1-5-18','S-1-5-32-544')){
    $identity=[System.Security.Principal.SecurityIdentifier]::new($sid)
    $rule=[System.Security.AccessControl.FileSystemAccessRule]::new($identity,[System.Security.AccessControl.FileSystemRights]::FullControl,$inherit,[System.Security.AccessControl.PropagationFlags]::None,[System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $Directory -AclObject $acl
}
$actual=Get-Acl -LiteralPath $Directory
$principals=@($actual.Access | Where-Object {$_.AccessControlType -eq 'Allow'} | ForEach-Object {$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value})
@{protected=$actual.AreAccessRulesProtected;currentUser=$current.Value;principals=$principals}|ConvertTo-Json -Compress
