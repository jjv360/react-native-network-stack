//
//  RNSocket.h
//  RNNetworkStack
//
//  Created by Josh Fox on 2019/03/07.
//  Copyright © 2019 Facebook. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RNSocket : NSObject <GCDAsyncSocketDelegate>
    
    // Local identifier used by Javascript
    @property int identifier;
    
    // Socket file descriptor ID
    @property int fd;
    @property int fd6;
    
    // Connection info
    @property NSString* localAddress;
    @property NSString* remoteAddress;
    @property int localPort;
    @property int remotePort;
    
    // Queues for reading and writing
    @property dispatch_queue_t readQueue;
    @property dispatch_queue_t writeQueue;
    
    // Streams
    @property NSInputStream* inputStream;
    @property NSOutputStream* outputStream;
    
    -(NSDictionary*) json;
    
@end

NS_ASSUME_NONNULL_END
