//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <dlfcn.h>
#import <sys/sysctl.h>
#import <TargetConditionals.h>
#import "UTMQemuSystem.h"
#import "UTMConfiguration.h"
#import "UTMConfiguration+Constants.h"
#import "UTMConfiguration+Display.h"
#import "UTMConfiguration+Drives.h"
#import "UTMConfiguration+Miscellaneous.h"
#import "UTMConfiguration+Networking.h"
#import "UTMConfiguration+Sharing.h"
#import "UTMConfiguration+System.h"
#import "UTMConfigurationPortForward.h"
#import "UTMJailbreak.h"
#import "UTMLogging.h"

typedef struct {
    NSInteger cpus;
    NSInteger threads;
} CPUCount;

@interface UTMQemuSystem ()

@property (nonatomic, readonly) NSURL *resourceURL;
@property (nonatomic, readonly) CPUCount emulatedCpuCount;
@property (nonatomic, readonly) BOOL useHypervisor;
@property (nonatomic, readonly) BOOL hasCustomBios;
@property (nonatomic, readonly) BOOL usbSupported;

@end

@implementation UTMQemuSystem {
    int (*_qemu_init)(int, const char *[], const char *[]);
    void (*_qemu_main_loop)(void);
    void (*_qemu_cleanup)(void);
}

static void *start_qemu(void *args) {
    UTMQemuSystem *self = (__bridge_transfer UTMQemuSystem *)args;
    NSArray<NSString *> *qemuArgv = self.argv;
    
    NSCAssert(self->_qemu_init != NULL, @"Started thread with invalid function.");
    NSCAssert(self->_qemu_main_loop != NULL, @"Started thread with invalid function.");
    NSCAssert(self->_qemu_cleanup != NULL, @"Started thread with invalid function.");
    NSCAssert(qemuArgv, @"Started thread with invalid argv.");
    
    int argc = (int)qemuArgv.count + 1;
    const char *argv[argc];
    argv[0] = "qemu-system";
    for (int i = 0; i < qemuArgv.count; i++) {
        argv[i+1] = [qemuArgv[i] UTF8String];
    }
    const char *envp[] = { NULL };
    self->_qemu_init(argc, argv, envp);
    self->_qemu_main_loop();
    self->_qemu_cleanup();
    self.status = 0;
    dispatch_semaphore_signal(self.done);
    return NULL;
}

static size_t sysctl_read(const char *name) {
    size_t len;
    unsigned int ncpu = 0;

    len = sizeof(ncpu);
    sysctlbyname(name, &ncpu, &len, NULL, 0);
    return ncpu;
}

- (instancetype)initWithConfiguration:(UTMConfiguration *)configuration imgPath:(nonnull NSURL *)imgPath {
    self = [self init];
    if (self) {
        self.configuration = configuration;
        self.imgPath = imgPath;
        self.qmpPort = 4444;
        self.spicePort = 5930;
        self.entry = start_qemu;
    }
    return self;
}

- (NSArray<NSString *> *)argv {
    NSArray<NSString *> *argv = [super argv];
    if (argv.count == 0) {
        // HACK: when called from QEMU settings page
        [self updateArgvWithUserOptions:NO];
    }
    return [super argv];
}

- (NSURL *)resourceURL {
    return [[NSBundle mainBundle] URLForResource:@"qemu" withExtension:nil];
}

- (CPUCount)emulatedCpuCount {
    static const CPUCount singleCpu = {
        .cpus = 1,
        .threads = 1,
    };
    CPUCount hostCount = {
        .cpus = sysctl_read("hw.physicalcpu"),
        .threads = sysctl_read("hw.logicalcpu"),
    };
    NSInteger userCpus = [self.configuration.systemCPUCount integerValue];
    if (userCpus > 0 || hostCount.cpus == 0) {
        CPUCount userCount = {
            .cpus = userCpus,
            .threads = userCpus,
        };
        return userCount; // user override
    }
#if defined(__aarch64__)
    // in ARM we can only emulate other weak architectures
    NSString *arch = self.configuration.systemArchitecture;
    if ([arch isEqualToString:@"alpha"] ||
        [arch isEqualToString:@"arm"] ||
        [arch isEqualToString:@"aarch64"] ||
        [arch isEqualToString:@"avr"] ||
        [arch hasPrefix:@"mips"] ||
        [arch hasPrefix:@"ppc"] ||
        [arch hasPrefix:@"riscv"] ||
        [arch hasPrefix:@"xtensa"]) {
        return hostCount;
    } else {
        return singleCpu;
    }
#elif defined(__x86_64__)
    // in x86 we can emulate weak on strong
    return hostCount;
#else
    return singleCpu;
#endif
}

- (void)architectureSpecificConfiguration {
    if ([self.configuration.systemArchitecture isEqualToString:@"x86_64"] ||
        [self.configuration.systemArchitecture isEqualToString:@"i386"]) {
        [self pushArgv:@"-global"];
        [self pushArgv:@"PIIX4_PM.disable_s3=1"]; // applies for pc-i440fx-* types
        [self pushArgv:@"-global"];
        [self pushArgv:@"ICH9-LPC.disable_s3=1"]; // applies for pc-q35-* types
    }
}

- (void)targetSpecificConfiguration {
    if ([self.configuration.systemTarget hasPrefix:@"virt"]) {
        NSString *name = [NSString stringWithFormat:@"edk2-%@-code.fd", self.configuration.systemArchitecture];
        NSURL *path = [self.resourceURL URLByAppendingPathComponent:name];
        if (!self.hasCustomBios && [[NSFileManager defaultManager] fileExistsAtPath:path.path]) {
            [self pushArgv:@"-bios"];
            [self pushArgv:path.path]; // accessDataWithBookmark called already
        }
    }
}

- (NSString *)expandDriveInterface:(NSString *)interface identifier:(NSString *)identifier removable:(BOOL)removable busInterfaceMap:(NSMutableDictionary<NSString *, NSNumber *> *)busInterfaceMap {
    NSInteger bootindex = [busInterfaceMap[@"boot"] integerValue];
    NSInteger busindex = [busInterfaceMap[interface] integerValue];
    if ([interface isEqualToString:@"ide"]) {
        [self pushArgv:@"-device"];
        [self pushArgv:[NSString stringWithFormat:@"%@,bus=ide.%lu,drive=%@,bootindex=%lu", removable ? @"ide-cd" : @"ide-hd", busindex++, identifier, bootindex++]];
    } else if ([interface isEqualToString:@"scsi"]) {
        if (busindex == 0) {
            [self pushArgv:@"-device"];
            [self pushArgv:@"lsi53c895a,id=scsi0"];
        }
        [self pushArgv:@"-device"];
        [self pushArgv:[NSString stringWithFormat:@"%@,bus=scsi0.0,channel=0,scsi-id=%lu,drive=%@,bootindex=%lu", removable ? @"scsi-cd" : @"scsi-hd", busindex++, identifier, bootindex++]];
    } else if ([interface isEqualToString:@"virtio"]) {
        [self pushArgv:@"-device"];
        [self pushArgv:[NSString stringWithFormat:@"%@,drive=%@,bootindex=%lu", [self.configuration.systemArchitecture isEqualToString:@"s390x"] ? @"virtio-blk-ccw" : @"virtio-blk-pci", identifier, bootindex++]];
    } else if ([interface isEqualToString:@"nvme"]) {
        [self pushArgv:@"-device"];
        [self pushArgv:[NSString stringWithFormat:@"nvme,drive=%@,serial=%@,bootindex=%lu", identifier, identifier, bootindex++]];
    } else if ([interface isEqualToString:@"usb"]) {
        [self pushArgv:@"-device"];
        [self pushArgv:[NSString stringWithFormat:@"usb-storage,drive=%@,removable=%@,bootindex=%lu", identifier, removable ? @"true" : @"false", bootindex++]];
    } else {
        return interface; // no expand needed
    }
    busInterfaceMap[@"boot"] = @(bootindex);
    busInterfaceMap[interface] = @(busindex);
    return @"none";
}

- (void)argsForCpu {
    if ([self.configuration.systemCPU isEqualToString:@"default"] && self.useHypervisor) {
        // if default and not hypervisor, we don't pass any -cpu argument
        [self pushArgv:@"-cpu"];
        [self pushArgv:@"host"];
    } else if (self.configuration.systemCPU.length > 0 && ![self.configuration.systemCPU isEqualToString:@"default"]) {
        NSString *cpu = self.configuration.systemCPU;
        for (NSString *flag in self.configuration.systemCPUFlags) {
            unichar prefix = [flag characterAtIndex:0];
            if (prefix != '-' && prefix != '+') {
                cpu = [cpu stringByAppendingFormat:@",+%@", flag];
            } else {
                cpu = [cpu stringByAppendingFormat:@",%@", flag];
            }
        }
        [self pushArgv:@"-cpu"];
        [self pushArgv:cpu];
    }
    [self pushArgv:@"-smp"];
    [self pushArgv:[NSString stringWithFormat:@"cpus=%lu,sockets=1,cores=%lu,threads=%lu", self.emulatedCpuCount.threads, self.emulatedCpuCount.cpus, self.emulatedCpuCount.threads / self.emulatedCpuCount.cpus]];
}

- (void)argsForDrives {
    NSMutableDictionary<NSString *, NSNumber *> *busInterfaceMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < self.configuration.countDrives; i++) {
        NSString *path = [self.configuration driveImagePathForIndex:i];
        UTMDiskImageType type = [self.configuration driveImageTypeForIndex:i];
        BOOL hasImage = ![self.configuration driveRemovableForIndex:i] && path;
        NSURL *fullPathURL;
        
        if (hasImage) {
            if ([path characterAtIndex:0] == '/') {
                fullPathURL = [NSURL fileURLWithPath:path isDirectory:NO];
            } else if ([path hasPrefix:@"file://"]) {
                fullPathURL = [NSURL URLWithString:path];
            } else {
                fullPathURL = [[self.imgPath URLByAppendingPathComponent:[UTMConfiguration diskImagesDirectory]] URLByAppendingPathComponent:[self.configuration driveImagePathForIndex:i]];
            }
            [self accessDataWithBookmark:[fullPathURL bookmarkDataWithOptions:0
                                               includingResourceValuesForKeys:nil
                                                                relativeToURL:nil
                                                                        error:nil]];
        }
        
        switch (type) {
            case UTMDiskImageTypeDisk:
            case UTMDiskImageTypeCD: {
                NSString *interface = [self.configuration driveInterfaceTypeForIndex:i];
                BOOL removable = (type == UTMDiskImageTypeCD) || [self.configuration driveRemovableForIndex:i];
                NSString *identifier = [NSString stringWithFormat:@"drive%lu", i];
                NSString *realInterface = [self expandDriveInterface:interface identifier:identifier removable:removable busInterfaceMap:busInterfaceMap];
                NSString *drive;
                [self pushArgv:@"-drive"];
                drive = [NSString stringWithFormat:@"if=%@,media=%@,id=%@", realInterface, removable ? @"cdrom" : @"disk", identifier];
                if (hasImage) {
                    drive = [NSString stringWithFormat:@"%@,file=%@,cache=writethrough", drive, fullPathURL.path];
                }
                [self pushArgv:drive];
                break;
            }
            case UTMDiskImageTypeBIOS: {
                if (hasImage) {
                    [self pushArgv:@"-bios"];
                    [self pushArgv:fullPathURL.path];
                }
                break;
            }
            case UTMDiskImageTypeKernel: {
                if (hasImage) {
                    [self pushArgv:@"-kernel"];
                    [self pushArgv:fullPathURL.path];
                }
                break;
            }
            case UTMDiskImageTypeInitrd: {
                if (hasImage) {
                    [self pushArgv:@"-initrd"];
                    [self pushArgv:fullPathURL.path];
                }
                break;
            }
            case UTMDiskImageTypeDTB: {
                if (hasImage) {
                    [self pushArgv:@"-dtb"];
                    [self pushArgv:fullPathURL.path];
                }
                break;
            }
            case UTMDiskImageTypeNone: {
                break; // ignore this image
            }
            default: {
                UTMLog(@"WARNING: unknown image type %lu, ignoring image %@", type, fullPathURL);
                break;
            }
        }
    }
}

- (void)argsForNetwork {
    if (self.configuration.networkEnabled) {
        [self pushArgv:@"-device"];
        [self pushArgv:[NSString stringWithFormat:@"%@,mac=%@,netdev=net0", self.configuration.networkCard, self.configuration.networkCardMac]];
        [self pushArgv:@"-netdev"];
        NSMutableString *netstr = [NSMutableString stringWithString:@"user,id=net0"];
        if (self.configuration.networkAddress.length > 0) {
            [netstr appendFormat:@",net=%@", self.configuration.networkAddress];
        }
        if (self.configuration.networkHost.length > 0) {
            [netstr appendFormat:@",host=%@", self.configuration.networkHost];
        }
        if (self.configuration.networkAddressIPv6.length > 0) {
            [netstr appendFormat:@",ipv6-net=%@", self.configuration.networkAddressIPv6];
        }
        if (self.configuration.networkHostIPv6.length > 0) {
            [netstr appendFormat:@",ipv6-host=%@", self.configuration.networkHostIPv6];
        }
        if (self.configuration.networkIsolate) {
            [netstr appendString:@",restrict=on"];
        }
        if (self.configuration.networkHost.length > 0) {
            [netstr appendFormat:@",hostname=%@", self.configuration.networkHost];
        }
        if (self.configuration.networkDhcpStart.length > 0) {
            [netstr appendFormat:@",dhcpstart=%@", self.configuration.networkDhcpStart];
        }
        if (self.configuration.networkDnsServer.length > 0) {
            [netstr appendFormat:@",dns=%@", self.configuration.networkDnsServer];
        }
        if (self.configuration.networkDnsServerIPv6.length > 0) {
            [netstr appendFormat:@",ipv6-dns=%@", self.configuration.networkDnsServerIPv6];
        }
        if (self.configuration.networkDnsSearch.length > 0) {
            [netstr appendFormat:@",dnssearch=%@", self.configuration.networkDnsSearch];
        }
        if (self.configuration.networkDhcpDomain.length > 0) {
            [netstr appendFormat:@",domainname=%@", self.configuration.networkDhcpDomain];
        }
        for (NSUInteger i = 0; i < [self.configuration countPortForwards]; i++) {
            UTMConfigurationPortForward *portForward = [self.configuration portForwardForIndex:i];
            [netstr appendFormat:@",hostfwd=%@:%@:%@-%@:%@", portForward.protocol, portForward.hostAddress, portForward.hostPort, portForward.guestAddress, portForward.guestPort];
        }
        [self pushArgv:netstr];
    } else {
        [self pushArgv:@"-nic"];
        [self pushArgv:@"none"];
    }
}

- (void)argsForUsb {
    // assume that for virt machines we can use USB 3.0 controller
    if ([self.configuration.systemTarget hasPrefix:@"virt"]) {
        [self pushArgv:@"-device"];
        [self pushArgv:@"qemu-xhci"];
    } else if ([self.configuration.systemTarget hasPrefix:@"pc"]) {
        // USB 1.0 controller for old PC system
        [self pushArgv:@"-usb"];
    } else { // USB 2.0 controller is most compatible
        [self pushArgv:@"-device"];
        [self pushArgv:@"usb-ehci"];
    }
    // set up USB input devices unless user requested legacy (QEMU default PS/2 input)
    if (!self.configuration.inputLegacy) {
        [self pushArgv:@"-device"];
        [self pushArgv:@"usb-tablet"];
        [self pushArgv:@"-device"];
        [self pushArgv:@"usb-mouse"];
        [self pushArgv:@"-device"];
        [self pushArgv:@"usb-kbd"];
    }
}

- (void)argsForSharing {
    if (self.configuration.displayConsoleOnly) {
        return; // no SPICE for console only
    }
    
    if (self.configuration.shareClipboardEnabled || self.configuration.shareDirectoryEnabled) {
        [self pushArgv:@"-device"];
        [self pushArgv:@"virtio-serial"];
    }
    
    if (self.configuration.shareClipboardEnabled) {
        [self pushArgv:@"-device"];
        [self pushArgv:@"virtserialport,chardev=vdagent,name=com.redhat.spice.0"];
        [self pushArgv:@"-chardev"];
        [self pushArgv:@"spicevmc,id=vdagent,debug=0,name=vdagent"];
    }
    
    if (self.configuration.shareDirectoryEnabled) {
        [self pushArgv:@"-device"];
        [self pushArgv:@"virtserialport,chardev=charchannel1,id=channel1,name=org.spice-space.webdav.0"];
        [self pushArgv:@"-chardev"];
        [self pushArgv:@"spiceport,name=org.spice-space.webdav.0,id=charchannel1"];
    }
}

- (NSString *)tcgAccelProperties {
    NSString *accel = @"tcg";
    
    if (self.configuration.systemForceMulticore) {
        accel = [accel stringByAppendingString:@",thread=multi"];
    }
    NSInteger tb_size = self.configuration.systemMemory.integerValue / 4;
    if (self.configuration.systemJitCacheSize.integerValue > 0) {
        tb_size = self.configuration.systemJitCacheSize.integerValue;
    }
    accel = [accel stringByAppendingFormat:@",tb-size=%ld", tb_size];
    
    // use mirror mapping when we don't have JIT entitlements
    if (!jb_has_jit_entitlement()) {
        accel = [accel stringByAppendingString:@",split-wx=on"];
    }
    
    return accel;
}

- (BOOL)useHypervisor {
#if TARGET_OS_IPHONE
    return NO;
#else
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return self.configuration.isTargetArchitectureMatchHost && ![defaults boolForKey:@"NoHypervisor"];
#endif
}

- (BOOL)hasCustomBios {
    for (NSUInteger i = 0; i < self.configuration.countDrives; i++) {
        UTMDiskImageType type = [self.configuration driveImageTypeForIndex:i];
        NSString *interface = [self.configuration driveInterfaceTypeForIndex:i];
        switch (type) {
            case UTMDiskImageTypeDisk:
            case UTMDiskImageTypeCD: {
                if ([interface isEqualToString:@"pflash"]) {
                    return YES;
                }
                break;
            }
            case UTMDiskImageTypeBIOS:
            case UTMDiskImageTypeKernel: {
                return YES;
                break;
            }
            default: {
                continue;
            }
        }
    }
    return NO;
}

- (BOOL)usbSupported {
    return ![self.configuration.systemTarget isEqualToString:@"isapc"];
}

- (NSString *)machineProperties {
    if (self.configuration.systemMachineProperties.length > 0) {
        return self.configuration.systemMachineProperties; // use specified properties
    }
    return @"";
}

- (void)argsRequired {
    [self clearArgv];
    [self pushArgv:@"-L"];
    [self accessDataWithBookmark:[self.resourceURL bookmarkDataWithOptions:0
                                            includingResourceValuesForKeys:nil
                                                             relativeToURL:nil
                                                                     error:nil]];
    [self pushArgv:self.resourceURL.path];
    [self pushArgv:@"-S"]; // startup stopped
    [self pushArgv:@"-qmp"];
    [self pushArgv:[NSString stringWithFormat:@"tcp:127.0.0.1:%lu,server,nowait", self.qmpPort]];
    [self pushArgv:@"-vga"];
    [self pushArgv:@"none"];// -vga none, avoid adding duplicate graphics cards
    if (self.configuration.displayConsoleOnly) {
        [self pushArgv:@"-nographic"];
        // terminal character device
        NSURL* ioFile = [self.configuration terminalInputOutputURL];
        [self pushArgv: @"-chardev"];
        [self accessDataWithBookmark:[[ioFile URLByDeletingLastPathComponent] bookmarkDataWithOptions:0
                                                                       includingResourceValuesForKeys:nil
                                                                                        relativeToURL:nil
                                                                                                error:nil]];
        [self pushArgv: [NSString stringWithFormat: @"pipe,id=term0,path=%@", ioFile.path]];
        [self pushArgv: @"-serial"];
        [self pushArgv: @"chardev:term0"];
    } else {
        [self pushArgv:@"-spice"];
        [self pushArgv:[NSString stringWithFormat:@"port=%lu,addr=127.0.0.1,disable-ticketing,image-compression=off,playback-compression=off,streaming-video=off", self.spicePort]];
        [self pushArgv:@"-device"];
        [self pushArgv:self.configuration.displayCard];
    }
}

- (void)argsFromConfiguration {
    [self argsForCpu];
    [self pushArgv:@"-machine"];
    [self pushArgv:[NSString stringWithFormat:@"%@,%@", self.configuration.systemTarget, [self machineProperties]]];
    if (self.useHypervisor) {
        [self pushArgv:@"-accel"];
        [self pushArgv:@"hvf"];
    }
    [self pushArgv:@"-accel"];
    [self pushArgv:[self tcgAccelProperties]];
    [self architectureSpecificConfiguration];
    [self targetSpecificConfiguration];
    // legacy boot order; new bootindex uses drive ordering
    if (self.configuration.systemBootDevice.length > 0 && ![self.configuration.systemBootDevice isEqualToString:@"hdd"]) {
        [self pushArgv:@"-boot"];
        if ([self.configuration.systemBootDevice isEqualToString:@"floppy"]) {
            [self pushArgv:@"order=ab"];
        } else {
            [self pushArgv:@"order=d"];
        }
    }
    [self pushArgv:@"-m"];
    [self pushArgv:[self.configuration.systemMemory stringValue]];
    // < macOS 11.3 we use fork() which is buggy and things are broken
    BOOL forceDisableSound = NO;
    if (@available(macOS 11.3, *)) {
    } else {
        if (self.configuration.displayConsoleOnly) {
            forceDisableSound = YES;
        }
    }
    if (self.configuration.soundEnabled && !forceDisableSound) {
        [self pushArgv:@"-device"];
        [self pushArgv:self.configuration.soundCard];
        if ([self.configuration.soundCard containsString:@"hda"]) {
            [self pushArgv:@"-device"];
            [self pushArgv:@"hda-duplex"];
        }
    }
    [self pushArgv:@"-name"];
    [self pushArgv:self.configuration.name];
    if (self.usbSupported) {
        [self argsForUsb];
    }
    [self argsForDrives];
    [self argsForNetwork];
    if (self.snapshot) {
        [self pushArgv:@"-loadvm"];
        [self pushArgv:self.snapshot];
    }
    
    [self argsForSharing];
    
    if (self.configuration.systemUUID.length > 0) {
        [self pushArgv:@"-uuid"];
        [self pushArgv:self.configuration.systemUUID];
    }
    
    // fix windows time issues
    [self pushArgv:@"-rtc"];
    [self pushArgv:@"base=localtime"];
}
    
- (void)argsFromUser {
    if (self.configuration.systemArguments.count != 0) {
        NSArray *addArgs = self.configuration.systemArguments;
        // Splits all spaces into their own, except when between quotes.
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\"[^\"]+\"|\\+|\\S+)" options:0 error:nil];
        
        for (NSString *arg in addArgs) {
            // No need to operate on empty arguments.
            if (arg.length == 0) {
                continue;
            }
            
            NSArray *splitArgsArray = [regex matchesInString:arg
                                              options:0
                                                range:NSMakeRange(0, [arg length])];
            
            
            for (NSTextCheckingResult *match in splitArgsArray) {
                NSRange matchRange = [match rangeAtIndex:1];
                NSString *argFragment = [arg substringWithRange:matchRange];
                if ([argFragment hasPrefix:@"\""] && [argFragment hasSuffix:@"\""]) {
                    argFragment = [argFragment substringWithRange:NSMakeRange(1, argFragment.length-2)];
                }
                [self pushArgv:argFragment];
            }
        }
    }
}

- (BOOL)didLoadDylib:(void *)handle {
    _qemu_init = dlsym(handle, "qemu_init");
    _qemu_main_loop = dlsym(handle, "qemu_main_loop");
    _qemu_cleanup = dlsym(handle, "qemu_cleanup");
    return (_qemu_init != NULL) && (_qemu_main_loop != NULL) && (_qemu_cleanup != NULL);
}

- (void)updateArgvWithUserOptions:(BOOL)userOptions {
    [self argsRequired];
    if (!self.configuration.ignoreAllConfiguration) {
        [self argsFromConfiguration];
    }
    if (userOptions) {
        [self argsFromUser];
    }
}

- (void)startWithCompletion:(void (^)(BOOL, NSString * _Nonnull))completion {
    [self updateArgvWithUserOptions:YES];
    [self startQemu:self.configuration.systemArchitecture completion:completion];
}

@end
