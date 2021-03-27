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

#import <Foundation/Foundation.h>
#import "UTMInputOutput.h"
#import "CSConnectionDelegate.h"
#import "UTMSpiceIODelegate.h"

@class UTMConfiguration;
@class CSDisplayMetal;
@class CSInput;

NS_ASSUME_NONNULL_BEGIN

@interface UTMSpiceIO : NSObject<UTMInputOutput, CSConnectionDelegate>

@property (nonatomic, readonly, nonnull) UTMConfiguration* configuration;
@property (nonatomic, readonly, nullable) CSDisplayMetal *primaryDisplay;
@property (nonatomic, readonly, nullable) CSInput *primaryInput;
@property (nonatomic, weak, nullable) id<UTMSpiceIODelegate> delegate;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithConfiguration: (UTMConfiguration*) configuration port:(NSInteger)port NS_DESIGNATED_INITIALIZER;
- (void)changeSharedDirectory:(NSURL *)url;
- (CSConnection*)getSpiceConnection;

@end

NS_ASSUME_NONNULL_END
