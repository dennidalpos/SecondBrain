#requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Repository,[string]$Project='root',[string]$Runtime='default',[string]$Category,[string]$Slug,[string]$ConfigPath,
    [string]$FilePath,[string[]]$Arguments=@(),[string]$WorkingDirectory,[switch]$Run,
    [switch]$Init,[switch]$Close,[string]$Task,[string]$SessionId,[string]$Client='agent',
    [switch]$Remove,[string]$Path,[switch]$Apply)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'work.run.explicit' = @{ en = 'Run requires an explicit executable and directory; no implicit shell' }
    'work.init.categoryslug' = @{ en = 'Init requires Category and Slug' }
    'work.close.manifest' = @{ en = 'Close requires a folder initialized with MANIFEST.json' }
    'work.checkout.unmanaged' =@{ en = 'Checkout not managed or ambiguous' }
    'work.remove.path' = @{ en = 'Remove requires -Path of an initialized work folder of this repository' }
    'work.remove.outside' = @{ en = 'Path is not a work folder of this repository: ''{0}''; use a folder created by work.ps1 -Init' }
    'work.remove.manifest' = @{ en = 'Folder has no MANIFEST.json; only folders created by work.ps1 -Init are removed' }
    'work.remove.open' = @{ en = 'Folder is still open: close it first with -Close once the reviewed images or reports are stored' }
}
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.TaskRunner.psm1')
# Runner session perimeter: work folders are written only for the task repository.
Assert-SBRunnerReadScope -Repository $Repository -Write
$config=Read-SBConfiguration $ConfigPath
$plan=if($Category -or $Slug){Get-SBWorkEnvironment -BrainRoot $config.brainRoot -HostId $config.workstationId -Repository $Repository -Category $Category -Slug $Slug}else{Get-SBWorkEnvironment $config.brainRoot $config.workstationId $Repository $Project $Runtime}
if($Init){
    # Creates the nested folder and its MANIFEST.json (owner, session, task, status, expiry): the folder is then traceable and subject to retention.
    if(!$Category -or !$Slug){throw (New-SBError 'work.init.categoryslug')}
    [IO.Directory]::CreateDirectory($plan.root)|Out-Null
    $manifestPath=Join-Path $plan.root 'MANIFEST.json'
    if(!(Test-Path -LiteralPath $manifestPath)){
        $today=(Get-SBNow).LocalDateTime
        # Every category has an expiry (days from creation): evidence and reports are reviewed after 90 days, never removed automatically.
        $retention=@{work=30;fixture=7;tmp=7;evidence=90;report=90}
        $expires=if($retention.ContainsKey($Category)){$today.AddDays($retention[$Category]).ToString('yyyy-MM-dd')}else{$null}
        $record=@{schemaVersion=1;category=$Category;name=(Split-Path $plan.root -Leaf);created=$today.ToString('yyyy-MM-dd');hostId=$config.workstationId;repository=(Get-SBRuntimeRepoSegment $Repository);owner=@{user=$env:USERNAME;computer=$env:COMPUTERNAME;client=$Client};sessionId=$SessionId;task=$Task;status='open';expires=$expires}
        [IO.File]::WriteAllText($manifestPath,(ConvertTo-SBJson $record),[Text.UTF8Encoding]::new($false))
    }
    $plan.manifest=$manifestPath;$plan.initialized=$true
    ConvertTo-SBJson $plan;exit 0
}
if($Close){
    # Marks the folder as closed: the retention clock starts here (work 30 days, evidence and report 90 days; fixture and tmp keep their expiry).
    if(!$Category -or !$Slug){throw (New-SBError 'work.init.categoryslug')}
    $manifestPath=Join-Path $plan.root 'MANIFEST.json'
    $record=Read-SBJson $manifestPath $null
    if($null -eq $record){throw (New-SBError 'work.close.manifest')}
    $now=(Get-SBNow).LocalDateTime;$record.status='closed';$record.closed=$now.ToString('yyyy-MM-dd')
    if($Category -eq 'work'){$record.expires=$now.AddDays(30).ToString('yyyy-MM-dd')}
    elseif($Category -in @('evidence','report')){$record.expires=$now.AddDays(90).ToString('yyyy-MM-dd')}
    Write-SBFile $manifestPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $record))) (Get-SBFileHash $manifestPath) (Join-Path $config.runtimeRoot 'backups')|Out-Null
    $plan.manifest=$manifestPath;$plan.closed=$true
    ConvertTo-SBJson $plan;exit 0
}
if($Remove){
    # Teardown at the end of the work (#702): previews by default; -Apply removes the whole folder, once it is closed and its reviewed
    # output is stored elsewhere. Only a folder created by -Init under this repository's work root is accepted; nothing is left behind.
    if(!$Path){throw (New-SBError 'work.remove.path')}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $category=Split-Path (Split-Path $full -Parent) -Leaf
    $repoRoot=Split-Path (Split-Path (Get-SBRuntimeWorkPath $config.brainRoot $config.workstationId $Repository $category 'x') -Parent) -Parent
    $inside=(Test-SBSamePath (Split-Path (Split-Path $full -Parent) -Parent) $repoRoot) -and (Test-Path -LiteralPath $full -PathType Container) -and !((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
    if(!$inside){throw (New-SBError 'work.remove.outside' @($Path))}
    $manifest=Read-SBJson (Join-Path $full 'MANIFEST.json') $null
    if($null -eq $manifest){throw (New-SBError 'work.remove.manifest')}
    if($manifest.status -cne 'closed'){throw (New-SBError 'work.remove.open')}
    $options=[IO.EnumerationOptions]::new();$options.RecurseSubdirectories=$true;$options.IgnoreInaccessible=$true;$options.AttributesToSkip=[IO.FileAttributes]::ReparsePoint
    $count=0;$bytes=0L
    foreach($file in ([IO.DirectoryInfo]::new($full)).EnumerateFiles('*',$options)){$count++;$bytes+=$file.Length}
    if($Apply){Remove-SBRuntimeTree $full $config.brainRoot}
    ConvertTo-SBJson @{applied=[bool]$Apply;removed=[bool]$Apply;path=$full;category=$category;files=$count;bytes=$bytes};exit 0
}
if(!$Run){ConvertTo-SBJson $plan;exit 0}
if(!$FilePath -or !$WorkingDirectory){throw (New-SBError 'work.run.explicit')}
$bindings=@($config.bindings|Where-Object {$_.identity -ceq $Repository -and [IO.Path]::GetFullPath($_.path) -eq [IO.Path]::GetFullPath($WorkingDirectory)})
if($bindings.Count -ne 1){throw (New-SBError 'work.checkout.unmanaged')}
# Only the work root is created and exported; TEMP/TMP, caches and build outputs of the product stay in the native OS and product folders.
foreach($path in @($plan.environment.Values)){[IO.Directory]::CreateDirectory($path)|Out-Null}
$start=[Diagnostics.ProcessStartInfo]::new($FilePath);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=$WorkingDirectory
foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
foreach($key in $plan.environment.Keys){$start.Environment[$key]=$plan.environment[$key]}
$process=[Diagnostics.Process]::Start($start)
try{$process.WaitForExit();exit $process.ExitCode}finally{$process.Dispose()}
