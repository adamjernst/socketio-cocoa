//
//  SocketIoClient.h
//  SocketIoCocoa
//
//  Created by Fred Potter on 11/11/10.
//  Copyright 2010 Fred Potter. All rights reserved.
//

#import <Foundation/Foundation.h>

@class WebSocket;
@protocol SocketIoClientDelegate;

extern NSString *SocketIoClientErrorDomain;

enum {
  /**
   * ConnectionTimeout indicates an error waiting for the SocketIo sessionid
   * handshake. It is also possible to receive an underlying connection timeout
   * error (due to WebSocket handshake timeout or TCP timeout). 
   */
  SocketIoClientErrorConnectionTimeout,
  /**
   * If the heartbeat times out, the connection is closed after you receive this
   * error.
   */
  SocketIoClientErrorHeartbeatTimeout,
};

typedef enum {
  SocketIoClientStateDisconnected,
  SocketIoClientStateConnecting,
  SocketIoClientStateConnected
} SocketIoClientState;

@interface SocketIoClient : NSObject {
  NSString *_host;
  NSInteger _port;
  WebSocket *_webSocket;
  
  NSTimeInterval _connectTimeout;
  
  NSTimeInterval _heartbeatTimeout;
  
  NSTimer *_timeout;

  BOOL _isConnected;
  BOOL _isConnecting;
  NSString *_sessionId;
  
  id<SocketIoClientDelegate> _delegate;
  
  NSMutableArray *_queue;
}

@property (nonatomic, retain, readonly) NSString *host;
@property (nonatomic, readonly) NSInteger port;

@property (nonatomic, retain, readonly) NSString *sessionId;
@property (nonatomic, readonly) SocketIoClientState state;

@property (nonatomic, assign) id<SocketIoClientDelegate> delegate;

@property (nonatomic, assign) NSTimeInterval connectTimeout;
@property (nonatomic, assign) NSTimeInterval heartbeatTimeout;

- (id)initWithHost:(NSString *)host port:(NSInteger)port;

/** 
 * Attempt the connection. Delegate will receive either 
 * -socketIoClientDidConnect: or -socketIoClient:connectDidFailWithError:,
 * unless connection is cancelled with |disconnect|.
 */
- (void)connect;

/**
 * If state is SocketIoClientStateConnecting, immediately cancels the 
 * pending connection and delegate does not receive any notification.
 * If state is SocketIoClientStateConnected, disconnects; delegate receives
 * socketIoClientDidDisconnect:withError:, with nil for error.
 */
- (void)disconnect;

/**
 * Rather than coupling this with any specific JSON library, you always
 * pass in a string (either _the_ string, or the the JSON-encoded version
 * of your object), and indicate whether or not you're passing a JSON object.
 */
- (void)send:(NSString *)data isJSON:(BOOL)isJSON;

/**
 * Deprecated. Do not use.
 */
- (BOOL)isConnected;
- (BOOL)isConnecting;

@end

@protocol SocketIoClientDelegate <NSObject>

@optional

/**
 * Message is always returned as a string, even when the message was meant to come
 * in as a JSON object.  Decoding the JSON is left as an exercise for the receiver.
 */
- (void)socketIoClient:(SocketIoClient *)client didReceiveMessage:(NSString *)message isJSON:(BOOL)isJSON;

/**
 * Sent when the socket has connected and both WebSocket and SocketIo 
 * handshaking has completed.
 */
- (void)socketIoClientDidConnect:(SocketIoClient *)client;

/**
 * If the socket was successfully opened (socketIoClientDidConnect: was called)
 * but closes due to error or a call to -disconnect, this method is 
 * called. This is the last call |delegate| will receive unless the socket is
 * reconnected with a call to -connect. It is safe to call |connect| from this
 * method since the socket is already closed.
 * 
 * If the disconnection was requested with a call to -disconnect, error will be
 * nil. Otherwise, it will be set to the error that triggered disconnection.
 * By the time this method is called, isConnecting and isConnected are both 
 * already NO.
 * 
 * The domain of the error will be WebSocketErrorDomain or 
 * SocketIoClientErrorDomain.
 */
- (void)socketIoClient:(SocketIoClient *)client didDisconnectWithError:(NSError *)error;

/**
 * If -connect was called, but the connection has failed due to a timeout, 
 * handshaking error, other networking problem, this method is called. This is 
 * the last call |delegate| will receive unless connection is retried with a 
 * call to |connect|. It is safe to call |connect| from this method.
 **/
- (void)socketIoClient:(SocketIoClient *)client connectDidFailWithError:(NSError *)error;

- (void)socketIoClient:(SocketIoClient *)client didSendMessage:(NSString *)message isJSON:(BOOL)isJSON;

@end
