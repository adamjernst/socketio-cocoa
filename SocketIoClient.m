//
//  SocketIoClient.m
//  SocketIoCocoa
//
//  Created by Fred Potter on 11/11/10.
//  Copyright 2010 Fred Potter. All rights reserved.
//

#import "SocketIoClient.h"
#import "WebSocket.h"

@interface SocketIoClient (FP_Private) <WebSocketDelegate>
- (void)log:(NSString *)message;
- (NSString *)encode:(NSArray *)messages;
- (void)onDisconnect;
- (void)onError:(NSError *)error;
- (void)notifyMessagesSent:(NSArray *)messages;
@end

@implementation SocketIoClient

@synthesize sessionId = _sessionId, delegate = _delegate, connectTimeout = _connectTimeout, 
            heartbeatTimeout = _heartbeatTimeout, isConnecting = _isConnecting, 
            isConnected = _isConnected, host = _host, port = _port;

- (id)initWithHost:(NSString *)host port:(NSInteger)port {
  if (self = [super init]) {
    _host = [host retain];
    _port = port;
    _queue = [[NSMutableArray array] retain];
    
    _connectTimeout = 5.0;
    _heartbeatTimeout = 15.0;
    
    NSString *URL = [NSString stringWithFormat:@"ws://%@:%d/socket.io/websocket",
                     _host,
                     _port];
    _webSocket = [[WebSocket alloc] initWithURLString:URL delegate:self];
  }
  return self;
}

- (void)dealloc {
  [_host release];
  [_queue release];
  [_webSocket release];
  self.sessionId = nil;
  
  [super dealloc];
}

- (void)checkIfConnected {
  if (!_isConnected) {
    [self onError:[NSError errorWithDomain:SocketIoClientErrorDomain 
                                      code:SocketIoClientErrorConnectionTimeout
                                  userInfo:nil]];
    [self disconnect];
  }
}

- (void)connect {
  if (!_isConnected) {
    
    if (_isConnecting) {
      [self disconnect];
    }
    
    _isConnecting = YES;
    
    [_webSocket open];
    
    if (_connectTimeout > 0.0) {
      [self performSelector:@selector(checkIfConnected) withObject:nil afterDelay:_connectTimeout];
    }
  }
}

- (void)disconnect {
  [self log:@"Disconnect"];
  // Close the underlying websocket, if it's connected, which should trigger
  // -webSocketDidClose: when the disconnection is completed (which will in turn
  // call onDisconnect).
  // If the socket is not connected, just do the bookkeeping by calling 
  // -onDisconnect.
  // Note that [_webSocket connected] is not the same as our ivar _isConnected;
  // the latter waits for the Socketio handshake.
  if ([_webSocket connected]) {
    [_webSocket close];
  } else {
    [self onDisconnect];
  }
}

- (void)send:(NSString *)data isJSON:(BOOL)isJSON {
  [self log:[NSString stringWithFormat:@"Sending %@:\n%@", isJSON ? @"JSON" : @"TEXT", data]];
  
  NSDictionary *message = [NSDictionary dictionaryWithObjectsAndKeys:
                           data,
                           @"data",
                           isJSON ? @"json" : @"text",
                           @"type",
                           nil];
  
  if (!_isConnected) {
    [_queue addObject:message];
  } else {
    NSArray *messages = [NSArray arrayWithObject:message];

    [_webSocket send:[self encode:messages]];
    
    [self notifyMessagesSent:messages];
  }
}

#pragma mark SocketIO Related Protocol

- (void)notifyMessagesSent:(NSArray *)messages {
  if ([_delegate respondsToSelector:@selector(socketIoClient:didSendMessage:isJSON:)]) {
    for (NSDictionary *message in messages) {
      NSString *data = [message objectForKey:@"data"];
      NSString *type = [message objectForKey:@"type"];

      [_delegate socketIoClient:self didSendMessage:data isJSON:[type isEqualToString:@"json"]];
    }
  }
}

- (NSString *)encode:(NSArray *)messages {
  NSMutableString *buffer = [[[NSMutableString alloc] initWithCapacity:0] autorelease];
  
  for (NSDictionary *message in messages) {
    
    NSString *data = [message objectForKey:@"data"];
    NSString *type = [message objectForKey:@"type"];
    
    NSString *dataWithType = nil;
    
    if ([type isEqualToString:@"json"]) {
      dataWithType = [NSString stringWithFormat:@"~j~%@", data];
    } else {
      dataWithType = data;
    }
    
    [buffer appendString:@"~m~"];
    [buffer appendFormat:@"%d", [dataWithType length]];
    [buffer appendString:@"~m~"];
    [buffer appendString:dataWithType];
  }

  return buffer;
}

- (NSArray *)decode:(NSString *)data {
  NSMutableArray *messages = [NSMutableArray array];
  
  int i = 0;
  int len = [data length];
  while (i < len) {
    if ([[data substringWithRange:NSMakeRange(i, 3)] isEqualToString:@"~m~"]) {
      
      i += 3;
      
      int lengthOfLengthString = 0;
      
      for (int j = i; j < len; j++) {
        unichar c = [data characterAtIndex:j];
        
        if ('0' <= c && c <= '9') {
          lengthOfLengthString++;
        } else {
          break;
        }
      }
      
      int messageLength = [[data substringWithRange:NSMakeRange(i, lengthOfLengthString)] intValue];
      i += lengthOfLengthString;
      
      // skip past the next frame
      i += 3;
      
      NSString *message = [data substringWithRange:NSMakeRange(i, messageLength)];
      i += messageLength;
      
      [messages addObject:message];
      
    } else {
      // No frame marker
      break;
    }
  }
  
  return messages;
}

- (void)onTimeout {
  [self log:@"Timed out waiting for heartbeat."];
  // Explicitly disconnect if the heartbeat timer times out. After 
  // disconnection, you will not receive any more messages unless you explicitly
  // reconnect. (Previous versions of this library sent a 
  // socketIoClientDidDisconnect: message to the delegate, but did not actually
  // close the connection, meaning the connection could miraculously reopen if
  // a message was later received.)
  [self disconnect];
}

- (void)setTimeout {
  // If the heartbeat timer is the last remaining reference to self, 
  // invalidating it will immediately release self and then creating a new timer
  // will fail since we're already deallocated. Prevent this by carefully 
  // creating a new timer first (which retains self) and *then* invalidating 
  // the old one.
  
  NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:_heartbeatTimeout
                                               target:self 
                                             selector:@selector(onTimeout) 
                                             userInfo:nil 
                                               repeats:NO];
  
  if (_timeout != nil) {
    [_timeout invalidate];
    [_timeout release];
    _timeout = nil;
  }
  
  _timeout = [t retain];
}

- (void)onHeartbeat:(NSString *)heartbeat {
  [self send:[NSString stringWithFormat:@"~h~%@", heartbeat] isJSON:NO];
}

- (void)doQueue {
  if ([_queue count] > 0) {
    [_webSocket send:[self encode:_queue]];
    
    [self notifyMessagesSent:_queue];
    
    [_queue removeAllObjects];
  }
}

- (void)onConnect {
  _isConnected = YES;
  _isConnecting = NO;
  
  [self doQueue];
  
  if ([_delegate respondsToSelector:@selector(socketIoClientDidConnect:)]) {
    [_delegate socketIoClientDidConnect:self];
  }
  
  [self setTimeout];
  
  // Clear any checkIfTimeout pending calls since we're now connected.
  // Otherwise if we are connected and immediately disconnected, a spurrious
  // timeout error could be generated.
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkIfConnected) object:nil];
}

- (void)onDisconnect {
  BOOL wasConnected = _isConnected;
  
  _isConnected = NO;
  _isConnecting = NO;
  self.sessionId = nil;
  
  if (wasConnected && [_delegate respondsToSelector:@selector(socketIoClientDidDisconnect:)]) {
    [_delegate socketIoClientDidDisconnect:self];
  }
}

- (void)onMessage:(NSString *)message {
  [self log:[NSString stringWithFormat:@"Message: %@", message]];
  
  if (self.sessionId == nil) {
    self.sessionId = message;
    [self onConnect];
  } else if ([[message substringWithRange:NSMakeRange(0, 3)] isEqualToString:@"~h~"]) {
    [self onHeartbeat:[message substringFromIndex:3]];
  } else if ([[message substringWithRange:NSMakeRange(0, 3)] isEqualToString:@"~j~"]) {
    if ([_delegate respondsToSelector:@selector(socketIoClient:didReceiveMessage:isJSON:)]) {
      [_delegate socketIoClient:self didReceiveMessage:[message substringFromIndex:3] isJSON:YES];
    }
  } else {
    if ([_delegate respondsToSelector:@selector(socketIoClient:didReceiveMessage:isJSON:)]) {
      [_delegate socketIoClient:self didReceiveMessage:message isJSON:NO];
    }
  }
}

- (void)onData:(NSString *)data {
  [self setTimeout];
  
  NSArray *messages = [self decode:data];
  
  for (NSString *message in messages) {
    [self onMessage:message];
  }
}

- (void)onError:(NSError *)error {
  if ([_delegate respondsToSelector:@selector(socketIoClient:didFailWithError:)]) {
    [_delegate socketIoClient:self didFailWithError:error];
  }
}

#pragma mark WebSocket Delegate Methods

- (void)webSocket:(WebSocket *)ws didFailWithError:(NSError *)error {
  [self log:[NSString stringWithFormat:@"Connection failed with error: %@", [error localizedDescription]]];
  [self onError:error];
}

- (void)webSocketDidClose:(WebSocket*)webSocket {
  [self log:[NSString stringWithFormat:@"Connection closed."]];
  [self onDisconnect];
}

- (void)webSocketDidOpen:(WebSocket *)ws {
  [self log:[NSString stringWithFormat:@"Connection opened."]];
}

- (void)webSocket:(WebSocket *)ws didReceiveMessage:(NSString*)message {  
  [self log:[NSString stringWithFormat:@"Received %@", message]];
  [self onData:message];
}

- (void)log:(NSString *)message {
  // NSLog(@"%@", message);
}

@end
