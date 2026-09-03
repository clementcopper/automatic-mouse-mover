# Handoff — 2026-09-03 11:47
Arbeitsverzeichnis: /Users/danielmartin/automatic-mouse-mover

## Stand
Learnings sind in path-scoped Regel-Dateien aufgeteilt (`.claude/rules/{build,native,testing}.md`),
CLAUDE.md zeigt darauf. Der Branch `fix/crashes-macos-and-arm64` ist in master gemerged
(`64f9b0b`) und lokal wie auf origin gelöscht. master ist gepusht, Working Tree clean,
`go vet` und `go test -race` grün. Von der anderen Session (M2) kam v1.6.1 mit dem 1.6.0
Field Report; dessen Einzeiler stecken schon in den Regel-Dateien.

## Nächster Schritt
Auf dem M2 den Stand nachziehen, sonst divergiert es wieder:
```bash
git checkout master && git pull --ff-only && git branch -d fix/crashes-macos-and-arm64 && git fetch -p
```
Danach offene Punkte aus dem Memory (`amm-fork-state`): Notarisierung, `appInfo/icon.svg`.

## Schon probiert, geht nicht
- Plain "Sync" in der IDE bei ahead/behind: scheitert an der Divergenz, fetch + rebase nötig.
- `TaskOutput` mit dem Namen "code-review" als task_id: kein Task; die Notification kommt von
  allein, nicht darauf warten.

## Was Daniel entschieden hat
- Fix-Branch merged und gelöscht; Arbeit läuft auf master (2026-09-03).
- `.claude/settings.local.json` und `.vscode/` sind in `.gitignore`, nicht committen.

## Erledigt und vom Tisch
- Review-Findings zu den Regel-Dateien (Scoping, Duplikate, MIN_MACOS, Statuszeile): alle eingearbeitet.
- CLAUDE.md-Konflikt aus dem Rebase: gelöst, Sessions/-Satz von remote übernommen.
