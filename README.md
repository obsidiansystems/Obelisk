# Obelisk

Obelisk provides an easy way to develop and deploy your [Reflex](https://github.com/reflex-frp/reflex) project as web apps and as mobile apps.

- [Installing Obelisk](#installing-obelisk)
- [Developing an Obelisk project](#developing-an-obelisk-project)
- [Deploying](#deploying)
  - [Locally](#locally)
  - [EC2](#ec2)
- [Mobile](#mobile)
  - [iOS](#ios)
  - [Android](#android)

## Installing Obelisk
1. [Install Nix](https://nixos.org/nix/).
    If you already have Nix installed, make sure you have version 2.0 or higher.  To check your current version, run `nix-env --version`.
1. Set up nix caches
    1. If you are running NixOS, add this to `/etc/nixos/configuration.nix`:
        ```
        nix.binaryCaches = [ "https://cache.nixos.org/" "https://nixcache.reflex-frp.org" ];
        nix.binaryCachePublicKeys = [ "ryantrinkle.com-1:JJiAKaRv9mWgpVAz8dwewnZe0AzzEAzPkagE9SP5NWI=" ];
        ```
    1. If you are using another operating system or linux distribution, ensure that these lines are present in `/etc/nix/nix.conf`:
        ```
        substituters = https://cache.nixos.org https://nixcache.reflex-frp.org
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= ryantrinkle.com-1:JJiAKaRv9mWgpVAz8dwewnZe0AzzEAzPkagE9SP5NWI=
        ```
        * other Linux: enable sandboxing (see https://github.com/obsidiansystems/obelisk/issues/6)
          ```
          sandbox = true
          ```
        * MacOS: disable sandboxing (there are still some impure dependencies for now)
          ```
          sandbox = false
          ```
          then restart the nix daemon
          ```
          sudo launchctl stop org.nixos.nix-daemon
          sudo launchctl start org.nixos.nix-daemon
          ```
1. Install obelisk: `nix-env -f https://github.com/obsidiansystems/obelisk/archive/master.tar.gz -iA command`

### Contributing to Obelisk

When developing on obelisk itself you may launch `ghcid` for the corresponding project as follows. For example to launch ghcid for `lib/backend` project:

```
nix-shell -A obelisk.obelisk-backend.env --run "cd lib/backend && ghcid -c 'cabal new-repl'"
```

Or to launch ghcid for `lib/command` project:

```
nix-shell -A obelisk.obelisk-command.env --run "cd lib/command && ghcid -c 'cabal new-repl'"
```

If you need a compatible `cabal-install` and `ghcid` installed in your `nix-shell` as well, use `obeliskDev` instead of `obelisk`, like so:

```
nix-shell -A obeliskDev.obelisk-command.env --run "cd lib/command && ghcid -c 'cabal new-repl'"
```

If you get an error like this one:

```
No files loaded, GHCi is not working properly.
Command: cabal new-repl
```

Issue a cabal new-build first:

```
nix-shell -A obeliskDev.obelisk-command.env --run "cd lib/command && cabal new-build"
```

Now `ghcid` should work fine.

### Accessing private repositories
To allow the Nix builder to access private git repositories, follow these steps:

1. [Get set up to connect to GitHub with SSH](https://help.github.com/articles/connecting-to-github-with-ssh/)
1. [Create a GitHub personal access token](https://help.github.com/articles/creating-a-personal-access-token-for-the-command-line/)
1. Set environment variables:
   * NixOS: Add this to `/etc/nixos/configuration.nix`:
    ```
    nix.envVars = {
      NIX_GITHUB_PRIVATE_USERNAME = "your-github-username";
      NIX_GITHUB_PRIVATE_PASSWORD = "your-github-personal-access-token";
    };
    ```
   * MacOS:
    ```
    sudo launchctl setenv NIX_GITHUB_PRIVATE_USERNAME "your-github-username"
    sudo launchctl setenv NIX_GITHUB_PRIVATE_PASSWORD "your-github-personal-access"
    sudo launchctl stop org.nixos.nix-daemon
    sudo launchctl start org.nixos.nix-daemon
    ```
1. `nix-env -i hub` OR `nix-env -iA nixos.gitAndTools.hub`
1. `hub clone yourusername/yourproject`
  * NOTE: you must authenticate with hub at least once, because the `ob` command uses `hub` for authentication
  #TODO: Make ob do this itself (either invoke hub automatically or not depend on hub)

## Developing an Obelisk project

To create a new Obelisk project, go to an empty directory and run:

```
ob init
```

Obelisk leverages ghcid to provide a live-reloading server that handles both frontend and backend. To run your Obelisk app and monitor the source for changes:

```
ob run
```

Now go to http://localhost:8000 (or the port specified in `config/common/route`) to access your app.

Every time you change the Haskell source files in frontend, common or backend, `ob run` will automatically recompile the modified files and reload the server. Furthermore, it will display on screen compilation errors and warnings if any.

## Deploying

### Locally

Build everything:

```
nix-build -A exe -o result-exe
```

Run the server:

```
cd result-exe
./backend
```

### EC2

In this section we will demonstrate how to deploy your Obelisk app to an Amazon EC2 instance.

First create a new EC2 instance:

1. Launch a NixOS 17.09 EC2 instance (we recommend [this AMI](https://console.aws.amazon.com/ec2/v2/home?region=us-east-1#LaunchInstanceWizard:ami=ami-40bee63a))
1. In the instance configuration wizard ensure that your instance has at least 1GB RAM and 10GB disk space.
1. When prompted save your AWS private key (`~/myaws.pem`) somewhere safe. We'll need it later during deployment.
1. Go to "Security Groups", select your instance's security group and under "Inbound" tab add a new rule for HTTP port 80 and 443.

At this stage your instance should be booting and become accessible shortly. Note down the hostname of your EC2 instance.

Now go to your Obelisk project directory (`~/code/myapp`), and initialize a deployment config (`~/code/myapp-deploy`):
Your project directory must be "thunkable", i.e. something on which `ob thunk pack` can be called. Usually it will be a git repository whose current revision has been pushed upstream.

```
cd ~/code/myapp
SERVER=ec2-35-183-22-197.ca-central-1.compute.amazonaws.com
ROUTE=https://myapp.com   # Publicly accessible route to your app
EMAIL=myname@myapp.com
ob deploy init \
  --ssh-key ~/myaws.pem \
  --hostname $SERVER \
  --route $ROUTE \
  --admin-email $EMAIL \
  ~/code/myapp-deploy
```

NOTE: HTTPS is enabled by default; to disable https, pass `--disable-https` to the `ob deploy init` command above.

Then go to that created deployment configuration directory, and initiate the deployment:

```
cd ~/code/myapp-deploy
ob deploy push
```

`ob deploy push` will locally build your app and then transfer it, along with all the Nix package dependencies, via ssh to the EC2 instance.

At this point you are done. Your app will be accessible at `${ROUTE}`.

### Deploying an updated version

If you'd like to deploy an updated version (with new commits) of your Obelisk app: simply go to the configuration directory, update the source thunk and push:

```
cd ~/code/myapp-deploy
ob deploy update
ob deploy push
```

## Mobile
Until Obelisk offers a `ob deploy` equivalent for mobile apps, you are recommended to do it manually as follows.

### iOS

#### First time setup
Development on iOS requires a computer running macOS and an iOS developer account.
Your account must also belong to an Apple Developer Team, if you want to access developer portal links (otherwise they'll redirect to your account page).

##### iPhone
1. Connect the iPhone on which you'd like to run builds - this will open up iTunes.
1. Click accept to authorize on both the computer and the iPhone.

##### Xcode
Install Xcode 8.2 (contains iOS SDK 10.2) and open it so that it runs its post install tool setup.

These versions will work out of the box but iOS SDKs prior to 11.3 should also work. You can choose another installed version in `default.nix`

More recent Xcodes should also work, as long as one of the SDKs mentioned above has been used.
To add another SDK to your current Xcode, [download](https://developer.apple.com/download/more/) the corresponding Xcode, extract it and copy its SDK folder next to the installed one, e.g.
```
open -W Xcode_9.2.xip
sudo cp -R Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS11.2.sdk
```


You can verify that you have correct versions by running
```
xcodebuild -showsdks
```

##### Certificates
To deploy and/or package apps, you'll need to inform Apple of your development devices and permissions by
adding credentials to the correct provisioning profile via the Apple Developer portal.

1. Open up XCode and go to Preferences - Accounts. Select the organization
Member role, click Manage Certificates, and add an iOS Development
certificate.
1. Go to [developer portal - devices](https://developer.apple.com/account/ios/device/) and add your device.
To find your device's UDID, select it in iTunes and click the serial number.
1. Go to [developer portal - development profiles](https://developer.apple.com/account/ios/profile/limited).
Create a development profile and add your certificate and device.
Click "Generate" and then download and open the profile.

#### Building
1. In your project's `default.nix` set values for `ios.bundleIdentifier` and `ios.bundleName`.
Ensure that `bundleIdentifier` matches the App ID of the development profile, or that you are using a wildcard profile.
1. Run `nix-build -A ios.frontend -o result-ios` to build the app. Find it at `result-ios/frontend.app`

#### Deploying
1. Connect the registered iPhone.
1. Find your Apple Team ID in the [developer portal](https://developer.apple.com/account/#/membership).
1. Run the deploy command with your Team ID:
```
result-ios/bin/deploy [TEAM_ID]
# or in debug mode via lldb:
result-ios/bin/deploy [TEAM_ID] -d
```

#### Packaging
1. Go to [developer portal - distribution profiles](https://developer.apple.com/account/ios/profile/production).
Create and download a distribution profile.
1. Run the package script with your TEAM ID and your distribution profile to create a `.ipa`:
```
result-ios/bin/package [TEAM_ID] /path/to/output/.ipa /path/to/profile/file
```

#### Debugging
It's also possible to inspect iOS WkWebView apps once they are installed in the iPhone:
1. On the desktop, go to Safari > Preferences > Advanced and enable Develop menu.
1. On the iPhone go to Settings > Safari > Advanced and enable Web Inspector.
1. Open the app on the iPhone while it is connected to the desktop.
1. In the desktop's Safari Develop menu, you should see your iPhone. Select the screen under the name of the app.

### Android

1. In your project's `default.nix` set a suitable value for `android.applicationId` and `android.displayName`.
1. Run `nix-build -A android.frontend -o result-android` to build the Android app.
1. A debug version of the app should be generated at `result-android/android-app-debug.apk`

Now deploy the built apk file to your Android device:

1. Enable *USB debugging* in your Android device ([instructions here](https://developer.android.com/studio/debug/dev-options))
1. Connect the device using USB (be sure to confirm any security prompts on the device)
1. Run the deploy script: `result-android/bin/deploy`

This should copy over and install the application on your device (if you see a  "*signatures do not match*" error, simply uninstall the previous app from the device before retrying the deploy). The name of the installed application will be what you have specified for `android.displayName` in the `default.nix`.

#### Releasing to Play Store

##### Configure signing

The previous section would have generated a debug version of the app. In order to build a release version you will need to sign your app. Obelisk can automatically sign the app during build if you provide it with your keystore file in `default.nix`.

First, if you do not already have a keystore, create it as follows (for more information, see the [Android documentation](https://developer.android.com/studio/publish/app-signing#signing-manually)):

```
nix-shell -p androidenv.platformTools --run "keytool -genkey -v -keystore myandroidkey.jks -keyalg RSA -keysize 2048 -validity 10000 -alias myandroidalias"
```

(Besure to give an appropriate keystore filename and key alias string above.)

The `keytool` command will ask you for some details, including a keystore password and a key password (we will use these passwords further below). It will now have created a `myandroidkey.jks` file under the current directory. Move that to somewhere safe, and note down its full path.

Now edit your project's `default.nix` and tell Obelisk of your app's keystore file. Your `default.nix` should look like this after the edit:

```nix
  ...
  android.applicationId = "com.example.myapp";
  android.displayName = "My App";
  android.releaseKey =
    { storeFile = /path/to/myandroidkey.jks;
      storePassword = "abcd1234";
      keyAlias = "myandroidalias";
      keyPassword = "abcd1234";
    };
  ...
```

##### Build a release version

After having configured signing for your app, you may proceed to build a release version of the app. This is no different to how you build the non-release version, so consult the section [Android](#android) further above for exact instructions on building and deploying to your device.
