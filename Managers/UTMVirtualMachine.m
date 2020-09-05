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
#import "UTMVirtualMachine+Sharing.h"
#import "UTMConfiguration.h"
#import "UTMConfiguration+Constants.h"
#import "UTMConfiguration+Display.h"
#import "UTMConfiguration+Miscellaneous.h"
#import "UTMViewState.h"
#import "UTMQemuImg.h"
#import "UTMQemuManager.h"
#import "UTMQemuSystemConfiguration.h"
#import "UTMTerminalIO.h"
#import "UTMSpiceIO.h"
#import "UTMLogging.h"
#import "UTMScreenshot.h"
#import "UTMPortAllocator.h"
#import "qapi-events.h"

const int kQMPMaxConnectionTries = 30; // qemu needs to start spice server first
const int64_t kStopTimeout = (int64_t)30*NSEC_PER_SEC;

NSString *const kUTMErrorDomain = @"com.osy86.utm";
NSString *const kUTMBundleConfigFilename = @"config.plist";
NSString *const kUTMBundleExtension = @"utm";
NSString *const kUTMBundleViewFilename = @"view.plist";
NSString *const kUTMBundleScreenshotFilename = @"screenshot.png";
NSString *const kSuspendSnapshotName = @"suspend";


@interface UTMVirtualMachine ()

@property (nonatomic, readwrite, nullable) NSURL *path;
@property (nonatomic, readwrite) UTMConfiguration *configuration;
@property (nonatomic, readonly) UTMQemuManager *qemu;
@property (nonatomic, readonly) UTMQemu *system;
@property (nonatomic, readwrite) UTMViewState *viewState;
@property (nonatomic, weak) UTMLogging *logging;
@property (nonatomic, readonly, nullable) id<UTMInputOutput> ioService;

@end

@implementation UTMVirtualMachine {
    UTMQemuSystemConfiguration *_qemu_system;
    dispatch_semaphore_t _will_quit_sema;
    dispatch_semaphore_t _qemu_exit_sema;
    BOOL _is_busy;
    UTMScreenshot *_screenshot;
    int64_t _relative_input_index;
    int64_t _absolute_input_index;
}

@synthesize busy = _is_busy;
@synthesize system = _qemu_system;

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
        _relative_input_index = -1;
        _absolute_input_index = -1;
        self.logging = [UTMLogging sharedInstance];
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
        self.viewState = [[UTMViewState alloc] initDefaults];
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
        self.configuration.existingPath = url;
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
            if (![fileManager moveItemAtURL:tmpPath toURL:dstPath error:&_err]) {
                goto error;
            }
        } else {
            if (![fileManager createDirectoryAtURL:dstPath withIntermediateDirectories:NO attributes:nil error:&_err]) {
                goto error;
            }
        }
    }
    self.path = url;
    return YES;
error:
    if (err) {
        *err = _err;
    }
    return NO;
}

- (void)errorTriggered:(nullable NSString *)msg {
    self.viewState.suspended = NO;
    [self saveViewState];
    [self quitVM];
    self.delegate.vmMessage = msg;
    [self changeState:kVMError];
}

- (BOOL)startVM {
    @synchronized (self) {
        if (self.busy || (self.state != kVMStopped && self.state != kVMSuspended)) {
            return NO; // already started
        } else {
            _is_busy = YES;
        }
    }
    // start logging
    if (self.configuration.debugLogEnabled) {
        [self.logging logToFile:[self.path URLByAppendingPathComponent:[UTMConfiguration debugLogName]]];
    }
    
    if (!_qemu_system) {
        _qemu_system = [[UTMQemuSystemConfiguration alloc] initWithConfiguration:self.configuration imgPath:self.path];
#if !TARGET_OS_IPHONE
        [_qemu_system setupXpc];
#endif
        _qemu_system.qmpPort = [[UTMPortAllocator sharedInstance] allocatePort];
        _qemu_system.spicePort = [[UTMPortAllocator sharedInstance] allocatePort];
        _qemu = [[UTMQemuManager alloc] initWithPort:_qemu_system.qmpPort];
        _qemu.delegate = self;
    }

    if (!_qemu_system) {
        [self errorTriggered:NSLocalizedString(@"Internal error starting VM.", @"UTMVirtualMachine")];
        _is_busy = NO;
        return NO;
    }
    
    if (!_ioService) {
        _ioService = [self inputOutputServiceWithPort:_qemu_system.spicePort];
    }
    
    self.delegate.vmMessage = nil;
    [self changeState:kVMStarting];
    if (self.configuration.debugLogEnabled) {
        [_ioService setDebugMode:YES];
    }
    
    BOOL ioStatus = [_ioService startWithError: nil];
    if (!ioStatus) {
        [self errorTriggered:NSLocalizedString(@"Internal error starting main loop.", @"UTMVirtualMachine")];
        _is_busy = NO;
        return NO;
    }
    if (self.viewState.suspended) {
        _qemu_system.snapshot = kSuspendSnapshotName;
    }
    [_qemu_system startWithCompletion:^(BOOL success, NSString *msg){
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
    _is_busy = NO;
    return YES;
}

- (BOOL)quitVM {
    @synchronized (self) {
        if (self.busy || self.state != kVMStarted) {
            return NO; // already stopping
        } else {
            _is_busy = YES;
        }
    }
    self.viewState.suspended = NO;
    [self syncViewState];
    [self changeState:kVMStopping];
    // save view settings early to win exit race
    [self saveViewState];
    
    [_qemu vmQuitWithCompletion:nil];
    if (dispatch_semaphore_wait(_will_quit_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
        // TODO: force shutdown
        UTMLog(@"Stop operation timeout");
    }
    [_qemu disconnect];
    _qemu.delegate = nil;
    _qemu = nil;
    [_ioService disconnect];
    _ioService = nil;
    
    if (dispatch_semaphore_wait(_qemu_exit_sema, dispatch_time(DISPATCH_TIME_NOW, kStopTimeout)) != 0) {
        // TODO: force shutdown
        UTMLog(@"Exit operation timeout");
    }
    [[UTMPortAllocator sharedInstance] freePort:_qemu_system.qmpPort];
    [[UTMPortAllocator sharedInstance] freePort:_qemu_system.spicePort];
    _qemu_system = nil;
    [self changeState:kVMStopped];
    // stop logging
    [self.logging endLog];
    _is_busy = NO;
    return YES;
}

- (BOOL)resetVM {
    @synchronized (self) {
        if (self.busy || (self.state != kVMStarted && self.state != kVMPaused)) {
            return NO; // already stopping
        } else {
            _is_busy = YES;
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
    _is_busy = NO;
    return success;
}

- (BOOL)pauseVM {
    @synchronized (self) {
        if (self.busy || self.state != kVMStarted) {
            return NO; // already stopping
        } else {
            _is_busy = YES;
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
    _is_busy = NO;
    return success;
}

- (BOOL)saveVM {
    @synchronized (self) {
        if (self.busy || (self.state != kVMPaused && self.state != kVMStarted)) {
            return NO;
        } else {
            _is_busy = YES;
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
    _is_busy = NO;
    return success;
}

- (BOOL)deleteSaveVM {
    __block BOOL success = YES;
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
    self.viewState.suspended = NO;
    [self saveViewState];
    return success;
}

- (BOOL)resumeVM {
    @synchronized (self) {
        if (self.busy || self.state != kVMPaused) {
            return NO;
        } else {
            _is_busy = YES;
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
    _is_busy = NO;
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
    if (!_is_busy) {
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
    NSError *err;
    if (!self.configuration.displayConsoleOnly && ![self startSharedDirectoryWithError:&err]) {
        UTMLog(@"Ignoring error trying to start shared directory: %@", err);
    }
    [self restoreRemovableDrivesFromBookmarks];
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
        self.viewState = [[UTMViewState alloc] initDefaults];
    }
}

- (void)saveViewState {
    [self savePlist:[self.path URLByAppendingPathComponent:kUTMBundleViewFilename]
               dict:self.viewState.dictRepresentation
          withError:nil];
}

#pragma mark - Screenshot

@synthesize screenshot = _screenshot;

- (void)loadScreenshot {
    NSURL *url = [self.path URLByAppendingPathComponent:kUTMBundleScreenshotFilename];
    _screenshot = [[UTMScreenshot alloc] initWithContentsOfURL:url];
}

- (void)saveScreenshot {
    _screenshot = [self.ioService screenshot];
    NSURL *url = [self.path URLByAppendingPathComponent:kUTMBundleScreenshotFilename];
    if (_screenshot) {
        [_screenshot writeToURL:url atomically:NO];
    }
}

- (void)deleteScreenshot {
    NSURL *url = [self.path URLByAppendingPathComponent:kUTMBundleScreenshotFilename];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

#pragma mark - Input device switching

- (void)requestInputTablet:(BOOL)tablet completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    int64_t *p_index = tablet ? &_absolute_input_index : &_relative_input_index;
    if (*p_index < 0) {
        [_qemu mouseIndexForAbsolute:tablet withCompletion:^(int64_t index, NSError *err) {
            if (err) {
                UTMLog(@"error finding index: %@", err);
            } else {
                UTMLog(@"found index:%lld absolute:%d", index, tablet);
                *p_index = index;
                [self->_qemu mouseSelect:*p_index withCompletion:completion];
            }
        }];
    } else {
        UTMLog(@"selecting input device %lld", *p_index);
        [_qemu mouseSelect:*p_index withCompletion:completion];
    }
}

@end
