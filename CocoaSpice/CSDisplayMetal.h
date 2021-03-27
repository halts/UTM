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

#import <Foundation/Foundation.h>
#import "UTMRenderSource.h"
@import CoreGraphics;

@class UTMScreenshot;

typedef struct _SpiceSession SpiceSession;

NS_ASSUME_NONNULL_BEGIN

@interface CSDisplayMetal : NSObject <UTMRenderSource>

@property (nonatomic, assign) BOOL ready;
@property (nonatomic, readonly, nullable) SpiceSession *session;
@property (nonatomic, readonly, assign) NSInteger channelID;
@property (nonatomic, readonly, assign) NSInteger monitorID;
@property (nonatomic, assign) CGSize displaySize;
@property (nonatomic, readonly) UTMScreenshot *screenshot;

- (id)initWithSession:(nonnull SpiceSession *)session channelID:(NSInteger)channelID monitorID:(NSInteger)monitorID;
- (id)initWithSession:(nonnull SpiceSession *)session channelID:(NSInteger)channelID;
- (void)updateVisibleAreaWithRect:(CGRect)rect;
- (void)requestResolution:(CGRect)bounds;
- (void)requestResolution:(CGRect)bounds monitorID:(NSInteger)monitorID;

@end

NS_ASSUME_NONNULL_END
