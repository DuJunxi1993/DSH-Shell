//
//  DSHObjCWebUIDelegate.h
//  dsh-swiftUI
//
//  Pure-ObjC WKUIDelegate adapter. WKWebView dispatches
//  `webView:runJavaScriptConfirmPanelWithMessage:...` via objc_msgSend; a
//  Swift-only conformance runs into Swift 6 strict-concurrency / witness-table
//  issues that can leave the selector unrouted at runtime. Implementing the
//  protocol in ObjC guarantees the three optional selectors are visible to
//  the ObjC runtime, regardless of the Swift module's actor-isolation state.
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHObjCWebUIDelegate : NSObject <WKUIDelegate>
@end

NS_ASSUME_NONNULL_END