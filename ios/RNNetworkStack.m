
#import "RNNetworkStack.h"
#import <netdb.h>
#import <arpa/inet.h>

@implementation RNNetworkStack

-(id) init {
    self = [super init];
    
    self.activeSockets = [NSMutableDictionary dictionary];
    
    return self;
    
}

+(BOOL) requiresMainQueueSetup {
    return NO;
}

-(NSArray<NSString*>*)supportedEvents {
    return @[@"net.read", @"net.write"];
}

RCT_EXPORT_MODULE();

// Connects to the host and resolves the promise
RCT_EXPORT_METHOD(tcpConnect:(NSString*)host port:(int)port resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    
    // Create and store socket
    RNSocket* sock = [[RNSocket alloc] init];
    
    // Do on background thread
    dispatch_async(sock.writeQueue, ^{
        
        // Create a struct describing the host/service we want to connect to
        struct addrinfo searchInfo = {0};
        searchInfo.ai_family = AF_UNSPEC;           // IPv4 or IPv6, we don't care
        searchInfo.ai_socktype = SOCK_STREAM;       // TCP connection please
        searchInfo.ai_flags = AI_V4MAPPED           // If only IPv6 is on this device and target is IPv4, give us a IPv6-to-IPv4 mapped address
        | AI_ADDRCONFIG                         // Only give us addresses that we have the hardware to connect to
        | AI_NUMERICSERV;                       // Our service is a numeric port number, not a "named" service
        
        // Fetch info describing how we should connect to this remote host
        const char* cHost = [host cStringUsingEncoding:NSUTF8StringEncoding];
        const char* cPort = [[NSString stringWithFormat:@"%i", port] cStringUsingEncoding:NSUTF8StringEncoding];
        struct addrinfo* connectionInfo;
        int result = getaddrinfo(cHost, cPort, &searchInfo, &connectionInfo);
        if (result != 0)
        return reject(@"invalid_host", [NSString stringWithCString:gai_strerror(result) encoding:NSUTF8StringEncoding], NULL);
        
        // Attempt to connect to each connection method in the list
        struct addrinfo* nextConnection = connectionInfo;
        int lastError = 0;
        while (nextConnection != NULL) {
            
            // Create socket
            int fd = socket(nextConnection->ai_family, nextConnection->ai_socktype, nextConnection->ai_protocol);
            if (fd == -1) {
                
                // Failed, try next one
                nextConnection = nextConnection->ai_next;
                lastError = errno;
                continue;
                
            }
            
            // Disable SIGPIPE
            int value = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, sizeof(value));
            
            // Socket created. Try to connect to remote device.
            result = connect(fd, nextConnection->ai_addr, nextConnection->ai_addrlen);
            if (fd == -1) {
                
                // Failed, try next one
                nextConnection = nextConnection->ai_next;
                close(fd);
                lastError = errno;
                continue;
                
            }
            
            // Get locally bound info
            sock.localPort = [self localPort:fd];
            sock.localAddress = [self localIP:fd];
            
            // Get remote port info
            sock.remoteAddress = [self ipFromAddr:(struct sockaddr*) nextConnection->ai_addr];
            sock.remotePort = [self portFromAddr:(struct sockaddr*) nextConnection->ai_addr];
            
            // Connected! Free memory
            freeaddrinfo(connectionInfo);
            
            // Store this socket in our list of active sockets
            sock.fd = fd;
            [self.activeSockets setObject:sock forKey:[NSNumber numberWithInt:sock.identifier]];
            resolve(sock.json);
            return;
            
        }
        
        // After all our attempts, we still don't have a valid connection. Return failure
        reject(@"connection_error", [NSString stringWithCString:strerror(lastError) encoding:NSUTF8StringEncoding], NULL);
        freeaddrinfo(connectionInfo);
        
    });
    
}

RCT_EXPORT_METHOD(tcpRead:(int)identifier
                  p1:(id)terminator
                  p2:(int)maxLength
                  p3:(NSString*)saveTo
                  p4:(BOOL)skip
                  p5:(NSString*)progressID
                  p6:(RCTPromiseResolveBlock)resolve
                  p7:(RCTPromiseRejectBlock)reject) {
    
    // Find socket
    RNSocket* sock = [self.activeSockets objectForKey:[NSNumber numberWithInt:identifier]];
    if (!sock)
    return reject(@"socket-closed", @"This socket has been closed.", NULL);
    
    // Do on background thread
    dispatch_async(sock.readQueue, ^{
        
        // Create appropriate output stream
        NSOutputStream* outStream;
        if (saveTo && saveTo.length > 0) {
            
            // User wants to save to a file, make sure directory exists first
            NSError* err = NULL;
            [[NSFileManager defaultManager] createDirectoryAtPath:saveTo.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&err];
            if (err)
            return reject(@"file-error", err.localizedDescription, err);
            
            // Create file output stream
            outStream = [NSOutputStream outputStreamToFileAtPath:saveTo append:NO];
            
        } else {
            
            // User wants the data
            outStream = [NSOutputStream outputStreamToMemory];
            
        }
        
        // Open output stream
        [outStream open];
        
        // Check how much data the user wants to read
        if (maxLength > -1) {
            
            // Read all data until the specified amount of bytes have been read
            NSString* err = [self readSocket:sock untilLength:maxLength toStream:outStream withProgress:^(long amount) {
                if (progressID.length > 0) [self sendEventWithName:@"net.read" body:[NSString stringWithFormat:@"%@|%li", progressID, amount]];
            }];
            if (err)
            return reject(@"read-error", err, NULL);
            
        } else if ([terminator isKindOfClass:[NSString class]]) {
            
            // User wants to read data until the specified string data is found. Convert terminator to data
            NSString* terminatorStr = terminator;
            NSData* terminatorData = [terminatorStr dataUsingEncoding:NSUTF8StringEncoding];
            
            // Read all data until the specified terminator has been read
            NSString* err = [self readSocket:sock untilTerminator:terminatorData toStream:outStream withProgress:^(long amount) {
                if (progressID.length > 0) [self sendEventWithName:@"net.read" body:[NSString stringWithFormat:@"%@|%li", progressID, amount]];
            }];
            if (err)
            return reject(@"read-error", err, NULL);
            
        } else if ([terminator isKindOfClass:[NSNumber class]]) {
            
            // User wants to read data until the specified byte is found. Convert terminator to data
            NSNumber* terminatorNum = terminator;
            int num = [terminatorNum intValue];
            if (num < 0 || num > 255) return reject(@"input-error", @"The terminator byte you provided was too big.", NULL);
            uint8_t byte = (uint8_t) num;
            NSData* terminatorData = [NSData dataWithBytes:&byte length:1];
            
            // Read all data until the specified terminator has been read
            NSString* err = [self readSocket:sock untilTerminator:terminatorData toStream:outStream withProgress:^(long amount) {
                if (progressID.length > 0) [self sendEventWithName:@"net.send" body:[NSString stringWithFormat:@"%@|%li", progressID, amount]];
            }];
            if (err)
            return reject(@"read-error", err, NULL);
            
        } else if (terminator) {
            
            // Unknown data type for the terminator
            return reject(@"param-error", @"Unknown data type provided for the terminator.", NULL);
            
        } else {
            
            // The user just wants a packet of data, they don't care how much they get
            NSString* err = [self readAnyDataFromSocket:sock toStream:outStream];
            if (err)
            return reject(@"read-error", err, NULL);
            
        }
        
        // Check if the user was saving to a file or not
        if (saveTo && saveTo.length > 0) {
            
            // We are done
            [outStream close];
            return resolve(NULL);
            
        } else {
            
            // User wants text output, return it to them as UTF8
            NSData* data = [outStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
            NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            [outStream close];
            return resolve(str);
            
        }
        
    });
    
}

// @private Read the socket until the specified amount of data has been read
-(NSString*) readSocket:(RNSocket*)sock untilLength:(long)maxLength toStream:(NSOutputStream*)stream withProgress:(void(^)(long amount))progress {
    
    // Read until all data has been read
    long amountRead = 0;
    NSTimeInterval lastNotify = 0;
    while (amountRead < maxLength) {
        
        // Read some data from the socket
        ssize_t amt = read(sock.fd, sock.readBuffer, MIN(sock.readBufferLength, maxLength - amountRead));
        if (amt == -1) {
            
            // Socket closed while we were reading from it!
            [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
            return [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding];
            
        }
        
        // Write to stream
        [stream write:sock.readBuffer maxLength:amt];
        amountRead += amt;
        
        // Notify
        if (NSDate.timeIntervalSinceReferenceDate - lastNotify > 0.5) {
            progress(amountRead);
            lastNotify = NSDate.timeIntervalSinceReferenceDate;
        }
        
    }
    
    // Done
    return NULL;
    
}

// @private Read the socket until the specified terminator has been read
-(NSString*) readSocket:(RNSocket*)sock untilTerminator:(NSData*)terminator toStream:(NSOutputStream*)stream withProgress:(void(^)(long amount))progress {
    
    // Throw an error if terminator data is empty
    if (terminator.length == 0)
    return @"Terminator cannot be empty.";
    
    // Read until all data has been read
    int lastTerminatorMatch = 0;
    int amountRead = 0;
    NSTimeInterval lastNotify = 0;
    while (true) {
        
        // Read a single byte
        uint8_t b = 0;
        ssize_t amt = read(sock.fd, &b, 1);
        if (amt == -1 || amt == 0) {
            
            // Socket closed while we were reading from it!
            [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
            return [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding];
            
        }
        
        // Check if this one matches our next desired terminator byte
        if (((uint8_t*) terminator.bytes)[lastTerminatorMatch] == b) {
            
            // It does match, increase terminator index
            lastTerminatorMatch += 1;
            amountRead += 1;
            
            // If all terminator bytes have been matched, stop
            if (lastTerminatorMatch >= terminator.length)
            break;
            
        } else {
            
            // No match, put this char into main buffer
            [stream write:&b maxLength:1];
            amountRead += 1;
            
            // Put any items we thought were part of the terminator, into the main buffer
            for (int i = 0 ; i < lastTerminatorMatch ; i++)
            [stream write:&((uint8_t*) terminator.bytes)[i] maxLength:1];
            
            // Reset count
            amountRead += lastTerminatorMatch;
            lastTerminatorMatch = 0;
            
        }
        
        // Notify
        if (NSDate.timeIntervalSinceReferenceDate - lastNotify > 0.5) {
            progress(amountRead);
            lastNotify = NSDate.timeIntervalSinceReferenceDate;
        }
        
    }
    
    // Done
    return NULL;
    
}

// @private Read the socket until any amount of data has been read
-(NSString*) readAnyDataFromSocket:(RNSocket*)sock toStream:(NSOutputStream*)stream {
    
    // Read some data from the socket
    ssize_t amt = read(sock.fd, sock.readBuffer, sock.readBufferLength);
    if (amt == -1) {
        
        // Socket closed while we were reading from it!
        [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
        return [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding];
        
    }
    
    // Write to stream
    [stream write:sock.readBuffer maxLength:amt];
    
    // Done
    return NULL;
    
}

// Writes data to the socket
RCT_EXPORT_METHOD(tcpWrite:(int)identifier p1:(id)data p2:(BOOL)isFile p3:(NSString*)progressID p4:(RCTPromiseResolveBlock)resolve p5:(RCTPromiseRejectBlock)reject) {
    
    // Find socket
    RNSocket* sock = [self.activeSockets objectForKey:[NSNumber numberWithInt:identifier]];
    if (!sock)
    return reject(@"socket-closed", @"This socket has been closed.", NULL);
    
    // Do on background thread
    dispatch_async(sock.writeQueue, ^{
        
        // Get input stream to read data from
        NSInputStream* inputStream;
        long long totalSize = 0;
        if (isFile) {
            
            // User wants to write the data in the specified file to the socket. Open the file.
            NSString* filePath = data;
            
            // Read file attributes
            // HACK: iOS 13 crashes when this is called on a background thread, so do this on the main thread
            __block NSError* err = NULL;
            __block NSDictionary* fileInfo = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{
                fileInfo = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&err];
            });
            if (err)
                return reject(@"file-error", err.localizedDescription, err);
            
            // Read file size
            NSNumber* fileSizeNumber = [fileInfo objectForKey:NSFileSize];
            totalSize = [fileSizeNumber longLongValue];
            
            // Open stream
            inputStream = [NSInputStream inputStreamWithFileAtPath:filePath];
            
        } else if ([data isKindOfClass:[NSString class]]) {
            
            // User wants to write some UTF8 encoded text to the socket. Create a stream for it.
            NSString* str = data;
            NSData* strData = [str dataUsingEncoding:NSUTF8StringEncoding];
            inputStream = [NSInputStream inputStreamWithData:strData];
            totalSize = strData.length;
            
        } else if ([data isKindOfClass:[NSNumber class]]) {
            
            // User wants to write a single byte to the socket. Create a stream for it.
            NSNumber* num = data;
            uint8_t byte = (uint8_t) [num intValue];
            NSData* strData = [NSData dataWithBytes:&byte length:1];
            inputStream = [NSInputStream inputStreamWithData:strData];
            totalSize = strData.length;
            
        } else {
            
            // Unknown input data type
            return reject(@"param-error", @"Unknown data format provided.", NULL);
            
        }
        
        // Open stream
        [inputStream open];
        
        // Start streaming the data
        long long amountRead = 0;
        NSTimeInterval lastNotify = 0;
        while (amountRead < totalSize) {
            
            // Read data
            NSInteger amt = [inputStream read:sock.writeBuffer maxLength:MIN(sock.writeBufferLength, totalSize - amountRead)];
            if (amt <= 0 && inputStream.streamError)
                return reject(@"input-error", inputStream.streamError.localizedDescription , inputStream.streamError);
            else if (amt <= 0)
                return reject(@"input-error", @"Input stream ended prematurely." , NULL);
            
            // Write to socket
            ssize_t result = write(sock.fd, sock.writeBuffer, amt);
            if (result >= 0 && result != amt) {
                
                // Buffer error!
                [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
                return reject(@"socket-error", @"Unable to send entire buffer to the remote device.", NULL);
                
            } else if (result < 0) {
                
                // Socket error!
                [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
                return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
                
            }
            
            // Increase counter
            amountRead += amt;
            
            // Notify
            if (progressID.length > 0 && NSDate.timeIntervalSinceReferenceDate - lastNotify > 0.5) {
                [self sendEventWithName:@"net.write" body:[NSString stringWithFormat:@"%@|%lli", progressID, amountRead]];
                lastNotify = NSDate.timeIntervalSinceReferenceDate;
            }
            
        }
        
        // Close stream
        [inputStream close];
        
        // Done
        return resolve(NULL);
        
    });
    
}

// Close the socket
RCT_EXPORT_METHOD(socketClose:(int)identifier p:(RCTPromiseResolveBlock)resolve p:(RCTPromiseRejectBlock)reject) {
    
    // Find socket - if not found, socket is already closed
    RNSocket* sock = [self.activeSockets objectForKey:[NSNumber numberWithInt:identifier]];
    if (!sock)
        return resolve(NULL);
    
    // Close it
    [sock close];
    
    // Remove the socket from our active sockets.
    [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:identifier]];
    resolve(NULL);
    
}

// Creates a socket which can accept incoming connections
RCT_EXPORT_METHOD(tcpListen:(NSString*)host port:(int)port resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    
    // Create and store socket
    RNSocket* sock = [[RNSocket alloc] init];
    
    // Do on background thread
    dispatch_async(sock.writeQueue, ^{
        
        // Create a struct describing the host/service we want to connect to
        struct addrinfo searchInfo = {0};
        searchInfo.ai_family = AF_INET;         // IPv4 only for now, support IPv6?
        searchInfo.ai_socktype = SOCK_STREAM;   // TCP connection please
        searchInfo.ai_flags = AI_V4MAPPED       // If only IPv6 is on this device and target is IPv4, give us a IPv6-to-IPv4 mapped address
        | AI_ADDRCONFIG                     // Only give us addresses that we have the hardware to connect to
        | AI_NUMERICSERV                    // Our service is a numeric port number, not a "named" service
        | AI_PASSIVE;                       // We want to bind to this socket
        
        // Fetch info describing how we should connect to this remote host
        const char* cHost = [host isEqualToString:@"0.0.0.0"] ? NULL : [host cStringUsingEncoding:NSUTF8StringEncoding];
        const char* cPort = [[NSString stringWithFormat:@"%i", port] cStringUsingEncoding:NSUTF8StringEncoding];
        struct addrinfo* connectionInfo;
        int result = getaddrinfo(cHost, cPort, &searchInfo, &connectionInfo);
        if (result != 0)
        return reject(@"invalid_host", [NSString stringWithCString:gai_strerror(result) encoding:NSUTF8StringEncoding], NULL);
        
        // Create IPv4 socket
        int fd = socket(connectionInfo->ai_family, connectionInfo->ai_socktype, connectionInfo->ai_protocol);
        if (fd == -1) {
            
            // Failed
            freeaddrinfo(connectionInfo);
            return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
            
        }
        
        // Disable SIGPIPE
        int value = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, sizeof(value));
        
        // Bind it
        result = bind(fd, connectionInfo->ai_addr, connectionInfo->ai_addrlen);
        if (result == -1) {
            
            // Failed
            close(fd);
            freeaddrinfo(connectionInfo);
            return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
            
        }
        
        // Start listening on it
        result = listen(fd, 8);
        if (result == -1) {
            
            // Failed
            close(fd);
            freeaddrinfo(connectionInfo);
            return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
            
        }
        
        // Get locally bound info
        sock.localPort = [self localPort:fd];
        sock.localAddress = [self localIP:fd];
        
        // Done! Store this socket in our list of active sockets
        sock.fd = fd;
        [self.activeSockets setObject:sock forKey:[NSNumber numberWithInt:sock.identifier]];
        resolve(sock.json);
        
        // Free memory
        freeaddrinfo(connectionInfo);
        return;
        
    });
    
}

// Gets local IP address from socket
-(NSString*) localIP:(int)fd {
    
    // Get locally bound info
    struct sockaddr_storage localInfo = {0};
    socklen_t len = sizeof(localInfo);
    if (getsockname(fd, (struct sockaddr*) &localInfo, &len) != 0)
    return @"";
    else
    return [self ipFromAddr:(struct sockaddr*) &localInfo];
    
}

// IP address from sockaddr structure
-(NSString*) ipFromAddr:(struct sockaddr*)addr {
    
    // Get address bytes
    const void* bytes = NULL;
    if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) addr;
        bytes = (const void*) &(ipv6->sin6_addr);
    } else if (addr->sa_family == AF_INET) {
        struct sockaddr_in* ipv4 = (struct sockaddr_in*) addr;
        bytes = (const void*) &(ipv4->sin_addr);
    }
    
    // Convert to human-readable string
    char buffer[256] = {0};
    inet_ntop(addr->sa_family, bytes, buffer, sizeof(buffer));
    return [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
    
}

// Gets local port from socket
-(int) localPort:(int)fd {
    
    // Get locally bound info
    struct sockaddr_storage localInfo = {0};
    socklen_t len = sizeof(localInfo);
    if (getsockname(fd, (struct sockaddr*) &localInfo, &len) != 0)
    return 0;
    
    // Get port
    if (localInfo.ss_family == AF_INET6) {
        struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) &localInfo;
        return ntohs(ipv6->sin6_port);
    } else if (localInfo.ss_family == AF_INET) {
        struct sockaddr_in* ipv4 = (struct sockaddr_in*) &localInfo;
        return ntohs(ipv4->sin_port);
    } else {
        return 0;
    }
    
}

// IP address from sockaddr structure
-(int) portFromAddr:(struct sockaddr*)addr {
    
    // Get port
    if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) addr;
        return ntohs(ipv6->sin6_port);
    } else if (addr->sa_family == AF_INET) {
        struct sockaddr_in* ipv4 = (struct sockaddr_in*) addr;
        return ntohs(ipv4->sin_port);
    } else {
        return 0;
    }
    
}

// Accepts an incoming connection
RCT_EXPORT_METHOD(tcpAccept:(int)identifier p4:(RCTPromiseResolveBlock)resolve p5:(RCTPromiseRejectBlock)reject) {
    
    // Find socket
    RNSocket* sock = [self.activeSockets objectForKey:[NSNumber numberWithInt:identifier]];
    if (!sock)
    return reject(@"socket-closed", @"This socket has been closed.", NULL);
    
    // Do on background thread
    dispatch_async(sock.readQueue, ^{
        
        // Accept a connection
        struct sockaddr_storage addr = {0};
        socklen_t size = sizeof(addr);
        int fd = accept(sock.fd, (struct sockaddr*) &addr, &size);
        if (fd == -1)
        return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
        
        // Disable SIGPIPE
        int value = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, sizeof(value));
        
        // Got a new socket, create it
        RNSocket* sock2 = [[RNSocket alloc] init];
        sock2.fd = fd;
        
        // Get locally bound info
        sock2.localPort = [self localPort:fd];
        sock2.localAddress = [self localIP:fd];
        
        // Get remote port info
        sock2.remoteAddress = [self ipFromAddr:(struct sockaddr*) &addr];
        sock2.remotePort = [self portFromAddr:(struct sockaddr*) &addr];
        
        // Done! Store this socket in our list of active sockets
        sock2.fd = fd;
        [self.activeSockets setObject:sock2 forKey:[NSNumber numberWithInt:sock2.identifier]];
        resolve(sock2.json);
        
    });
    
}

// Connects to the host and resolves the promise
RCT_EXPORT_METHOD(udpBind:(int)port p:(BOOL)broadcast p:(BOOL)reuse resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    
    // Create and store socket
    RNSocket* sock = [[RNSocket alloc] init];
    
    // Do on background thread
    dispatch_async(sock.writeQueue, ^{
        
        // Create a struct describing the host/service we want to connect to
        struct addrinfo searchInfo = {0};
        searchInfo.ai_family = AF_UNSPEC;       // IPv4 or IPv6, we don't care
        searchInfo.ai_socktype = SOCK_DGRAM;    // UDP connection please
        searchInfo.ai_flags = AI_V4MAPPED       // If only IPv6 is on this device and target is IPv4, give us a IPv6-to-IPv4 mapped address
        | AI_ADDRCONFIG                         // Only give us addresses that we have the hardware to connect to
        | AI_NUMERICSERV                        // Our service is a numeric port number, not a "named" service
        | AI_PASSIVE;                           // We want to bind to this socket
        
        // Fetch info describing how we should bind to the local adapter
        const char* cHost = [@"0.0.0.0" cStringUsingEncoding:NSUTF8StringEncoding];
        const char* cPort = [[NSString stringWithFormat:@"%i", port] cStringUsingEncoding:NSUTF8StringEncoding];
        struct addrinfo* connectionInfo;
        int result = getaddrinfo(cHost, cPort, &searchInfo, &connectionInfo);
        if (result != 0)
        return reject(@"invalid_host", [NSString stringWithCString:gai_strerror(result) encoding:NSUTF8StringEncoding], NULL);
        
        // Create socket
        int fd = socket(connectionInfo->ai_family, connectionInfo->ai_socktype, connectionInfo->ai_protocol);
        if (fd == -1) {
            
            // Failed
            freeaddrinfo(connectionInfo);
            return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
            
        }
        
        // Disable SIGPIPE
        int value = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, sizeof(value));
        
        // Set broadcast flag if needed
        if (broadcast) {
            
            int val = 1;
            result = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &val, sizeof(val));
            if (result == -1) {
                
                // Failed
                close(fd);
                freeaddrinfo(connectionInfo);
                return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
                
            }
            
        }
        
        // Set reuse flag if needed
        if (reuse) {
            
            int val = 1;
            result = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, sizeof(val));
            if (result == -1) {
                
                // Failed
                close(fd);
                freeaddrinfo(connectionInfo);
                return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
                
            }
            
            val = 1;
            result = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &val, sizeof(val));
            if (result == -1) {
                
                // Failed
                close(fd);
                freeaddrinfo(connectionInfo);
                return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
                
            }
            
        }
        
        // Socket created. Try to connect to remote device.
        result = bind(fd, connectionInfo->ai_addr, connectionInfo->ai_addrlen);
        if (result == -1) {
            
            // Failed
            close(fd);
            freeaddrinfo(connectionInfo);
            return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
            
        }
        
        // Get locally bound info
        sock.localPort = [self localPort:fd];
        sock.localAddress = [self localIP:fd];
        
        // Connected! Free memory
        freeaddrinfo(connectionInfo);
        
        // Store this socket in our list of active sockets
        sock.fd = fd;
        [self.activeSockets setObject:sock forKey:[NSNumber numberWithInt:sock.identifier]];
        resolve(sock.json);
        
    });
    
}

// Read from a UDP socket
RCT_EXPORT_METHOD(udpRead:(int)identifier resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    
    // Find socket
    RNSocket* sock = [self.activeSockets objectForKey:[NSNumber numberWithInt:identifier]];
    if (!sock)
    return reject(@"socket-closed", @"This socket has been closed.", NULL);
    
    // Do on background thread
    dispatch_async(sock.readQueue, ^{
        
        // Read some data from the socket
        struct sockaddr_storage source = {0};
        socklen_t size = sizeof(source);
        ssize_t amt = recvfrom(sock.fd, sock.readBuffer, sock.readBufferLength, 0, (struct sockaddr*) &source, &size);
        if (amt == -1) {
            
            // Socket closed while we were reading from it!
            [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
            return reject(@"socket-closed", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
            
        }
        
        // Construct response
        NSMutableDictionary* dict = [NSMutableDictionary dictionary];
        [dict setObject:[self ipFromAddr:(struct sockaddr*) &source] forKey:@"senderAddress"];
        [dict setObject:[NSNumber numberWithInt:[self portFromAddr:(struct sockaddr*) &source]] forKey:@"senderPort"];
        
        // Convert data to requested type (only UTF8 supported for now)
        NSData* data = [NSData dataWithBytes:sock.readBuffer length:amt];
        [dict setObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] forKey:@"data"];
        
        // Done
        return resolve(dict);
        
    });
    
}

// Send data via UDP
RCT_EXPORT_METHOD(udpSend:(int)identifier p:(NSString*)address p:(int)port p:(NSString*)data p:(RCTPromiseResolveBlock)resolve p:(RCTPromiseRejectBlock)reject) {
    
    // Find socket
    RNSocket* sock = [self.activeSockets objectForKey:[NSNumber numberWithInt:identifier]];
    if (!sock)
    return reject(@"socket-closed", @"This socket has been closed.", NULL);
    
    // Do on background thread
    dispatch_async(sock.writeQueue, ^{
        
        // Create a struct describing the host/service we want to connect to
        struct addrinfo searchInfo = {0};
        searchInfo.ai_family = AF_UNSPEC;           // IPv4 or IPv6, we don't care
        searchInfo.ai_socktype = SOCK_DGRAM;        // UDP connection please
        searchInfo.ai_flags = AI_V4MAPPED           // If only IPv6 is on this device and target is IPv4, give us a IPv6-to-IPv4 mapped address
        | AI_ADDRCONFIG                             // Only give us addresses that we have the hardware to connect to
        | AI_NUMERICSERV;                           // Our service is a numeric port number, not a "named" service
        
        // Fetch info describing how we should connect to this remote host
        const char* cHost = [address cStringUsingEncoding:NSUTF8StringEncoding];
        const char* cPort = [[NSString stringWithFormat:@"%i", port] cStringUsingEncoding:NSUTF8StringEncoding];
        struct addrinfo* connectionInfo;
        int result = getaddrinfo(cHost, cPort, &searchInfo, &connectionInfo);
        if (result != 0)
        return reject(@"invalid_host", [NSString stringWithCString:gai_strerror(result) encoding:NSUTF8StringEncoding], NULL);
        
        // Convert data to our required format (only UTF8 supported for now)
        NSData* dataBuffer = [data dataUsingEncoding:NSUTF8StringEncoding];
        
        // Send data
        ssize_t amt = sendto(sock.fd, dataBuffer.bytes, dataBuffer.length, 0, connectionInfo->ai_addr, connectionInfo->ai_addrlen);
        if (amt == -1)
        return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
        
        // Done
        return resolve([NSNumber numberWithLongLong:amt]);
        
    });
    
}

// Join a multicast group
RCT_EXPORT_METHOD(udpJoin:(int)identifier p:(NSString*)address p:(RCTPromiseResolveBlock)resolve p:(RCTPromiseRejectBlock)reject) {
    
    // Find socket
    RNSocket* sock = [self.activeSockets objectForKey:[NSNumber numberWithInt:identifier]];
    if (!sock)
    return reject(@"socket-closed", @"This socket has been closed.", NULL);
    
    // Do on background thread
    dispatch_async(sock.writeQueue, ^{
        
        // Get locally bound info
        struct sockaddr_storage localInfo = {0};
        socklen_t len = sizeof(localInfo);
        if (getsockname(sock.fd, (struct sockaddr*) &localInfo, &len) != 0)
        return reject(@"invalid-socket", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
        
        // Create a struct describing the host info we want to join
        struct addrinfo searchInfo = {0};
        searchInfo.ai_family = localInfo.ss_family; // Same IP family as our socket is bound to
        searchInfo.ai_socktype = SOCK_DGRAM;        // UDP connection please
        searchInfo.ai_flags = AI_V4MAPPED           // If only IPv6 is on this device and target is IPv4, give us a IPv6-to-IPv4 mapped address
        | AI_ADDRCONFIG;                            // Only give us addresses that we have the hardware to connect to
        
        // Fetch IP address info
        const char* cHost = [address cStringUsingEncoding:NSUTF8StringEncoding];
        struct addrinfo* connectionInfo;
        int result = getaddrinfo(cHost, NULL, &searchInfo, &connectionInfo);
        if (result != 0)
        return reject(@"invalid_host", [NSString stringWithCString:gai_strerror(result) encoding:NSUTF8StringEncoding], NULL);
        
        // Check if IPv4 or IPv6
        if (connectionInfo->ai_family == AF_INET6) {
            
            // Create group membership structre
            struct sockaddr_in6* addr6 = (struct sockaddr_in6*) connectionInfo->ai_addr;
            struct ipv6_mreq mreq = {0};
            mreq.ipv6mr_multiaddr = addr6->sin6_addr;
            
            // Join group
            result = setsockopt(sock.fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq, sizeof(mreq));
            
        } else {
            
            // Create group membership structre
            struct sockaddr_in* addr = (struct sockaddr_in*) connectionInfo->ai_addr;
            struct ip_mreq mreq = {0};
            mreq.imr_multiaddr = addr->sin_addr;
            
            // Join group
            result = setsockopt(sock.fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq));
            
        }
        
        // Check response
        freeaddrinfo(connectionInfo);
        if (result == -1)
        return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
        
        // Done
        return resolve(NULL);
        
    });
    
}

// Leave a multicast group
RCT_EXPORT_METHOD(udpLeave:(int)identifier p:(NSString*)address p:(RCTPromiseResolveBlock)resolve p:(RCTPromiseRejectBlock)reject) {
    
    // Find socket
    RNSocket* sock = [self.activeSockets objectForKey:[NSNumber numberWithInt:identifier]];
    if (!sock)
    return reject(@"socket-closed", @"This socket has been closed.", NULL);
    
    // Do on background thread
    dispatch_async(sock.writeQueue, ^{
        
        // Get locally bound info
        struct sockaddr_storage localInfo = {0};
        socklen_t len = sizeof(localInfo);
        if (getsockname(sock.fd, (struct sockaddr*) &localInfo, &len) != 0)
        return reject(@"invalid-socket", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
        
        // Create a struct describing the host info we want to join
        struct addrinfo searchInfo = {0};
        searchInfo.ai_family = localInfo.ss_family; // Same IP family as our socket is bound to
        searchInfo.ai_socktype = SOCK_DGRAM;        // UDP connection please
        searchInfo.ai_flags = AI_V4MAPPED           // If only IPv6 is on this device and target is IPv4, give us a IPv6-to-IPv4 mapped address
        | AI_ADDRCONFIG;                            // Only give us addresses that we have the hardware to connect to
        
        // Fetch IP address info
        const char* cHost = [address cStringUsingEncoding:NSUTF8StringEncoding];
        struct addrinfo* connectionInfo;
        int result = getaddrinfo(cHost, NULL, &searchInfo, &connectionInfo);
        if (result != 0)
        return reject(@"invalid_host", [NSString stringWithCString:gai_strerror(result) encoding:NSUTF8StringEncoding], NULL);
        
        // Check if IPv4 or IPv6
        if (connectionInfo->ai_family == AF_INET6) {
            
            // Create group membership structre
            struct sockaddr_in6* addr6 = (struct sockaddr_in6*) connectionInfo->ai_addr;
            struct ipv6_mreq mreq = {0};
            mreq.ipv6mr_multiaddr = addr6->sin6_addr;
            
            // Leave group
            result = setsockopt(sock.fd, IPPROTO_IPV6, IPV6_LEAVE_GROUP, &mreq, sizeof(mreq));
            
        } else {
            
            // Create group membership structre
            struct sockaddr_in* addr = (struct sockaddr_in*) connectionInfo->ai_addr;
            struct ip_mreq mreq = {0};
            mreq.imr_multiaddr = addr->sin_addr;
            
            // Leave group
            result = setsockopt(sock.fd, IPPROTO_IP, IP_DROP_MEMBERSHIP, &mreq, sizeof(mreq));
            
        }
        
        // Check response
        freeaddrinfo(connectionInfo);
        if (result == -1)
        return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
        
        // Done
        return resolve(NULL);
        
    });
    
}

@end

