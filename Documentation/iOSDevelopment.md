# iOS Development

This document describes the steps to build and debug UTM on iOS and simulator devices.

## Getting the Source

Make sure you perform a recursive clone to get all the submodules:
```
git clone --recursive https://github.com/utmapp/UTM.git
```

Alternatively, run `git submodule update --init --recursive` after cloning if you did not do a recursive clone.

## Dependencies

The easy way is to get the prebuilt dependences from [Github Actions][1]. Pick the latest release and download all of the `Sysroot-iOS-*` artifacts. You need to be logged in to Github to download artifacts. If you want to run on a real iOS device, get the `arm64` variant. If you want to run on iOS simulator for Intel Mac, get the `x86_64` variant. At this time, there is no pre-built for iOS simulator for M1 Macs.

### Building Dependencies (Advanced)

If you want to build the dependencies yourself, it is highly recommended that you start with a fresh macOS VM. This is because some of the dependencies attempt to use `/usr/local/lib` even though the architecture does not match. Certain installed packages like `libusb`, `gawk`, and `cmake` will break the build.

1. Install Xcode command line and [Homebrew][1]
2. Install the following build prerequisites
    `brew install bison pkg-config gettext glib libgpg-error nasm make meson`
   Make sure to add `bison` and `gettext` to your `$PATH` environment variable!
	`export PATH=/usr/local/opt/bison/bin:/usr/local/opt/gettext/bin:$PATH`
3. Run `./scripts/build_dependencies.sh -p ios -a arm64` for iOS devices.
4. (Intel Macs only) Run `./scripts/build_dependencies.sh -p ios -a x86_64` for iOS simulator.

## Building UTM

### Command Line

You can build UTM with the script:

```
./scripts/build_utm.sh -p ios -a arm64 -o /path/to/output/directory
```

The built artifact is an unsigned `.xcarchive` which you can use with the package tool (see below).

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

To build in Xcode for debugging, you need to change the bundle identifier to a unique value. In the project settings, choose the "iOS" target and go to the "Signing & Capabilities" tab and change the "Bundle Identifier". This can be any value that is not used by anyone else. Then choose a "Team" (free or paid account) and a certificate and profile should be generated automatically.

### Tethered Launch

For JIT to work on the latest version of iOS, it must be launched through the debugger. You can do it from Xcode (and detach the debugger after launching) or you can follow [these instructions](TetheredLaunch.md) for an easier way.

[1]: https://github.com/utmapp/UTM/actions?query=event%3Arelease+workflow%3ABuild
[2]: https://brew.sh
[3]: https://dantheman827.github.io/ios-app-signer/