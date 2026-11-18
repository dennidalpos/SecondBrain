#requires -Version 7.5
Set-StrictMode -Version Latest
foreach($m in 'Core','Access','Host','Pending','Tracker','Knowledge','Para'){Import-Module (Join-Path $PSScriptRoot ('SecondBrain.'+$m+'.psm1'))}
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'mcpwrite.invalid' = @{ en = 'MCP write: invalid input ({0})' }
    'mcpwrite.approval' = @{ en = 'MCP write: local approval is missing, expired or invalid' }
    'mcpwrite.stale' = @{ en = 'MCP write: plan or preconditions changed; preview and approve a new request' }
    'mcpwrite.activity' = @{ en = 'Real activity log disabled: complete F6/F11 activation procedure; no write' }
    'mcpwrite.grant.scope' = @{ en = 'MCP write: the active grant does not cover this operation (allowed: task.status, task.update with status/reason/evidence, task.new as non-autonomous)' }
    'mcpwrite.grant.none' = @{ en = 'MCP write: no grant stored for {0}' }
    'mcpwrite.disabled' = @{ en = 'New MCP writes disabled in NoRecovery mode' }
}
function Assert-SBMcpWriteFields($Value,[string[]]$Allowed,[string[]]$Required) {
    if($Value -isnot [Collections.IDictionary] -or @($Value.Keys|Where-Object {$_ -cnotin $Allowed}).Count -or
       @($Required|Where-Object {!$Value.ContainsKey($_)}).Count){throw (New-SBError 'mcpwrite.invalid' @('fields'))}
}
function Assert-SBMcpWriteText($Value,[int]$Maximum=65536) {
    if($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Maximum){throw (New-SBError 'mcpwrite.invalid' @('text'))}
}
function Get-SBMcpWriteRequires($Value) {
    # An array of allowed capability names (an empty array is valid and clears the field on update).
    $allowed=Get-SBTaskRequiresValues
    if($Value -isnot [array] -or $Value.Count -gt 8 -or @($Value|Where-Object {$_ -isnot [string] -or $_ -cnotin $allowed}).Count){throw (New-SBError 'mcpwrite.invalid' @('requires'))}
    ,[string[]]@($Value|Select-Object -Unique)
}
function Get-SBMcpWriteHash($Value,[string]$HashField) {
    $copy=@{}+$Value;[void]$copy.Remove($HashField)
    Get-SBTextHash (ConvertTo-SBJson $copy)
}
function Get-SBMcpWriteContext([string]$BrainRoot,[string]$ConfigPath,[string]$Repository,[string]$CheckoutPath,[string]$RequestId) {
    if($RequestId -cnotmatch '^[a-f0-9]{32}$' -or !(Test-SBRepositoryIdentity $Repository) -or
       ![IO.Path]::IsPathFullyQualified($CheckoutPath)){throw (New-SBError 'mcpwrite.invalid' @('scope/ID'))}
    $config=Read-SBConfiguration -ConfigPath $ConfigPath -BrainRoot $BrainRoot -ReadOnly
    $asset=Get-SBCheckoutAsset $CheckoutPath $config.bindings
    $matches=@($config.bindings|Where-Object {$_.identity -ceq $Repository -and (Test-SBSamePath $_.path $asset.path)})
    if($asset.identity -cne $Repository -or $matches.Count -ne 1){throw (New-SBError 'mcpwrite.invalid' @('checkout binding'))}
    $dossier=Join-Path $BrainRoot (Resolve-SBWorkingDossier $BrainRoot $Repository)
    $approval=Join-Path $config.localStateRoot ('mcp-write-approvals/'+(Get-SBRuntimeRepoSegment $Repository)+'/'+$RequestId+'.json')
    Assert-SBPlainPath $approval
    @{config=$config;checkout=$asset.path;dossier=$dossier;approvalPath=$approval}
}
function Get-SBMcpWritePinnedExecutor($Plan) {
    # The executor captured at preview (task operations only); null when the plan has none.
    $arguments=$Plan.pending.arguments
    if($arguments -is [Collections.IDictionary]){if($arguments.Contains('Executor')){return $arguments['Executor']};return $null}
    if($arguments -and $arguments.PSObject.Properties['Executor']){return $arguments.Executor}
    $null
}
function New-SBMcpWritePlan {
    param([string]$BrainRoot,[string]$ConfigPath,[string]$Repository,[string]$CheckoutPath,[string]$RequestId,[string]$Operation,$Payload,$Executor)
    $ctx=Get-SBMcpWriteContext $BrainRoot $ConfigPath $Repository $CheckoutPath $RequestId
    if((ConvertTo-SBJson $Payload).Length -gt 131072 -or (ConvertTo-SBJson $Payload) -match '(?is)<\s*/?\s*private\b|<\s*/?\s*do[-_]not[-_]memorize\b'){
        throw (New-SBError 'mcpwrite.invalid' @('size/private content'))
    }
    $args=@{};$expected=@{};$pendingOperation=''
    switch($Operation){
        'task.status' {
            Assert-SBMcpWriteFields $Payload @('taskId','status','reason') @('taskId','status')
            Assert-SBMcpWriteText $Payload.taskId 128
            if($Payload.status -cnotin @('todo','in_progress','blocked','done','cancelled','unknown')){throw (New-SBError 'mcpwrite.invalid' @('status'))}
            $args=@{TaskId=$Payload.taskId;Status=$Payload.status}
            if($Payload.ContainsKey('reason')){Assert-SBMcpWriteText $Payload.reason 4096;$args.StateReason=$Payload.reason}
            $pendingOperation='task.status'
        }
        'task.update' {
            # Same fields and validation as knowledge.ps1 -UpdateTaskId: Update-SBTrackerTask validates the candidate during preview.
            Assert-SBMcpWriteFields $Payload @('taskId','status','reason','priority','execution','stream','awaiting','requires','evidence') @('taskId')
            Assert-SBMcpWriteText $Payload.taskId 128
            if($Payload.Keys.Count -lt 2){throw (New-SBError 'mcpwrite.invalid' @('fields'))}
            $args=@{TaskId=$Payload.taskId}
            if($Payload.ContainsKey('status')){
                if($Payload.status -cnotin @('todo','in_progress','blocked','done','cancelled','unknown')){throw (New-SBError 'mcpwrite.invalid' @('status'))}
                $args.Status=$Payload.status
            }
            if($Payload.ContainsKey('reason')){Assert-SBMcpWriteText $Payload.reason 4096;$args.StateReason=$Payload.reason}
            if($Payload.ContainsKey('priority')){if($Payload.priority -cnotin @('P0','P1','P2','P3','P4')){throw (New-SBError 'mcpwrite.invalid' @('priority'))};$args.Priority=$Payload.priority}
            if($Payload.ContainsKey('execution')){if($Payload.execution -cnotin @('autonomous','user_required','unspecified')){throw (New-SBError 'mcpwrite.invalid' @('execution'))};$args.Execution=$Payload.execution}
            foreach($pair in @(@('stream','Stream'),@('awaiting','Awaiting'))){
                if($Payload.ContainsKey($pair[0])){
                    # An empty string clears the field, as with -Stream '' and -Awaiting ''.
                    $value=$Payload[$pair[0]]
                    if($value -isnot [string] -or $value.Length -gt 512){throw (New-SBError 'mcpwrite.invalid' @($pair[0]))}
                    $args[$pair[1]]=$value
                }
            }
            if($Payload.ContainsKey('requires')){
                # An empty array clears the capability list; only the values of Get-SBTaskRequiresValues are accepted.
                $args.Requires=Get-SBMcpWriteRequires $Payload.requires
            }
            if($Payload.ContainsKey('evidence')){
                # Evidence entries appended to the task, as knowledge.ps1 -Evidence: "reference|outcome" strings or {reference, outcome} objects.
                $items=@($Payload.evidence)
                if($Payload.evidence -is [string] -or !$items.Count -or $items.Count -gt 20){throw (New-SBError 'mcpwrite.invalid' @('evidence'))}
                $args.Evidence=@(foreach($item in $items){
                    if($item -is [Collections.IDictionary]){
                        if(@($item.Keys|Where-Object {$_ -notin @('reference','outcome')}).Count -or $item['reference'] -isnot [string] -or $item['outcome'] -isnot [string]){throw (New-SBError 'mcpwrite.invalid' @('evidence'))}
                        Assert-SBMcpWriteText $item.reference 1024
                        $item=$item.reference+'|'+$item.outcome
                    }elseif($item -isnot [string]){throw (New-SBError 'mcpwrite.invalid' @('evidence'))}
                    Assert-SBMcpWriteText $item 1100
                    $parts=$item -split '\|',2
                    if(!$parts[0].Trim() -or ($parts.Count -eq 2 -and $parts[1].Trim() -cnotin @('passed','failed','partial','unverified'))){throw (New-SBError 'mcpwrite.invalid' @('evidence'))}
                    $item
                })
            }
            $pendingOperation='task.update'
        }
        'task.evidence.correct' {
            # #669: audited replacement of one task's evidence (evidence is otherwise append-only). The reason is mandatory, the replaced entries
            # are kept in the task's evidenceCorrections and a ledger record is written; like every MCP write it needs preview and local approval.
            Assert-SBMcpWriteFields $Payload @('taskId','reason','evidence') @('taskId','reason','evidence')
            Assert-SBMcpWriteText $Payload.taskId 128;Assert-SBMcpWriteText $Payload.reason 1024
            $items=@($Payload.evidence)
            if($Payload.evidence -is [string] -or $items.Count -gt 100){throw (New-SBError 'mcpwrite.invalid' @('evidence'))}
            $entries=@(foreach($item in $items){
                if($item -is [Collections.IDictionary]){
                    if(@($item.Keys|Where-Object {$_ -notin @('reference','outcome')}).Count -or $item['reference'] -isnot [string] -or $item['outcome'] -isnot [string]){throw (New-SBError 'mcpwrite.invalid' @('evidence'))}
                    Assert-SBMcpWriteText $item.reference 1024
                    $item=$item.reference+'|'+$item.outcome
                }elseif($item -isnot [string]){throw (New-SBError 'mcpwrite.invalid' @('evidence'))}
                Assert-SBMcpWriteText $item 1100
                $parts=$item -split '\|',2
                if(!$parts[0].Trim() -or $parts.Count -ne 2 -or $parts[1].Trim() -cnotin @('passed','failed','partial','unverified')){throw (New-SBError 'mcpwrite.invalid' @('evidence'))}
                $item
            })
            $args=@{TaskId=$Payload.taskId;EvidenceCorrection=@{Reason=$Payload.reason;Evidence=@($entries)}}
            $pendingOperation='task.update'
        }
        'task.new' {
            Assert-SBMcpWriteFields $Payload @('title','description','priority','acceptance','provenance','pointer','requires') @('title','acceptance','provenance')
            Assert-SBMcpWriteText $Payload.title 200
            if($Payload.title -notmatch '\p{L}'){throw (New-SBError 'tracker.title.invalid')}
            if($Payload.acceptance -isnot [array] -or !$Payload.acceptance.Count -or $Payload.acceptance.Count -gt 32){throw (New-SBError 'mcpwrite.invalid' @('acceptance'))}
            foreach($item in $Payload.acceptance){Assert-SBMcpWriteText $item 4096}
            Assert-SBMcpWriteText $Payload.provenance 512
            if($Payload.provenance -cnotmatch '^history/[a-zA-Z0-9][a-zA-Z0-9_-]*/report\.md$'){throw (New-SBError 'mcpwrite.invalid' @('provenance path'))}
            [void](Resolve-SBParaPath $ctx.dossier $Payload.provenance)
            $args=@{Title=$Payload.title;Id=('MCP-'+$RequestId);Acceptance=$Payload.acceptance;ProvenanceReference=$Payload.provenance;Priority='P2';Execution=$(if(Read-SBMcpWriteGrant $ctx.config $Repository){'user_required'}else{'autonomous'})}
            if($Payload.ContainsKey('priority')){if($Payload.priority -cnotin @('P0','P1','P2','P3','P4')){throw (New-SBError 'mcpwrite.invalid' @('priority'))};$args.Priority=$Payload.priority}
            if($Payload.ContainsKey('description')){Assert-SBMcpWriteText $Payload.description 8192;$args.Description=$Payload.description}
            if($Payload.ContainsKey('pointer')){Assert-SBMcpWriteText $Payload.pointer 512;$args.ProvenancePointer=$Payload.pointer}
            if($Payload.ContainsKey('requires')){
                $required=Get-SBMcpWriteRequires $Payload.requires
                if($required.Count){$args.Requires=$required}
            }
            $pendingOperation='task.new'
        }
        'memory.append' {
            Assert-SBMcpWriteFields $Payload @('content') @('content');Assert-SBMcpWriteText $Payload.content
            $args=@{relativePath='memory.md';content=$Payload.content};$pendingOperation='file.append'
        }
        'history.save' {
            Assert-SBMcpWriteFields $Payload @('path','content') @('path','content')
            Assert-SBMcpWriteText $Payload.path 256;Assert-SBMcpWriteText $Payload.content
            if($Payload.path -cnotmatch '^history/[a-zA-Z0-9][a-zA-Z0-9_-]*/report\.md$' -or $Payload.path -ceq 'history/activity/report.md'){throw (New-SBError 'mcpwrite.invalid' @('history path'))}
            $args=@{relativePath=$Payload.path;content=$Payload.content};$expected.hash=Get-SBFileHash (Resolve-SBParaPath $ctx.dossier $Payload.path);$pendingOperation='file.save'
        }
        'activity.append' {
            Assert-SBMcpWriteFields $Payload @('taskId','sessionId','when','outcome','detail') @('taskId','sessionId','when','outcome','detail')
            foreach($key in 'taskId','sessionId','when','detail'){Assert-SBMcpWriteText $Payload[$key] 8192}
            if($Payload.outcome -cnotin @('started','progress','completed','blocked','failed')){throw (New-SBError 'mcpwrite.invalid' @('outcome'))}
            $when=[DateTimeOffset]::MinValue
            if(![DateTimeOffset]::TryParse($Payload.when,[ref]$when)){throw (New-SBError 'mcpwrite.invalid' @('when'))}
            $tracker=Read-SBJson (Join-Path $ctx.dossier tracker.json) $null
            $archived=(Read-SBTrackerArchive (Join-Path $ctx.dossier tracker.json) $Repository).data
            if($Payload.taskId -cnotin @(@($tracker.tasks)+@($archived.tasks)|ForEach-Object id)){throw (New-SBError 'mcpwrite.invalid' @('activity task'))}
            $record=@{schemaVersion=1;eventId=$RequestId;user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;repository=$Repository;taskId=$Payload.taskId;session=$Payload.sessionId;
                when=$when.ToUniversalTime().ToString('o');where=$ctx.checkout;computer=[Environment]::MachineName;outcome=$Payload.outcome;detail=$Payload.detail}
            $args=@{relativePath='history/activity/report.md';content=((ConvertTo-SBStableValue $record|ConvertTo-Json -Depth 15 -Compress)+"`n")};$pendingOperation='file.append'
        }
        default {throw (New-SBError 'mcpwrite.invalid' @('operation'))}
    }
    # #708: the executor is resolved once at preview and pinned in the plan; approval and submission reuse that value so a different caller
    # environment (agent preview, owner terminal approval) does not change the plan hash.
    if($pendingOperation -like 'task.*' -and $Executor){
        $pinned=if($Executor -is [Collections.IDictionary]){$Executor}else{(ConvertTo-SBJson $Executor)|ConvertFrom-Json -AsHashtable}
        $args.Executor=$pinned
    }
    $prepared=New-SBPendingWrite -BrainRoot $BrainRoot -Repository $Repository -Operation $pendingOperation -Arguments $args -Expected $expected -Config $ctx.config -RequestId $RequestId -PrepareOnly -StrictPreconditions
    $plan=@{schemaVersion=1;repository=$Repository;checkoutPath=$ctx.checkout;dossierPath=$ctx.dossier;requestId=$RequestId;operation=$Operation;payload=$Payload;
        workstationId=$ctx.config.workstationId;user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;
        pending=@{operation=$prepared.request.operation;arguments=$prepared.request.arguments;expected=$prepared.request.expected};
        pendingHash=$prepared.contentHash}
    $plan.planHash=Get-SBMcpWriteHash $plan planHash
    if([Text.Encoding]::UTF8.GetByteCount((ConvertTo-SBJson $plan)) -gt 256KB){throw (New-SBError 'mcpwrite.invalid' @('plan size'))}
    $plan
}
function Read-SBMcpWriteApproval($Context,[string]$PlanHash) {
    $receipt=Read-SBJson $Context.approvalPath $null
    if(!$receipt -or $receipt.schemaVersion -ne 1 -or $receipt.planHash -cne $PlanHash -or
       $receipt.receiptHash -cne (Get-SBMcpWriteHash $receipt receiptHash) -or
       $receipt.plan.planHash -cne (Get-SBMcpWriteHash $receipt.plan planHash) -or $receipt.plan.planHash -cne $PlanHash -or
       $receipt.workstationId -cne $Context.config.workstationId -or $receipt.user -cne [Security.Principal.WindowsIdentity]::GetCurrent().Name -or
       (!(Test-SBSamePath $receipt.plan.checkoutPath $Context.checkout) -or !(Test-SBSamePath $receipt.plan.dossierPath $Context.dossier))){
        throw (New-SBError 'mcpwrite.approval')
    }
    $receipt
}
$script:SBMcpGrantOperations=@('task.status','task.update','task.new')
function Get-SBMcpWriteGrantPath($Config,[string]$Repository) {
    $path=Join-Path $Config.localStateRoot ('mcp-write-grants/'+(Get-SBRuntimeRepoSegment $Repository)+'/grant.json')
    Assert-SBPlainPath $path
    $path
}
function Read-SBMcpWriteGrantFile($Config,[string]$Repository) {
    # The stored grant as written (may be expired or revoked); null when absent or when binding or hash do not match this workstation and user.
    $path=Get-SBMcpWriteGrantPath $Config $Repository
    if(![IO.File]::Exists($path)){return $null}
    $grant=Read-SBJson $path $null
    if($grant -isnot [Collections.IDictionary] -or $grant.schemaVersion -ne 1 -or $grant.repository -cne $Repository -or
       $grant.grantHash -cne (Get-SBMcpWriteHash $grant grantHash) -or
       $grant.workstationId -cne $Config.workstationId -or $grant.user -cne [Security.Principal.WindowsIdentity]::GetCurrent().Name){return $null}
    $grant
}
function Read-SBMcpWriteGrant($Config,[string]$Repository) {
    # The active grant: stored, bound to repository, workstation and OS user, not revoked and not expired.
    $grant=Read-SBMcpWriteGrantFile $Config $Repository
    if(!$grant -or $grant.ContainsKey('revokedAt') -or [DateTimeOffset]::Parse($grant.expiresAt) -le (Get-SBNow)){return $null}
    $grant
}
function Test-SBMcpWriteGrantCovers($Grant,$Plan) {
    # Granted: task.status; task.update limited to status, reason and evidence; task.new only forced non-autonomous and without requires.
    # Never granted: memory.append, history.save, task.evidence.correct, activity.append, execution/requires changes.
    if($Plan.operation -cnotin @($Grant.operations)){return $false}
    $payload=$Plan.payload
    if($payload -isnot [Collections.IDictionary]){return $false}
    switch($Plan.operation){
        'task.status' {return $true}
        'task.update' {return !@($payload.Keys|Where-Object {$_ -cnotin @('taskId','status','reason','evidence')}).Count}
        'task.new' {return (!$payload.ContainsKey('requires') -and $Plan.pending.arguments.Execution -ceq 'user_required')}
        default {return $false}
    }
}
function Save-SBMcpWriteGrant($Config,[string]$Repository,$Grant) {
    $path=Get-SBMcpWriteGrantPath $Config $Repository
    $Grant.grantHash=Get-SBMcpWriteHash $Grant grantHash
    [void](Write-SBFile $path ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $Grant))) (Get-SBFileHash $path) $Config.localStateBackupRoot)
}
function New-SBMcpWriteGrant {
    # Owner action (terminal): lets the agent submit the granted operations for one repository without a per-call receipt until it expires or is revoked.
    param([string]$BrainRoot,[string]$ConfigPath,[string]$Repository,[int]$Hours=8,[string]$Authorization,[string]$SessionId)
    if(!(Test-SBRepositoryIdentity $Repository) -or !$Authorization -or $Hours -lt 1 -or $Hours -gt 72){throw (New-SBError 'mcpwrite.invalid' @('grant'))}
    $config=Read-SBConfiguration -ConfigPath $ConfigPath -BrainRoot $BrainRoot -ReadOnly
    $session=Assert-SBSession $config $SessionId
    if($session.repository -cne $Repository){throw (New-SBError 'mcpwrite.approval')}
    $now=Get-SBNow
    $grant=@{schemaVersion=1;repository=$Repository;workstationId=$config.workstationId;user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;
        grantedAt=$now.ToString('o');expiresAt=$now.AddHours($Hours).ToString('o');operations=@($script:SBMcpGrantOperations);authorization=$Authorization}
    Save-SBMcpWriteGrant $config $Repository $grant
    @{granted=$true;repository=$Repository;expiresAt=$grant.expiresAt;operations=@($grant.operations)}
}
function Revoke-SBMcpWriteGrant {
    param([string]$BrainRoot,[string]$ConfigPath,[string]$Repository,[string]$SessionId)
    if(!(Test-SBRepositoryIdentity $Repository)){throw (New-SBError 'mcpwrite.invalid' @('grant'))}
    $config=Read-SBConfiguration -ConfigPath $ConfigPath -BrainRoot $BrainRoot -ReadOnly
    $session=Assert-SBSession $config $SessionId
    if($session.repository -cne $Repository){throw (New-SBError 'mcpwrite.approval')}
    $grant=Read-SBMcpWriteGrantFile $config $Repository
    if(!$grant){throw (New-SBError 'mcpwrite.grant.none' @($Repository))}
    if(!$grant.ContainsKey('revokedAt')){$grant.revokedAt=(Get-SBNow).ToString('o');Save-SBMcpWriteGrant $config $Repository $grant}
    @{revoked=$true;repository=$Repository}
}
function Get-SBMcpWriteGrants {
    param([string]$BrainRoot,[string]$ConfigPath)
    $config=Read-SBConfiguration -ConfigPath $ConfigPath -BrainRoot $BrainRoot -ReadOnly
    $root=Join-Path $config.localStateRoot 'mcp-write-grants'
    $items=@()
    if([IO.Directory]::Exists($root)){
        foreach($file in Get-ChildItem -LiteralPath $root -Recurse -Filter grant.json -File){
            $grant=Read-SBJson $file.FullName $null
            if($grant -is [Collections.IDictionary] -and $grant.ContainsKey('repository')){
                $state=if($grant.ContainsKey('revokedAt')){'revoked'}elseif([DateTimeOffset]::Parse($grant.expiresAt) -le (Get-SBNow)){'expired'}else{'active'}
                $items+=@{repository=$grant.repository;state=$state;grantedAt=$grant.grantedAt;expiresAt=$grant.expiresAt;operations=@($grant.operations)}
            }
        }
    }
    @{grants=@($items)}
}
function Assert-SBMcpWriteGrantedPlan($Context,[string]$Repository,[string]$RequestId,[string]$PlanHash,$Supplied) {
    # Submit under a grant: the caller supplies the previewed plan (the preview persists nothing); it must be intact, bound to this request and covered.
    $grant=Read-SBMcpWriteGrant $Context.config $Repository
    if(!$grant){throw (New-SBError 'mcpwrite.approval')}
    if($Supplied -isnot [Collections.IDictionary] -or $Supplied.planHash -cne $PlanHash -or (Get-SBMcpWriteHash $Supplied planHash) -cne $PlanHash -or
       $Supplied.repository -cne $Repository -or $Supplied.requestId -cne $RequestId -or $Supplied.workstationId -cne $Context.config.workstationId -or
       !(Test-SBSamePath $Supplied.checkoutPath $Context.checkout) -or !(Test-SBSamePath $Supplied.dossierPath $Context.dossier)){throw (New-SBError 'mcpwrite.approval')}
    if(!(Test-SBMcpWriteGrantCovers $grant $Supplied)){throw (New-SBError 'mcpwrite.grant.scope')}
    $Supplied
}
function Approve-SBMcpWritePlan {
    param([string]$BrainRoot,[string]$ConfigPath,$Plan,[string]$ExpectedPlanHash,[string]$Authorization,[string]$SessionId)
    if(!$Authorization -or !$ExpectedPlanHash -or $Plan.planHash -cne $ExpectedPlanHash -or
       (Get-SBMcpWriteHash $Plan planHash) -cne $ExpectedPlanHash){throw (New-SBError 'mcpwrite.approval')}
    $ctx=Get-SBMcpWriteContext $BrainRoot $ConfigPath $Plan.repository $Plan.checkoutPath $Plan.requestId
    $session=Assert-SBSession $ctx.config $SessionId
    if($session.repository -cne $Plan.repository){throw (New-SBError 'mcpwrite.approval')}
    $fresh=New-SBMcpWritePlan $BrainRoot $ConfigPath $Plan.repository $Plan.checkoutPath $Plan.requestId $Plan.operation $Plan.payload (Get-SBMcpWritePinnedExecutor $Plan)
    if($fresh.planHash -cne $ExpectedPlanHash){throw (New-SBError 'mcpwrite.stale')}
    if([IO.File]::Exists($ctx.approvalPath)){
        $existing=Read-SBMcpWriteApproval $ctx $ExpectedPlanHash
        if([DateTimeOffset]::Parse($existing.expiresAt) -le (Get-SBNow)){throw (New-SBError 'mcpwrite.approval')}
        return @{approved=$true;planHash=$ExpectedPlanHash;requestId=$Plan.requestId;expiresAt=$existing.expiresAt;receiptPath=$ctx.approvalPath}
    }
    $now=(Get-SBNow)
    $receipt=@{schemaVersion=1;plan=$fresh;planHash=$ExpectedPlanHash;workstationId=$ctx.config.workstationId;
        user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;approvedAt=$now.ToString('o');expiresAt=$now.AddMinutes(10).ToString('o');authorization=$Authorization}
    $receipt.receiptHash=Get-SBMcpWriteHash $receipt receiptHash
    [void](Write-SBFile $ctx.approvalPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $receipt))) 'absent' $ctx.config.localStateBackupRoot)
    @{approved=$true;planHash=$ExpectedPlanHash;requestId=$Plan.requestId;expiresAt=$receipt.expiresAt;receiptPath=$ctx.approvalPath}
}
function Submit-SBMcpWrite {
    param([string]$BrainRoot,[string]$ConfigPath,[string]$Repository,[string]$CheckoutPath,[string]$RequestId,[string]$PlanHash,$SuppliedPlan)
    $ctx=Get-SBMcpWriteContext $BrainRoot $ConfigPath $Repository $CheckoutPath $RequestId
    $receipt=$null
    if([IO.File]::Exists($ctx.approvalPath) -or !$SuppliedPlan){$receipt=Read-SBMcpWriteApproval $ctx $PlanHash;$plan=$receipt.plan}
    else{$plan=Assert-SBMcpWriteGrantedPlan $ctx $Repository $RequestId $PlanHash $SuppliedPlan}
    if($plan.repository -cne $Repository -or $plan.requestId -cne $RequestId){throw (New-SBError 'mcpwrite.approval')}
    $queueScope=Get-SBScopeKey $Repository
    $queueDir=if($plan.pending.operation -eq 'task.update'){".runtime/access/pending-writes/$queueScope/task-update/"}else{".runtime/access/pending-writes/$queueScope/"}
    $queuedPath=Join-Path $BrainRoot ($queueDir+$RequestId+'.json')
    Assert-SBPlainPath $queuedPath
    $queued=[IO.File]::Exists($queuedPath)
    if(!$queued){
        if($receipt -and ([DateTimeOffset]::Parse($receipt.approvedAt) -gt (Get-SBNow) -or
           [DateTimeOffset]::Parse($receipt.expiresAt) -le (Get-SBNow))){throw (New-SBError 'mcpwrite.approval')}
        if($plan.operation -eq 'activity.append' -and (!$ctx.config.ContainsKey('activityLogEnabled') -or $ctx.config.activityLogEnabled -ne $true)){throw (New-SBError 'mcpwrite.activity')}
        $fresh=New-SBMcpWritePlan $BrainRoot $ConfigPath $Repository $CheckoutPath $RequestId $plan.operation $plan.payload (Get-SBMcpWritePinnedExecutor $plan)
        if($fresh.planHash -cne $PlanHash){throw (New-SBError 'mcpwrite.stale')}
    }
    $submission=New-SBPendingWrite -BrainRoot $BrainRoot -Repository $Repository -Operation $plan.pending.operation -Arguments $plan.pending.arguments -Expected $plan.pending.expected -Config $ctx.config -RequestId $RequestId -PreparedHash $plan.pendingHash -StrictPreconditions
    Complete-SBPendingSubmission $submission $ctx.config -OnlySubmission
}
Export-ModuleMember -Function New-SBMcpWritePlan,Approve-SBMcpWritePlan,Submit-SBMcpWrite,New-SBMcpWriteGrant,Revoke-SBMcpWriteGrant,Get-SBMcpWriteGrants,Assert-SBMcpWriteFields