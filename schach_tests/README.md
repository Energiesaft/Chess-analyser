# Schach-Simulation: erste automatisierte Tests

## Was wird geprüft?

- Python-Syntax der inline in CloudFormation eingebetteten Processor- und Confirm-Lambda.
- Vorhandensein der `.eml`-Parsinglogik in beiden Handlern.
- Das derzeitige Eingabeformat: whitespace-getrennte Felder wie `e2 e4 e7 e5`.
- Gültige und absichtlich ungültige Testdateien aus `fixtures/`.

Wichtig: Diese Tests prüfen noch keine AWS-Integration und keine vollständige Schachregeln/Legalität. Der aktuelle Stack validiert die Form von Feld-Tokens, nicht ob die Züge eine legale Partie bilden.

## Lokal ausführen (PowerShell)

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
py -m pip install -r requirements-dev.txt
py -m pytest -v
```

## Vor jeder Stack-Änderung

1. Vorlage `Schachformation1.7_SNS_IAM_Fix.yml` in diesem Ordner durch die aktuell eingesetzte CloudFormation-Vorlage ersetzen.
2. `py -m pytest -v` ausführen.
3. Erst wenn die Tests bestehen, die Vorlage in CloudFormation aktualisieren.

## Nächster sinnvoller Schritt

Die Zugformatprüfung aus beiden Lambdas in eine kleine gemeinsame, testbare Funktion refaktorieren. Danach lassen sich die Tests direkt gegen den Produktionscode ausführen, statt das Eingabeformat in den Tests nachzubilden. Anschließend können wir AWS-Aufrufe mit Mocks testen.
