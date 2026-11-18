#requires -Version 7.5
# End-to-end fixtures for scripts/subagents.ps1 Create, Edit, Revise and Retire (#674): write session, preview, -Apply, backups and exit codes.
# Synthetic dossier in an isolated fixture brain; no real dossier is touched.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:cliChecks=0
function Assert-Cli($Condition,[string]$Message){if(!$Condition){throw ('FAIL SUBAGENTS-CLI: '+$Message)};$script:cliChecks++}
function Write-CliFile([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory((Split-Path $Path))|Out-Null;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
$fixture=Join-Path (Get-SBTestRoot) ('subagents-cli-'+[guid]::NewGuid().ToString('N'))
$brain=Join-Path $fixture 'brain'
$identity='github.com/test/subcli'
$dossier=Join-Path $brain 'repos/SubCli'
$agentDir=Join-Path $dossier 'subagents'
$hostId=Get-SBHostId
$runtime=Join-Path $brain ('.runtime/hosts/'+$hostId)
$configPath=Join-Path $runtime 'workstation.json'
$backupRoot=Join-Path $runtime 'backups'
function Invoke-SubCli([string[]]$CliArguments){
    # The fixture brain is the parent of its own scripts/: an inherited override (queue runs) would point the CLI at the live dossier.
    $saved=$env:SECONDBRAIN_BRAIN_ROOT;Remove-Item Env:SECONDBRAIN_BRAIN_ROOT -ErrorAction SilentlyContinue
    try{
        $lines=@(& pwsh -NoProfile -File (Join-Path $brain 'scripts/subagents.ps1') -Repository $identity -ConfigPath $configPath @CliArguments 2>&1|ForEach-Object {$_.ToString()})
        $code=$LASTEXITCODE
    }finally{if($null -ne $saved){$env:SECONDBRAIN_BRAIN_ROOT=$saved}}
    @{code=$code;text=($lines -join "`n")}
}
function Get-BackupCount{if(Test-Path -LiteralPath $backupRoot){@(Get-ChildItem -LiteralPath $backupRoot -Recurse -File).Count}else{0}}
function Get-FileText([string]$Path){if(Test-Path -LiteralPath $Path){[IO.File]::ReadAllText($Path)}else{$null}}
function Read-Def([string]$Path){(Get-FileText $Path)|ConvertFrom-Json -AsHashtable}
function New-CliDef([string]$name){
    [ordered]@{schemaVersion=2;name=$name;description='Reads tasks and searches knowledge.';role='You are a read-only reviewer.';context='Start from the tracker task; cite sources.';permissions=[ordered]@{tools=@('get_task','search_knowledge');write=$false};output=[ordered]@{kind='report'};bounds=[ordered]@{depth=1;budget=[ordered]@{turns=20}}}
}
function Save-CliJson([string]$Name,$Value){$p=Join-Path $fixture $Name;Write-CliFile $p (ConvertTo-SBJson $Value);$p}
[IO.Directory]::CreateDirectory((Join-Path $brain 'scripts'))|Out-Null
Get-ChildItem -LiteralPath $PSScriptRoot -File|Copy-Item -Destination (Join-Path $brain 'scripts')
Write-CliFile (Join-Path $brain 'VERSION') (Read-SBText (Join-Path $PSScriptRoot '../VERSION'))
Write-CliFile (Join-Path $brain 'config/shared.json') (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
Write-CliFile (Join-Path $dossier 'entity.json') (ConvertTo-SBJson @{schemaVersion=1;id='subcli-area';kind='area';title='SubCli';status='active'})
Write-CliFile (Join-Path $dossier 'repository.json') (ConvertTo-SBJson @{schemaVersion=1;identity=$identity;tracker=@{location='dossier';path='tracker.json';schemaVersion=1}})
Write-CliFile (Join-Path $dossier 'context.md') "# Context`n"
Write-CliFile (Join-Path $dossier 'memory.md') "# Memory`n"
Write-CliFile (Join-Path $dossier 'brief.md') '# Synthetic subagents CLI fixture'
$cfg=@{schemaVersion=1;mode='portable';brainRoot=$brain;workstationId=$hostId;runtimeRoot=$runtime;backupRoot=$backupRoot;repositoryRoot=$brain;coordinationRoot=(Join-Path $brain '.runtime/access');bindings=@();ides=@();sessionTimeoutMinutes=30;lockWaitMs=60000;configPath=$configPath}
Write-CliFile $configPath (ConvertTo-SBJson $cfg)
$file=Join-Path $agentDir 'planner.json'

# Create: preview writes nothing, -Apply writes the definition.
$createPath=Save-CliJson 'create.json' (New-CliDef 'planner')
$r=Invoke-SubCli @('-Operation','Create','-DefinitionPath',$createPath)
Assert-Cli ($r.code -eq 0 -and $r.text -match '"state":\s*"preview"' -and !(Test-Path -LiteralPath $file)) ('Create preview exits 0 and writes nothing: '+$r.text)
$r=Invoke-SubCli @('-Operation','Create','-DefinitionPath',$createPath,'-Apply')
Assert-Cli ($r.code -eq 0 -and $r.text -match '"state":\s*"applied"' -and (Test-Path -LiteralPath $file)) ('Create -Apply writes the definition: '+$r.text)
$created=Read-Def $file
Assert-Cli ($created.revision -eq 1 -and $created.id -cmatch '^agt-[0-9a-f]{8}$') 'created definition has revision 1 and an assigned ID'
Assert-Cli ((Invoke-SubCli @('-Operation','Validate')).code -eq 0) 'Validate accepts the created definition'
$createdText=Get-FileText $file
$r=Invoke-SubCli @('-Operation','Create','-DefinitionPath',$createPath,'-Apply')
Assert-Cli ($r.code -ne 0 -and (Get-FileText $file) -ceq $createdText) 'Create of an existing name exits non-zero and changes nothing'

# Edit: preview leaves the file byte-identical; -Apply changes the wording and backs the previous file up.
$before=Get-FileText $file;$backupsBefore=Get-BackupCount
$editPath=Save-CliJson 'edit.json' @{name='planner';description='A clearer description.'}
$r=Invoke-SubCli @('-Operation','Edit','-DefinitionPath',$editPath)
Assert-Cli ($r.code -eq 0 -and $r.text -match '"state":\s*"preview"' -and (Get-FileText $file) -ceq $before -and (Get-BackupCount) -eq $backupsBefore) ('Edit preview changes neither file nor backups: '+$r.text)
$r=Invoke-SubCli @('-Operation','Edit','-DefinitionPath',$editPath,'-Apply')
$after=Read-Def $file
Assert-Cli ($r.code -eq 0 -and $after.description -ceq 'A clearer description.' -and $after.revision -eq 1) ('Edit -Apply changes the description and keeps the revision: '+$r.text)
Assert-Cli ((Get-BackupCount) -gt $backupsBefore) 'Edit -Apply keeps a backup of the previous file'
Assert-Cli (@(Get-ChildItem -LiteralPath $backupRoot -Recurse -File|Where-Object {(Get-FileText $_.FullName) -ceq $before}).Count -ge 1) 'the backup holds the content before the edit'
$afterText=Get-FileText $file
$r=Invoke-SubCli @('-Operation','Edit','-DefinitionPath',(Save-CliJson 'edit-contract.json' @{name='planner';role='A different role.'}),'-Apply')
Assert-Cli ($r.code -ne 0 -and (Get-FileText $file) -ceq $afterText) 'Edit of a contract field exits non-zero and changes nothing'
$r=Invoke-SubCli @('-Operation','Edit','-DefinitionPath',$editPath,'-Apply')
Assert-Cli ($r.code -ne 0 -and (Get-FileText $file) -ceq $afterText) 'Edit with no change exits non-zero'

# Revise: next revision with a compatible change; widening or skipping is refused.
$backupsBefore=Get-BackupCount
$rev=Read-Def $file;$rev.revision=2;$rev.context='Start from the tracker task; cite sources; keep answers short.'
$revPath=Save-CliJson 'revise.json' $rev
$r=Invoke-SubCli @('-Operation','Revise','-DefinitionPath',$revPath)
Assert-Cli ($r.code -eq 0 -and $r.text -match '"state":\s*"preview"' -and (Get-FileText $file) -ceq $afterText -and (Get-BackupCount) -eq $backupsBefore) ('Revise preview changes nothing: '+$r.text)
$r=Invoke-SubCli @('-Operation','Revise','-DefinitionPath',$revPath,'-Apply')
$revised=Read-Def $file
Assert-Cli ($r.code -eq 0 -and $revised.revision -eq 2 -and $revised.id -ceq $created.id -and $revised.context -ceq $rev.context) ('Revise -Apply bumps the revision and keeps the ID: '+$r.text)
Assert-Cli ((Get-BackupCount) -gt $backupsBefore) 'Revise -Apply keeps a backup'
$revisedText=Get-FileText $file
$wide=Read-Def $file;$wide.revision=3;$wide.permissions.tools=@('get_task','search_knowledge','get_decisions')
$r=Invoke-SubCli @('-Operation','Revise','-DefinitionPath',(Save-CliJson 'widen.json' $wide),'-Apply')
Assert-Cli ($r.code -ne 0 -and (Get-FileText $file) -ceq $revisedText) 'a widening Revise exits non-zero and changes nothing'
$skip=Read-Def $file;$skip.revision=9;$skip.context='skip ahead'
$r=Invoke-SubCli @('-Operation','Revise','-DefinitionPath',(Save-CliJson 'skip.json' $skip),'-Apply')
Assert-Cli ($r.code -ne 0 -and (Get-FileText $file) -ceq $revisedText) 'a Revise that skips a revision exits non-zero'

# Retire: preview, then -Apply; forward transitions only.
$backupsBefore=Get-BackupCount
$r=Invoke-SubCli @('-Operation','Retire','-Name','planner','-Status','deprecated')
Assert-Cli ($r.code -eq 0 -and $r.text -match '"state":\s*"preview"' -and (Get-FileText $file) -ceq $revisedText -and (Get-BackupCount) -eq $backupsBefore) ('Retire preview changes nothing: '+$r.text)
$r=Invoke-SubCli @('-Operation','Retire','-Name','planner','-Status','deprecated','-Apply')
Assert-Cli ($r.code -eq 0 -and (Read-Def $file).status -ceq 'deprecated' -and (Get-BackupCount) -gt $backupsBefore) ('Retire -Apply deprecates and keeps a backup: '+$r.text)
$r=Invoke-SubCli @('-Operation','Retire','-Name','planner','-Status','retired','-Apply')
Assert-Cli ($r.code -eq 0 -and (Read-Def $file).status -ceq 'retired') ('Retire -Apply retires: '+$r.text)
$frozen=Get-FileText $file
$r=Invoke-SubCli @('-Operation','Retire','-Name','planner','-Status','deprecated','-Apply')
Assert-Cli ($r.code -ne 0 -and (Get-FileText $file) -ceq $frozen) 'a retired definition cannot go back: non-zero and unchanged'
$r=Invoke-SubCli @('-Operation','Retire','-Name','missing','-Status','retired','-Apply')
Assert-Cli ($r.code -ne 0) 'retiring an unknown definition exits non-zero'
$r=Invoke-SubCli @('-Operation','Retire','-Name','planner','-Status','retired','-ReplacedBy','agt-0000dead','-Apply')
Assert-Cli ($r.code -ne 0 -and (Get-FileText $file) -ceq $frozen) 'Retire with an unknown replacement exits non-zero'

# Parameter and input refusals.
Assert-Cli ((Invoke-SubCli @('-Operation','Create','-Apply')).code -ne 0) 'Create without -DefinitionPath exits non-zero'
Assert-Cli ((Invoke-SubCli @('-Operation','Create','-DefinitionPath',(Join-Path $fixture 'absent.json'),'-Apply')).code -ne 0) 'Create with a missing definition file exits non-zero'
Write-CliFile (Join-Path $fixture 'bad.json') 'not json{'
Assert-Cli ((Invoke-SubCli @('-Operation','Create','-DefinitionPath',(Join-Path $fixture 'bad.json'),'-Apply')).code -ne 0) 'Create with invalid JSON exits non-zero'
$bad=New-CliDef 'broken';$bad.permissions.tools=@('rm_rf')
$r=Invoke-SubCli @('-Operation','Create','-DefinitionPath',(Save-CliJson 'unknown-tool.json' $bad),'-Apply')
Assert-Cli ($r.code -ne 0 -and !(Test-Path -LiteralPath (Join-Path $agentDir 'broken.json'))) 'Create with an unknown tool exits non-zero and writes nothing'
Assert-Cli (@(Get-ChildItem -LiteralPath $agentDir -File).Count -eq 1) 'only the one definition exists after every refusal'
'SUCCESS SUBAGENTS-CLI: '+$script:cliChecks+' checks; retained fixture '+$fixture
