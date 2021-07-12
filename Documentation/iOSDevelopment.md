# iOS Development

This document describes the steps to build and debug UTM on iOS and simulator devices.

## Getting the Source

Make sure you perform a recursive clone to get all the submodules:
```
git clone --recursive https://github.com/utmapp/UTM.git
```

Alternatively, run `git submodule update --init --recursive` after cloning if you did not do a recursive clone.

## Dependencies

The easy way is to get the prebuilt dependences from [Github Actions][1]. Pick the latest release and download the `Sysroot-*` artifact for the targets you wish to develop on. You need to be logged in to Github to download artifacts.

|              | Intel                      | Apple Silicon             |
|--------------|----------------------------|---------------------------|
| iOS          | N/A                        | `ios-arm64`               |
| iOS SE       | N/A                        | `ios-tci-arm64`           |
| Simulator    | `ios_simulator-x86_64`     | `ios_simulator-arm64`     |
| Simulator SE | `ios_simulator-tci-x86_64` | `ios_simulator-tci-arm64` |

### Important Note on Prebuilt Dependencies
If you choose to leverage prebuilt dependencies, you will need to fetch the dependencies that correspond to the version of UTM that you have checked out. All UTM releases are tagged in Git. For example, if you are trying to build version `X.Y.Z`, you will first want to run `git checkout X.Y.Z`, and then download the prebuilt dependency package for that release version. You will need to place the extracted artifacts in the same directory as the UTM source code. Once you have done this, you can follow the instructions below to complete the build or even build and debug from XCode.

If you are building off of the latest `master` branch, then use the latest pre-built dependencies.

### Building Dependencies (Advanced)

If you want to build the dependencies yourself, it is highly recommended that you start with a fresh macOS VM. This is because some of the dependencies attempt to use `/usr/local/lib` even though the architecture does not match. Certain installed packages like `libusb`, `gawk`, and `cmake` will break the build.

1. Install Xcode command line and [Homebrew][1]
2. Install the following build prerequisites
    `brew install bison pkg-config gettext glib libgpg-error nasm make meson`
   Make sure to add `bison` and `gettext` to your `$PATH` environment variable!
	`export PATH=/usr/local/opt/bison/bin:/usr/local/opt/gettext/bin:$PATH`
3. Run `./scripts/build_dependencies.sh -p PLATFORM -a ARCHITECTURE` where `ARCHITECTURE` is the last part of the table above (e.g. `x86_64`) and `PLATFORM` is the first part (e.g. `ios_simulator-tci`).
4. Repeat the above for any other platforms and architectures you wish to target.

## Building UTM

### Command Line

You can build UTM with the script:

```
./scripts/build_utm.sh -p ios -a arm64 -o /path/to/output/directory
```

The built artifact is an unsigned `.xcarchive` which you can use with the package tool (see below). Replace `ios` with `ios-tci` to build UTM SE.

### Packaging

Artifacts built with `build_utm.sh` (includes Github Actions artifacts) must be re-signed before it can be used. For stock iOS devices, you can sign with either a free developer account or a paid developer account. Free accounts have a 7 day expire time and must be re-signed every 7 days. For jailbroken iOS devices, you can generate a DEB which is fake-signed.

#### Stock signed IPA

For a user friendly option, you can use [iOS App Signer][3] to re-sign the `.xcarchive`. Advanced users can use the package.sh script:

```
./scripts/package.sh signedipa /path/to/UTM.xcarchive /path/to/output TEAM_ID PROFILE_UUID
```

This builds `UTM.ipa` in `/path/to/output` which can be installed by Xcode, iTunes, or AirDrop. Note that you need a "Development" signing certificate and NOT a "Distribution" certificate. This is because UTM requires a provisioning profile with the `get-task-allow` entitlement which Apple only grants for Development signing.

#### Unsigned IPA

```
./scripts/package.sh ipa /path/to/UTM.xcarchive /path/to/output
```

This builds `UTM.ipa` in `/path/to/output` which can be installed by AltStore or a jailbroken device with AppSync Unified installed.

#### DEB Package

```
./scripts/package.sh deb /path/to/UTM.xcarchive /path/to/output
```

This builds `UTM.deb` which is a wrapper for an unsigned `UTM.ipa` which can be installed by Cydia or Sileo along with AppSync Unified.

### Xcode Development

Copy `CodeSigning.xcconfig.sample` to `CodeSigning.xcconfig` and modify the file replacing `DEVELOPMENT_TEAM` with your Team ID and `PRODUCT_BUNDLE_PREFIX` with a bundle identifier that is registered to you.

If you have a paid Apple Developer account, you can find your Team ID at https://developer.apple.com/account/#/membership

If you have a free Apple Developer account, you need to generate a new signing certificate. To do so, follow the steps in [iOS App Signer][3] to create a new Xcode project and generate a provisioning profile. After saving the project, open `project.pbxproj` inside your newly created `.xcproj` and look for `DEVELOPMENT_TEAM`. Copy this value to `CodeSigning.xcconfig` and your unique identifier to `PRODUCT_BUNDLE_PREFIX`.

### Tethered Launch

For JIT to work on the latest version of iOS, it must be launched through the debugger. You can do it from Xcode (and detach the debugger after launching) or you can follow [these instructions](TetheredLaunch.md) for an easier way.

[1]: https://github.com/utmapp/UTM/actions?query=event%3Arelease+workflow%3ABuild
[2]: https://brew.sh
[3]: https://dantheman827.github.io/ios-app-signer/
