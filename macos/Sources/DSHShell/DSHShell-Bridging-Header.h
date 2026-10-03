//
//  DSHShell-Bridging-Header.h
//  Use this file to import your target's public ObjC headers that you would
//  like to expose to Swift code. (For Xcode-only builds; SwiftPM auto-imports
//  the DSHShellBridge module instead.)
//

#if __has_include(<DSHShellBridge/DSHObjCWebUIDelegate.h>)
#import <DSHShellBridge/DSHObjCWebUIDelegate.h>
#else
#import "DSHObjCWebUIDelegate.h"
#endif