
#if __has_include("RCTBridgeModule.h")
#import "RCTBridgeModule.h"
#else
#import <React/RCTBridgeModule.h>
#endif

#import <React/RCTEventEmitter.h>
#import "RNSocket.h"

@interface RNNetworkStack : RCTEventEmitter <RCTBridgeModule>
    @property (strong) NSMutableDictionary* activeSockets;
@end
  
