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

#import "AppDelegate.h"

const NSNotificationName UTMImportNotification = @"UTMImportNotification";

@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    // trigger "allow network usage" popup in some regions
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:@"http://captive.apple.com"]] resume];
    if (launchOptions[UIApplicationLaunchOptionsURLKey]) {
        self.openURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    }
    return YES;
}


- (void)applicationWillTerminate:(UIApplication *)application {
    // You can't fire me, I quit!
    exit(0);
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    self.openURL = url;
    [[NSNotificationCenter defaultCenter] postNotificationName:UTMImportNotification object:self];
    return YES;
}

- (BOOL)application:(UIApplication *)application
        openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation
{
    NSLog(@"URL query: %@", [url query]);
    return YES;
}

@end
