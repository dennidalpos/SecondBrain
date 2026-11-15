#requires -Version 7.5
# Delegated IDE/agent verification (#155): SecondBrain builds an instruction package, an installed agent observes a
# NEW session and produces a receipt; this module validates and registers it. It never edits IDE files, never reads
# authentication stores and never automates a login.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'ideobs.invalid' = @{ en = 'IDE observation: invalid data ({0})' }
    'ideobs.preview' = @{ en = 'IDE observation: preview hash missing or different; run a new preview' }
}
$script:SBIdeObservationFields=@('ideId','workstationId','profile','environment','accountAlias','accountVerified','observedAt','observedHash','loadingVerified','sessionId','evidencePath','evidenceSha256')

function Get-SBIdeObservationStorePath([string]$BrainRoot) {
    Join-Path ([IO.Path]::GetFullPath($BrainRoot)) ('.runtime/hosts/'+(Get-SBHostId)+'/ide-observations.json')
}

function Find-SBIdeEntry($Map,[string]$IdeId) {
    $found=@($Map.ides|Where-Object {$_ -is [Collections.IDictionary] -and $_.ContainsKey('id') -and $_.id -ceq $IdeId -and (!$_.ContainsKey('selected') -or $_.selected)})
    if($found.Count -ne 1){throw (New-SBError 'ideobs.invalid' @('ide id'))}
    $found[0]
}

# Package for an installed agent: what to verify in a new session and the exact receipt to produce.
function Get-SBIdeObservationPackage($Ide,[string]$GlobalText,[string]$BrainRoot,[string]$WorkstationId) {
    $hash=Get-SBTextHash $GlobalText.Trim()
    $revision=if($GlobalText -match 'Revisi(?:on|one) (\d+(?:\.\d+)+)'){$Matches[1]}else{'unknown'}
    $evidenceDir=Join-Path ([IO.Path]::GetFullPath($BrainRoot)) ('.runtime/hosts/'+$WorkstationId+'/ide-evidence')
    $template=[ordered]@{ideId=$Ide.id;workstationId=$WorkstationId;profile=$(if($Ide.ContainsKey('profile')){$Ide.profile}else{'default'});observedAt='<ISO 8601 UTC, at most 15 minutes old>';
        observedHash=$hash;loadingVerified=$true;sessionId='<id of the NEW session>';evidencePath=(Join-Path $evidenceDir ($Ide.id+'.txt'));evidenceSha256='<sha256 of the evidence file>'}
    if($Ide.ContainsKey('environment')){$template.environment=$Ide.environment}
    if($Ide.mode -eq 'manual'){$template.accountAlias=$Ide.accountAlias;$template.accountVerified=$true}
    $steps=@(
        'Open a NEW session in the client/profile below; do not reuse an older conversation.',
        'Confirm the active account is the one declared by the alias. Do not read, copy or print credentials, tokens or authentication stores, and do not sign in or out on behalf of the user.',
        ('Ask the session to quote the revision line and state whether the SecondBrain global instructions are loaded ("Revisione '+$revision+'").'),
        'Save a short proof (revision line and session id, no secrets) to the evidencePath and compute its SHA-256.',
        ('Write the receipt below as JSON under .runtime and register it with: pwsh -NoProfile -File scripts/ide-observation.ps1 -Operation Register -IdeId '+$Ide.id+' -InputPath <receipt.json>; review the preview and repeat with -PreviewSha256 <hash> -Apply.'))
    [ordered]@{schemaVersion=1;ideId=$Ide.id;name=$Ide.name;mode=$Ide.mode;accountAlias=$(if($Ide.ContainsKey('accountAlias')){$Ide.accountAlias}else{$null});
        expectedRevision=$revision;expectedHash=$hash;steps=$steps;receiptTemplate=$template;
        boundary='SecondBrain does not log in, read authentication stores or modify IDE files. The receipt is declared by the observing agent and proven only by the evidence file hash.'}
}

function Test-SBIdeObservationInput($Input_,[string]$IdeId) {
    if($Input_ -isnot [Collections.IDictionary]){throw (New-SBError 'ideobs.invalid' @('receipt'))}
    foreach($key in $Input_.Keys){if($key -cnotin $script:SBIdeObservationFields){throw (New-SBError 'ideobs.invalid' @('field '+$key))}}
    if(!$Input_.ContainsKey('ideId') -or $Input_.ideId -cne $IdeId){throw (New-SBError 'ideobs.invalid' @('ideId'))}
    foreach($key in 'workstationId','profile','observedAt','observedHash','loadingVerified','sessionId','evidencePath','evidenceSha256'){
        if(!$Input_.ContainsKey($key)){throw (New-SBError 'ideobs.invalid' @('missing '+$key))}
    }
    if($Input_.sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($Input_.sessionId) -or $Input_.sessionId.Length -gt 256){throw (New-SBError 'ideobs.invalid' @('sessionId'))}
    if($Input_.evidenceSha256 -isnot [string] -or $Input_.evidenceSha256 -cnotmatch '^[A-Fa-f0-9]{64}$'){throw (New-SBError 'ideobs.invalid' @('evidenceSha256'))}
}

function Read-SBIdeObservationStore([string]$BrainRoot) {
    $path=Get-SBIdeObservationStorePath $BrainRoot
    Assert-SBPlainPath $path
    $store=Read-SBJson $path $null
    if($store -and $store.schemaVersion -eq 1 -and $store.observations -is [array]){return @{path=$path;hash=(Get-SBFileHash $path);observations=@($store.observations)}}
    @{path=$path;hash=(Get-SBFileHash $path);observations=@()}
}

function Save-SBIdeObservationStore($Store,$Observations,[string]$BackupRoot) {
    $document=[ordered]@{schemaVersion=1;observations=@($Observations)}
    [void][IO.Directory]::CreateDirectory((Split-Path $Store.path))
    [void](Write-SBFile $Store.path ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-SBJson $document))) $Store.hash $BackupRoot)
}

# Validates with the same predicate used by ide-map/Check; the receipt replaces any previous one for the same IDE id.
function Register-SBIdeObservation($Map,[string]$IdeId,$Receipt,[string]$GlobalText,[string]$BrainRoot,[string]$WorkstationId,[string]$BackupRoot,[switch]$Apply,[string]$PreviewSha256) {
    $ide=Find-SBIdeEntry $Map $IdeId
    Test-SBIdeObservationInput $Receipt $IdeId
    $expected=Get-SBTextHash $GlobalText.Trim()
    if(!(Test-SBIDEObservation $ide $expected @($Receipt) $BrainRoot $WorkstationId)){throw (New-SBError 'ideobs.invalid' @('observation does not qualify this IDE/account'))}
    $normalized=ConvertTo-SBStableValue $Receipt
    $previewHash=Get-SBTextHash (ConvertTo-SBJson $normalized)
    $store=Read-SBIdeObservationStore $BrainRoot
    if($Apply){
        if($PreviewSha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or $PreviewSha256 -ine $previewHash){throw (New-SBError 'ideobs.preview')}
        $kept=@($store.observations|Where-Object {$_.ideId -cne $IdeId})
        Save-SBIdeObservationStore $store (@($kept)+@(,$normalized)) $BackupRoot
    }
    @{state=$(if($Apply){'registered'}else{'preview'});ideId=$IdeId;accountAlias=$(if($ide.ContainsKey('accountAlias')){$ide.accountAlias}else{$null});previewSha256=$previewHash;store=$store.path}
}

# Receipts of integrations no longer in the map (for example after -Unbind) are removed; others are untouched.
function Remove-SBStaleIdeObservations($Map,[string]$BrainRoot,[string]$BackupRoot,[switch]$Apply) {
    $active=@($Map.ides|Where-Object {$_ -is [Collections.IDictionary] -and $_.ContainsKey('id') -and (!$_.ContainsKey('selected') -or $_.selected)}|ForEach-Object id)
    $store=Read-SBIdeObservationStore $BrainRoot
    $stale=@($store.observations|Where-Object {$_.ideId -cnotin $active})
    if($Apply -and $stale.Count){Save-SBIdeObservationStore $store @($store.observations|Where-Object {$_.ideId -cin $active}) $BackupRoot}
    @{state=$(if(!$stale.Count){'unchanged'}elseif($Apply){'pruned'}else{'preview'});removed=@($stale|ForEach-Object ideId)}
}
# Guide: everything deterministic is checked here (file block against the generated text, account text hash against the observed
# one, observation receipts); what only a person can do is returned as an action with the steps for that client. Read-only.
$script:SBIdeGuideWhere=@{
    'Claude account instructions'='Claude app or claude.ai: Settings, then the profile or personal preferences (custom instructions) field.'
    'VS Code'='Your chat extension''s custom-instructions setting (user settings or a user-level instructions file); the location depends on the extension and version.'
    'Android Studio'='Settings, then the AI assistant''s rules or custom-instructions page; the location depends on the plugin and version.'
    'Continue'='The user-level Continue configuration (rules); the location depends on the version.'
    'JetBrains AI'='Settings, then the AI Assistant rules or custom-instructions page; the location depends on the version.'
}
Add-SBMessages @{
    'ideguide.file.aligned' = @{ en = 'file block aligned (revision {0}); loading in a session is not certified by the file' }
    'ideguide.file.stale' = @{ en = 'file block out of date (found revision {0}, expected {1})' }
    'ideguide.file.noblock' = @{ en = 'file without the secondbrain:global block (revision {0})' }
    'ideguide.file.missing' = @{ en = 'instructions file missing: {0}' }
    'ideguide.manual.stale' = @{ en = 'account text out of date (observed revision {0}, expected {1})' }
    'ideguide.manual.unobserved' = @{ en = 'no valid observation of the account text' }
    'ideguide.observed' = @{ en = 'new-session observation valid' }
    'ideguide.loading.unobserved' = @{ en = 'loading in a new session not observed' }
    'ideguide.step.sync' = @{ en = 'Run: pwsh -NoProfile -File scripts/secondbrain.ps1 -Sync (rewrites only the managed block; review conflicts it reports).' }
    'ideguide.step.paste' = @{ en = 'Open {0} and replace the previous SecondBrain text with the text below, or add it if there is none. Where: {1}' }
    'ideguide.step.paste.generic' = @{ en = 'Apply the text below in the instructions setting of this client; check the client documentation for the exact place in your version.' }
    'ideguide.step.new' = @{ en = 'Open a NEW session in the client and profile of this integration (not an old conversation) and check that the active account is the declared one; do not share credentials.' }
    'ideguide.step.quote' = @{ en = 'Ask the session to quote the line starting with "Revision {0}" and say whether the SecondBrain instructions are loaded.' }
    'ideguide.step.record' = @{ en = 'Record the observation: pwsh -NoProfile -File scripts/ide-observation.ps1 -Operation Package -IdeId {0} prints the steps and the receipt template; register it with -Operation Register (preview, then -PreviewSha256 and -Apply).' }
    'ideguide.step.declare' = @{ en = 'Declare the pasted account text (preview first, then add -Yes -Apply): pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -Roots <your roots> -IdeAccount "{0}|{1}|revision={2}|hash={3}" -PreviewOnly' }
}
function Get-SBIdeGuide($Map,[string]$GlobalText,$Observations,[string]$BrainRoot,[string]$WorkstationId) {
    $expected=$GlobalText.Trim()
    $revision=if($expected -match 'Revisi(?:on|one) (\d+(?:\.\d+)+)'){$Matches[1]}else{'unknown'}
    $hash=Get-SBTextHash $expected
    $wanted="<!-- secondbrain:global:begin -->`n"+$expected+"`n<!-- secondbrain:global:end -->"
    $items=@()
    foreach($ide in $Map.ides){
        if($ide.ContainsKey('selected') -and !$ide.selected){continue}
        $label=$ide.name+$(if($ide.ContainsKey('id')){' ['+$ide.id+$(if($ide.ContainsKey('accountAlias') -and $ide.accountAlias){', alias '+$ide.accountAlias})+']'})
        $automated=@();$steps=@();$needsPaste=$false
        $observed=Test-SBIDEObservation $ide $hash @($Observations) $BrainRoot $WorkstationId
        if($ide.mode -eq 'file'){
            if(!(Test-Path -LiteralPath ([string]$ide.instructions) -PathType Leaf)){
                $automated+=(Get-SBMessage 'ideguide.file.missing' @([string]$ide.instructions));$steps+=(Get-SBMessage 'ideguide.step.sync')
            }else{
                $text=(Read-SBText $ide.instructions) -replace "`r`n","`n"
                $block=Get-SBManagedContent $text 'global'
                $found=if($null -ne $block -and $block -match 'Revisi(?:on|one) (\d+(?:\.\d+)+)'){$Matches[1]}else{'none'}
                if($null -ne $block -and $block -ceq $wanted){$automated+=(Get-SBMessage 'ideguide.file.aligned' @($found))}
                else{
                    $automated+=$(if($null -eq $block){Get-SBMessage 'ideguide.file.noblock' @($found)}else{Get-SBMessage 'ideguide.file.stale' @($found,$revision)})
                    $steps+=(Get-SBMessage 'ideguide.step.sync')
                }
            }
        }else{
            if($ide.ContainsKey('observedHash') -and $ide.observedHash -and [string]$ide.observedHash -cne $hash){
                $automated+=(Get-SBMessage 'ideguide.manual.stale' @($(if($ide.ContainsKey('observedRevision') -and $ide.observedRevision){$ide.observedRevision}else{'unknown'}),$revision));$needsPaste=$true
            }elseif(!$observed){$automated+=(Get-SBMessage 'ideguide.manual.unobserved');$needsPaste=$true}
        }
        if($observed){$automated+=(Get-SBMessage 'ideguide.observed')}
        else{
            $automated+=(Get-SBMessage 'ideguide.loading.unobserved')
            if($needsPaste){
                $where=$script:SBIdeGuideWhere[[string]$ide.name]
                $steps+=$(if($where){Get-SBMessage 'ideguide.step.paste' @($ide.name,$where)}else{Get-SBMessage 'ideguide.step.paste.generic'})
                $steps+=(Get-SBMessage 'ideguide.step.declare' @($ide.name,$(if($ide.ContainsKey('accountAlias') -and $ide.accountAlias){$ide.accountAlias}else{'<alias>'}),$revision,$hash))
            }
            $steps+=(Get-SBMessage 'ideguide.step.new');$steps+=(Get-SBMessage 'ideguide.step.quote' @($revision))
            $steps+=(Get-SBMessage 'ideguide.step.record' @($ide.id))
        }
        $items+=[ordered]@{ide=$label;automated=@($automated);steps=@($steps);complete=[bool](!$steps.Count)}
    }
    [ordered]@{expectedRevision=$revision;expectedHash=$hash;items=@($items);pending=@($items|Where-Object {!$_.complete}).Count;pasteText=$expected}
}
Export-ModuleMember -Function @('Get-SBIdeObservationStorePath','Get-SBIdeObservationPackage','Register-SBIdeObservation','Remove-SBStaleIdeObservations','Read-SBIdeObservationStore','Get-SBIdeGuide')
