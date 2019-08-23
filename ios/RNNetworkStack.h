
#if __has_include("RCTBridgeModule.h")
#import "RCTBridgeModule.h"
#else
#import <React/RCTBridgeModule.h>
#endif

#import "RNSocket.h"

@interface RNNetworkStack : NSObject <RCTBridgeModule>
    @property (strong) NSMutableDictionary* activeSockets;
@end
  
