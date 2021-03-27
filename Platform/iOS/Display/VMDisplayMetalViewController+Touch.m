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

#import "UIViewController+Extensions.h"
#import "VMDisplayMetalViewController.h"
#import "VMDisplayMetalViewController+Touch.h"
#import "VMDisplayMetalViewController+Pencil.h"
#import "VMCursor.h"
#import "VMScroll.h"
#import "CSDisplayMetal.h"
#import "UTMConfiguration.h"
#import "UTMConfiguration+Miscellaneous.h"
#import "UTMSpiceIO.h"
#import "UTMLogging.h"
#import "UTMVirtualMachine.h"
#import "UTMVirtualMachine+SPICE.h"

const CGFloat kScrollSpeedReduction = 100.0f;
const CGFloat kCursorResistance = 50.0f;
const CGFloat kScrollResistance = 10.0f;

@implementation VMDisplayMetalViewController (Gestures)

- (void)initTouch {
    // mouse cursor
    _cursor = [[VMCursor alloc] initWithVMViewController:self];
    _scroll = [[VMScroll alloc] initWithVMViewController:self];
    
    // Set up gesture recognizers because Storyboards is BROKEN and doing it there crashes!
    _swipeUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(gestureSwipeUp:)];
    _swipeUp.numberOfTouchesRequired = 3;
    _swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
    _swipeUp.delegate = self;
    _swipeDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(gestureSwipeDown:)];
    _swipeDown.numberOfTouchesRequired = 3;
    _swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
    _swipeDown.delegate = self;
    _swipeScrollUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(gestureSwipeScroll:)];
    _swipeScrollUp.numberOfTouchesRequired = 2;
    _swipeScrollUp.direction = UISwipeGestureRecognizerDirectionUp;
    _swipeScrollUp.delegate = self;
    _swipeScrollDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(gestureSwipeScroll:)];
    _swipeScrollDown.numberOfTouchesRequired = 2;
    _swipeScrollDown.direction = UISwipeGestureRecognizerDirectionDown;
    _swipeScrollDown.delegate = self;
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(gesturePan:)];
    _pan.minimumNumberOfTouches = 1;
    _pan.maximumNumberOfTouches = 1;
    _pan.delegate = self;
    _pan.cancelsTouchesInView = NO;
    _twoPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(gestureTwoPan:)];
    _twoPan.minimumNumberOfTouches = 2;
    _twoPan.maximumNumberOfTouches = 2;
    _twoPan.delegate = self;
    _threePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(gestureThreePan:)];
    _threePan.minimumNumberOfTouches = 3;
    _threePan.maximumNumberOfTouches = 3;
    _threePan.delegate = self;
    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(gestureTap:)];
    _tap.delegate = self;
    _tap.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
    _tap.cancelsTouchesInView = NO;
    _twoTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(gestureTwoTap:)];
    _twoTap.numberOfTouchesRequired = 2;
    _twoTap.delegate = self;
    _twoTap.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
    _longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(gestureLongPress:)];
    _longPress.delegate = self;
    _longPress.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
    _pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(gesturePinch:)];
    _pinch.delegate = self;
    [self.view addGestureRecognizer:_swipeUp];
    [self.view addGestureRecognizer:_swipeDown];
    [self.view addGestureRecognizer:_swipeScrollUp];
    [self.view addGestureRecognizer:_swipeScrollDown];
    [self.view addGestureRecognizer:_pan];
    [self.view addGestureRecognizer:_twoPan];
    [self.view addGestureRecognizer:_threePan];
    [self.view addGestureRecognizer:_tap];
    [self.view addGestureRecognizer:_twoTap];
    [self.view addGestureRecognizer:_longPress];
    [self.view addGestureRecognizer:_pinch];
    
    // Feedback generator for clicks
    _clickFeedbackGenerator = [[UISelectionFeedbackGenerator alloc] init];
    _resizeFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] init];
}

#pragma mark - Properties from instance

- (CSInputButton)mouseButtonDown {
    CSInputButton button = kCSInputButtonNone;
    if (_mouseLeftDown) {
        button |= kCSInputButtonLeft;
    }
    if (_mouseRightDown) {
        button |= kCSInputButtonRight;
    }
    if (_mouseMiddleDown) {
        button |= kCSInputButtonMiddle;
    }
    return button;
}

#pragma mark - Properties from settings

- (VMGestureType)gestureTypeForSetting:(NSString *)key {
    NSInteger integer = [self integerForSetting:key];
    if (integer < VMGestureTypeNone || integer >= VMGestureTypeMax) {
        return VMGestureTypeNone;
    } else {
        return (VMGestureType)integer;
    }
}

- (VMGestureType)longPressType {
    return [self gestureTypeForSetting:@"GestureLongPress"];
}

- (VMGestureType)twoFingerTapType {
    return [self gestureTypeForSetting:@"GestureTwoTap"];
}

- (VMGestureType)twoFingerPanType {
    return [self gestureTypeForSetting:@"GestureTwoPan"];
}

- (VMGestureType)twoFingerScrollType {
    return [self gestureTypeForSetting:@"GestureTwoScroll"];
}

- (VMGestureType)threeFingerPanType {
    return [self gestureTypeForSetting:@"GestureThreePan"];
}

- (VMMouseType)mouseTypeForSetting:(NSString *)key {
    NSInteger integer = [self integerForSetting:key];
    if (integer < VMGestureTypeNone || integer >= VMGestureTypeMax) {
        return VMMouseTypeRelative;
    } else {
        return (VMMouseType)integer;
    }
}

- (VMMouseType)touchMouseType {
    return [self mouseTypeForSetting:@"MouseTouchType"];
}

- (VMMouseType)pencilMouseType {
    return [self mouseTypeForSetting:@"MousePencilType"];
}

- (VMMouseType)indirectMouseType {
    return [self mouseTypeForSetting:@"MouseIndirectType"];
}

#pragma mark - Converting view points to VM display points

static CGRect CGRectClipToBounds(CGRect rect1, CGRect rect2) {
    if (rect2.origin.x < rect1.origin.x) {
        rect2.origin.x = rect1.origin.x;
    } else if (rect2.origin.x + rect2.size.width > rect1.origin.x + rect1.size.width) {
        rect2.origin.x = rect1.origin.x + rect1.size.width - rect2.size.width;
    }
    if (rect2.origin.y < rect1.origin.y) {
        rect2.origin.y = rect1.origin.y;
    } else if (rect2.origin.y + rect2.size.height > rect1.origin.y + rect1.size.height) {
        rect2.origin.y = rect1.origin.y + rect1.size.height - rect2.size.height;
    }
    return rect2;
}

static CGFloat CGPointToPixel(CGFloat point) {
    return point * [UIScreen mainScreen].scale; // FIXME: multiple screens?
}

- (CGPoint)clipCursorToDisplay:(CGPoint)pos {
    CGSize screenSize = self.mtkView.drawableSize;
    CGSize scaledSize = {
        self.vmDisplay.displaySize.width * self.vmDisplay.viewportScale,
        self.vmDisplay.displaySize.height * self.vmDisplay.viewportScale
    };
    CGRect drawRect = CGRectMake(
        self.vmDisplay.viewportOrigin.x + screenSize.width/2 - scaledSize.width/2,
        self.vmDisplay.viewportOrigin.y + screenSize.height/2 - scaledSize.height/2,
        scaledSize.width,
        scaledSize.height
    );
    pos.x -= drawRect.origin.x;
    pos.y -= drawRect.origin.y;
    if (pos.x < 0) {
        pos.x = 0;
    } else if (pos.x > scaledSize.width) {
        pos.x = scaledSize.width;
    }
    if (pos.y < 0) {
        pos.y = 0;
    } else if (pos.y > scaledSize.height) {
        pos.y = scaledSize.height;
    }
    pos.x /= self.vmDisplay.viewportScale;
    pos.y /= self.vmDisplay.viewportScale;
    return pos;
}

- (CGPoint)clipDisplayToView:(CGPoint)target {
    CGSize screenSize = self.mtkView.drawableSize;
    CGSize scaledSize = {
        self.vmDisplay.displaySize.width * self.vmDisplay.viewportScale,
        self.vmDisplay.displaySize.height * self.vmDisplay.viewportScale
    };
    CGRect drawRect = CGRectMake(
        target.x + screenSize.width/2 - scaledSize.width/2,
        target.y + screenSize.height/2 - scaledSize.height/2,
        scaledSize.width,
        scaledSize.height
    );
    CGRect boundRect = {
        {
            screenSize.width - MAX(screenSize.width, scaledSize.width),
            screenSize.height - MAX(screenSize.height, scaledSize.height)
            
        },
        {
            2*MAX(screenSize.width, scaledSize.width) - screenSize.width,
            2*MAX(screenSize.height, scaledSize.height) - screenSize.height
        }
    };
    CGRect clippedRect = CGRectClipToBounds(boundRect, drawRect);
    clippedRect.origin.x -= (screenSize.width/2 - scaledSize.width/2);
    clippedRect.origin.y -= (screenSize.height/2 - scaledSize.height/2);
    return CGPointMake(clippedRect.origin.x, clippedRect.origin.y);
}

#pragma mark - Gestures

- (void)moveMouseWithInertia:(UIPanGestureRecognizer *)sender {
    CGPoint location = [sender locationInView:sender.view];
    CGPoint velocity = [sender velocityInView:sender.view];
    if (sender.state == UIGestureRecognizerStateBegan) {
        [_cursor startMovement:location];
    }
    if (sender.state != UIGestureRecognizerStateCancelled) {
        [_cursor updateMovement:location];
    }
    if (sender.state == UIGestureRecognizerStateEnded) {
        [_cursor endMovementWithVelocity:velocity resistance:kCursorResistance];
    }
}

- (void)scrollWithInertia:(UIPanGestureRecognizer *)sender {
    CGPoint location = [sender locationInView:sender.view];
    CGPoint velocity = [sender velocityInView:sender.view];
    if (sender.state == UIGestureRecognizerStateBegan) {
        [_scroll startMovement:location];
    }
    if (sender.state != UIGestureRecognizerStateCancelled) {
        [_scroll updateMovement:location];
    }
    if (sender.state == UIGestureRecognizerStateEnded) {
        [_scroll endMovementWithVelocity:velocity resistance:kScrollResistance];
    }
}

- (IBAction)gesturePan:(UIPanGestureRecognizer *)sender {
    if (self.serverModeCursor) {  // otherwise we handle in touchesMoved
        [self moveMouseWithInertia:sender];
    }
}

- (void)moveScreen:(UIPanGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan) {
        _lastTwoPanOrigin = self.vmDisplay.viewportOrigin;
    }
    if (sender.state != UIGestureRecognizerStateCancelled) {
        CGPoint translation = [sender translationInView:sender.view];
        CGPoint viewport = self.vmDisplay.viewportOrigin;
        viewport.x = CGPointToPixel(translation.x) + _lastTwoPanOrigin.x;
        viewport.y = CGPointToPixel(translation.y) + _lastTwoPanOrigin.y;
        self.vmDisplay.viewportOrigin = [self clipDisplayToView:viewport];
    }
    if (sender.state == UIGestureRecognizerStateEnded) {
        // TODO: decelerate
    }
}

- (IBAction)gestureTwoPan:(UIPanGestureRecognizer *)sender {
    switch (self.twoFingerPanType) {
        case VMGestureTypeMoveScreen:
            [self moveScreen:sender];
            break;
        case VMGestureTypeDragCursor:
            [self dragCursor:sender.state primary:YES secondary:NO middle:NO];
            [self moveMouseWithInertia:sender];
            break;
        case VMGestureTypeMouseWheel:
            [self scrollWithInertia:sender];
            break;
        default:
            break;
    }
}

- (IBAction)gestureThreePan:(UIPanGestureRecognizer *)sender {
    switch (self.threeFingerPanType) {
        case VMGestureTypeMoveScreen:
            [self moveScreen:sender];
            break;
        case VMGestureTypeDragCursor:
            [self dragCursor:sender.state primary:YES secondary:NO middle:NO];
            [self moveMouseWithInertia:sender];
            break;
        case VMGestureTypeMouseWheel:
            [self scrollWithInertia:sender];
            break;
        default:
            break;
    }
}

- (CGPoint)moveMouseAbsolute:(CGPoint)location {
    CGPoint translated = location;
    translated.x = CGPointToPixel(translated.x);
    translated.y = CGPointToPixel(translated.y);
    translated = [self clipCursorToDisplay:translated];
    if (!self.vmInput.serverModeCursor) {
        [self.vmInput sendMouseMotion:self.mouseButtonDown point:translated];
        [self.vmInput forceCursorPosition:translated]; // required to show cursor on screen
    } else {
        UTMLog(@"Warning: ignored mouse set (%f, %f) while mouse is in server mode", translated.x, translated.y);
    }
    return translated;
}

- (CGPoint)moveMouseRelative:(CGPoint)translation {
    translation.x = CGPointToPixel(translation.x) / self.vmDisplay.viewportScale;
    translation.y = CGPointToPixel(translation.y) / self.vmDisplay.viewportScale;
    if (self.vmInput.serverModeCursor) {
        [self.vmInput sendMouseMotion:self.mouseButtonDown point:translation];
    } else {
        UTMLog(@"Warning: ignored mouse motion (%f, %f) while mouse is in client mode", translation.x, translation.y);
    }
    return translation;
}

- (CGPoint)moveMouseScroll:(CGPoint)translation {
    translation.y = CGPointToPixel(translation.y) / kScrollSpeedReduction;
    if (self.vmConfiguration.inputScrollInvert) {
        translation.y = -translation.y;
    }
    [self.vmInput sendMouseScroll:kCSInputScrollSmooth button:self.mouseButtonDown dy:translation.y];
    return translation;
}

- (void)mouseClick:(CSInputButton)button location:(CGPoint)location {
    if (!self.serverModeCursor) {
        _cursor.center = location;
    }
    [self.vmInput sendMouseButton:button pressed:YES point:CGPointZero];
    [self onDelay:0.05f action:^{
        self->_mouseLeftDown = NO;
        self->_mouseRightDown = NO;
        self->_mouseMiddleDown = NO;
        [self.vmInput sendMouseButton:button pressed:NO point:CGPointZero];
    }];
    [_clickFeedbackGenerator selectionChanged];
}

- (void)dragCursor:(UIGestureRecognizerState)state primary:(BOOL)primary secondary:(BOOL)secondary middle:(BOOL)middle {
    if (state == UIGestureRecognizerStateBegan) {
        [_clickFeedbackGenerator selectionChanged];
        if (primary) {
            _mouseLeftDown = YES;
        }
        if (secondary) {
            _mouseRightDown = YES;
        }
        if (middle) {
            _mouseMiddleDown = YES;
        }
        [self.vmInput sendMouseButton:self.mouseButtonDown pressed:YES point:CGPointZero];
    } else if (state == UIGestureRecognizerStateEnded) {
        _mouseLeftDown = NO;
        _mouseRightDown = NO;
        _mouseMiddleDown = NO;
        [self.vmInput sendMouseButton:self.mouseButtonDown pressed:NO point:CGPointZero];
    }
}

- (IBAction)gestureTap:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded &&
        self.serverModeCursor) { // otherwise we handle in touchesBegan
        [self mouseClick:kCSInputButtonLeft location:[sender locationInView:sender.view]];
    }
}

- (IBAction)gestureTwoTap:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded &&
        self.twoFingerTapType == VMGestureTypeRightClick) {
        [self mouseClick:kCSInputButtonRight location:[sender locationInView:sender.view]];
    }
}

- (IBAction)gestureLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded &&
        self.longPressType == VMGestureTypeRightClick) {
        [self mouseClick:kCSInputButtonRight location:[sender locationInView:sender.view]];
    } else if (self.longPressType == VMGestureTypeDragCursor) {
        [self dragCursor:sender.state primary:YES secondary:NO middle:NO];
    }
}

- (IBAction)gesturePinch:(UIPinchGestureRecognizer *)sender {
    // disable pinch if move screen on pan is disabled
    if (self.twoFingerPanType == VMGestureTypeMoveScreen || self.threeFingerPanType == VMGestureTypeMoveScreen) {
        NSAssert(sender.scale > 0, @"sender.scale cannot be 0");
        self.vmDisplay.viewportScale *= sender.scale;
        sender.scale = 1.0;
    }
}

- (IBAction)gestureSwipeUp:(UISwipeGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded) {
        if (self.toolbarVisible) {
            self.toolbarVisible = NO;
        } else if (!self.keyboardVisible) {
            self.keyboardVisible = YES;
        }
    }
}

- (IBAction)gestureSwipeDown:(UISwipeGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded) {
        if (self.keyboardVisible) {
            self.keyboardVisible = NO;
        } else if (!self.toolbarVisible) {
            self.toolbarVisible = YES;
        }
    }
}

- (IBAction)gestureSwipeScroll:(UISwipeGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded &&
        self.twoFingerScrollType == VMGestureTypeMouseWheel) {
        if (sender == _swipeScrollUp) {
            [self.vmInput sendMouseScroll:kCSInputScrollUp button:self.mouseButtonDown dy:0];
        } else if (sender == _swipeScrollDown) {
            [self.vmInput sendMouseScroll:kCSInputScrollDown button:self.mouseButtonDown dy:0];
        } else {
            NSAssert(0, @"Invalid call to gestureSwipeScroll");
        }
    }
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer == _twoPan && otherGestureRecognizer == _swipeUp) {
        return YES;
    }
    if (gestureRecognizer == _twoPan && otherGestureRecognizer == _swipeDown) {
        return YES;
    }
    if (gestureRecognizer == _twoTap && otherGestureRecognizer == _swipeDown) {
        return YES;
    }
    if (gestureRecognizer == _twoTap && otherGestureRecognizer == _swipeUp) {
        return YES;
    }
    if (gestureRecognizer == _tap && otherGestureRecognizer == _twoTap) {
        return YES;
    }
    if (gestureRecognizer == _longPress && otherGestureRecognizer == _tap) {
        return YES;
    }
    if (gestureRecognizer == _longPress && otherGestureRecognizer == _twoTap) {
        return YES;
    }
    if (gestureRecognizer == _pinch && otherGestureRecognizer == _swipeDown) {
        return YES;
    }
    if (gestureRecognizer == _pinch && otherGestureRecognizer == _swipeUp) {
        return YES;
    }
    if (gestureRecognizer == _pan && otherGestureRecognizer == _swipeUp) {
        return YES;
    }
    if (gestureRecognizer == _pan && otherGestureRecognizer == _swipeDown) {
        return YES;
    }
    if (gestureRecognizer == _threePan && otherGestureRecognizer == _swipeUp) {
        return YES;
    }
    if (gestureRecognizer == _threePan && otherGestureRecognizer == _swipeDown) {
        return YES;
    }
    // only if we do not disable two finger swipe
    if (self.twoFingerScrollType != VMGestureTypeNone) {
        if (gestureRecognizer == _twoPan && otherGestureRecognizer == _swipeScrollUp) {
            return YES;
        }
        if (gestureRecognizer == _twoPan && otherGestureRecognizer == _swipeScrollDown) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer == _twoPan && otherGestureRecognizer == _pinch) {
        if (self.twoFingerPanType == VMGestureTypeMoveScreen) {
            return YES;
        } else {
            return NO;
        }
    } else if (gestureRecognizer == _pan && otherGestureRecognizer == _longPress) {
        return YES;
    } else if (self.twoFingerScrollType == VMGestureTypeNone && otherGestureRecognizer == _twoPan) {
        // if two finger swipe is disabled, we can also recognize two finger pans
        if (gestureRecognizer == _swipeScrollUp) {
            return YES;
        } else if (gestureRecognizer == _swipeScrollDown) {
            return YES;
        } else {
            return NO;
        }
    } else {
        return NO;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveEvent:(UIEvent *)event API_AVAILABLE(ios(13.4)) {
    if (event.type == UIEventTypeTransform) {
        UTMLog(@"ignoring UIEventTypeTransform");
        return NO;
    } else {
        return YES;
    }
}

#pragma mark - Touch type

- (VMMouseType)touchTypeToMouseType:(UITouchType)type {
    switch (type) {
        case UITouchTypeDirect: {
            return self.touchMouseType;
        }
        case UITouchTypePencil: {
            return self.pencilMouseType;
        }
        case UITouchTypeIndirect:
        default: { // covers UITouchTypeIndirectPointer
            return self.indirectMouseType;
        }
    }
}

- (BOOL)switchMouseType:(VMMouseType)type {
    BOOL shouldHideCursor = (type == VMMouseTypeAbsoluteHideCursor);
    BOOL shouldUseServerMouse = (type == VMMouseTypeRelative);
    self.vmInput.inhibitCursor = shouldHideCursor;
    if (shouldUseServerMouse != self.vmInput.serverModeCursor) {
        UTMLog(@"Switching mouse mode to server:%d for type:%ld", shouldUseServerMouse, type);
        [self.vm requestInputTablet:!shouldUseServerMouse];
        return YES;
    }
    return NO;
}

#pragma mark - Touch event handling

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.vmConfiguration.inputLegacy) {
        for (UITouch *touch in [event touchesForView:self.view]) {
            VMMouseType type = [self touchTypeToMouseType:touch.type];
            if ([self switchMouseType:type]) {
                [self dragCursor:UIGestureRecognizerStateEnded primary:YES secondary:YES middle:YES]; // reset drag
            } else if (!self.vmInput.serverModeCursor) { // start click for client mode
                BOOL primary = YES;
                BOOL secondary = NO;
                BOOL middle = NO;
                CGPoint pos = [touch locationInView:self.view];
                // iOS 13.4+ Pointing device support
                if (@available(iOS 13.4, *)) {
                    if (touch.type == UITouchTypeIndirectPointer) {
                        primary = (event.buttonMask & UIEventButtonMaskPrimary) != 0;
                        secondary = (event.buttonMask & UIEventButtonMaskSecondary) != 0;
                        middle = (event.buttonMask & 0x4) != 0; // undocumented mask
                    }
                }
                // Apple Pencil 2 right click mode
                if (@available(iOS 12.1, *)) {
                    if (touch.type == UITouchTypePencil) {
                        primary = !_pencilForceRightClickOnce;
                        secondary = _pencilForceRightClickOnce;
                        _pencilForceRightClickOnce = false;
                    }
                }
                [_cursor startMovement:pos];
                [_cursor updateMovement:pos];
                [self dragCursor:UIGestureRecognizerStateBegan primary:primary secondary:secondary middle:middle];
            }
            break; // handle a single touch only
        }
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // move cursor in client mode, in server mode we handle in gesturePan
    if (!self.vmConfiguration.inputLegacy && !self.vmInput.serverModeCursor) {
        for (UITouch *touch in [event touchesForView:self.view]) {
            [_cursor updateMovement:[touch locationInView:self.view]];
            break; // handle single touch
        }
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // release click in client mode, in server mode we handle in gesturePan
    if (!self.vmConfiguration.inputLegacy && !self.vmInput.serverModeCursor) {
        [self dragCursor:UIGestureRecognizerStateEnded primary:YES secondary:YES middle:YES];
    }
    [super touchesCancelled:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // release click in client mode, in server mode we handle in gesturePan
    if (!self.vmConfiguration.inputLegacy && !self.vmInput.serverModeCursor) {
        [self dragCursor:UIGestureRecognizerStateEnded primary:YES secondary:YES middle:YES];
    }
    [super touchesEnded:touches withEvent:event];
}

@end
