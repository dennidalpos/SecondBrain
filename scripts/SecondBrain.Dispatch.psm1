#requires -Version 7.5
# `sb` dispatcher (#724): one entry point with subcommands. The existing scripts stay the implementation.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'dispatch.command.unknown' = @{ en = 'Unknown sb command: {0}. Run sb help to list the commands.' }
    'dispatch.argument.missing' = @{ en = 'Missing argument for sb {0}: {1}' }
}

# Command words (lowercase) -> script and fixed arguments. The longest matching prefix wins; the words after it
# are passed through to the script. The prompt forms with a key or text are handled in Resolve-SBDispatch.
function Get-SBDispatchTable {
    @(
        @{words='home';script='prompts.ps1';args=@()},
        @{words='maintenance';script='prompts.ps1';args=@('-Menu','maintenance')},
        @{words='mcp';script='prompts.ps1';args=@('-Menu','mcp')},
        @{words='mcp status';script='mcp-maintenance.ps1';args=@('-Status')},
        @{words='mcp realign';script='mcp-maintenance.ps1';args=@('-Realign')},
        @{words='mcp pair';script='mcp-server.ps1';args=@('-Pair')},
        @{words='mcp package';script='mcp-server.ps1';args=@('-ExportPackage')},
        @{words='runner gui';script='runner.ps1';args=@('-Mode','gui')},
        @{words='runner cli';script='runner.ps1';args=@('-Mode','cli')},
        @{words='activate';script='secondbrain.ps1';args=@('-Setup','-Interactive')},
        @{words='setup';script='setup-status.ps1';args=@()},
        @{words='skills';script='skills.ps1';args=@()},
        @{words='check';script='secondbrain.ps1';args=@('-Check')},
        @{words='sync';script='secondbrain.ps1';args=@('-Sync')},
        @{words='compact ai';script='compact-ai.ps1';args=@()},
        @{words='compact';script='knowledge.ps1';args=@('-Compact','-Mechanical')},
        @{words='queue status';script='queue.ps1';args=@('-Status')},
        @{words='queue stop';script='queue.ps1';args=@('-Stop')},
        @{words='queue';script='queue.ps1';args=@()},
        @{words='runner status';script='runner-status.ps1';args=@()},
        @{words='runner';script='runner.ps1';args=@()},
        @{words='reconcile tasks';script='reconcile-tasks.ps1';args=@()},
        @{words='stop';script='prompts.ps1';args=@('-Compose','-Prompt','session.stop')},
        @{words='tasks';script='knowledge.ps1';args=@('-Tasks')},
        @{words='next';script='next-steps.ps1';args=@()},
        @{words='pending flush';script='knowledge.ps1';args=@('-FlushPending')},
        @{words='pending';script='knowledge.ps1';args=@('-PendingWrites')},
        @{words='publish check';script='publication.ps1';args=@('-RepositoryPath','.')},
        @{words='grants';script='mcp-write.ps1';args=@('-Grants')},
        @{words='projects';script='projects.ps1';args=@('-List')},
        @{words='status';script='secondbrain.ps1';args=@('-Setup','-Status')},
        @{words='ides';script='ide-map.ps1';args=@('-Verify')},
        @{words='backup verify';script='backup.ps1';args=@('-Verify')},
        @{words='backup';script='backup.ps1';args=@()},
        @{words='sources';script='sources.ps1';args=@('-Check')},
        @{words='cleanup';script='cleanup.ps1';args=@('-ListRuntime')},
        @{words='bindings';script='bindings.ps1';args=@('-MigrateBindings')},
        @{words='recover';script='recover.ps1';args=@()},
        @{words='directives check';script='secondbrain.ps1';args=@('-Check')},
        @{words='directives propose';script='prompts.ps1';args=@('-Compose','-Prompt','pmt-fd98d7ce','-Objective')},
        @{words='prompts check';script='build-prompts.ps1';args=@('-Check')},
        @{words='onboard';script='onboard.ps1';args=@()},
        @{words='offboard';script='offboard.ps1';args=@()},
        @{words='resync';script='resync.ps1';args=@()},
        @{words='uninstall';script='uninstall.ps1';args=@()}
    )
}

# Returns @{script;arguments} or throws the unknown-command error. $Words are the words after `sb`.
function Resolve-SBDispatch([string[]]$Words=@()) {
    $words=@($Words|Where-Object {$_ -ne ''})
    if(!$words.Count -or $words[0] -in @('help','-h','--help','/?')){return @{script='';arguments=@();help=$true}}
    $first=$words[0].ToLowerInvariant()
    if($first -eq 'prompt'){
        $rest=@($words|Select-Object -Skip 1)
        if(!$rest.Count){return @{script='prompts.ps1';arguments=@()}}
        $sub=$rest[0].ToLowerInvariant()
        if($sub -eq 'list'){return @{script='prompts.ps1';arguments=@('-List','-Compact')+@($rest|Select-Object -Skip 1)}}
        if($sub -eq 'area'){
            if($rest.Count -lt 2){throw (New-SBError 'dispatch.argument.missing' @('prompt area','AREA'))}
            return @{script='prompts.ps1';arguments=@('-List','-Category',$rest[1])}
        }
        if($sub -eq 'show'){
            if($rest.Count -lt 2){throw (New-SBError 'dispatch.argument.missing' @('prompt show','KEY'))}
            return @{script='prompts.ps1';arguments=@('-Show','-Prompt',$rest[1])}
        }
        # sb prompt KEY: objective (the colon is optional)
        $key=$rest[0].TrimEnd(':')
        $objective=(@($rest|Select-Object -Skip 1) -join ' ')
        # #801: sb prompt wf-NAME: objective runs a whole preset (the chain of its cards with their gates).
        if($key -cmatch '^(wf-[a-z0-9]+(-[a-z0-9]+)*|wfl-[0-9a-f]{8})$'){
            $preset=@('-Preset',$key)
            if($objective){$preset+=@('-Objective',$objective)}
            return @{script='prompts.ps1';arguments=$preset}
        }
        $composed=@('-Compose','-Prompt',$key)
        if($objective){$composed+=@('-Objective',$objective)}
        return @{script='prompts.ps1';arguments=$composed}
    }
    $match=$null;$matchLength=0
    foreach($entry in @(Get-SBDispatchTable)){
        $entryWords=@($entry.words -split ' ')
        if($entryWords.Count -gt $words.Count){continue}
        $same=$true
        for($i=0;$i -lt $entryWords.Count;$i++){if($words[$i].ToLowerInvariant() -ne $entryWords[$i]){$same=$false;break}}
        if($same -and $entryWords.Count -gt $matchLength){$match=$entry;$matchLength=$entryWords.Count}
    }
    if(!$match){throw (New-SBError 'dispatch.command.unknown' @($words -join ' '))}
    @{script=$match.script;arguments=@($match.args)+@($words|Select-Object -Skip $matchLength)}
}

Export-ModuleMember -Function Get-SBDispatchTable,Resolve-SBDispatch
