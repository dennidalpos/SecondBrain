#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')

function Get-SBNextSteps {
    # Reasoned next steps for a project, from facts only. Pure: every input is passed in, nothing is read or written here.
    # Tasks: tracker entries (id, seq, title, status, priority). Ready: the tasks the runner would accept. Runs: run summaries, newest first.
    # Each step says why it is proposed; the order follows urgency (verify what just ran, finish what is open, then new work and housekeeping).
    param($Tasks=@(),$Ready=@(),$Runs=@(),$GitUpdate=$null,[bool]$HasSkills=$true,[int]$Limit=6,$SkillsCard=$null)
    $steps=@()
    $last=@($Runs)|Select-Object -First 1
    $results=@(if($last -and ($last -is [Collections.IDictionary] -or $last.PSObject.Properties['results'])){@($last.results)})
    $reviewIds=@()
    foreach($r in $results){
        $findings=$null;if($r -is [Collections.IDictionary]){if($r.Contains('findings')){$findings=$r['findings']}}elseif($r.PSObject.Properties['findings']){$findings=$r.findings}
        if($findings){$created=0;if($findings -is [Collections.IDictionary]){if($findings.Contains('created')){$created=[int]$findings['created']}}elseif($findings.PSObject.Properties['created']){$created=[int]$findings.created}
            if($created -gt 0){$reviewIds+=@([string]$(if($r -is [Collections.IDictionary]){$r['id']}else{$r.id}))}}
    }
    $unverified=@($results|Where-Object {
        $a=if($_ -is [Collections.IDictionary]){if($_.Contains('acceptance')){$_['acceptance']}else{$null}}elseif($_.PSObject.Properties['acceptance']){$_.acceptance}else{$null}
        $a -in @('unverified','open')
    })
    $failed=@($results|Where-Object {
        $p=if($_ -is [Collections.IDictionary]){if($_.Contains('process')){$_['process']}else{$null}}elseif($_.PSObject.Properties['process']){$_.process}else{$null}
        $p -eq 'failed'
    })
    if($failed.Count){$steps+=[ordered]@{id='recheck-failed';kind='verify';priority=10;title=('Look at the '+$failed.Count+' task(s) whose agent process failed in the last run');why='A failed process leaves the task in the state the agent reached; its report folder shows where it stopped.';action=[ordered]@{type='command';value='scripts/runner-status.ps1 -List -Limit 1'}}}
    if($unverified.Count){$steps+=[ordered]@{id='verify-acceptance';kind='verify';priority=20;title=('Verify the acceptance of '+$unverified.Count+' task(s) from the last run');why='The agent exited successfully but the acceptance criteria are not proven with passed evidence recorded in that attempt.';action=[ordered]@{type='command';value='scripts/knowledge.ps1 -Registry'};followUp=[ordered]@{title=('Verify the acceptance of '+$unverified.Count+' task(s) left unverified by the last run');description='The last run ended with agent exits that are not backed by passed evidence for every acceptance criterion; check each criterion and record the evidence.';priority='P2';acceptance=@('Each unverified task has passed evidence for every criterion, or a state reason saying what is missing')}}}
    if($reviewIds.Count){$steps+=[ordered]@{id='review-findings';kind='review';priority=30;title=('Review the follow-up tasks created from findings of '+($reviewIds -join ', '));why='The agent reported unresolved problems; they are now tasks and wait for a decision or a later run.';action=[ordered]@{type='command';value='scripts/knowledge.ps1 -Tasks -ReadyOnly'};followUp=[ordered]@{title=('Review the follow-up tasks created from findings of '+($reviewIds -join ', '));description='The agent reported unresolved problems that became tasks; decide which to run, merge or cancel.';priority='P2';acceptance=@('Each follow-up task is scheduled, merged or cancelled with a reason')}}}
    $open=@($Tasks|Where-Object {$_.status -eq 'in_progress'})
    if($open.Count){$steps+=[ordered]@{id='finish-open';kind='continue';priority=40;title=('Finish the '+$open.Count+' task(s) already in progress, starting with #'+(@($open|Sort-Object {[int]$_.seq})[0]).seq);why='Unfinished work is cheaper to close than to resume later, and it may block ready tasks.';action=[ordered]@{type='task';value=[string](@($open|Sort-Object {[int]$_.seq})[0]).id}}}
    $next=@($Ready|Sort-Object @{Expression={[string]$_.priority}},@{Expression={[int]$_.seq}})|Select-Object -First 1
    if($next){$steps+=[ordered]@{id='run-next';kind='run';priority=50;title=('Run the next ready task: #'+$next.seq+' '+([string]$next.title -replace '^#\d+\s*[2014-]\s*',''));why=('It is the highest-priority task the runner can execute alone ('+@($Ready).Count+' ready).');action=[ordered]@{type='task';value=[string]$next.id}}}
    elseif(@($Tasks|Where-Object {$_.status -eq 'blocked'}).Count){$steps+=[ordered]@{id='unblock';kind='decide';priority=55;title='Nothing is ready: decide what unblocks the blocked tasks';why=(''+@($Tasks|Where-Object {$_.status -eq 'blocked'}).Count+' task(s) are blocked and none is ready to run; each blocker names what is missing.');action=[ordered]@{type='command';value='scripts/knowledge.ps1 -Tasks'}}}
    if($GitUpdate -and !$GitUpdate.confirmed){$steps+=[ordered]@{id='git-update';kind='setup';priority=60;title='Choose how Git and GitHub are updated for this project';why=('No choice is recorded; the proposed default is '+$GitUpdate.mode+' on '+$GitUpdate.branch+', applied only after you confirm.');action=[ordered]@{type='command';value='scripts/para.ps1 -SetGitUpdate'}}}
    if(!$HasSkills){$steps+=[ordered]@{id='skills';kind='setup';priority=70;title='Install skills that fit this project';why='No agent skill is installed in the project; the project facts support a few useful ones.';action=[ordered]@{type='command';value='sb skills'};card=$SkillsCard}}
    @($steps|Sort-Object priority|Select-Object -First $Limit)
}
Export-ModuleMember -Function Get-SBNextSteps
