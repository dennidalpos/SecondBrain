# config

Schemi e policy condivise, senza dati locali.

- `publication-policy.json`: ammissioni dei riscontri e revisioni binarie della scansione di pubblicazione (tracciata, sopravvive al reset di `.runtime`).
- `shared.json`: policy condivisa (proprietari ammessi, cartelle escluse, letture tra progetti).
- `*.schema.json`: schemi di catalogo prompt, fonti e tracker.
- `PSScriptAnalyzerSettings.psd1`, `lint-baseline.json`: regole di analisi statica e riscontri differiti per `scripts/lint.ps1` (baseline aggiornata a mano con `-ExportBaseline`).
  Deferred findings (98 on 2026-11-24, kept on purpose, each group reviewed for #817): `PSUseBOMForUnicodeEncodedFile` (22) because the repository writes UTF-8 without BOM and PowerShell 7.5 reads it; `PSAvoidUsingWriteHost` (53) in console-facing CLIs (`rollback-repo.ps1`, `SecondBrain.Portable.psm1`, test runners) and `mcp-server.ps1`, where a rewrite to the message keys would change output that tests and clients parse; `PSUseApprovedVerbs` (21) on test helper and internal function names, where renames touch many callers for no behavior gain; `PSAvoidDefaultValueSwitchParameter` (2) in `secondbrain.ps1` and `SecondBrain.Portable.psm1`, whose defaults are part of the documented CLI. New findings still fail `scripts/lint.ps1`.
- `workstation.example.json`: esempio di configurazione della postazione.
- `local/`: configurazione locale della postazione, ignorata da Git.
- **Chi scrive:** revisione manuale; i dati della postazione vanno in `.runtime`, non qui.
