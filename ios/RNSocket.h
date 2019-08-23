//
//  RNSocket.h
//  RNNetworkStack
//
//  Created by Josh Fox on 2019/03/07.
//  Copyright © 2019 Facebook. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define SOCK_BUFFER_SIZE 1024*512

@interface RNSocket : NSObject {
    
    // Buffers
    uint8_t writeBuffer[SOCK_BUFFER_SIZE];
    uint8_t readBuffer[SOCK_BUFFER_SIZE];
    
}
    
    // Local identifier used by Javascript
    @property int identifier;
    
    // Socket file descriptor ID
    @property int fd;
    @property int fd6;
    
    // Connection info
    @property (strong) NSString* localAddress;
    @property (strong) NSString* remoteAddress;
    @property int localPort;
    @property int remotePort;
    
    // Queues for reading and writing
    @property (strong) dispatch_queue_t readQueue;
    @property (strong) dispatch_queue_t writeQueue;
    
    // Streams
    @property (strong) NSInputStream* inputStream;
    @property (strong) NSOutputStream* outputStream;
    
    -(NSDictionary*) json;
    
    // Buffers
    -(uint8_t*) readBuffer;
    -(int) readBufferLength;
    -(uint8_t*) writeBuffer;
    -(int) writeBufferLength;
    
@end

NS_ASSUME_NONNULL_END
