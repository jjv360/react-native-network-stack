//
//  RNSocket.m
//  RNNetworkStack
//
//  Created by Josh Fox on 2019/03/07.
//  Copyright © 2019 Facebook. All rights reserved.
//

#import "RNSocket.h"

static int nextSocketID = 0;

@implementation RNSocket
    
-(id) init {
    self = [super init];
    
    // Create ID
    self.identifier = ++nextSocketID;
    self.fd = -1;
    self.fd6 = -1;
    self.localAddress = @"";
    self.remoteAddress = @"";
    
    // Create queues
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    self.readQueue = dispatch_queue_create([[NSString stringWithFormat:@"RNNetworkStack read %i", self.identifier] cStringUsingEncoding:NSUTF8StringEncoding], attr);
    self.writeQueue = dispatch_queue_create([[NSString stringWithFormat:@"RNNetworkStack write %i", self.identifier] cStringUsingEncoding:NSUTF8StringEncoding], attr);
    
    // Done
    return self;
    
}

-(void) dealloc {
    
    // If we still have an active socket, close it
    if (self.fd != -1)
        close(self.fd);
    
    // Close any active IPv6 socket as well
    if (self.fd6 != -1)
        close(self.fd6);
    
}

-(NSDictionary*) json {
    
    // Create dict
    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
    [dict setObject:[NSNumber numberWithInt:self.identifier] forKey:@"id"];
    [dict setObject:self.localAddress forKey:@"localAddress"];
    [dict setObject:self.remoteAddress forKey:@"remoteAddress"];
    [dict setObject:[NSNumber numberWithInt:self.localPort] forKey:@"localPort"];
    [dict setObject:[NSNumber numberWithInt:self.remotePort] forKey:@"remotePort"];
    return dict;
    
}
    
// Get read buffer
-(uint8_t*) readBuffer {
    return readBuffer;
}
    
-(int) readBufferLength {
    return SOCK_BUFFER_SIZE;
}
    
// Get write buffer
-(uint8_t*) writeBuffer {
    return writeBuffer;
}
    
-(int) writeBufferLength {
    return SOCK_BUFFER_SIZE;
}

@end
