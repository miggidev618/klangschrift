# Build the iPhone app

[Deutsch](BUILD-IOS.de.md)

You need a Mac with Xcode, an iPhone and an Apple ID.

1. Open `ios/KlangschriftIOS.xcodeproj` in Xcode.
2. Select your own team for the app and the keyboard. Change bundle IDs and the App Group to your own values (for example, `com.yourname.klangschrift`).
3. Connect the iPhone, turn on Developer Mode on the iPhone and press Run in Xcode.
4. Download a model in the app (recommended: Whisper Base).
5. On the iPhone, add the Klangschrift keyboard under Settings → General → Keyboard → Keyboards and allow “Full Access”.

With a free Apple ID, the app works for seven days. Then simply reinstall it in Xcode.

You can also build in Terminal without the Xcode interface:

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
