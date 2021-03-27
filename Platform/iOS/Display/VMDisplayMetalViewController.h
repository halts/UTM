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

#import <UIKit/UIKit.h>
#import "VMDisplayViewController.h"
#import "UTMSpiceIODelegate.h"

@class UTMSpiceIO;
@class UTMVirtualMachine;
@class VMCursor;
@class VMScroll;
@class VMKeyboardView;
@class VMKeyboardButton;
@class GCController;

NS_ASSUME_NONNULL_BEGIN

@interface VMDisplayMetalViewController : VMDisplayViewController<UTMSpiceIODelegate> {
    // cursor handling
    CGPoint _lastTwoPanOrigin;
    BOOL _mouseLeftDown;
    BOOL _mouseRightDown;
    BOOL _mouseMiddleDown;
    BOOL _pencilForceRightClickOnce;
    VMCursor *_cursor;
    VMScroll *_scroll;
    
    // Gestures
    UISwipeGestureRecognizer *_swipeUp;
    UISwipeGestureRecognizer *_swipeDown;
    UISwipeGestureRecognizer *_swipeScrollUp;
    UISwipeGestureRecognizer *_swipeScrollDown;
    UIPanGestureRecognizer *_pan;
    UIPanGestureRecognizer *_twoPan;
    UIPanGestureRecognizer *_threePan;
    UITapGestureRecognizer *_tap;
    UITapGestureRecognizer *_twoTap;
    UILongPressGestureRecognizer *_longPress;
    UIPinchGestureRecognizer *_pinch;
    
    //Gamepad
    GCController *_controller;
    
    // Feedback generators
    UISelectionFeedbackGenerator *_clickFeedbackGenerator;
    UIImpactFeedbackGenerator *_resizeFeedbackGenerator;
}

@property (weak, nonatomic) IBOutlet MTKView *mtkView;
@property (weak, nonatomic) IBOutlet UIImageView *placeholderImageView;
@property (weak, nonatomic) IBOutlet VMKeyboardView *keyboardView;

@property (nonatomic, assign) BOOL lastDisplayChangeResize;
@property (nonatomic, readonly) BOOL serverModeCursor;

- (void)sendExtendedKey:(CSInputKey)type code:(int)code;
- (void)resetDisplay;
- (void)displayResize:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
