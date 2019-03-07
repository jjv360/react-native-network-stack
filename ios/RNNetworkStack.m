
#import "RNNetworkStack.h"
#import <netdb.h>
#import <arpa/inet.h>
#import <React/RCTConvert.h>

@implementation RNNetworkStack
    
    -(id) init {
        self = [super init];
        
        self.activeSockets = [NSMutableDictionary dictionary];
        
        return self;
        
    }
    
    +(BOOL) requiresMainQueueSetup {
        return NO;
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
                if (nextConnection->ai_addr->sa_family == AF_INET6) {
                    struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) nextConnection->ai_addr;
                    sock.remotePort = ntohs(ipv6->sin6_port);
                } else if (nextConnection->ai_addr->sa_family == AF_INET) {
                    struct sockaddr_in* ipv4 = (struct sockaddr_in*) nextConnection->ai_addr;
                    sock.remotePort = ntohs(ipv4->sin_port);
                }
                
                // Get remote IP address
                char buffer[256] = {0};
                if (nextConnection->ai_family == AF_INET6) {
                    struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) &nextConnection->ai_addr;
                    inet_ntop(nextConnection->ai_family, (const void*) &(ipv6->sin6_addr), buffer, sizeof(buffer));
                } else if (nextConnection->ai_family == AF_INET) {
                    struct sockaddr_in* ipv4 = (struct sockaddr_in*) &nextConnection->ai_addr;
                    inet_ntop(nextConnection->ai_family, (const void*) &(ipv4->sin_addr), buffer, sizeof(buffer));
                }
                sock.remoteAddress = [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
                
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
            
            // Check how much data the user wants to read
            if (maxLength > -1) {
                
                // Read all data until the specified amount of bytes have been read
                NSString* err = [self readSocket:sock untilLength:maxLength toStream:outStream];
                if (err)
                    return reject(@"read-error", err, NULL);
                
            } else if (terminator && [RCTConvert NSString:terminator]) {
                
                // User wants to read data until the specified string data is found. Convert terminator to data
                NSData* terminatorData = [[RCTConvert NSString:terminator] dataUsingEncoding:NSUTF8StringEncoding];
                
                // Read all data until the specified terminator has been read
                NSString* err = [self readSocket:sock untilTerminator:terminatorData toStream:outStream];
                if (err)
                    return reject(@"read-error", err, NULL);
                
            } else if (terminator && [RCTConvert NSInteger:terminator]) {
                
                // User wants to read data until the specified byte is found. Convert terminator to data
                uint8_t byte = [RCTConvert NSInteger:terminator];
                NSData* terminatorData = [NSData dataWithBytes:&byte length:1];
                
                // Read all data until the specified terminator has been read
                NSString* err = [self readSocket:sock untilTerminator:terminatorData toStream:outStream];
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
                NSData* data = [outStream valueForKey:NSStreamDataWrittenToMemoryStreamKey];
                NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                [outStream close];
                return resolve(str);
                
            }
            
        });
        
    }
    
    // @private Read the socket until the specified amount of data has been read
    -(NSString*) readSocket:(RNSocket*)sock untilLength:(int)maxLength toStream:(NSOutputStream*)stream {
        
        // Read until all data has been read
        uint8_t tempBuffer[1024*512];
        int amountRead = 0;
        while (amountRead < maxLength) {
            
            // Read some data from the socket
            ssize_t amt = read(sock.fd, tempBuffer, sizeof(tempBuffer));
            if (amt == -1) {
                
                // Socket closed while we were reading from it!
                [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
                return [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding];
                
            }
            
            // Write to stream
            [stream write:tempBuffer maxLength:amt];
            amountRead += amt;
            
        }
        
        // Done
        return NULL;
        
    }
    
    // @private Read the socket until the specified terminator has been read
    -(NSString*) readSocket:(RNSocket*)sock untilTerminator:(NSData*)terminator toStream:(NSOutputStream*)stream {
        
        // Throw an error if terminator data is empty
        if (terminator.length == 0)
            return @"Terminator cannot be empty.";
        
        // Read until all data has been read
        int lastTerminatorMatch = 0;
        int amountRead = 0;
        while (true) {
            
            // Read a single byte
            uint8_t b = 0;
            ssize_t amt = read(sock.fd, &b, 1);
            if (amt == -1) {
                
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
            
        }
        
        // Done
        return NULL;
        
    }
    
    // @private Read the socket until any amount of data has been read
    -(NSString*) readAnyDataFromSocket:(RNSocket*)sock toStream:(NSOutputStream*)stream {
        
        // Read until all data has been read
        uint8_t tempBuffer[1024*512];
        
        // Read some data from the socket
        ssize_t amt = read(sock.fd, tempBuffer, sizeof(tempBuffer));
        if (amt == -1) {
            
            // Socket closed while we were reading from it!
            [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
            return [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding];
            
        }
        
        // Write to stream
        [stream write:tempBuffer maxLength:amt];
        
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
                NSString* filePath = [RCTConvert NSString:data];
                
                // Read file attributes
                NSError* err = NULL;
                NSDictionary* fileInfo = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&err];
                if (err)
                    return reject(@"file-error", err.localizedDescription, err);
                
                // Read file size
                NSNumber* fileSizeNumber = [fileInfo objectForKey:NSFileSize];
                totalSize = [fileSizeNumber longLongValue];
                
                // Open stream
                inputStream = [NSInputStream inputStreamWithFileAtPath:filePath];
                
            } else if ([RCTConvert NSString:data]) {
                
                // User wants to write some UTF8 encoded text to the socket. Create a stream for it.
                NSString* str = [RCTConvert NSString:data];
                NSData* strData = [str dataUsingEncoding:NSUTF8StringEncoding];
                inputStream = [NSInputStream inputStreamWithData:strData];
                totalSize = strData.length;
                
            } else if ([RCTConvert NSNumber:data]) {
                
                // User wants to write a single byte to the socket. Create a stream for it.
                NSNumber* num = [RCTConvert NSNumber:data];
                uint8_t byte = (uint8_t) [num intValue];
                NSData* strData = [NSData dataWithBytes:&byte length:1];
                inputStream = [NSInputStream inputStreamWithData:strData];
                totalSize = strData.length;
                
            } else {
                
                // Unknown input data type
                return reject(@"param-error", @"Unknown data format provided.", NULL);
                
            }
            
            // Start streaming the data
            long long amountRead = 0;
            uint8_t buffer[1024*512];
            while (amountRead < totalSize) {
                
                // Read data
                NSInteger amt = [inputStream read:buffer maxLength:sizeof(buffer)];
                if (amt == -1)
                    return reject(@"input-error", inputStream.streamError.localizedDescription, inputStream.streamError);
                
                // Write to socket
                ssize_t result = write(sock.fd, buffer, amt);
                if (result == -1) {
                    
                    // Socket error!
                    [self.activeSockets removeObjectForKey:[NSNumber numberWithInt:sock.identifier]];
                    return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
                    
                }
                
            }
            
            // Done
            return resolve(NULL);
            
        });
        
    }
    
    // Close the socket
    RCT_EXPORT_METHOD(socketClose:(int)identifier p:(RCTPromiseResolveBlock)resolve p:(RCTPromiseRejectBlock)reject) {
        
        // Remove the socket from our active sockets. ARC will ensure it's closed properly.
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
        
        // Get IP address
        char buffer[256] = {0};
        if (localInfo.ss_family == AF_INET6) {
            struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) &localInfo;
            inet_ntop(localInfo.ss_family, (const void*) &(ipv6->sin6_addr), buffer, sizeof(buffer));
        } else if (localInfo.ss_family == AF_INET) {
            struct sockaddr_in* ipv4 = (struct sockaddr_in*) &localInfo;
            inet_ntop(localInfo.ss_family, (const void*) &(ipv4->sin_addr), buffer, sizeof(buffer));
        }
        return [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
        
    }
    
    // Gets local port from socket
    -(int) localPort:(int)fd {
        
        // Get locally bound info
        struct sockaddr localInfo = {0};
        localInfo.sa_len = sizeof(localInfo);
        socklen_t len = sizeof(localInfo);
        if (getsockname(fd, &localInfo, &len) != 0)
            return 0;
        
        // Get port
        if (localInfo.sa_family == AF_INET6) {
            struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) &localInfo;
            return ntohs(ipv6->sin6_port);
        } else if (localInfo.sa_family == AF_INET) {
            struct sockaddr_in* ipv4 = (struct sockaddr_in*) &localInfo;
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
            if (fd == -1) {
                
                // Failed
                return reject(@"socket-error", [NSString stringWithCString:strerror(errno) encoding:NSUTF8StringEncoding], NULL);
                
            }
            
            // Got a new socket, create it
            RNSocket* sock2 = [[RNSocket alloc] init];
            sock2.fd = fd;
            
            // Get locally bound info
            sock2.localPort = [self localPort:fd];
            sock2.localAddress = [self localIP:fd];
            
            // Get remote port info
            if (addr.ss_family== AF_INET6) {
                struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) &addr;
                sock2.remotePort = ntohs(ipv6->sin6_port);
            } else if (addr.ss_family == AF_INET) {
                struct sockaddr_in* ipv4 = (struct sockaddr_in*) &addr;
                sock2.remotePort = ntohs(ipv4->sin_port);
            }
            
            // Get remote IP address
            char buffer[256] = {0};
            if (addr.ss_family == AF_INET6) {
                struct sockaddr_in6* ipv6 = (struct sockaddr_in6*) &addr;
                inet_ntop(addr.ss_family, (const void*) &(ipv6->sin6_addr), buffer, sizeof(buffer));
            } else if (addr.ss_family == AF_INET) {
                struct sockaddr_in* ipv4 = (struct sockaddr_in*) &addr;
                inet_ntop(addr.ss_family, (const void*) &(ipv4->sin_addr), buffer, sizeof(buffer));
            }
            sock2.remoteAddress = [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
            
            // Done! Store this socket in our list of active sockets
            sock2.fd = fd;
            [self.activeSockets setObject:sock2 forKey:[NSNumber numberWithInt:sock2.identifier]];
            resolve(sock2.json);
            
        });
        
    }

@end
  
