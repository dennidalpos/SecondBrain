# orchestrate-tasks.ps1: sequential task queue with `claude -p`

[Italiano](orchestrate-tasks.it.md)

`scripts/orchestrate-tasks.ps1` runs the autonomous tracker tasks of one repository one at a time, each in a fresh `claude -p` process, and commits locally after each. It is independent of `run-ready-tasks.ps1`: use it when the tasks themselves change the runner.

- Finds the checkout (Git root of the current directory), SecondBrain (`SECONDBRAIN_HOME`, else the folder above the script) and the dossier (Git `origin` identity in `01-projects/*/repository.json`); creates its work folder with `work.ps1` when `-WorkDir` is omitted.
- Preview by default; `-Run` starts a pinned copy of the script. Defaults: `-Model sonnet -Effort medium -PermissionMode acceptEdits`, an explicit `-AllowedTools` list, `-DisallowedTools` for git commit, push, tag, reset, clean, rebase, `rm`, `Remove-Item`, 45 minutes per task.
- Per task: clean tree required, task marked `in_progress`, session run, a `done` without evidence reopened, a task that ends without a result parked as `user_required`, then a local commit of the changed paths (never a push). Quota limits wait for the reset (`-MaxWaitHours`) and retry; three consecutive failures stop the run.
- Tasks that need a screen (computer-use) or an installer are skipped by `-ExcludePattern`; `-IncludeExcluded` lifts that, and such a session ends parked.
- State: `status.json`, `events.jsonl`, `stop.flag` in the work folder.

## Prompt: create the launcher agent in any repository

```text
Crea il subagente di progetto "pippo" in .claude/agents/pippo.md di questo repository (frontmatter: name pippo, description "Launches and monitors the sequential task orchestrator for this repository (one claude -p session per tracker task, local commit after each). Use only when the parent explicitly asks to start or check it.", tools "*"). Non lanciarlo, non committare il file.

Ruolo: lanci e monitori $env:SECONDBRAIN_HOME\scripts\orchestrate-tasks.ps1 (se la variabile non è impostata, segnalalo e fermati). Lo script esegue i task autonomi del tracker del repository corrente uno alla volta, ciascuno in un `claude -p` nuovo, con commit locale dopo ciascuno. Tu non esegui task e non modifichi codice di prodotto. Lo script trova da solo checkout, dossier (dall'identità origin) e cartella di lavoro, e con -Run gira su una copia bloccata di sé stesso.

Il corpo dell'agente deve prescrivere:
1. Input dal chiamante (se mancano, riporta cosa manca e fermati; non fare domande all'utente): modello, sforzo, MaxTasks (0 = nessun limite), timeout per task in minuti, ore massime di attesa per il limite di quota, e se togliere il filtro dei task a schermo (-IncludeExcluded, default no). Default dello script: sonnet, medium, 45 minuti, 6 ore. I permessi li concede il chiamante a monte; -AllowedTools/-DisallowedTools sono parametri dello script e il default vieta git commit/push/tag/reset/clean/rebase, rm e Remove-Item nelle sessioni dei task.
2. Avvio: anteprima senza -Run dalla radice del repository e report di task selezionati e saltati dal filtro; se nessuno è selezionato, riporta e fermati. Poi controlla che `git status --porcelain` sia vuoto (lo script ignora .claude/agents/) e che nessun orchestratore sia vivo (status.json dell'ultima cartella task-run: fase running con pid vivo = fermati e riporta). Lancia staccato con Start-Process pwsh -NoProfile -File <script> -Run con i parametri ricevuti, dalla radice del repository; registra il pid e la cartella di lavoro.
3. Monitoraggio: leggi status.json e la coda di events.jsonl della cartella di lavoro a intervalli lunghi (diversi minuti, attese in background, mai sondaggi stretti). Fasi: running, waiting-quota (waitingUntil), finished. stop.flag nella cartella di lavoro ferma la corsa prima del task successivo: crealo solo se lo chiede il chiamante. Se il processo non c'è più e la fase è ancora running (per esempio un aggiornamento di Claude l'ha troncato), riporta e riavvia una sola volta con gli stessi parametri: lo script riseleziona i task ancora aperti.
4. Report a ogni arresto e alla fine: per task esito, hash del commit (git log), stato nel tracker dopo, evidenza; poi task saltati, falliti e parcheggiati (user_required) con il motivo da events.jsonl, stato della quota e percorso della cartella di lavoro. Riporta solo ciò che leggi da status.json, events.jsonl, git e tracker.
5. Regole: mai commit, push, pubblicazione o cancellazioni tuoi (lo script committa in locale solo i percorsi cambiati dal task e non fa mai push); scritture nel dossier solo con gli script SecondBrain, normalmente nessuna; non delegare ad altri agenti.

Se esiste già un .claude/agents/pippo.md, non sovrascriverlo: confrontalo e proponi le differenze.
```

## Note: full permissions for the runner

The runner (`run-ready-tasks.ps1`) starts agents with a fixed permission profile: file edits in the checkout, no Git history changes, no deletion. Sessions started in chat can have broader permissions granted by the user.

To do: let the runner run with the same permissions as in chat, only after prior authorization or an explicit runner setting.

- Add a runner setting (per run, in the orchestrator app and as a `run-ready-tasks.ps1` parameter) that selects the permission profile: standard (today) or extended (as in chat).
- Require an explicit confirmation before the run for the extended profile, and record the profile, who confirmed and when in `status.json` and the run report.
- `orchestrate-tasks.ps1` already exposes this through `-PermissionMode`, `-AllowedTools` and `-DisallowedTools`: widen them only with the user's prior authorization.
- Keep the forbidden actions of the repository directives (commit, push, publication, deletion) outside the extended profile unless the authorization names them.
