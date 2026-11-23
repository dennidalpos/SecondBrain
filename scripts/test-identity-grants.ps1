# Included by essential after test-mcp-writes.ps1 (group mcp-writes). Fixtures for rename-identity.ps1 (#792) and the standing-grant onboarding hooks (#793).
$igRoot=Join-Path $fixture 'identity-grants'
function New-IGBrain([string]$Name){
    $path=Join-Path $igRoot $Name
    foreach($dir in @((Join-Path $path scripts))){[void][IO.Directory]::CreateDirectory($dir)}
    Get-ChildItem -LiteralPath (Join-Path $brain scripts) -File|Copy-Item -Destination (Join-Path $path scripts)
    foreach($file in 'config/shared.json','config/tracker.schema.json','directives/approved.json','directives/AGENTS.global_ide.md','directives/workstation.template.md','VERSION'){
        Put (Join-Path $path $file) (Read-SBText (Join-Path $brain $file))
    }
    $path
}
function New-IGDossier([string]$Brain,[string]$Folder,[string]$Identity,$Aliases,[string]$ReferencedIdentity){
    $dossier=Join-Path $Brain ('repos/'+$Folder)
    Put (Join-Path $dossier entity.json) (ConvertTo-SBJson @{schemaVersion=1;id=($Folder.ToLowerInvariant()+'-area');kind='area';title=$Folder;status='active'})
    $meta=@{schemaVersion=1;identity=$Identity;tracker=@{location='dossier';path='tracker.json';schemaVersion=1}}
    if($null -ne $Aliases){$meta.aliases=$Aliases}
    Put (Join-Path $dossier repository.json) (ConvertTo-SBJson $meta)
    foreach($name in 'brief.md','memory.md','context.md'){Put (Join-Path $dossier $name) ('# '+$Folder+"`n")}
    Put (Join-Path $dossier 'history/seed/report.md') 'Synthetic provenance'
    $task=New-SBTrackerTask @{id=($Folder+'-1');title='Synthetic task';status='todo';acceptance=@('fixture')} $ReferencedIdentity 'fixture' 'history/seed/report.md' (Get-SBTextHash 'Synthetic provenance') 'fixture'
    $task.seq=1;$task.title='#001 — Synthetic task'
    Put (Join-Path $dossier tracker.json) (ConvertTo-SBJson @{schemaVersion=1;repository=$ReferencedIdentity;updatedAt=[DateTimeOffset]::UtcNow.ToString('o');tasks=@($task);history=@();extensions=@{lastSeq=1}})
    $dossier
}
function New-IGRename([string]$Name,$Aliases){
    $from='github.com/test/'+$Name+'-old';$to='github.com/test/'+$Name+'-new'
    $path=New-IGBrain $Name
    $checkout=Join-Path $path 'checkout';[void][IO.Directory]::CreateDirectory($checkout)
    [void](Invoke-SBGit $checkout @('init','-q'));[void](Invoke-SBGit $checkout @('remote','add','origin',('https://'+$to+'.git')))
    $dossier=New-IGDossier $path 'Moved' $from $Aliases $from
    [void](New-IGDossier $path 'Bystander' ('github.com/test/'+$Name+'-other') $null $from)
    $runtime=Get-SBStateRoot $path (Get-SBHostId);$configPath=Join-Path $runtime workstation.json
    Put $configPath (ConvertTo-SBJson @{schemaVersion=1;mode='portable';brainRoot=$path;workstationId=(Get-SBHostId);runtimeRoot=$runtime;backupRoot=(Join-Path $runtime backups);bindings=@(@{identity=$from;remoteIdentity=$to;path=$checkout});ides=@();activityLogEnabled=$true})
    @{brain=$path;configPath=$configPath;from=$from;to=$to;dossier=$dossier;checkout=$checkout}
}
function Invoke-IGRename($Fx,[switch]$Apply,[string]$SessionId){
    $arguments=@('-NoProfile','-File',(Join-Path $Fx.brain 'scripts/rename-identity.ps1'),'-From',$Fx.from,'-To',$Fx.to)
    if($Apply){$arguments+=@('-Apply','-SessionId',$SessionId)}
    $out=@(& pwsh @arguments 2>&1)
    @{code=$LASTEXITCODE;text=($out|Out-String)}
}
function Start-IGSession($Fx,[string]$Identity){& (Join-Path $Fx.brain scripts/access.ps1) -Start -Mode Write -Client Fixture -Repository $Identity -ConfigPath $Fx.configPath|ConvertFrom-Json}
$igSavedHome=$env:SECONDBRAIN_HOME
try {
    # #792: rename-identity preview, refusal with unapplied queued writes, apply, and the alias array for none / one / several existing aliases.
    foreach($case in @(@{name='rn0';aliases=$null;expect=@()},@{name='rn1';aliases=@('github.com/test/legacy-one');expect=@('github.com/test/legacy-one')})){
        $fx=New-IGRename $case.name $case.aliases
        $env:SECONDBRAIN_HOME=$fx.brain
        $metaPath=Join-Path $fx.dossier repository.json
        $before=@{meta=(Get-SBFileHash $metaPath);tracker=(Get-SBFileHash (Join-Path $fx.dossier tracker.json));config=(Get-SBFileHash $fx.configPath)}
        $preview=Invoke-IGRename $fx
        Check ($preview.code -eq 0) ($case.name+': rename preview succeeds: '+$preview.text)
        $previewJson=$preview.text|ConvertFrom-Json -AsHashtable
        Check (!$previewJson.applied -and @($previewJson.otherDossiersReferencingOldIdentity) -contains ('github.com/test/'+$case.name+'-other')) ($case.name+': the preview lists other dossiers that still reference the old identity')
        Check ($before.meta -ceq (Get-SBFileHash $metaPath) -and $before.tracker -ceq (Get-SBFileHash (Join-Path $fx.dossier tracker.json)) -and $before.config -ceq (Get-SBFileHash $fx.configPath)) ($case.name+': the preview writes nothing')
        $bystander=Join-Path $fx.brain 'repos/Bystander/tracker.json';$bystanderHash=Get-SBFileHash $bystander
        $session=Start-IGSession $fx $fx.from
        try{
            if($case.name -eq 'rn0'){
                # An unapplied queued write of the old identity blocks the apply.
                $cfg=Read-SBConfiguration -BrainRoot $fx.brain -ConfigPath $fx.configPath -ReadOnly
                $queued=New-SBPendingWrite -BrainRoot $fx.brain -Repository $fx.from -Operation file.append -Arguments @{relativePath='memory.md';content='queued'} -Config $cfg
                $refused=Invoke-IGRename $fx -Apply -SessionId $session.sessionId
                Check ($refused.code -ne 0 -and $refused.text -like '*queued dossier writes*') 'rn0: apply is refused while the old identity has unapplied queued writes'
                Check ($before.meta -ceq (Get-SBFileHash $metaPath)) 'rn0: the refused apply leaves the dossier untouched'
                [void](Invoke-SBPendingWrites -BrainRoot $fx.brain -Config $cfg -RequestId $queued.id)
            }
            $applied=Invoke-IGRename $fx -Apply -SessionId $session.sessionId
            Check ($applied.code -eq 0) ($case.name+': rename apply succeeds: '+$applied.text)
        }finally{& (Join-Path $fx.brain scripts/access.ps1) -End -SessionId $session.sessionId -ConfigPath $fx.configPath|Out-Null}
        $metaAfter=Read-SBJson $metaPath $null
        Check ($metaAfter.identity -ceq $fx.to) ($case.name+': the dossier carries the new identity')
        $expectedAliases=@(@($case.expect)+@($fx.from)|Sort-Object -Unique)
        Check ($metaAfter.aliases -is [System.Collections.IList] -and (@($metaAfter.aliases) -join '|') -ceq ($expectedAliases -join '|') -and @($metaAfter.aliases) -notcontains $fx.to) ($case.name+': aliases is an array with the old identity and not the new one: '+(ConvertTo-SBJson $metaAfter.aliases))
        Check ((Read-SBJson (Join-Path $fx.dossier tracker.json) $null).repository -ceq $fx.to -and !(Read-SBText (Join-Path $fx.dossier tracker.json)).Contains($fx.from)) ($case.name+': tracker references move to the new identity')
        Check ($bystanderHash -ceq (Get-SBFileHash $bystander)) ($case.name+': another dossier is reported, never edited')
        $bindingAfter=@((Read-SBJson $fx.configPath $null).bindings)
        Check ($bindingAfter.Count -eq 1 -and $bindingAfter[0].identity -ceq $fx.to) ($case.name+': the workstation binding moves to the new identity')
        $again=Invoke-IGRename $fx
        Check ($again.code -ne 0) ($case.name+': a second rename of the same identity is refused')
    }
    # #793: onboard -Apply issues the standing grant; secondbrain.ps1 is stubbed in the fixture so no IDE file, allowlist or environment variable is touched.
    $gb=New-IGBrain 'grants'
    $gCheckouts=@{}
    foreach($name in 'a','b','c','e'){
        $dir=Join-Path $gb ('co-'+$name);[void][IO.Directory]::CreateDirectory($dir)
        [void](Invoke-SBGit $dir @('init','-q'));[void](Invoke-SBGit $dir @('remote','add','origin',('https://github.com/test/ig-'+$name+'.git')))
        $gCheckouts[$name]=$dir
        [void](New-IGDossier $gb ('Ig'+$name.ToUpperInvariant()) ('github.com/test/ig-'+$name) $null ('github.com/test/ig-'+$name))
    }
    $gRuntime=Get-SBStateRoot $gb (Get-SBHostId);$gConfigPath=Join-Path $gRuntime workstation.json
    $gBindings=@(foreach($name in 'a','b','c','e'){@{identity=('github.com/test/ig-'+$name);remoteIdentity=('github.com/test/ig-'+$name);path=$gCheckouts[$name]}})
    Put $gConfigPath (ConvertTo-SBJson @{schemaVersion=1;mode='portable';brainRoot=$gb;workstationId=(Get-SBHostId);runtimeRoot=$gRuntime;backupRoot=(Join-Path $gRuntime backups);bindings=$gBindings;ides=@();activityLogEnabled=$true})
    Put (Join-Path $gb 'scripts/secondbrain.ps1') @'
param([string]$AddRepo,[string]$Customer,[switch]$ApplyAdd,[string]$SessionId)
@{applied=[bool]$ApplyAdd;entry=@{identity=$env:IG_STUB_IDENTITY;path=$AddRepo}}|ConvertTo-Json -Depth 4
'@
    $env:SECONDBRAIN_HOME=$gb
    function Get-IGGrants{@((Get-SBMcpWriteGrants $gb $gConfigPath).grants)}
    function Get-IGActiveCount([string]$Identity){@(Get-IGGrants|Where-Object {$_.repository -ceq $Identity -and $_.state -eq 'active'}).Count}
    function Invoke-IGOnboard([string]$Identity,[switch]$Apply,[switch]$NoGrant){
        $env:IG_STUB_IDENTITY=$Identity
        $arguments=@('-NoProfile','-File',(Join-Path $gb 'scripts/onboard.ps1'),'-Path',$gCheckouts['a'])
        if($Apply){$arguments+='-Apply'};if($NoGrant){$arguments+='-NoGrant'}
        $out=@(& pwsh @arguments 2>&1)
        @{code=$LASTEXITCODE;text=($out|Out-String)}
    }
    try {
        $preview=Invoke-IGOnboard 'github.com/test/ig-a'
        Check ($preview.code -eq 0 -and (Get-IGActiveCount 'github.com/test/ig-a') -eq 0) 'onboard without -Apply issues no grant'
        $applied=Invoke-IGOnboard 'github.com/test/ig-a' -Apply
        Check ($applied.code -eq 0 -and (Get-IGActiveCount 'github.com/test/ig-a') -eq 1) ('onboard -Apply issues an active standing grant for a repository with a remote identity: '+$applied.text)
        $local=Invoke-IGOnboard 'local:ig-local' -Apply
        Check ($local.code -eq 0 -and @(Get-IGGrants|Where-Object {$_.repository -like 'local*'}).Count -eq 0) 'onboard -Apply issues no grant for a local: identity'
        $skipped=Invoke-IGOnboard 'github.com/test/ig-b' -Apply -NoGrant
        Check ($skipped.code -eq 0 -and (Get-IGActiveCount 'github.com/test/ig-b') -eq 0) 'onboard -Apply -NoGrant skips the grant'
        $revokeSession=& (Join-Path $gb scripts/access.ps1) -Start -Mode Write -Client Fixture -Repository 'github.com/test/ig-a' -ConfigPath $gConfigPath|ConvertFrom-Json
        try{
            $revoked=@(& pwsh -NoProfile -File (Join-Path $gb 'scripts/mcp-write.ps1') -Revoke -Repository 'github.com/test/ig-a' -SessionId $revokeSession.sessionId 2>&1)
            Check ($LASTEXITCODE -eq 0 -and (Get-IGActiveCount 'github.com/test/ig-a') -eq 0) ('mcp-write.ps1 -Revoke ends the standing grant: '+($revoked|Out-String))
        }finally{& (Join-Path $gb scripts/access.ps1) -End -SessionId $revokeSession.sessionId -ConfigPath $gConfigPath|Out-Null}
        # grant-repositories: a pre-existing active grant is left alone, the others are previewed, then granted on -Apply.
        $again=Invoke-IGOnboard 'github.com/test/ig-c' -Apply
        Check ($again.code -eq 0 -and (Get-IGActiveCount 'github.com/test/ig-c') -eq 1) 'a second repository gets its own grant through onboard'
        $grantedAt=@(Get-IGGrants|Where-Object {$_.repository -ceq 'github.com/test/ig-c'})[0]|ConvertTo-SBJson
        $listBefore=(Get-IGGrants|ConvertTo-SBJson)
        $listing=@(& pwsh -NoProfile -File (Join-Path $gb 'scripts/grant-repositories.ps1') 2>&1|Out-String)
        Check ($listing -match 'would-grant' -and $listing -match 'already-granted' -and $listing -match 'Preview only' -and (Get-IGGrants|ConvertTo-SBJson) -ceq $listBefore) 'grant-repositories previews would-grant and already-granted without writing'
        $grantRun=@(& pwsh -NoProfile -File (Join-Path $gb 'scripts/grant-repositories.ps1') -Apply 2>&1|Out-String)
        Check ($LASTEXITCODE -eq 0 -and $grantRun -match 'granted') ('grant-repositories -Apply runs: '+$grantRun)
        Check ((Get-IGActiveCount 'github.com/test/ig-a') -eq 1 -and (Get-IGActiveCount 'github.com/test/ig-b') -eq 1 -and (Get-IGActiveCount 'github.com/test/ig-e') -eq 1 -and (Get-IGActiveCount 'github.com/test/ig-c') -eq 1) 'grant-repositories -Apply grants the repositories without one'
        Check ((@(Get-IGGrants|Where-Object {$_.repository -ceq 'github.com/test/ig-c'})[0]|ConvertTo-SBJson) -ceq $grantedAt) 'grant-repositories leaves an existing active grant untouched'
    } finally {Remove-Item Env:IG_STUB_IDENTITY -ErrorAction SilentlyContinue}
} finally {$env:SECONDBRAIN_HOME=$igSavedHome}
