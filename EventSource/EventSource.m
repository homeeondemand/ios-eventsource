//
//  EventSource.m
//  EventSource
//
//  Created by Neil on 25/07/2013.
//  Copyright (c) 2013 Neil Cowburn. All rights reserved.
//

#import "EventSource.h"
#import <CoreGraphics/CGBase.h>

static CGFloat const ES_RECONNECT_TIMEOUT = 1.0;
static CGFloat const ES_DEFAULT_TIMEOUT = 300.0;

@interface EventSource () <NSURLConnectionDelegate, NSURLConnectionDataDelegate> {
    BOOL wasClosed;
}

@property (nonatomic, strong) NSURL *eventURL;
@property (nonatomic, strong) NSURLConnection *eventSource;
@property (nonatomic, strong) NSMutableDictionary *listeners;
@property (nonatomic, assign) NSTimeInterval timeoutInterval;

- (void)open;

@end

@implementation EventSource

+ (id)eventSourceWithURL:(NSURL *)URL
{
    return [[EventSource alloc] initWithURL:URL];
}

+ (id)eventSourceWithURL:(NSURL *)URL timeoutInterval:(NSTimeInterval)timeoutInterval
{
    return [[EventSource alloc] initWithURL:URL timeoutInterval:timeoutInterval];
}

- (id)initWithURL:(NSURL *)URL
{
    return [self initWithURL:URL timeoutInterval:ES_DEFAULT_TIMEOUT];
}

- (id)initWithURL:(NSURL *)URL timeoutInterval:(NSTimeInterval)timeoutInterval
{
    self = [super init];
    if (self) {
        _listeners = [NSMutableDictionary dictionary];
        _eventURL = URL;
        _timeoutInterval = timeoutInterval;
        
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ES_RECONNECT_TIMEOUT * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self open];
        });
    }
    return self;
}

- (void)addEventListener:(NSString *)eventName handler:(EventSourceEventHandler)handler
{
    if (self.listeners[eventName] == nil) {
        [self.listeners setObject:[NSMutableArray array] forKey:eventName];
    }
    
    [self.listeners[eventName] addObject:handler];
}

- (void)onMessage:(EventSourceEventHandler)handler
{
    [self addEventListener:MessageEvent handler:handler];
}

- (void)onError:(EventSourceEventHandler)handler
{
    [self addEventListener:ErrorEvent handler:handler];
}

- (void)onOpen:(EventSourceEventHandler)handler
{
    [self addEventListener:OpenEvent handler:handler];
}

- (void)open
{
    wasClosed = NO;
    NSURLRequest *request = [NSURLRequest requestWithURL:self.eventURL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:self.timeoutInterval];
    self.eventSource = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:YES];
}

- (void)close
{
    wasClosed = YES;
    [self.eventSource cancel];
}

// ---------------------------------------------------------------------------------------------------------------------

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode == 200) {
        // Opened
        Event *e = [Event new];
        e.readyState = kEventStateOpen;
        
        NSArray *openHandlers = self.listeners[OpenEvent];
        for (EventSourceEventHandler handler in openHandlers) {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(e);
            });
        }
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    Event *e = [Event new];
    e.readyState = kEventStateClosed;
    e.error = error;
    
    NSArray *errorHandlers = self.listeners[ErrorEvent];
    for (EventSourceEventHandler handler in errorHandlers) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(e);
        });
    }
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ES_RECONNECT_TIMEOUT * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self open];
    });
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    __block NSString *eventString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if ([eventString hasSuffix:@"\n\n"]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            eventString = [eventString stringByReplacingOccurrencesOfString:@"\n\n" withString:@""];
            NSMutableArray *components = [[eventString componentsSeparatedByString:@"\n"] mutableCopy];
            
            Event *e = [Event new];
            e.readyState = kEventStateOpen;
            
            for (NSString *component in components) {
                NSArray *pairs = [component componentsSeparatedByString:@": "];
                if ([component hasPrefix:@"id"]) {
                    e.id = pairs[1];
                } else if ([component hasPrefix:@"event"]) {
                    e.event = pairs[1];
                } else if ([component hasPrefix:@"data"]) {
                    e.data = pairs[1];
                }
            }
            
            NSArray *messageHandlers = self.listeners[MessageEvent];
            for (EventSourceEventHandler handler in messageHandlers) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(e);
                });
            }
            
            if (e.event != nil) {
                NSArray *namedEventhandlers = self.listeners[e.event];
                for (EventSourceEventHandler handler in namedEventhandlers) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        handler(e);
                    });
                }
            }
        });
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    if (wasClosed) {
        return;
    }
    
    Event *e = [Event new];
    e.readyState = kEventStateClosed;
    e.error = [NSError errorWithDomain:@""
                                  code:e.readyState
                              userInfo:@{ NSLocalizedDescriptionKey: @"Connection with the event source was closed." }];
    
    NSArray *errorHandlers = self.listeners[ErrorEvent];
    for (EventSourceEventHandler handler in errorHandlers) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(e);
        });
    }
    
    [self open];
}

@end

// ---------------------------------------------------------------------------------------------------------------------

@implementation Event

- (NSString *)description
{
    NSString *state = nil;
    switch (self.readyState) {
        case kEventStateConnecting:
            state = @"CONNECTING";
            break;
        case kEventStateOpen:
            state = @"OPEN";
            break;
        case kEventStateClosed:
            state = @"CLOSED";
            break;
    }
    
    return [NSString stringWithFormat:@"<%@: readyState: %@, id: %@; event: %@; data: %@>",
            [self class],
            state,
            self.id,
            self.event,
            self.data];
}

@end

NSString *const MessageEvent = @"message";
NSString *const ErrorEvent = @"error";
NSString *const OpenEvent = @"open";