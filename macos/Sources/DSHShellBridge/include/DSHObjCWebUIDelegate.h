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

/// Called for `target="_blank"` / `window.open`, on the main thread.
///
/// The shell always returns `nil` from `createWebViewWith…` — it has exactly one
/// webview and a second one would have no bridge state and no window — so this
/// block is where the URL is actually dealt with. The coordinator applies the
/// same origin policy as `decidePolicyFor`: dsh's own origin is refused (it
/// would need a token the browser does not have), an external http(s) URL goes
/// to the system browser.
@property (nonatomic, copy, nullable) void (^newWindowHandler)(NSURL *url);

@end

NS_ASSUME_NONNULL_END