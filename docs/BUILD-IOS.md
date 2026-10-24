# Klangschrift für iPhone bauen

## Voraussetzungen

- Mac mit aktuellem Xcode und iOS-SDK
- ein iPhone mit der für das gewählte Modell erforderlichen iOS-Version
- eigene Apple-ID; Xcode erlaubt persönlichen Selbstbau auf dem eigenen Gerät

## Projekt einrichten

Der folgende unsignierte Release-Bau wurde mit zwei Jobs geprüft. Er verwendet die im Projekt-Workspace gespeicherte `Package.resolved` unverändert und sperrt automatische Paketaktualisierungen:

```sh
cd ios
/usr/bin/lockf -k /tmp/ks-ios-build.lock xcodebuild \
  -project KlangschriftIOS.xcodeproj -target Klangschrift -configuration Release -sdk iphoneos \
  -clonedSourcePackagesDirPath /private/tmp/klangschrift-ios-packages \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  COMPILER_INDEX_STORE_ENABLE=NO -jobs 2 build
```

Für ein eigenes Gerät:

1. `ios/KlangschriftIOS.xcodeproj` in Xcode öffnen.
2. Die im Projekt-Workspace gespeicherte `Package.resolved` unverändert verwenden; ihre SHA-256 für diese Quellversion ist `7742c1164769fb200e608d5e0a3a5b7b90deac78b89a8d67450eb90778f31a35`. Keine automatische Paketaktualisierung zulassen.
3. Für Haupt-App und Tastatur-Erweiterung das eigene Team auswählen. Die Beispiel-Bundle-IDs und die App-Group durch eigene eindeutige Werte ersetzen.
4. Automatisches Signing aktivieren, iPhone koppeln und Entwicklermodus aktivieren.
5. Nach dem ersten Start in der App **Whisper Base** laden und danach vorbereiten, bevor Diktieren erwartet wird.
6. Haupt-App und Tastatur auf dem echten iPhone prüfen, insbesondere gemeinsame App Group und Aufnahme.

Ein kostenloses persönliches Profil läuft nach sieben Tagen ab. Der vollständige Weg mit App Group und Tastatur für ein fremdes kostenloses Personal Team ist noch nicht geprüft. Der unsignierte Quellbau und die Modell-Auswahllogik ersetzen keinen nativen Erststart und keine Abnahme von Haupt-App oder Tastatur auf einem iPhone. Simulator-Ergebnisse ersetzen keine Prüfung auf einem iPhone. Das Projekt verspricht keine Ein-Klick-Installation und keine allgemeine IPA-Verteilung.
