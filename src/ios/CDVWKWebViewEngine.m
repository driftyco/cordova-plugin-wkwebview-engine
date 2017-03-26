/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVWKWebViewEngine.h"
#import "AFNetworking.h"
#import "CDVWKProcessPoolFactory.h"
#import "CDVWKWebViewUIDelegate.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerErrorResponse.h"
#import "GCDWebServerResponse.h"
#import <Cordova/NSDictionary+CordovaPreferences.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/message.h>

#define CDV_LOCAL_SERVER @"http://localhost:8080"
#define CDV_BRIDGE_NAME @"cordova"
#define CDV_IONIC_STOP_SCROLL @"stopScroll"

@interface CDVWKWeakScriptMessageHandler : NSObject <WKScriptMessageHandler>

@property(nonatomic, weak, readonly) id<WKScriptMessageHandler>
    scriptMessageHandler;

- (instancetype)initWithScriptMessageHandler:
    (id<WKScriptMessageHandler>)scriptMessageHandler;

@end

@interface CDVWKWebViewEngine ()

@property(nonatomic, strong, readwrite) UIView *engineWebView;
@property(nonatomic, strong, readwrite) id<WKUIDelegate> uiDelegate;
@property(nonatomic, weak) id<WKScriptMessageHandler> weakScriptMessageHandler;
@property(nonatomic, strong) GCDWebServer *webServer;
@property(nonatomic, readwrite) CGRect frame;
@property(nonatomic, strong) NSString *proxyUrl;
@property(nonatomic, strong) NSString *proxyMode;
@property(nonatomic, strong) NSString *secret;

@end

// see forwardingTargetForSelector: selector comment for the reason for this
// pragma
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CDVWKWebViewEngine

@synthesize engineWebView = _engineWebView;

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super init];
  if (self) {
    if (NSClassFromString(@"WKWebView") == nil) {
      return nil;
    }
    self.frame = frame;

    self.engineWebView = [[WKWebView alloc] initWithFrame:frame];
    self.fileQueue = [[NSOperationQueue alloc] init];
  }
  return self;
}

- (void)startServer {
  __weak CDVWKWebViewEngine *weakSelf = self;

  if ([@"LOCALWEB" isEqualToString:self.proxyMode]) {
    self.webServer = [[GCDWebServer alloc] init];

    [self.webServer addGETHandlerForBasePath:@"/"
                               directoryPath:@"/"
                               indexFilename:nil
                                    cacheAge:3600
                          allowRangeRequests:YES];
    NSDictionary *options = @{
      GCDWebServerOption_Port : @(8080),
      GCDWebServerOption_BindToLocalhost : @(YES),
      GCDWebServerOption_ServerName : @"Ionic"
    };
    [self.webServer startWithOptions:options error:nil];
  } else if ([@"LOCALPROXY" isEqualToString:self.proxyMode]) {
    self.webServer = [[GCDWebServer alloc] init];
    [self.webServer
        addHandlerForMethod:@"POST"
                  pathRegex:@"/api/*"
               requestClass:[GCDWebServerDataRequest class]
          asyncProcessBlock:^(GCDWebServerDataRequest *request,
                              GCDWebServerCompletionBlock completionBlock) {
            CDVWKWebViewEngine *strongSelf = weakSelf;

            NSDictionary *headers = request.headers;
            NSString *urlString = headers[@"X-original-url"];
            NSURL *url = [NSURL URLWithString:urlString];
            NSLog(@"JSON: original url, %@", url);
            NSString *reqSecret = headers[@"X-proxy-secret"];
            if (![strongSelf.secret isEqualToString:reqSecret]) {
              GCDWebServerResponse *res =
                  [GCDWebServerDataResponse responseWithStatusCode:500];
              [strongSelf setCORSHeaders:res];
              [res setValue:@"0" forAdditionalHeader:@"Content-Length"];
              completionBlock(res);
              return;
            }

            // 2
            // AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
            AFURLSessionManager *manager = [[AFURLSessionManager alloc]
                initWithSessionConfiguration:[NSURLSessionConfiguration
                                                 defaultSessionConfiguration]];
            NSMutableURLRequest *req = [[AFJSONRequestSerializer serializer]
                requestWithMethod:@"POST"
                        URLString:url.absoluteString
                       parameters:nil
                            error:nil];

            for (NSString *key in headers) {
              NSString *value;
              value = headers[key];
              [req setValue:value forHTTPHeaderField:key];
              NSLog(@"JSON: req header key, %@", key);
              NSLog(@"JSON: req header value, %@", value);
            }
            NSError *error;
            NSData *jsonData =
                [NSJSONSerialization dataWithJSONObject:request.jsonObject
                                                options:0
                                                  error:&error];
            NSString *jsonString =
                [[NSString alloc] initWithData:jsonData
                                      encoding:NSUTF8StringEncoding];
            [req setHTTPBody:[jsonString
                                 dataUsingEncoding:NSUTF8StringEncoding]];

            [[manager
                dataTaskWithRequest:req
                  completionHandler:^(NSURLResponse *_Nonnull dataResponse,
                                      id _Nullable responseObject,
                                      NSError *_Nullable error) {
                    if (!error) {
                      NSLog(@"JSON: result post, %@", dataResponse.URL);

                      GCDWebServerResponse *res = [GCDWebServerDataResponse
                          responseWithJSONObject:responseObject
                                     contentType:@"application/json"];
                      NSHTTPURLResponse *response =
                          (NSHTTPURLResponse *)dataResponse;
                      [res setStatusCode:200];
                      NSDictionary *responseHeaders = response.allHeaderFields;
                      for (NSString *key in responseHeaders) {
                        NSString *value;
                        value = responseHeaders[key];
                        NSLog(@"JSON: result header key, %@", key);
                        NSLog(@"JSON: result header value, %@", value);
                        if (![key isEqual:@"Content-Encoding"]) {
                          [res setValue:value forAdditionalHeader:key];
                        }
                      }
                      [strongSelf setCORSHeaders:res];

                      completionBlock(res);
                    } else {
                      NSLog(@"Error: %@", error);
                      GCDWebServerErrorResponse *res =
                          [GCDWebServerErrorResponse
                              responseWithStatusCode:500];
                      [strongSelf setCORSHeaders:res];
                      completionBlock(res);
                    }
                  }] resume];
          }];

    [self.webServer addDefaultHandlerForMethod:@"OPTIONS"
                                  requestClass:[GCDWebServerRequest class]
                                  processBlock:^GCDWebServerResponse *(
                                      GCDWebServerRequest *request) {
                                    NSLog(@"JSON: OPTIONS data");
                                    CDVWKWebViewEngine *strongSelf = weakSelf;
                                    GCDWebServerDataResponse *res =
                                        [GCDWebServerDataResponse
                                            responseWithStatusCode:200];

                                    [strongSelf setCORSHeaders:res];
                                    [res setValue:@"0"
                                        forAdditionalHeader:@"Content-Length"];
                                    return res;

                                  }];
  }
  if (self.webServer != nil) {
    [self.webServer startWithOptions:@{
      @"Port" : port,
      @"AutomaticallySuspendInBackground" : @NO
    }
                               error:nil];
  }
}

- (void)setCORSHeaders:(GCDWebServerResponse *)res {
  [res setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
  [res setValue:@"POST, GET, PUT, DELETE, OPTIONS"
      forAdditionalHeader:@"Access-Control-Allow-Methods"];
  [res setValue:@"1728000" forAdditionalHeader:@"Access-Control-Max-Age"];
  [res setValue:@"Access-Control-Allow-Methods,Access-Control-Max-Age, "
                @"Access-Control-Allow-Headers,Access-Control-Allow-"
                @"Credentials, Access-Control-Allow-Origin, Authorization, "
                @"Origin, X-Requested-With, X-HTTP-Method-Override, "
                @"Content-Type, Accept, X-original-url, X-proxy-secret"
      forAdditionalHeader:@"Access-Control-Allow-Headers"];
}

- (WKWebViewConfiguration *)createConfigurationFromSettings:
    (NSDictionary *)settings {
  WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
  configuration.processPool =
      [[CDVWKProcessPoolFactory sharedFactory] sharedProcessPool];
  if (settings == nil) {
    return configuration;
  }

  configuration.allowsInlineMediaPlayback =
      [settings cordovaBoolSettingForKey:@"AllowInlineMediaPlayback"
                            defaultValue:NO];
  configuration.mediaPlaybackRequiresUserAction =
      [settings cordovaBoolSettingForKey:@"MediaPlaybackRequiresUserAction"
                            defaultValue:YES];
  configuration.suppressesIncrementalRendering =
      [settings cordovaBoolSettingForKey:@"SuppressesIncrementalRendering"
                            defaultValue:NO];
  configuration.mediaPlaybackAllowsAirPlay =
      [settings cordovaBoolSettingForKey:@"MediaPlaybackAllowsAirPlay"
                            defaultValue:YES];
    
  return configuration;
}

- (void)pluginInitialize {
  // viewController would be available now. we attempt to set all possible
  // delegates to it, by default
  NSDictionary *settings = self.commandDelegate.settings;
  self.proxyMode = [settings cordovaSettingForKey:@"ProxyMode"];
  if (![@"DISABLEPROXY" isEqualToString:self.proxyMode]) {
    [self startServer];
  }

  self.uiDelegate = [[CDVWKWebViewUIDelegate alloc]
      initWithTitle:[[NSBundle mainBundle]
                        objectForInfoDictionaryKey:@"CFBundleDisplayName"]];

  CDVWKWeakScriptMessageHandler *weakScriptMessageHandler =
      [[CDVWKWeakScriptMessageHandler alloc] initWithScriptMessageHandler:self];

  WKUserContentController *userContentController =
      [[WKUserContentController alloc] init];
  [userContentController addScriptMessageHandler:weakScriptMessageHandler
                                            name:CDV_BRIDGE_NAME];
  [userContentController addScriptMessageHandler:weakScriptMessageHandler
                                            name:CDV_IONIC_STOP_SCROLL];

  // Inject XHR Polyfill
  NSLog(@"CDVWKWebViewEngine: trying to inject XHR polyfill");
  WKUserScript *wkScript = [self wkPluginScript];
  if (wkScript) {
    [userContentController addUserScript:wkScript];
  }

  WKUserScript *configScript = [self configScript];
  if (configScript) {
    [userContentController addUserScript:configScript];
  }

  BOOL autoCordova =
      [settings cordovaBoolSettingForKey:@"AutoInjectCordova" defaultValue:NO];
  if (autoCordova) {
    NSLog(@"CDVWKWebViewEngine: trying to inject XHR polyfill");
    WKUserScript *cordova = [self autoCordovify];
    if (cordova) {
      [userContentController addUserScript:cordova];
    }
  }

  // Inject XHR Proxy Polyfill
  if ([@"LOCALPROXY" isEqualToString:self.proxyMode]) {
    NSLog(@"CDVWKWebViewEngine: trying to inject XHR proxy polyfill");
    WKUserScript *wkScript = [self wkXHRProxyScript];
    if (wkScript) {
      [userContentController addUserScript:wkScript];
    }
  } else {
    NSLog(@"CDVWKWebViewEngine: skipped XHR proxy polyfill");
  }
    
  WKWebViewConfiguration *configuration =
      [self createConfigurationFromSettings:settings];
  configuration.userContentController = userContentController;

  // re-create WKWebView, since we need to update configuration
  WKWebView *wkWebView =
      [[WKWebView alloc] initWithFrame:self.frame configuration:configuration];
  self.proxyMode = [settings cordovaSettingForKey:@"ProxyMode"];
  if (self.proxyMode == nil) {
    self.proxyMode = @"LOCALWEB";
  }

  WKWebView *wkWebView =
      [[WKWebView alloc] initWithFrame:self.engineWebView.frame
                         configuration:configuration];
  wkWebView.UIDelegate = self.uiDelegate;
  self.engineWebView = wkWebView;

  if (IsAtLeastiOSVersion(@"9.0") &&
      [self.viewController isKindOfClass:[CDVViewController class]]) {
    wkWebView.customUserAgent =
        ((CDVViewController *)self.viewController).userAgent;
  }

  if ([self.viewController conformsToProtocol:@protocol(WKUIDelegate)]) {
    wkWebView.UIDelegate = (id<WKUIDelegate>)self.viewController;
  }

  if ([self.viewController
          conformsToProtocol:@protocol(WKNavigationDelegate)]) {
    wkWebView.navigationDelegate =
        (id<WKNavigationDelegate>)self.viewController;
  } else {
    wkWebView.navigationDelegate = (id<WKNavigationDelegate>)self;
  }

  if ([self.viewController
          conformsToProtocol:@protocol(WKScriptMessageHandler)]) {
    [wkWebView.configuration.userContentController
        addScriptMessageHandler:(id<WKScriptMessageHandler>)self.viewController
                           name:CDV_BRIDGE_NAME];
  }

  [self updateSettings:settings];

  // check if content thread has died on resume
  NSLog(@"%@",
        @"CDVWKWebViewEngine will reload WKWebView if required on resume");
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(onAppWillEnterForeground:)
             name:UIApplicationWillEnterForegroundNotification
           object:nil];

  NSLog(@"Using Ionic WKWebView");

  [self addURLObserver];
}

- (void)onReset {
  [self addURLObserver];
}

static void *KVOContext = &KVOContext;

- (void)addURLObserver {
  if (!IsAtLeastiOSVersion(@"9.0")) {
    [self.webView addObserver:self
                   forKeyPath:@"URL"
                      options:0
                      context:KVOContext];
  }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSString *, id> *)change
                       context:(void *)context {
  if (context == KVOContext) {
    if (object == [self webView] && [keyPath isEqualToString:@"URL"] &&
        [object valueForKeyPath:keyPath] == nil) {
      NSLog(@"URL is nil. Reloading WKWebView");
      [(WKWebView *)_engineWebView reload];
    }
  } else {
    [super observeValueForKeyPath:keyPath
                         ofObject:object
                           change:change
                          context:context];
  }
}

- (void)onAppWillEnterForeground:(NSNotification *)notification {
  if ([self shouldReloadWebView]) {
    NSLog(@"%@", @"CDVWKWebViewEngine reloading!");
    [(WKWebView *)_engineWebView reload];
  }
}

- (BOOL)shouldReloadWebView {
  WKWebView *wkWebView = (WKWebView *)_engineWebView;
  return [self shouldReloadWebView:wkWebView.URL title:wkWebView.title];
}

- (BOOL)shouldReloadWebView:(NSURL *)location title:(NSString *)title {
  BOOL title_is_nil = (title == nil);
  BOOL location_is_blank =
      [[location absoluteString] isEqualToString:@"about:blank"];

  BOOL reload = (title_is_nil || location_is_blank);

#ifdef DEBUG
  NSLog(@"%@", @"CDVWKWebViewEngine shouldReloadWebView::");
  NSLog(@"CDVWKWebViewEngine shouldReloadWebView title: %@", title);
  NSLog(@"CDVWKWebViewEngine shouldReloadWebView location: %@",
        [location absoluteString]);
  NSLog(@"CDVWKWebViewEngine shouldReloadWebView reload: %u", reload);
#endif

  return reload;
}

- (id)loadRequest:(NSURLRequest *)request {
  if (request.URL.fileURL) {
    NSURL *url = [[NSURL URLWithString:CDV_LOCAL_SERVER]
        URLByAppendingPathComponent:request.URL.path];
    if (request.URL.query) {
      url =
          [NSURL URLWithString:[@"?" stringByAppendingString:request.URL.query]
                 relativeToURL:url];
  if ([self canLoadRequest:request]) { // can load, differentiate between file
                                       // urls and other schemes
    if (request.URL.fileURL && [@"LOCALWEB" isEqualToString:self.proxyMode]) {
      NSURL *url = [[NSURL URLWithString:self.proxyUrl]
          URLByAppendingPathComponent:request.URL.path];
      NSURLRequest *request2 = [NSURLRequest requestWithURL:url];
      return [(WKWebView *)_engineWebView loadRequest:request2];
    } else {
      return [(WKWebView *)_engineWebView loadRequest:request];
    }
    if (request.URL.fragment) {
      url = [NSURL
          URLWithString:[@"#" stringByAppendingString:request.URL.fragment]
          relativeToURL:url];
    }
    request = [NSURLRequest requestWithURL:url];
  }
  return [(WKWebView *)_engineWebView loadRequest:request];
}

- (id)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
  return [(WKWebView *)_engineWebView loadHTMLString:string baseURL:baseURL];
}

- (NSURL *)URL {
  return [(WKWebView *)_engineWebView URL];
}

- (BOOL)canLoadRequest:(NSURLRequest *)request {
  return TRUE;
  // See: https://issues.apache.org/jira/browse/CB-9636
  SEL wk_sel = NSSelectorFromString(CDV_WKWEBVIEW_FILE_URL_LOAD_SELECTOR);

  // if it's a file URL, check whether WKWebView has the selector (which is in
  // iOS 9 and up only)
  if (request.URL.fileURL) {
    return [_engineWebView respondsToSelector:wk_sel];
  } else {
    return YES;
  }
}

- (void)updateSettings:(NSDictionary *)settings {
  WKWebView *wkWebView = (WKWebView *)_engineWebView;

  wkWebView.configuration.preferences.minimumFontSize =
      [settings cordovaFloatSettingForKey:@"MinimumFontSize" defaultValue:0.0];
  wkWebView.allowsLinkPreview =
      [settings cordovaBoolSettingForKey:@"AllowLinkPreview" defaultValue:NO];
  wkWebView.scrollView.scrollEnabled =
      [settings cordovaBoolSettingForKey:@"ScrollEnabled" defaultValue:NO];
  wkWebView.allowsBackForwardNavigationGestures =
      [settings cordovaBoolSettingForKey:@"AllowBackForwardNavigationGestures"
                            defaultValue:NO];

  /*
   wkWebView.configuration.preferences.javaScriptEnabled = [settings
   cordovaBoolSettingForKey:@"JavaScriptEnabled" default:YES];
   wkWebView.configuration.preferences.javaScriptCanOpenWindowsAutomatically =
   [settings cordovaBoolSettingForKey:@"JavaScriptCanOpenWindowsAutomatically"
   default:NO];
   */

  // By default, DisallowOverscroll is false (thus bounce is allowed)
  BOOL bounceAllowed =
      !([settings cordovaBoolSettingForKey:@"DisallowOverscroll"
                              defaultValue:NO]);

  // prevent webView from bouncing
  if (!bounceAllowed) {
    if ([wkWebView respondsToSelector:@selector(scrollView)]) {
      ((UIScrollView *)[wkWebView scrollView]).bounces = NO;
    } else {
      for (id subview in wkWebView.subviews) {
        if ([[subview class] isSubclassOfClass:[UIScrollView class]]) {
          ((UIScrollView *)subview).bounces = NO;
        }
      }
    }
  }

  wkWebView.scrollView.scrollEnabled =
      [settings cordovaFloatSettingForKey:@"ScrollEnabled" defaultValue:YES];

  NSString *decelerationSetting =
      [settings cordovaSettingForKey:@"WKWebViewDecelerationSpeed"];
  if (!decelerationSetting) {
    // Fallback to the UIWebView-named preference
    decelerationSetting =
        [settings cordovaSettingForKey:@"UIWebViewDecelerationSpeed"];
  }

  if (![@"fast" isEqualToString:decelerationSetting]) {
    [wkWebView.scrollView
        setDecelerationRate:UIScrollViewDecelerationRateNormal];
  } else {
    [wkWebView.scrollView setDecelerationRate:UIScrollViewDecelerationRateFast];
  }
}

- (void)updateWithInfo:(NSDictionary *)info {
  NSDictionary *scriptMessageHandlers =
      [info objectForKey:kCDVWebViewEngineScriptMessageHandlers];
  NSDictionary *settings =
      [info objectForKey:kCDVWebViewEngineWebViewPreferences];
  id navigationDelegate =
      [info objectForKey:kCDVWebViewEngineWKNavigationDelegate];
  id uiDelegate = [info objectForKey:kCDVWebViewEngineWKUIDelegate];

  WKWebView *wkWebView = (WKWebView *)_engineWebView;

  if (scriptMessageHandlers &&
      [scriptMessageHandlers isKindOfClass:[NSDictionary class]]) {
    NSArray *allKeys = [scriptMessageHandlers allKeys];

    for (NSString *key in allKeys) {
      id object = [scriptMessageHandlers objectForKey:key];
      if ([object conformsToProtocol:@protocol(WKScriptMessageHandler)]) {
        [wkWebView.configuration.userContentController
            addScriptMessageHandler:object
                               name:key];
      }
    }
  }

  if (navigationDelegate &&
      [navigationDelegate conformsToProtocol:@protocol(WKNavigationDelegate)]) {
    wkWebView.navigationDelegate = navigationDelegate;
  }

  if (uiDelegate && [uiDelegate conformsToProtocol:@protocol(WKUIDelegate)]) {
    wkWebView.UIDelegate = uiDelegate;
  }

  if (settings && [settings isKindOfClass:[NSDictionary class]]) {
    [self updateSettings:settings];
  }
}

// This forwards the methods that are in the header that are not implemented
// here.
// Both WKWebView and UIWebView implement the below:
//     loadHTMLString:baseURL:
//     loadRequest:
- (id)forwardingTargetForSelector:(SEL)aSelector {
  return _engineWebView;
}

- (UIView *)webView {
  return self.engineWebView;
}

- (WKUserScript *)wkPluginScript {
  NSString *scriptFile =
      [[NSBundle mainBundle] pathForResource:@"www/wk-plugin" ofType:@"js"];
  if (scriptFile == nil) {
    NSLog(@"CDVWKWebViewEngine: WK plugin was not found");
    return nil;
  }
  NSError *error = nil;
  NSString *source = [NSString stringWithContentsOfFile:scriptFile
                                               encoding:NSUTF8StringEncoding
                                                  error:&error];
  if (source == nil || error != nil) {
    NSLog(@"CDVWKWebViewEngine: WK plugin can not be loaded: %@", error);
    return nil;
  }

  return [[WKUserScript alloc]
        initWithSource:source
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:YES];
}

- (WKUserScript *)configScript {
  Class keyboard = NSClassFromString(@"CDVIonicKeyboard");
  BOOL keyboardPlugin = keyboard != nil;
  if (!keyboardPlugin) {
    return nil;
  }

  BOOL keyboardResizes =
      [self.commandDelegate.settings cordovaBoolSettingForKey:@"KeyboardResizes"
                                                 defaultValue:YES];
  NSString *source =
      [NSString stringWithFormat:@"window.Ionic = window.Ionic || {};"
                                 @"window.Ionic.keyboardPlugin=true;"
                                 @"window.Ionic.keyboardResizes=%@",
                                 keyboardResizes ? @"true" : @"false"];

  return [[WKUserScript alloc]
        initWithSource:source
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:YES];
}

- (WKUserScript *)autoCordovify {
  NSURL *cordovaURL =
      [[NSBundle mainBundle] URLForResource:@"www/cordova" withExtension:@"js"];
  if (cordovaURL == nil) {
    NSLog(@"CDVWKWebViewEngine: cordova.js WAS NOT FOUND");
    return nil;
  }
  NSError *error = nil;
  NSString *source = [NSString stringWithContentsOfURL:cordovaURL
                                              encoding:NSUTF8StringEncoding
                                                 error:&error];
  if (source == nil || error != nil) {
    NSLog(@"CDVWKWebViewEngine: cordova.js can not be loaded: %@", error);
    return nil;
  }
  NSLog(@"CDVWKWebViewEngine: auto injecting cordova");
  NSString *cordovaPath = [CDV_LOCAL_SERVER
      stringByAppendingString:cordovaURL.URLByDeletingLastPathComponent.path];
  NSString *replacement =
      [NSString stringWithFormat:@"var pathPrefix = '%@/';", cordovaPath];
  source = [source stringByReplacingOccurrencesOfString:
                       @"var pathPrefix = findCordovaPath();"
                                             withString:replacement];

  return [[WKUserScript alloc]
        initWithSource:source
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:YES];
}

- (WKUserScript *)wkXHRProxyScript {
  NSString *scriptFile =
      [[NSBundle mainBundle] pathForResource:@"www/wk-xhr" ofType:@"js"];
  if (scriptFile == nil) {
    NSLog(@"CDVWKWebViewEngine: WK xhr was not found");
    return nil;
  }
  NSError *error = nil;
  NSString *source = [NSString stringWithContentsOfFile:scriptFile
                                               encoding:NSUTF8StringEncoding
                                                  error:&error];
  if (source == nil || error != nil) {
    NSLog(@"CDVWKWebViewEngine: WK plugin can not be loaded: %@", error);
    return nil;
  }
  self.secret = [[NSUUID UUID] UUIDString];

  source = [source stringByReplacingOccurrencesOfString:@"${proxyurl}"
                                             withString:self.proxyUrl];
  source = [source stringByReplacingOccurrencesOfString:@"${secret}"
                                             withString:self.secret];
  return [[WKUserScript alloc]
        initWithSource:source
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:YES];
}

#pragma mark WKScriptMessageHandler implementation

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
  if ([message.name isEqualToString:CDV_BRIDGE_NAME]) {
    [self handleCordovaMessage:message];
  } else if ([message.name isEqualToString:CDV_IONIC_STOP_SCROLL]) {
    [self handleStopScroll];
  }
}

- (void)handleCordovaMessage:(WKScriptMessage *)message {
  CDVViewController *vc = (CDVViewController *)self.viewController;

  NSArray *jsonEntry = message.body; // NSString:callbackId, NSString:service,
                                     // NSString:action, NSArray:args
  CDVInvokedUrlCommand *command =
      [CDVInvokedUrlCommand commandFromJson:jsonEntry];
  CDV_EXEC_LOG(@"Exec(%@): Calling %@.%@", command.callbackId,
               command.className, command.methodName);

  if (![vc.commandQueue execute:command]) {
#ifdef DEBUG
    NSError *error = nil;
    NSString *commandJson = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonEntry
                                                       options:0
                                                         error:&error];

    if (error == nil) {
      commandJson = [[NSString alloc] initWithData:jsonData
                                          encoding:NSUTF8StringEncoding];
    }

    static NSUInteger maxLogLength = 1024;
    NSString *commandString =
        ([commandJson length] > maxLogLength)
            ? [NSString
                  stringWithFormat:@"%@[...]",
                                   [commandJson substringToIndex:maxLogLength]]
            : commandJson;

    NSLog(@"FAILED pluginJSON = %@", commandString);
#endif
  }
}

- (void)handleStopScroll {
  WKWebView *wkWebView = (WKWebView *)_engineWebView;
  NSLog(@"CDVWKWebViewEngine: handleStopScroll");
  [self recursiveStopScroll:[wkWebView scrollView]];
  [wkWebView evaluateJavaScript:@"window.IonicStopScroll.fire()"
              completionHandler:nil];
}

- (void)recursiveStopScroll:(UIView *)node {
  if ([node isKindOfClass:[UIScrollView class]]) {
    UIScrollView *nodeAsScroll = (UIScrollView *)node;

    if ([nodeAsScroll isScrollEnabled] && ![nodeAsScroll isHidden]) {
      [nodeAsScroll setScrollEnabled:NO];
      [nodeAsScroll setScrollEnabled:YES];
    }
  }

  // iterate tree recursivelly
  for (UIView *child in [node subviews]) {
    [self recursiveStopScroll:child];
  }
}

#pragma mark WKNavigationDelegate implementation

- (void)webView:(WKWebView *)webView
    didStartProvisionalNavigation:(WKNavigation *)navigation {
  [[NSNotificationCenter defaultCenter]
      postNotification:[NSNotification
                           notificationWithName:CDVPluginResetNotification
                                         object:webView]];
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
  CDVViewController *vc = (CDVViewController *)self.viewController;
  [CDVUserAgentUtil releaseLock:vc.userAgentLockToken];

  [[NSNotificationCenter defaultCenter]
      postNotification:[NSNotification
                           notificationWithName:CDVPageDidLoadNotification
                                         object:webView]];
}

- (void)webView:(WKWebView *)theWebView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
  [self webView:theWebView didFailNavigation:navigation withError:error];
}

- (void)webView:(WKWebView *)theWebView
    didFailNavigation:(WKNavigation *)navigation
            withError:(NSError *)error {
  CDVViewController *vc = (CDVViewController *)self.viewController;
  [CDVUserAgentUtil releaseLock:vc.userAgentLockToken];

  NSString *message =
      [NSString stringWithFormat:@"Failed to load webpage with error: %@",
                                 [error localizedDescription]];
  NSLog(@"%@", message);

  NSURL *errorUrl = vc.errorURL;
  if (errorUrl) {
    errorUrl = [NSURL
        URLWithString:
            [NSString
                stringWithFormat:@"?error=%@",
                                 [message
                                     stringByAddingPercentEscapesUsingEncoding:
                                         NSUTF8StringEncoding]]
        relativeToURL:errorUrl];
    NSLog(@"%@", [errorUrl absoluteString]);
    [theWebView loadRequest:[NSURLRequest requestWithURL:errorUrl]];
  }
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  [webView reload];
}

- (BOOL)defaultResourcePolicyForURL:(NSURL *)url {
  // all file:// urls are allowed
  if ([url isFileURL]) {
    return YES;
  }

  return NO;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:
                        (void (^)(WKNavigationActionPolicy))decisionHandler {
  NSURL *url = [navigationAction.request URL];
  CDVViewController *vc = (CDVViewController *)self.viewController;

  /*
   * Give plugins the chance to handle the url
   */
  BOOL anyPluginsResponded = NO;
  BOOL shouldAllowRequest = NO;

  for (NSString *pluginName in vc.pluginObjects) {
    CDVPlugin *plugin = [vc.pluginObjects objectForKey:pluginName];
    SEL selector =
        NSSelectorFromString(@"shouldOverrideLoadWithRequest:navigationType:");
    if ([plugin respondsToSelector:selector]) {
      anyPluginsResponded = YES;
      // https://issues.apache.org/jira/browse/CB-12497
      int navType = (int)navigationAction.navigationType;
      if (WKNavigationTypeOther == navigationAction.navigationType) {
        navType = (int)UIWebViewNavigationTypeOther;
      }
      shouldAllowRequest = (((BOOL(*)(id, SEL, id, int))objc_msgSend)(
          plugin, selector, navigationAction.request, navType));
      if (!shouldAllowRequest) {
        break;
      }
    }
  }

  if (!anyPluginsResponded) {
    /*
     * Handle all other types of urls (tel:, sms:), and requests to load a url
     * in the main webview.
     */
    shouldAllowRequest = [self defaultResourcePolicyForURL:url];
    if (!shouldAllowRequest) {
      [[NSNotificationCenter defaultCenter]
          postNotification:
              [NSNotification
                  notificationWithName:CDVPluginHandleOpenURLNotification
                                object:url]];
    }
  }

  if (shouldAllowRequest) {
    NSString *scheme = url.scheme;
    if ([scheme isEqualToString:@"tel"] || [scheme isEqualToString:@"mailto"] ||
        [scheme isEqualToString:@"facetime"] ||
        [scheme isEqualToString:@"sms"] || [scheme isEqualToString:@"maps"] ||
        [scheme isEqualToString:@"itms-services"]) {
      [[UIApplication sharedApplication] openURL:url];
      decisionHandler(WKNavigationActionPolicyCancel);
    } else {
      decisionHandler(WKNavigationActionPolicyAllow);
    }
  } else {
    decisionHandler(WKNavigationActionPolicyCancel);
  }
}

@end

#pragma mark - CDVWKWeakScriptMessageHandler

@implementation CDVWKWeakScriptMessageHandler

- (instancetype)initWithScriptMessageHandler:
    (id<WKScriptMessageHandler>)scriptMessageHandler {
  self = [super init];
  if (self) {
    _scriptMessageHandler = scriptMessageHandler;
  }
  return self;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
  [self.scriptMessageHandler userContentController:userContentController
                           didReceiveScriptMessage:message];
}

@end
