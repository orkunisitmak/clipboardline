param([Parameter(Mandatory=$true)][string]$Directory,[switch]$Check)
$ErrorActionPreference='Stop'
$current=[System.Security.Principal.WindowsIdentity]::GetCurrent().User
$dirInfo=[System.IO.DirectoryInfo]::new($Directory)
if(-not $Check){
  if(-not $dirInfo.Exists){throw 'The application data directory is unavailable.'}
  # Keep the directory's existing owner/group and SACL. Reassigning ownership or
  # touching SACL requires SeSecurityPrivilege on Windows, causing crashes on
  # non-elevated accounts after initial setup. Writing only AccessControlSections::Access (DACL)
  # ensures permission changes succeed without privilege escalation.
  $acl=$dirInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
  $acl.SetAccessRuleProtection($true,$false)
  foreach($existing in @($acl.Access)){[void]$acl.RemoveAccessRuleSpecific($existing)}
  $inherit=[System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
  foreach($sid in @($current.Value,'S-1-5-18','S-1-5-32-544')){
    $identity=[System.Security.Principal.SecurityIdentifier]::new($sid)
    $rule=[System.Security.AccessControl.FileSystemAccessRule]::new($identity,[System.Security.AccessControl.FileSystemRights]::FullControl,$inherit,[System.Security.AccessControl.PropagationFlags]::None,[System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
  }
  $dirInfo.SetAccessControl($acl)
}
$actual=$dirInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
$principals=@($actual.Access | Where-Object {$_.AccessControlType -eq 'Allow'} | ForEach-Object {$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value})
@{protected=$actual.AreAccessRulesProtected;currentUser=$current.Value;principals=$principals}|ConvertTo-Json -Compress
