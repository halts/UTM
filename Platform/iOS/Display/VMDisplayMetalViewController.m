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

#import "VMDisplayMetalViewController.h"
#import "VMDisplayMetalViewController+Keyboard.h"
#import "VMDisplayMetalViewController+Touch.h"
#import "VMDisplayMetalViewController+Pointer.h"
#import "VMDisplayMetalViewController+Pencil.h"
#import "VMDisplayMetalViewController+Gamepad.h"
#import "VMKeyboardView.h"
#import "UTMRenderer.h"
#import "UTMVirtualMachine.h"
#import "UTMQemuManager.h"
#import "UTMConfiguration.h"
#import "UTMConfiguration+Display.h"
#import "UTMLogging.h"
#import "CSDisplayMetal.h"
#import "UTMScreenshot.h"
#import "UTM-Swift.h"

@interface VMDisplayMetalViewController ()

@property (nonatomic) ExternalScreenController *externalController;

@end

@implementation VMDisplayMetalViewController {
    UTMRenderer *_renderer;
}

@synthesize vmDisplay;
@synthesize vmInput;

- (BOOL)serverModeCursor {
    return self.vmInput.serverModeCursor;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // set up software keyboard
    self.keyboardView.inputAccessoryView = self.inputAccessoryView;
    
    // Set the view to use the default device
    self.mtkView.device = MTLCreateSystemDefaultDevice();
    if (!self.mtkView.device) {
        UTMLog(@"Metal is not supported on this device");
        return;
    }
    
    _renderer = [[UTMRenderer alloc] initWithMetalKitView:self.mtkView];
    if (!_renderer) {
        UTMLog(@"Renderer failed initialization");
        return;
    }
    
    // Initialize our renderer with the view size
    [_renderer mtkView:self.mtkView drawableSizeWillChange:self.mtkView.drawableSize];
    _renderer.sourceScreen = self.vmDisplay;
    _renderer.sourceCursor = self.vmInput;
    
    [_renderer changeUpscaler:self.vmConfiguration.displayUpscalerValue
                   downscaler:self.vmConfiguration.displayDownscalerValue];
    
    self.mtkView.delegate = _renderer;
    
    [self initTouch];
    [self initGamepad];
    // Pointing device support on iPadOS 13.4 GM or later
    if (@available(iOS 13.4, *)) {
        // Betas of iPadOS 13.4 did not include this API, that's why I check if the class exists
        if (NSClassFromString(@"UIPointerInteraction") != nil) {
            [self initPointerInteraction];
        }
    }
    // Apple Pencil 2 double tap support on iOS 12.1+
    if (@available(iOS 12.1, *)) {
        [self initPencilInteraction];
    }
    // External screen
    _externalController = [[ExternalScreenController alloc] initWithVmViewController:self metalView: self.mtkView];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.vm.state == kVMStopped || self.vm.state == kVMSuspended) {
        if ([self.vm startVM]) {
            self.vm.ioDelegate = self;
        }
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self displayResize:[self.externalController displaySize]];
}

- (void)virtualMachine:(UTMVirtualMachine *)vm transitionToState:(UTMVMState)state {
    [super virtualMachine:vm transitionToState:state];
    switch (state) {
        case kVMStopped:
        case kVMPaused:
        case kVMSuspended: {
            [UIView transitionWithView:self.view duration:0.5 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                self.placeholderImageView.hidden = NO;
                self.placeholderImageView.image = self.vm.screenshot.image;
                self.mtkView.hidden = YES;
            } completion:nil];
            if (self.vmConfiguration.shareClipboardEnabled) {
                [[UTMPasteboard generalPasteboard] releasePollingModeForObject:self];
            }
            break;
        }
        case kVMStarted: {
            [UIView transitionWithView:self.view duration:0.5 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                self.placeholderImageView.hidden = YES;
                self.mtkView.hidden = NO;
            } completion:nil];
            self->_renderer.sourceScreen = self.vmDisplay;
            self->_renderer.sourceCursor = self.vmInput;
            [self displayResize:self.view.bounds.size];
            if (self.vmConfiguration.shareClipboardEnabled) {
                [[UTMPasteboard generalPasteboard] requestPollingModeForObject:self];
            }
            //[self displayResize: [self.externalController displaySize]];
            break;
        }
        default: {
            break;
        }
    }
}

#pragma mark - Key handling

- (void)setKeyboardVisible:(BOOL)keyboardVisible {
    if (keyboardVisible) {
        [self.keyboardView becomeFirstResponder];
    } else {
        [self.keyboardView resignFirstResponder];
    }
    [super setKeyboardVisible:keyboardVisible];
}

- (void)sendExtendedKey:(CSInputKey)type code:(int)code {
    if ((code & 0xFF00) == 0xE000) {
        code = 0x100 | (code & 0xFF);
    } else if (code >= 0x100) {
        UTMLog(@"warning: ignored invalid keycode 0x%x", code);
    }
    [self.vmInput sendKey:type code:code];
}

#pragma mark - Toolbar actions

- (void)setLastDisplayChangeResize:(BOOL)lastDisplayChangeResize {
    _lastDisplayChangeResize = lastDisplayChangeResize;
    if (lastDisplayChangeResize) {
        [self.zoomButton setImage:[UIImage imageNamed:@"Toolbar Minimize"] forState:UIControlStateNormal];
    } else {
        [self.zoomButton setImage:[UIImage imageNamed:@"Toolbar Maximize"] forState:UIControlStateNormal];
    }
}

- (void)resizeDisplayToFit {
    CGSize viewSize = self.mtkView.drawableSize;
    CGSize displaySize = self.vmDisplay.displaySize;
    CGSize scaled = CGSizeMake(viewSize.width / displaySize.width, viewSize.height / displaySize.height);
    self.vmDisplay.viewportScale = MIN(scaled.width, scaled.height);
    self.vmDisplay.viewportOrigin = CGPointMake(0, 0);
}

- (void)resetDisplay {
    self.vmDisplay.viewportScale = 1.0;
    self.vmDisplay.viewportOrigin = CGPointMake(0, 0);
}

- (IBAction)changeDisplayZoom:(UIButton *)sender {
    if (self.lastDisplayChangeResize) {
        [self resetDisplay];
    } else {
        [self resizeDisplayToFit];
    }
    self.lastDisplayChangeResize = !self.lastDisplayChangeResize;
}

#pragma mark - Resizing

- (void)displayResize:(CGSize)size {
    UTMLog(@"resizing to (%f, %f)", size.width, size.height);
    CGRect bounds = CGRectMake(0, 0, size.width, size.height);
    if (self.vmConfiguration.displayRetina) {
        CGFloat scale = [UIScreen mainScreen].scale;
        CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
        bounds = CGRectApplyAffineTransform(bounds, transform);
    }
    [self.vmDisplay requestResolution:bounds];
}

@end
