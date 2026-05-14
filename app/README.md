# Omi App

The Omi App is a Flutter-based mobile application that serves as the companion app for Omi devices. This app enables users to interact with their Omi device, manage apps, and customize their experience.

## 📚 **[View Full App setup instructions in the documentation](https://docs.omi.me/doc/developer/AppSetup)**

### Quick Setup

Before getting started, make sure your device is connected and unlocked. If you're using an iPhone, ensure that Developer Mode is enabled — you can toggle this in the iPhone settings. For Android devices, make sure the device is connected and USB debugging is enabled in Developer Options

1. Navigate to the app directory:
   ```bash
   cd app
   ```

2. Run setup script:
   ```bash
   # For iOS
   bash setup.sh ios

   # For Android
   bash setup.sh android
   ```
 
3. Ensure GitHub SSH access is set up correctly for pulling certificates from repositories. After running the command below, if you're prompted for a passphrase, enter your SSH passphrase — or simply press Enter/Return if you haven't set one.
    ```bash
   cd ~/.ssh; ssh-add
   ```

4. To run the app, navigate to the app directory and use the following command:
   ```bash
   flutter run --flavor dev
   ```


### Building and Deploying to iPhone

To build and deploy the app to an iPhone so it can run independently from your laptop:

#### Local signing with Adam's Apple Development cert

For Adam's local iPhone installs, use the local signing override rather than the upstream
BasedHardware team. The installed certificate appears as
`Apple Development: coralcaves@gmail.com (M6V8W4X24Z)`, but the Apple team identifier
for Xcode builds is `66K48S8RD4`.

1. Copy `ios/Flutter/LocalSigning.example.xcconfig` to
   `ios/Flutter/LocalSigning.xcconfig`.
2. Keep `.dev.env` pointed at hosted Omi auth/backend:
   `API_BASE_URL=https://api.omi.me/`, `USE_WEB_AUTH=true`,
   `USE_AUTH_CUSTOM_TOKEN=true`.
3. In a fresh worktree, restore the ignored local build inputs from the main
   checkout or existing working tree before building:
   - `.dev.env`
   - `lib/firebase_options_dev.dart`
   - `lib/firebase_options_prod.dart`
   - `ios/Config/Dev/GoogleService-Info.plist`
   - `ios/Config/Prod/GoogleService-Info.plist`
   - `ios/Runner/GoogleService-Info.plist` (copy the dev plist here before
     the first build, because Xcode expects the file to exist before its copy
     script refreshes it)
4. Refresh generated Flutter files and Xcode paths inside the current checkout.
   Use Profile for standalone device installs; Debug iOS builds require Flutter
   tooling or Xcode to be attached and will crash when launched from the home
   screen:
   ```bash
   flutter pub get
   flutter pub run build_runner build --delete-conflicting-outputs
   flutter build ios --profile --flavor dev --config-only --no-codesign
   ```
5. Build with the local signing override:
   ```bash
   xcodebuild -workspace ios/Runner.xcworkspace \
     -scheme dev \
     -configuration Profile-dev \
     -destination 'id=00008150-001004D93E40401C' \
     -xcconfig ios/Flutter/LocalSigning.xcconfig \
     -allowProvisioningUpdates \
     -allowProvisioningDeviceRegistration \
     build
   ```
6. Install and launch the resulting app with `devicectl`:
   ```bash
   xcrun devicectl device install app \
     --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 \
     ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Profile-dev-iphoneos/Runner.app

   xcrun devicectl device process launch \
     --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 \
     com.adam.omi.dev
   ```

Do not change the checked-in official bundle IDs just to satisfy local signing. The app
group is build-setting driven through `APP_GROUP_IDENTIFIER`, so the official default
stays `group.com.friend-app-with-wearable.ios12` and local installs can use
`group.com.adam.omi.dev`. This installs as the local bundle `com.adam.omi.dev`;
overwriting the official Omi bundle requires valid BasedHardware signing assets.

1. Build the iOS app with release mode and specific flavor:
   ```bash
   flutter build ios --flavor dev --release
   ```
   This produces an .app bundle at:
   ```
   build/ios/iphoneos/Runner.app
   ```

2. **Install directly from the .app bundle (recommended for local device install):**
   ```bash
   ios-deploy --bundle build/ios/iphoneos/Runner.app --debug
   ```
   This will install the app directly to your connected iPhone.

Once installed, the app will run on your iPhone independently from your development machine.

## Need Help?

- 💬 Join our [Discord Community](http://discord.omi.me)
