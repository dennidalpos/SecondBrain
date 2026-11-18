#requires -Version 7.5
# sb resync (#726): realign a repository changed outside SecondBrain. Pure mapping from the findings of
# `secondbrain.ps1 -Check -Repository` to a plan: what is safe to apply, and for every conflict what to do.
Set-StrictMode -Version Latest

# kind -> safe (true: `sb sync` realigns it, nothing user-written is overwritten), action text, optional prompt role.
$script:SBResyncRules=@{
    'directive-pending'=@{safe=$true;action='Run sb sync: the managed block in the repository is out of date.'}
    'pointer-pending'=@{safe=$true;action='Run sb sync: the pointer block is out of date.'}
    'global-text-pending'=@{safe=$true;action='Run sb sync: the global instruction text is out of date.'}
    'toc-pending'=@{safe=$true;action='Run sb sync: the dossier index is out of date.'}
    'history-index-pending'=@{safe=$true;action='Run sb sync: the history index is out of date.'}
    'agent-view-pending'=@{safe=$true;action='Run sb sync: the agent memory view is out of date.'}
    'prompt-index-drift'=@{safe=$true;action='Run sb prompts check and regenerate the indexes with build-prompts.ps1.'}
    'directive-conflict'=@{safe=$false;action='The managed block was edited by hand. Compare it with the approved text, keep or discard your edit in the repository file, then run sb sync.'}
    'pointer-conflict'=@{safe=$false;action='The pointer block was edited by hand. Fix it in the repository file, then run sb sync.'}
    'ide-conflict'=@{safe=$false;action='An IDE instruction file differs from the approved text. Resolve it in that file, then run sb sync.'}
    'tracker-merge'=@{safe=$false;action='The checkout brings a tracker that diverges from the dossier. Preview with import-tracker.ps1 -Merge, then apply with the owner decisions.'}
    'tracker-import'=@{safe=$false;action='A tracker import is pending: run import-tracker.ps1 (preview first) and apply with the owner confirmation.'}
    'tracker-import-required'=@{safe=$false;action='The repository tracker must be imported: run import-tracker.ps1 (preview first).'}
    'tracker-authority'=@{safe=$false;action='Two tracker sources disagree: keep the dossier tracker and remove or import the other one.'}
    'repository-unverified'=@{safe=$false;action='The checkout moved or changed identity. Run sb offboard for the old binding and sb onboard -Path <new checkout> -Apply.'}
    'pending-conflict'=@{safe=$false;action='Queued writes conflict: run sb reconcile tasks (plan first, then -Apply and -Decide).'}
    'pending-transaction'=@{safe=$false;action='An interrupted transaction is pending: run sb recover with its manifest (preview first).'}
    'closure-memory-pending'=@{safe=$false;action='A task was closed after the last memory update: run the session.close prompt (sb prompt session.close).';prompt='session.close'}
    'compaction-advised'=@{safe=$false;action='Run sb compact (nothing is compacted without confirmation).'}
    'compaction-required'=@{safe=$false;action='Run sb compact before the next session.'}
    'forbidden-repository-in-bindings'=@{safe=$false;action='The repository is forbidden on this workstation: run sb offboard or remove it from the forbidden list on purpose.'}
}

function Get-SBResyncPlan([object[]]$Findings=@(),[string]$Repository='') {
    $items=@()
    foreach($finding in @($Findings)){
        $kind=[string]$finding.kind
        $rule=if($script:SBResyncRules.ContainsKey($kind)){$script:SBResyncRules[$kind]}else{@{safe=$false;action=('Unrecognized finding: read the reason and fix it in the repository or run sb check.')}}
        $detail=''
        foreach($field in 'reason','detail'){if($finding -is [System.Collections.IDictionary]){if($finding.Contains($field) -and $finding[$field]){$detail=[string]$finding[$field];break}}elseif($finding.PSObject.Properties[$field] -and $finding.$field){$detail=[string]$finding.$field;break}}
        $items+=[ordered]@{kind=$kind;safe=[bool]$rule.safe;action=$rule.action;prompt=$(if($rule.ContainsKey('prompt')){$rule.prompt}else{$null});detail=$detail}
    }
    $safe=@($items|Where-Object safe)
    $manual=@($items|Where-Object {!$_.safe})
    [ordered]@{
        repository=$Repository
        status=$(if(!$items.Count){'aligned'}elseif($manual.Count){'needs-decision'}else{'safe-to-apply'})
        safeCount=$safe.Count
        manualCount=$manual.Count
        items=$items
    }
}

Export-ModuleMember -Function Get-SBResyncPlan
