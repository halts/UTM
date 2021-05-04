//
// Copyright © 2019 osy. All rights reserved.
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

#import <TargetConditionals.h>
#import "UTMVirtualMachine.h"
#import "UTMVirtualMachine+Drives.h"
#import "UTMVirtualMachine+SPICE.h"
#import "UTMConfiguration.h"
#import "UTMConfiguration+Constants.h"
#import "UTMConfiguration+Display.h"
#import "UTMConfiguration+Drives.h"
#import "UTMConfiguration+Miscellaneous.h"
#import "UTMViewState.h"
#import "UTMQemuManager.h"
#import "UTMQemuSystem.h"
#import "UTMTerminalIO.h"
#import "UTMSpiceIO.h"
#import "UTMLogging.h"
#import "UTMScreenshot.h"
#import "UTMPortAllocator.h"
#import "qapi-events.h"

const int kQMPMaxConnectionTries = 30; // qemu needs to start spice server first
const int64_t kStopTimeout = (int64_t)30*NSEC_PER_SEC;

NSString *const kUTMErrorDomain = @"com.utmapp.utm";
NSString *const kUTMBundleConfigFilename = @"config.plist";
NSString *const kUTMBundleExtension = @"utm";
NSString *const kUTMBundleViewFilename = @"view.plist";
NSString *const kUTMBundleScreenshotFilename = @"screenshot.png";
NSString *const kSuspendSnapshotName = @"suspend";


@interface UTMVirtualMachine ()

@property (nonatomic, readwrite, nullable) NSURL *path;
@property (nonatomic, readwrite, copy) UTMConfiguration *configuration;
@property (nonatomic, readonly) UTMQemuManager *qemu;
@property (nonatomic, readwrite, nullable) UTMQemuSystem *system;
@property (nonatomic, readwrite) UTMViewState *viewState;
@property (nonatomic) UTMLogging *logging;
@property (nonatomic, readonly, nullable) id<UTMInputOutput> ioService;
@property (nonatomic, readwrite) BOOL busy;
@property (nonatomic, readwrite, nullable) UTMScreenshot *screenshot;

@end

@implementation UTMVirtualMachine {
    dispatch_semaphore_t _will_quit_sema;
    dispatch_semaphore_t _qemu_exit_sema;
}

- (void)setDelegate:(id<UTMVirtualMachineDelegate>)delegate {
    _delegate = delegate;
    _delegate.vmConfiguration = self.configuration;
    [self restoreViewState];
}

- (id)ioDelegate {
    if ([self.ioService isKindOfClass:[UTMSpiceIO class]]) {
        return ((UTMSpiceIO *)self.ioService).delegate;
    } else if ([self.ioService isKindOfClass:[UTMTerminalIO class]]) {
        return ((UTMTerminalIO *)self.ioService).terminal.delegate;
    } else {
        return nil;
    }
}

- (void)setIoDelegate:(id)ioDelegate {
    if ([self.ioService isKindOfClass:[UTMSpiceIO class]]) {
        ((UTMSpiceIO *)self.ioService).delegate = ioDelegate;
    } else if ([self.ioService isKindOfClass:[UTMTerminalIO class]]) {
        ((UTMTerminalIO *)self.ioService).terminal.delegate = ioDelegate;
    } else {
        NSAssert(0, @"ioService class is invalid: %@", NSStringFromClass([self.ioService class]));
    }
}

+ (BOOL)URLisVirtualMachine:(NSURL *)url {
    return [url.pathExtension isEqualToString:kUTMBundleExtension];
}

+ (NSString *)virtualMachineName:(NSURL *)url {
    return [[[NSFileManager defaultManager] displayNameAtPath:url.path] stringByDeletingPathExtension];
}

+ (NSURL *)virtualMachinePath:(NSString *)name inParentURL:(NSURL *)parent {
    return [[parent URLByAppendingPathComponent:name] URLByAppendingPathExtension:kUTMBundleExtension];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _will_quit_sema = dispatch_semaphore_create(0);
        _qemu_exit_sema = dispatch_semaphore_create(0);
#if TARGET_OS_IPHONE
        self.logging = [UTMLogging sharedInstance];
#else
        self.logging = [UTMLogging new];
#endif
    }
    return self;
}

- (nullable instancetype)initWithURL:(NSURL *)url {
    self = [self init];
    if (self) {
        self.path = url;
        self.parentPath = url.URLByDeletingLastPathComponent;
        if (![self loadConfigurationWithReload:NO error:nil]) {
            self = nil;
            return self;
        }
        [self loadViewState];
        [self loadScreenshot];
        if (self.viewState.suspended) {
            _state = kVMSuspended;
        } else {
            _state = kVMStopped;
        }
    }
    return self;
}

- (instancetype)initWithConfiguration:(UTMConfiguration *)configuration withDestinationURL:(NSURL *)dstUrl {
    self = [self init];
    if (self) {
        self.parentPath = dstUrl;
        self.configuration = configuration;
        self.viewState = [[UTMViewState alloc] init];
    }
    return self;
}

- (void)changeState:(UTMVMState)state {
    @synchronized (self) {
        _state = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate virtualMachine:self transitionToState:state];
        });
    }
    self.viewState.active = (state == kVMStarted);
}

- (NSURL *)packageURLForName:(NSString *)name {
    return [[self.parentPath URLByAppendingPathComponent:name] URLByAppendingPathExtension:kUTMBundleExtension];
}

- (BOOL)loadConfigurationWithReload:(BOOL)reload error:(NSError * _Nullable __autoreleasing *)err {
    NSAssert(self.path != nil, @"Cannot load configuration on an unsaved VM.");
    NSString *name = [UTMVirtualMachine virtualMachineName:self.path];
    NSDictionary *plist = [self loadPlist:[self.path URLByAppendingPathComponent:kUTMBundleConfigFilename] withError:err];
    if (!plist) {
        UTMLog(@"Failed to parse config for %@, error: %@", self.path, err ? *err : nil);
        return NO;
    }
    if (reload) {
        NSAssert(self.configuration != nil, @"Trying to reload when no configuration is loaded.");
        [self.configuration reloadConfigurationWithDictionary:plist name:name path:self.path];
    } else {
        self.configuration = [[UTMConfiguration alloc] initWithDictionary:plist name:name path:self.path];
    }
    return YES;
}

- (BOOL)reloadConfigurationWithError:(NSError * _Nullable __autoreleasing *)err {
    return [self loadConfigurationWithReload:YES error:err];
}

- (BOOL)saveUTMWithError:(NSError * _Nullable *)err {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *url = [self packageURLForName:self.configuration.name];
    __block NSError *_err;
    if (!self.configuration.existingPath) { // new package
        if (![fileManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:&_err]) {
            goto error;
        }
    } else if (![self.configuration.existingPath.URLByStandardizingPath isEqual:url.URLByStandardizingPath]) { // rename if needed
        if (![fileManager moveItemAtURL:self.configuration.existingPath toURL:url error:&_err]) {
            goto error;
        }
    }
    // save icon
    if (self.configuration.iconCustom && self.configuration.selectedCustomIconPath) {
        NSURL *oldIconPath = [url URLByAppendingPathComponent:self.configuration.icon];
        NSString *newIcon = self.configuration.selectedCustomIconPath.lastPathComponent;
        NSURL *newIconPath = [url URLByAppendingPathComponent:newIcon];
        
        // delete old icon
        if ([fileManager fileExistsAtPath:oldIconPath.path]) {
            [fileManager removeItemAtURL:oldIconPath error:&_err]; // ignore error
        }
        // copy new icon
        if (![fileManager copyItemAtURL:self.configuration.selectedCustomIconPath toURL:newIconPath error:&_err]) {
            goto error;
        }
        // commit icon
        self.configuration.icon = newIcon;
        self.configuration.selectedCustomIconPath = nil;
    }
    // save config
    if (![self savePlist:[url URLByAppendingPathComponent:kUTMBundleConfigFilename]
                    dict:self.configuration.dictRepresentation
               withError:err]) {
        return NO;
    }
    // create disk images directory
    if (!self.configuration.existingPath) {
        NSURL *dstPath = [url URLByAppendingPathComponent:[UTMConfiguration diskImagesDirectory] isDirectory:YES];
        NSURL *tmpPath = [fileManager.temporaryDirectory URLByAppendingPathComponent:[UTMConfiguration diskImagesDirectory] isDirectory:YES];
        
        // create images directory
        if ([fileManager fileExistsAtPath:tmpPath.path]) {
            // delete any orphaned images
            NSArray<NSString *> *orphans = self.configuration.orphanedDrives;
            for (NSInteger i = 0; i < orphans.count; i++) {
                NSURL *orphanPath = [tmpPath URLByAppendingPathComponent:orphans[i]];
                UTMLog(@"Deleting orphaned image '%@'", orphans[i]);
                if (![fileManager removeItemAtURL:orphanPath error:&_err]) {
                    UTMLog(@"Ignoring error deleting orphaned image: %@", _err.localizedDescription);
                    _err = nil;
                }
            }
            // move remaining drives to VM package
            if (![fileManager moveItemAtURL:tmpPath toURL:dstPath error:&_err]) {
                goto error;
            }
        } else if (![fileManager fileExistsAtPath:dstPath.path]) {
            if (![fileManager createDirectoryAtURL:dstPath withIntermediateDirectories:NO attributes:nil error:&_err]) {
                goto error;
            }
        }
    }
    self.configuration.existingPath = url;
    self.path = url;
    return YES;
error:
    if (err) {
        *err = _err;
    }
    return NO;
}

- (void)errorTriggered:(nullable NSString *)msg {
    /*if (self.state != kVMStopped && self.state != kVMError) {
        self.viewState.suspended = NO;
        [self saveViewState];
        [self quitVMForce:true];
    }
    if (self.state != kVMError) { // don't stack errors
        self.delegate.vmMessage = msg;
        [self changeState:kVMError];
    }*/
}

- (BOOL)startVM {
    @synchronized (self) {
        if (self.busy || (self.state != kVMStopped && self.state != kVMSuspended)) {
            return NO; // already started
        } else {
            self.busy = YES;
        }
    }
    // start logging
    if (self.configuration.debugLogEnabled) {
        [self.logging logToFile:[self.path URLByAppendingPathComponent:[UTMConfiguration debugLogName]]];
    }
    
    if (!self.system) {
        self.system = [[UTMQemuSystem alloc] initWithConfiguration:self.configuration imgPath:self.path];
        self.system.logging = self.logging;
#if !TARGET_OS_IPHONE
        [self.system setupXpc];
#endif
        self.system.qmpPort = [[UTMPortAllocator sharedInstance] allocatePort];
        self.system.spicePort = [[UTMPortAllocator sharedInstance] allocatePort];
        _qemu = [[UTMQemuManager alloc] initWithPort:self.system.qmpPort];
        _qemu.delegate = self;
    }

    if (!self.system) {
        [self errorTriggered:NSLocalizedString(@"Internal error starting VM.", @"UTMVirtualMachine")];
        self.busy = NO;
        return NO;
    }
    
    if (!_ioService) {
        _ioService = [self inputOutputServiceWithPort:self.system.spicePort];
    }
    
    self.delegate.vmMessage = nil;
    [self changeState:kVMStarting];
    if (self.configuration.debugLogEnabled) {
        [_ioService setDebugMode:YES];
    }
    
    BOOL ioStatus = [_ioService startWithError: nil];
    if (!ioStatus) {
        [self errorTriggered:NSLocalizedString(@"Internal error starting main loop.", @"UTMVirtualMachine")];
        self.busy = NO;
        return NO;
    }
    if (self.viewState.suspended) {
        self.system.snapshot = kSuspendSnapshotName;
    }
    [self.system startWithCompletion:^(BOOL success, NSString *msg){
        if (!success) {
            [self errorTriggered:msg];
        }
        dispatch_semaphore_signal(self->_qemu_exit_sema);
    }];
    [self->_ioService connectWithCompletion:^(BOOL success, NSString * _Nullable msg) {
        if (!success) {
            [self errorTriggered:msg];
        } else {
            [self changeState:kVMStarted];
            [self restoreViewState];
            if (self.viewState.suspended) {
                [self deleteSaveVM];
            }
        }
    }];
    self->_qemu.retries = kQMPMaxConnectionTries;
    [self->_qemu connect];
    self.busy = NO;
    return YES;
}

- (BOOL)quitVM {
    return [self quitVMForce:false];
}

- (BOOL)quitVMForce:(BOOL)force {
    @synchronized (self) {
        if (!force && (self.busy || self.state != kVMStarted)) {
            return NO; // already stopping
        } else {
            self.busy = YES;
        }
    }
    self.viewState.suspended = NO;
    [self syncViewState];
    if (!force) {
        [self changeState:kVMStopping];
    }
    // save view settings early to win exit race
    [self saveViewState];
    
    _qemu.retries = 0;
    [_qemu vmQuitWithCompletion:nil];
    if (force || dispatch_semaphore_wait(_will_quit_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
        UTMLog(@"Stop operation timeout or force quit");
    }
    [_qemu disconnect];
    _qemu.delegate = nil;
    _qemu = nil;
    [_ioService disconnect];
    _ioService = nil;
    
    if (force || dispatch_semaphore_wait(_qemu_exit_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
        UTMLog(@"Exit operation timeout or force quit");
    }
    [self.system stopQemu];
    if (self.system.qmpPort) {
        [[UTMPortAllocator sharedInstance] freePort:self.system.qmpPort];
        self.system.qmpPort = 0;
    }
    if (self.system.spicePort) {
        [[UTMPortAllocator sharedInstance] freePort:self.system.spicePort];
        self.system.spicePort = 0;
    }
    self.system = nil;
    [self changeState:kVMStopped];
    // stop logging
    [self.logging endLog];
    self.busy = NO;
    return YES;
}

- (BOOL)resetVM {
    @synchronized (self) {
        if (self.busy || (self.state != kVMStarted && self.state != kVMPaused)) {
            return NO; // already stopping
        } else {
            self.busy = YES;
        }
    }
    [self syncViewState];
    [self changeState:kVMStopping];
    if (self.viewState.suspended) {
        [self deleteSaveVM];
    }
    [self saveViewState];
    __block BOOL success = YES;
    dispatch_semaphore_t reset_sema = dispatch_semaphore_create(0);
    [_qemu vmResetWithCompletion:^(NSError *err) {
        UTMLog(@"reset callback: err? %@", err);
        if (err) {
            UTMLog(@"error: %@", err);
            success = NO;
        }
        dispatch_semaphore_signal(reset_sema);
    }];
    if (dispatch_semaphore_wait(reset_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
        UTMLog(@"Reset operation timeout");
        success = NO;
    }
    if (success) {
        [self changeState:kVMStarted];
    } else {
        [self changeState:kVMError];
    }
    self.busy = NO;
    return success;
}

- (BOOL)pauseVM {
    @synchronized (self) {
        if (self.busy || self.state != kVMStarted) {
            return NO; // already stopping
        } else {
            self.busy = YES;
        }
    }
    [self syncViewState];
    [self changeState:kVMPausing];
    [self saveScreenshot];
    __block BOOL success = YES;
    dispatch_semaphore_t suspend_sema = dispatch_semaphore_create(0);
    [_qemu vmStopWithCompletion:^(NSError * err) {
        UTMLog(@"stop callback: err? %@", err);
        if (err) {
            UTMLog(@"error: %@", err);
            success = NO;
        }
        dispatch_semaphore_signal(suspend_sema);
    }];
    if (dispatch_semaphore_wait(suspend_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
        UTMLog(@"Stop operation timeout");
        success = NO;
    }
    if (success) {
        [self changeState:kVMPaused];
    } else {
        [self changeState:kVMError];
    }
    self.busy = NO;
    return success;
}

- (BOOL)saveVM {
    @synchronized (self) {
        if (self.busy || (self.state != kVMPaused && self.state != kVMStarted)) {
            return NO;
        } else {
            self.busy = YES;
        }
    }
    UTMVMState state = self.state;
    [self changeState:kVMPausing];
    __block BOOL success = YES;
    dispatch_semaphore_t save_sema = dispatch_semaphore_create(0);
    [_qemu vmSaveWithCompletion:^(NSString *result, NSError *err) {
        UTMLog(@"save callback: %@", result);
        if (err) {
            UTMLog(@"error: %@", err);
            success = NO;
        } else if ([result localizedCaseInsensitiveContainsString:@"Error"]) {
            UTMLog(@"save result: %@", result);
            success = NO; // error message
        }
        dispatch_semaphore_signal(save_sema);
    } snapshotName:kSuspendSnapshotName];
    if (dispatch_semaphore_wait(save_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
        UTMLog(@"Save operation timeout");
        success = NO;
    } else if (success) {
        UTMLog(@"Save completed");
        self.viewState.suspended = YES;
        [self saveViewState];
        [self saveScreenshot];
    }
    [self changeState:state];
    self.busy = NO;
    return success;
}

- (BOOL)deleteSaveVM {
    __block BOOL success = YES;
    if (self.qemu) { // if QEMU is running
        dispatch_semaphore_t save_sema = dispatch_semaphore_create(0);
        [_qemu vmDeleteSaveWithCompletion:^(NSString *result, NSError *err) {
            UTMLog(@"delete save callback: %@", result);
            if (err) {
                UTMLog(@"error: %@", err);
                success = NO;
            } else if ([result localizedCaseInsensitiveContainsString:@"Error"]) {
                UTMLog(@"save result: %@", result);
                success = NO; // error message
            }
            dispatch_semaphore_signal(save_sema);
        } snapshotName:kSuspendSnapshotName];
        if (dispatch_semaphore_wait(save_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
            UTMLog(@"Delete save operation timeout");
            success = NO;
        } else {
            UTMLog(@"Delete save completed");
        }
    } // otherwise we mark as deleted
    self.viewState.suspended = NO;
    [self saveViewState];
    return success;
}

- (BOOL)resumeVM {
    @synchronized (self) {
        if (self.busy || self.state != kVMPaused) {
            return NO;
        } else {
            self.busy = YES;
        }
    }
    [self changeState:kVMResuming];
    __block BOOL success = YES;
    dispatch_semaphore_t resume_sema = dispatch_semaphore_create(0);
    [_qemu vmResumeWithCompletion:^(NSError *err) {
        UTMLog(@"resume callback: err? %@", err);
        if (err) {
            UTMLog(@"error: %@", err);
            success = NO;
        }
        dispatch_semaphore_signal(resume_sema);
    }];
    if (dispatch_semaphore_wait(resume_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
        UTMLog(@"Resume operation timeout");
        success = NO;
    }
    if (success) {
        [self changeState:kVMStarted];
        [self restoreViewState];
    } else {
        [self changeState:kVMError];
    }
    if (self.viewState.suspended) {
        [self deleteSaveVM];
    }
    self.busy = NO;
    return success;
}

- (UTMDisplayType)supportedDisplayType {
    if ([self.configuration displayConsoleOnly]) {
        return UTMDisplayTypeConsole;
    } else {
        return UTMDisplayTypeFullGraphic;
    }
}

- (id<UTMInputOutput>)inputOutputServiceWithPort:(NSInteger)port {
    if ([self supportedDisplayType] == UTMDisplayTypeConsole) {
        return [[UTMTerminalIO alloc] initWithConfiguration:[self.configuration copy]];
    } else {
        return [[UTMSpiceIO alloc] initWithConfiguration:[self.configuration copy] port:port];
    }
}

#pragma mark - Qemu manager delegate

- (void)qemuHasWakeup:(UTMQemuManager *)manager {
    UTMLog(@"qemuHasWakeup");
}

- (void)qemuHasResumed:(UTMQemuManager *)manager {
    UTMLog(@"qemuHasResumed");
}

- (void)qemuHasStopped:(UTMQemuManager *)manager {
    UTMLog(@"qemuHasStopped");
}

- (void)qemuHasReset:(UTMQemuManager *)manager guest:(BOOL)guest reason:(ShutdownCause)reason {
    UTMLog(@"qemuHasReset, reason = %s", ShutdownCause_str(reason));
}

- (void)qemuHasSuspended:(UTMQemuManager *)manager {
    UTMLog(@"qemuHasSuspended");
}

- (void)qemuWillQuit:(UTMQemuManager *)manager guest:(BOOL)guest reason:(ShutdownCause)reason {
    UTMLog(@"qemuWillQuit, reason = %s", ShutdownCause_str(reason));
    dispatch_semaphore_signal(_will_quit_sema);
    if (!self.busy) {
        [self quitVM];
    }
}

- (void)qemuError:(UTMQemuManager *)manager error:(NSString *)error {
    UTMLog(@"qemuError: %@", error);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        [self errorTriggered:error];
    });
}

// this is called right before we execute qmp_cont so we can setup additional option
- (void)qemuQmpDidConnect:(UTMQemuManager *)manager {
    UTMLog(@"qemuQmpDidConnect");
    __autoreleasing NSError *err = nil;
    NSString *errMsg = nil;
    if (!self.configuration.displayConsoleOnly) {
        if (![self startSharedDirectoryWithError:&err]) {
            errMsg = [NSString stringWithFormat:NSLocalizedString(@"Error trying to start shared directory: %@", @"UTMVirtualMachine"), err.localizedDescription];
            UTMLog(@"%@", errMsg);
        }
    }
    if (!err && ![self restoreRemovableDrivesFromBookmarksWithError:&err]) {
        errMsg = [NSString stringWithFormat:NSLocalizedString(@"Error trying to restore removable drives: %@", @"UTMVirtualMachine"), err.localizedDescription];
        UTMLog(@"%@", errMsg);
    }
    if (errMsg) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            [self errorTriggered:errMsg];
        });
    }
}

#pragma mark - Plist Handling

- (NSDictionary *)loadPlist:(NSURL *)path withError:(NSError **)err {
    NSData *data = [NSData dataWithContentsOfURL:path];
    if (!data) {
        if (err) {
            *err = [NSError errorWithDomain:kUTMErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Failed to load plist", @"UTMVirtualMachine")}];
        }
        return nil;
    }
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:err];
    if (!plist) {
        return nil;
    }
    if (![plist isKindOfClass:[NSDictionary class]]) {
        if (err) {
            *err = [NSError errorWithDomain:kUTMErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Config format incorrect.", @"UTMVirtualMachine")}];
        }
        return nil;
    }
    return plist;
}

- (BOOL)savePlist:(NSURL *)path dict:(NSDictionary *)dict withError:(NSError **)err {
    NSError *_err;
    // serialize plist
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:&_err];
    if (_err && err) {
        *err = _err;
        return NO;
    }
    // write plist
    [data writeToURL:path options:NSDataWritingAtomic error:&_err];
    if (_err && err) {
        *err = _err;
        return NO;
    }
    return YES;
}

#pragma mark - View State

- (void)syncViewState {
    [self.ioService syncViewState:self.viewState];
    self.viewState.showToolbar = self.delegate.toolbarVisible;
    self.viewState.showKeyboard = self.delegate.keyboardVisible;
}

- (void)restoreViewState {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.ioService restoreViewState:self.viewState];
        self.delegate.toolbarVisible = self.viewState.showToolbar;
        self.delegate.keyboardVisible = self.viewState.showKeyboard;
    });
}

- (void)loadViewState {
    NSDictionary *plist = [self loadPlist:[self.path URLByAppendingPathComponent:kUTMBundleViewFilename] withError:nil];
    if (plist) {
        self.viewState = [[UTMViewState alloc] initWithDictionary:plist];
    } else {
        self.viewState = [[UTMViewState alloc] init];
    }
}

- (void)saveViewState {
    [self savePlist:[self.path URLByAppendingPathComponent:kUTMBundleViewFilename]
               dict:self.viewState.dictRepresentation
          withError:nil];
}

#pragma mark - Screenshot

- (void)loadScreenshot {
    NSURL *url = [self.path URLByAppendingPathComponent:kUTMBundleScreenshotFilename];
    self.screenshot = [[UTMScreenshot alloc] initWithContentsOfURL:url];
}

- (void)saveScreenshot {
    self.screenshot = [self.ioService screenshot];
    NSURL *url = [self.path URLByAppendingPathComponent:kUTMBundleScreenshotFilename];
    if (self.screenshot) {
        [self.screenshot writeToURL:url atomically:NO];
    }
}

- (void)deleteScreenshot {
    NSURL *url = [self.path URLByAppendingPathComponent:kUTMBundleScreenshotFilename];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    self.screenshot = nil;
}

@end
