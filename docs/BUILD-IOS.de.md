# iPhone-App bauen

[English](BUILD-IOS.md)

Du brauchst einen Mac mit Xcode, ein iPhone und eine Apple-ID.

1. `ios/KlangschriftIOS.xcodeproj` in Xcode öffnen.
2. Bei der App und bei der Tastatur dein eigenes Team auswählen. Bundle-IDs und App Group auf eigene Werte ändern (z. B. `com.deinname.klangschrift`).
3. iPhone anschliessen, auf dem iPhone den Entwicklermodus einschalten und in Xcode auf Start drücken.
4. In der App ein Modell laden (empfohlen: Whisper Base).
5. Auf dem iPhone unter Einstellungen → Allgemein → Tastatur → Tastaturen die Klangschrift-Tastatur hinzufügen und „Vollen Zugriff“ erlauben.

Mit einer kostenlosen Apple-ID läuft die App sieben Tage. Danach in Xcode einfach neu installieren.

Ohne Xcode-Oberfläche geht der Build auch im Terminal:

```sh
cd ios
xcodebuild -project KlangschriftIOS.xcodeproj -target Klangschrift \
  -configuration Release -sdk iphoneos \
  -clonedSourcePackagesDirPath /private/tmp/klangschrift-ios-packages \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT=/private/tmp/klangschrift-ios-build \
  OBJROOT=/private/tmp/klangschrift-ios-obj \
  build
```
