# orchestrate-tasks.ps1: coda sequenziale di task con `claude -p`

[English](orchestrate-tasks.md)

`scripts/orchestrate-tasks.ps1` esegue i task autonomi del tracker di un repository uno alla volta, ciascuno in un processo `claude -p` nuovo, con commit locale dopo ciascuno. È indipendente da `run-ready-tasks.ps1`: serve quando i task modificano il runner.

- Trova checkout (radice Git della cartella corrente), SecondBrain (`SECONDBRAIN_HOME`, altrimenti la cartella sopra lo script) e dossier (identità `origin` di Git in `01-projects/*/repository.json`); crea la cartella di lavoro con `work.ps1` se manca `-WorkDir`.
- Anteprima per impostazione predefinita; `-Run` avvia una copia bloccata dello script. Predefiniti: `-Model sonnet -Effort medium -PermissionMode acceptEdits`, un elenco esplicito `-AllowedTools`, `-DisallowedTools` per git commit, push, tag, reset, clean, rebase, `rm`, `Remove-Item`, 45 minuti per task.
- Per task: albero pulito richiesto, task messo `in_progress`, sessione eseguita, un `done` senza evidenza riaperto, un task che finisce senza risultato parcheggiato come `user_required`, poi commit locale dei percorsi cambiati (mai push). Un limite di quota attende il reset (`-MaxWaitHours`) e riprova; tre fallimenti di fila fermano la corsa.
- I task che richiedono lo schermo (computer-use) o un installer sono saltati da `-ExcludePattern`; `-IncludeExcluded` toglie il filtro e quella sessione finisce parcheggiata.
- Stato: `status.json`, `events.jsonl`, `stop.flag` nella cartella di lavoro.

## Prompt: creare l'agente di avvio in qualsiasi repository

```text
Crea il subagente di progetto "task-runner" in .claude/agents/task-runner.md di questo repository (frontmatter: name task-runner, description "Launches and monitors the sequential task orchestrator for this repository (one claude -p session per tracker task, local commit after each). Use only when the parent explicitly asks to start or check it.", tools "*"). Non lanciarlo, non committare il file.

Ruolo: lanci e monitori $env:SECONDBRAIN_HOME\scripts\orchestrate-tasks.ps1 (se la variabile non è impostata, segnalalo e fermati). Lo script esegue i task autonomi del tracker del repository corrente uno alla volta, ciascuno in un `claude -p` nuovo, con commit locale dopo ciascuno. Tu non esegui task e non modifichi codice di prodotto. Lo script trova da solo checkout, dossier (dall'identità origin) e cartella di lavoro, e con -Run gira su una copia bloccata di sé stesso.

Il corpo dell'agente deve prescrivere:
1. Input dal chiamante (se mancano, riporta cosa manca e fermati; non fare domande all'utente): modello, sforzo, MaxTasks (0 = nessun limite), timeout per task in minuti, ore massime di attesa per il limite di quota, e se togliere il filtro dei task a schermo (-IncludeExcluded, default no). Default dello script: sonnet, medium, 45 minuti, 6 ore. I permessi li concede il chiamante a monte; -AllowedTools/-DisallowedTools sono parametri dello script e il default vieta git commit/push/tag/reset/clean/rebase, rm e Remove-Item nelle sessioni dei task.
2. Avvio: anteprima senza -Run dalla radice del repository e report di task selezionati e saltati dal filtro; se nessuno è selezionato, riporta e fermati. Poi controlla che `git status --porcelain` sia vuoto (lo script ignora .claude/agents/) e che nessun orchestratore sia vivo (status.json dell'ultima cartella task-run: fase running con pid vivo = fermati e riporta). Lancia staccato con Start-Process pwsh -NoProfile -File <script> -Run con i parametri ricevuti, dalla radice del repository; registra il pid e la cartella di lavoro.
3. Monitoraggio: leggi status.json e la coda di events.jsonl della cartella di lavoro a intervalli lunghi (diversi minuti, attese in background, mai sondaggi stretti). Fasi: running, waiting-quota (waitingUntil), finished. stop.flag nella cartella di lavoro ferma la corsa prima del task successivo: crealo solo se lo chiede il chiamante. Se il processo non c'è più e la fase è ancora running (per esempio un aggiornamento di Claude l'ha troncato), riporta e riavvia una sola volta con gli stessi parametri: lo script riseleziona i task ancora aperti.
4. Report a ogni arresto e alla fine: per task esito, hash del commit (git log), stato nel tracker dopo, evidenza; poi task saltati, falliti e parcheggiati (user_required) con il motivo da events.jsonl, stato della quota e percorso della cartella di lavoro. Riporta solo ciò che leggi da status.json, events.jsonl, git e tracker.
5. Regole: mai commit, push, pubblicazione o cancellazioni tuoi (lo script committa in locale solo i percorsi cambiati dal task e non fa mai push); scritture nel dossier solo con gli script SecondBrain, normalmente nessuna; non delegare ad altri agenti.

Se esiste già un .claude/agents/task-runner.md, non sovrascriverlo: confrontalo e proponi le differenze.
```

## Nota: permessi completi per il runner

Il runner (`run-ready-tasks.ps1`) avvia gli agenti con un profilo di permessi fisso: modifica dei file nel checkout, nessun cambio alla storia Git, nessuna cancellazione. Le sessioni avviate in chat possono avere permessi più ampi concessi dall'utente.

Da fare: far girare il runner con gli stessi permessi della chat, solo dopo autorizzazione preventiva o impostazione esplicita nel runner.

- Aggiungere un'impostazione del runner (per corsa, nell'app orchestratore e come parametro di `run-ready-tasks.ps1`) che sceglie il profilo di permessi: standard (oggi) o esteso (come in chat).
- Richiedere una conferma esplicita prima della corsa per il profilo esteso, e registrare profilo, chi ha confermato e quando in `status.json` e nel rapporto della corsa.
- `orchestrate-tasks.ps1` lo espone già con `-PermissionMode`, `-AllowedTools` e `-DisallowedTools`: ampliarli solo con l'autorizzazione preventiva dell'utente.
- Le azioni vietate dalle direttive del repository (commit, push, pubblicazione, cancellazione) restano fuori dal profilo esteso, salvo che l'autorizzazione le nomini.
