# Datenschutz

Klangschrift ist für lokale Verarbeitung ausgelegt. Aufnahmen und Transkripte werden auf dem verwendeten Gerät verarbeitet und gespeichert. Für Modell- oder Paketdownloads wird Netzwerkzugang benötigt; das ist keine Zusage, dass niemals Netzwerkverkehr entsteht.

Auf dem Mac liegt die App-Datenwurzel unter `~/Library/Application Support/io.github.miggidev618.klangschrift/`; dazu gehören die Datenbank `klangschrift.sqlite` sowie die Ordner `audio`, `backups` und `recovery`. Repository-Inhalte werden mit AES-GCM verschlüsselt; der Schlüssel kommt aus der macOS-Schlüsselbundverwaltung. Das ist keine Zusage einer Vollverschlüsselung sämtlicher Dateien oder des Laufwerks.

Auf dem iPhone werden Verlauf und eigene Schreibweisen in den App-Einstellungen gespeichert. Heruntergeladene Modelle liegen im App-Container unter `Application Support/Klangschrift/Models/`. Die App und Tastatur tauschen ihren lokalen Zustand über die konfigurierte App Group aus. Die Diagnosespur enthält laut Code Metadaten; sie ist nicht als allgemeine Garantie für die Abwesenheit personenbezogener Daten gedacht.

Für Diktate benötigt die Mac-App Mikrofonzugriff und kann für das Einfügen in andere Programme Bedienungshilfen benötigen. Die iPhone-Tastatur benötigt für die lokale Verbindung den von iOS angebotenen vollständigen Tastaturzugriff. Diese Rechte können in den Systemeinstellungen widerrufen werden.

Im Mac-Verlauf gibt es „Auswahl löschen“ und „Alles löschen“. Auswahl löschen verschiebt zunächst in den internen Papierkorb; „Alles löschen“ ist endgültig. Auf dem iPhone lassen sich Verlaufseinträge einzeln entfernen.

Auf dem iPhone bietet „Speicher & Daten“ zusätzlich das Löschen des gesamten Verlaufs, nicht aktiver heruntergeladener Modelle sowie Klangschrift-eigener temporärer und Cache-Dateien. Wörterbuch und Einstellungen bleiben beim Verlaufslöschen erhalten. Die Bereinigung ist nur möglich, wenn kein Diktat, Modellvorgang, Download oder Tastaturvorgang läuft.

Vor dem Teilen von Fehlerberichten Diktate, Audio, Verlauf, Tokens und private Geräteinformationen entfernen.
