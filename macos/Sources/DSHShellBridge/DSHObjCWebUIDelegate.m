//
//  DSHObjCWebUIDelegate.m
//  dsh-swiftUI
//

#import "DSHObjCWebUIDelegate.h"
#import <os/log.h>

@implementation DSHObjCWebUIDelegate

- (void)webView:(WKWebView *)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                          initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(BOOL))completionHandler
{
    os_log_t logger = os_log_create("ai.deepseek.dsh-shell", "ObjCWebUIDialog");
    os_log_info(logger, "ObjC confirm called — message=%{public}@ url=%{public}@",
        [message length] > 80 ? [[message substringToIndex:80] stringByAppendingString:@"…"] : message,
        webView.URL.absoluteString ?: @"<none>");

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = @"";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];
    BOOL ok = (response == NSAlertFirstButtonReturn);

    os_log_info(logger, "ObjC confirm result — ok=%d response=%ld", ok, (long)response);
    completionHandler(ok);
}

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                         initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(void))completionHandler
{
    os_log_t logger = os_log_create("ai.deepseek.dsh-shell", "ObjCWebUIDialog");
    os_log_info(logger, "ObjC alert called — message=%{public}@ url=%{public}@",
        [message length] > 80 ? [[message substringToIndex:80] stringByAppendingString:@"…"] : message,
        webView.URL.absoluteString ?: @"<none>");

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = @"";
    [alert addButtonWithTitle:@"OK"];

    [alert runModal];
    os_log_info(logger, "ObjC alert dismissed");
    completionHandler();
}

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                              defaultText:(nullable NSString *)defaultText
                          initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(NSString *_Nullable))completionHandler
{
    os_log_t logger = os_log_create("ai.deepseek.dsh-shell", "ObjCWebUIDialog");
    os_log_info(logger, "ObjC prompt called — prompt=%{public}@", prompt);

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = prompt;
    alert.informativeText = @"";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    input.stringValue = defaultText ?: @"";
    alert.accessoryView = input;

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        os_log_info(logger, "ObjC prompt result — value=%{public}@", input.stringValue);
        completionHandler(input.stringValue);
    } else {
        os_log_info(logger, "ObjC prompt result — cancelled");
        completionHandler(nil);
    }
}

@end