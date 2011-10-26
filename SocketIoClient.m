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
@property (nonatomic, retain, readwrite) NSString *sessionId;
@property (nonatomic, readwrite) SocketIoClientState state;
- (void)log:(NSString *)message;
- (NSString *)encode:(NSArray *)messages;
- (void)onDisconnect;
- (void)onError:(NSError *)error;
- (void)onConnectError:(NSError *)error;
- (void)notifyMessagesSent:(NSArray *)messages;
@end

NSString *SocketIoClientErrorDomain = @"SocketIoClientErrorDomain";

@implementation SocketIoClient

@synthesize sessionId = _sessionId, delegate = _delegate, connectTimeout = _connectTimeout, 
            heartbeatTimeout = _heartbeatTimeout, state = _state, host = _host, port = _port;

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
  [_sessionId release];
  
  [super dealloc];
}

- (BOOL)isConnected {
  return [self state] == SocketIoClientStateConnected;
}

- (BOOL)isConnecting {
  return [self state] == SocketIoClientStateConnecting;
}

- (void)checkIfConnected {
  if ([self state] != SocketIoClientStateConnected) {
    // First close the socket, in case the client tries to immediately reconnect.
    // This will not dispatch any messages to the delegate (as documented) 
    // since state is not Connected.
    [self disconnect];
    [self onConnectError:[NSError errorWithDomain:SocketIoClientErrorDomain 
                                             code:SocketIoClientErrorConnectionTimeout
                                         userInfo:nil]];
  }
}

- (void)connect {
  if ([self state] != SocketIoClientStateConnected) {
    
    if ([self state] == SocketIoClientStateConnecting) {
      // This will cancel the connection. The delegate will not receive an error
      // since state is still not Connected.
      [self disconnect];
    }
    
    [self setState:SocketIoClientStateConnecting];
    
    [_webSocket open];
    
    if (_connectTimeout > 0.0) {
      [self performSelector:@selector(checkIfConnected) withObject:nil afterDelay:_connectTimeout];
    }
  }
}

- (void)disconnect {
  [self log:@"Disconnect"];
    
  if ([self state] == SocketIoClientStateConnecting) {
    // Set state to Disconnected to ensure that the delegate doesn't receive 
    // connectDidFailWithError: messages.
    // If state is Connected, leave it that way so that you *do* receive
    // a didDisconnectWithError: message.
    [self setState:SocketIoClientStateDisconnected];
    
    // Also cancel the connection timeout timer, so you don't get an error after
    // disconnecting.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkIfConnected) object:nil];
  }
  
  [_webSocket close];
}

- (void)send:(NSString *)data isJSON:(BOOL)isJSON {
  [self log:[NSString stringWithFormat:@"Sending %@:\n%@", isJSON ? @"JSON" : @"TEXT", data]];
  
  NSDictionary *message = [NSDictionary dictionaryWithObjectsAndKeys:
                           data,
                           @"data",
                           isJSON ? @"json" : @"text",
                           @"type",
                           nil];
  
  if ([self state] != SocketIoClientStateConnected) {
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
  
  // Prevent the delegate from getting a second message when the connection is 
  // closed upon request:
  [self setState:SocketIoClientStateDisconnected];
  [self disconnect];
  
  // Send the delegate the error:
  [self onError:[NSError errorWithDomain:SocketIoClientErrorDomain 
                                    code:SocketIoClientErrorHeartbeatTimeout
                                userInfo:nil]];
}

- (void)clearTimeout {
  if (_timeout != nil) {
    [_timeout invalidate];
    [_timeout release];
    _timeout = nil;
  }
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
  [self clearTimeout];
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
  [self setState:SocketIoClientStateConnected];
  
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
  if ([_delegate respondsToSelector:@selector(socketIoClient:didDisconnectWithError:)]) {
    [_delegate socketIoClient:self didDisconnectWithError:nil];
  }
}

- (void)onMessage:(NSString *)message {
  [self log:[NSString stringWithFormat:@"Message: %@", message]];
  
  if ([self sessionId] == nil) {
    [self setSessionId:message];
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
    [_delegate socketIoClient:self didDisconnectWithError:error];
  }
}

- (void)onConnectError:(NSError *)error {
  if ([_delegate respondsToSelector:@selector(socketIoClient:connectDidFailWithError:)]) {
    [_delegate socketIoClient:self connectDidFailWithError:error];
  }
}

#pragma mark WebSocket Delegate Methods

// In case of error or socket close, it's important that we don't send the 
// delegate the corresponding message immediately.
// Otherwise the AsyncSocket will still be in the process of shutting down
// its socket when the delegate receives the message. If the delegate
// immediately retries the connection, we'll end up connecting in the middle
// of a pending disconnection.
// Delay with performSelector:withObject:afterDelay:.

- (void)webSocket:(WebSocket *)ws didFailWithError:(NSError *)error {
  [self log:[NSString stringWithFormat:@"Connection failed with error: %@", [error localizedDescription]]];
  
  // After an error, heartbeat timeouts don't matter any more.
  [self clearTimeout];
  
  if ([self state] == SocketIoClientStateConnected) {
    // We had a fully negotiated connection, but the connection failed.
    [self performSelector:@selector(onError:) withObject:error afterDelay:0.0];
  } else {
    // In this case we were connecting, but experienced a socket error.
    [self performSelector:@selector(onConnectError:) withObject:error afterDelay:0.0];
  }
  [self setState:SocketIoClientStateDisconnected];
}

- (void)webSocketDidClose:(WebSocket*)webSocket {
  [self log:[NSString stringWithFormat:@"Connection closed."]];
  
  // We're now disconnected, so heartbeat timeouts don't matter any more.
  [self clearTimeout];
  
  // If we are still connected, then we never received didFailWithError:.
  // The user must have requested disconnection by calling -disconnect.
  if ([self state] == SocketIoClientStateConnected) {
    [self performSelector:@selector(onDisconnect) withObject:nil afterDelay:0.0];
  }
  [self setState:SocketIoClientStateDisconnected];

  // Finally, clear the sessionId since the websocket is no longer connected.
  [self setSessionId:nil];
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
