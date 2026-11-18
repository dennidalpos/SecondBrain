#requires -Version 7.5
<#
.SYNOPSIS
sb offboard: removes SecondBrain from one repository. The binding, the managed blocks and the pointers go away and the open tasks are written to TASKS.md in the repository; the dossier is saved in the backup folder first.
.DESCRIPTION
Previews by default and changes nothing. With -Apply the repository matches a fresh clone plus TASKS.md. -Forbid also adds it to the forbidden repositories.
.EXAMPLE
pwsh -NoProfile -File scripts/offboard.ps1 -RepositoryIdentity github.com/my-org/my-project
.EXAMPLE
pwsh -NoProfile -File scripts/offboard.ps1 -RepositoryIdentity github.com/my-org/my-project -Apply
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryIdentity,[string]$DestinationPath,[switch]$Forbid,[switch]$Force,[switch]$Apply,[string]$SessionId,[string]$ConfigPath)
$ErrorActionPreference='Stop'
$arguments=@('-RepositoryIdentity',$RepositoryIdentity,'-TasksOnly')
if($DestinationPath){$arguments+=@('-DestinationPath',$DestinationPath)}
if($ConfigPath){$arguments+=@('-ConfigPath',$ConfigPath)}
if($SessionId){$arguments+=@('-SessionId',$SessionId)}
if($Forbid){$arguments+='-Forbid'}
if($Force){$arguments+='-Force'}
if($Apply){$arguments+='-Apply'}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'rollback-repo.ps1') @arguments
exit $LASTEXITCODE
