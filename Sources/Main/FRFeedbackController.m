/*
 * Copyright 2008-2019, Torsten Curdt
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FRFeedbackController.h"
#import "FRFeedbackReporter.h"
#import "FRUploader.h"
#import "FRCommand.h"
#import "FRApplication.h"
#import "FRCrashLogFinder.h"
#import "FRSystemProfile.h"
#import "FRConstants.h"
#import "FRConsoleLog.h"
#import "FRLocalizedString.h"

#import "NSMutableDictionary+Additions.h"

#import <AddressBook/AddressBook.h>
#import <SystemConfiguration/SystemConfiguration.h>

// Private interface.
@interface FRFeedbackController()
@property (readwrite, strong, nonatomic) IBOutlet NSArrayController *systemDiscovery;

@property (readwrite, weak, nonatomic) IBOutlet NSTextField *headingField;
@property (readwrite, weak, nonatomic) IBOutlet NSTextField *subheadingField;

@property (readwrite, weak, nonatomic) IBOutlet NSTextField *messageLabel;
#if (MAC_OS_X_VERSION_MIN_REQUIRED < 101200)
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *messageView;
#else
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *messageView;
#endif

@property (readwrite, weak, nonatomic) IBOutlet NSTextField *emailLabel;
@property (readwrite, weak, nonatomic) IBOutlet NSComboBox *emailBox;

@property (readwrite, weak, nonatomic) IBOutlet NSButton *detailsButton;
@property (readwrite, weak, nonatomic) IBOutlet NSTextField *detailsLabel;

@property (readwrite, weak, nonatomic) IBOutlet NSButton *sendDetailsCheckbox;

@property (readwrite, weak, nonatomic) IBOutlet NSTabView *tabView;
@property (readwrite, nonatomic) CGFloat detailsDeltaHeight;

// Even though they are not top-level objects, keep strong references to the tabViews because they are added/removed from their owning TabView, so something needs to hold on to them.
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabSystem;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabConsole;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabCrash;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabScript;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabPreferences;
@property (readwrite, strong, nonatomic) IBOutlet NSTabViewItem *tabException;

@property (readwrite, weak, nonatomic) IBOutlet NSTableView *systemView;
#if (MAC_OS_X_VERSION_MIN_REQUIRED < 101200)
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *consoleView;
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *crashesView;
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *scriptView;
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *preferencesView;
@property (readwrite, assign, nonatomic) IBOutlet NSTextView *exceptionView;
#else
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *consoleView;
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *crashesView;
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *scriptView;
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *preferencesView;
@property (readwrite, weak, nonatomic) IBOutlet NSTextView *exceptionView;
#endif

@property (readwrite, weak, nonatomic) IBOutlet NSProgressIndicator *indicator;

@property (readwrite, weak, nonatomic) IBOutlet NSButton *cancelButton;
@property (readwrite, weak, nonatomic) IBOutlet NSButton *sendButton;

@property (readwrite, nonatomic) BOOL detailsShown;
@property (readwrite, strong, nonatomic, nullable) FRUploader *uploader;
@property (readwrite, strong, nonatomic) NSString *type;
@end

@implementation FRFeedbackController

#pragma mark Construction

- (instancetype) init
{
    self = [super initWithWindowNibName:@"FeedbackReporter"];
    if (self != nil) {
        _detailsShown = YES;
    }
    return self;
}

#pragma mark Accessors

- (void) setHeading:(NSString*)message
{
    assert(message);
    [[self headingField] setStringValue:message];
}

- (void) setSubheading:(NSString *)informativeText
{
    assert(informativeText);
    [[self subheadingField] setStringValue:informativeText];
}

- (void) setMessage:(NSString*)message
{
    [[self messageView] setString:message];
}

- (void) setException:(NSString*)exception
{
    [[self exceptionView] setString:exception];
}

#pragma mark information gathering

- (NSString*) consoleLog
{
    NSNumber *hours = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_LOGHOURS];

    int h = 24;

    if (hours != nil) {
        h = [hours intValue];
    }

    NSDate *since = [NSDate dateWithTimeIntervalSinceNow:-h * 60.0 * 60.0];

    NSNumber *maximumSize = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_MAXCONSOLELOGSIZE];

    return [FRConsoleLog logSince:since maxSize:maximumSize];
}


- (NSArray*) systemProfile
{
    static NSArray *systemProfile = nil;

    static dispatch_once_t predicate = 0;
    dispatch_once(&predicate, ^{
        systemProfile = [FRSystemProfile discover];
    });

    return systemProfile;
}

- (NSString*) systemProfileAsString
{
    NSMutableString *string = [NSMutableString string];
    NSArray *dicts = [self systemProfile];
    for (NSDictionary *dict in dicts) {
        [string appendFormat:@"%@ = %@\n", [dict objectForKey:@"key"], [dict objectForKey:@"value"]];
    }
    return string;
}

- (NSString*) crashLog
{
    NSDate *lastSubmissionDate = [[NSUserDefaults standardUserDefaults] objectForKey:DEFAULTS_KEY_LASTSUBMISSIONDATE];
    if (lastSubmissionDate && ![lastSubmissionDate isKindOfClass:[NSDate class]]) {
        lastSubmissionDate = nil;
    }
    
    NSString *expectedPrefix = [FRApplication applicationName];
    NSArray *crashFiles = [FRCrashLogFinder findCrashLogsSince:lastSubmissionDate
                                                  withBaseName:expectedPrefix];
    
    NSLog(@"Found %lu crash files earlier than latest submission on: %@",
          (unsigned long)[crashFiles count],
          lastSubmissionDate);
    
    NSURL *latestCrashFileURL = [crashFiles lastObject];
    if (latestCrashFileURL == nil) {
        return @"";
    }
    
    NSLog(@"Chose newest crash file at: %@", latestCrashFileURL);
    
    NSError *error = nil;
    NSString *fileContents = [NSString stringWithContentsOfURL:latestCrashFileURL
                                                      encoding:NSUTF8StringEncoding
                                                         error:&error];
    if (fileContents == nil) {
        NSLog(@"Failed to read crash file because: %@", error);
        return @"";
    }
    
    return fileContents;
}

- (NSString*) scriptLog
{
    NSMutableString *scriptLog = [NSMutableString string];

    NSURL *scriptFileURL = [[NSBundle mainBundle] URLForResource:@"FRFeedbackReporter" withExtension:@"sh"];

    if (scriptFileURL) {
        FRCommand *cmd = [[FRCommand alloc] initWithFileURL:scriptFileURL args:@[]];
        [cmd setOutput:scriptLog];
        [cmd setError:scriptLog];
        int ret = [cmd execute];

        NSLog(@"Script exit code = %d", ret);
    }

    return scriptLog;
}

- (NSString*) preferences
{
    NSMutableDictionary *preferences = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:[FRApplication applicationIdentifier]] mutableCopy];

    if (preferences == nil) {
        return @"";
    }

    [preferences removeObjectForKey:DEFAULTS_KEY_SENDEREMAIL];

    id<FRFeedbackReporterDelegate> strongDelegate = [self delegate];
    if ([strongDelegate respondsToSelector:@selector(anonymizePreferencesForFeedbackReport:)]) {
        NSDictionary *newPreferences = [strongDelegate anonymizePreferencesForFeedbackReport:preferences];
        assert(newPreferences);
        return [NSString stringWithFormat:@"%@", newPreferences];
    }
    else {
        return [NSString stringWithFormat:@"%@", preferences];
    }
}


#pragma mark UI Actions

- (void) showDetails:(BOOL)show animate:(BOOL)animate
{
    if ([self detailsShown] == show) {
        return;
    }

    NSWindow *window = [self window];
    NSRect windowFrame = [window frame];

    if (show) {
        CGFloat deltaHeight = [self detailsDeltaHeight];
        assert(deltaHeight > 0.0);

        windowFrame.origin.y -= deltaHeight;
        windowFrame.size.height += deltaHeight;
        [window setFrame: windowFrame
                 display: YES
                 animate: animate];

    } else {
        CGFloat deltaHeight = NSHeight([[self tabView] frame]);
        assert(deltaHeight > 0.0);

        windowFrame.origin.y += deltaHeight;
        windowFrame.size.height -= deltaHeight;
        [window setFrame: windowFrame
                 display: YES
                 animate: animate];

        // Remember the height change so we can restore it later.
        [self setDetailsDeltaHeight:deltaHeight];
    }

    [self setDetailsShown:show];
}

- (IBAction) showDetails:(id)sender
{
    assert([sender isKindOfClass:[NSControl class]]);
    BOOL show = [[sender objectValue] boolValue];
    [self showDetails:show animate:YES];
}

- (IBAction) cancel:(id)sender
{
    (void)sender;

    [[self uploader] cancel];
    [self setUploader:nil];

    [self close];
}

- (IBAction) send:(id)sender
{
    (void)sender;

    if ([self uploader] != nil) {
        NSLog(@"Still uploading");
        return;
    }

    NSURL *url = nil;

    id<FRFeedbackReporterDelegate> strongDelegate = [self delegate];
    if ([strongDelegate respondsToSelector:@selector(targetURLForFeedbackReport)]) {
        url = [strongDelegate targetURLForFeedbackReport];
        assert(url);
    }
    else {
	    NSString *target = [[FRApplication feedbackURL] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
	    if (target == nil) {
            NSLog(@"You are missing the %@ key in your Info.plist!", PLIST_KEY_TARGETURL);
            return;
        }
	    url = [NSURL URLWithString:target];
    }

    SCNetworkConnectionFlags reachabilityFlags = 0;

    NSString *host = [url host];
    const char *hostname = [host UTF8String];

    Boolean reachabilityResult = false;
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, hostname);
    if (reachability) {
        reachabilityResult = SCNetworkReachabilityGetFlags(reachability, &reachabilityFlags);
        CFRelease(reachability);
    }

    BOOL reachable = reachabilityResult
        &&  (reachabilityFlags & kSCNetworkFlagsReachable)
        && !(reachabilityFlags & kSCNetworkFlagsConnectionRequired)
        && !(reachabilityFlags & kSCNetworkFlagsConnectionAutomatic)
        && !(reachabilityFlags & kSCNetworkFlagsInterventionRequired);

    if (!reachable) {
        NSString *fullName = [NSString stringWithFormat:@"%@://%@", [url scheme], host];
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:FRLocalizedString(@"Proceed Anyway", nil)];
        [alert addButtonWithTitle:FRLocalizedString(@"Cancel", nil)];
        [alert setMessageText:FRLocalizedString(@"Feedback Host Not Reachable", nil)];
        [alert setInformativeText:[NSString stringWithFormat:FRLocalizedString(@"You may not be able to send feedback because %@ isn't reachable.", nil), fullName]];
        NSInteger alertResult = [alert runModal];

        if (alertResult != NSAlertFirstButtonReturn) {
            return;
        }
    }

    FRUploader* uploader = [[FRUploader alloc] initWithTargetURL:url delegate:self];
    [self setUploader:uploader];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    [dict setValidString:[[self emailBox] stringValue]
                  forKey:POST_KEY_EMAIL];

    [dict setValidString:[[self messageView] string]
                  forKey:POST_KEY_MESSAGE];

    [dict setValidString:[self type]
                  forKey:POST_KEY_TYPE];

    [dict setValidString:[FRApplication applicationShortVersion]
                  forKey:POST_KEY_VERSION_SHORT];

    [dict setValidString:[FRApplication applicationBundleVersion]
                  forKey:POST_KEY_VERSION_BUNDLE];

    [dict setValidString:[FRApplication applicationVersion]
                  forKey:POST_KEY_VERSION];

    if ([[self sendDetailsCheckbox] state] == NSOnState) {
        if ([strongDelegate respondsToSelector:@selector(customParametersForFeedbackReport)]) {
            NSDictionary *customParams = [strongDelegate customParametersForFeedbackReport];
            if (customParams) {
                [dict addEntriesFromDictionary:customParams];
            }
        }

        [dict setValidString:[self systemProfileAsString]
                      forKey:POST_KEY_SYSTEM];

        [dict setValidString:[[self consoleView] string]
                      forKey:POST_KEY_CONSOLE];

        [dict setValidString:[[self crashesView] string]
                      forKey:POST_KEY_CRASHES];

        [dict setValidString:[[self scriptView] string]
                      forKey:POST_KEY_SHELL];

        [dict setValidString:[[self preferencesView] string]
                      forKey:POST_KEY_PREFERENCES];

        [dict setValidString:[[self exceptionView] string]
                      forKey:POST_KEY_EXCEPTION];
    }

    NSLog(@"Sending feedback to %@", url);

    [uploader postAndNotify:dict];
}

- (void) uploaderStarted:(FRUploader*)pUploader
{
    assert(pUploader); (void)pUploader;

    // NSLog(@"Upload started");

    [[self indicator] setHidden:NO];
    [[self indicator] startAnimation:self];

    [[self messageView] setEditable:NO];
    [[self sendButton] setEnabled:NO];
}

- (void) uploaderFailed:(FRUploader*)pUploader withError:(NSError*)error
{
    assert(pUploader); (void)pUploader;

    NSLog(@"Upload failed: %@", error);

    [[self indicator] stopAnimation:self];
    [[self indicator] setHidden:YES];

    [self setUploader:nil];

    [[self messageView] setEditable:YES];
    [[self sendButton] setEnabled:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:FRLocalizedString(@"OK", nil)];
    [alert setMessageText:FRLocalizedString(@"Sorry, failed to submit your feedback to the server.", nil)];
    [alert setInformativeText:[NSString stringWithFormat:FRLocalizedString(@"Error: %@", nil), [error localizedDescription]]];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert runModal];

    [self close];
}

- (void) uploaderFinished:(FRUploader*)pUploader
{
    assert(pUploader); (void)pUploader;

    // NSLog(@"Upload finished");

    [[self indicator] stopAnimation:self];
    [[self indicator] setHidden:YES];

    NSString *response = [[self uploader] response];

    [self setUploader:nil];

    [[self messageView] setEditable:YES];
    [[self sendButton] setEnabled:YES];

    NSArray *lines = [response componentsSeparatedByString:@"\n"];
    for (NSString *line in [lines reverseObjectEnumerator]) {
        if ([line length] == 0) {
            continue;
        }

        if (![line hasPrefix:@"OK "]) {

            NSLog (@"Failed to submit to server: %@", response);

            NSAlert *alert = [[NSAlert alloc] init];
            [alert addButtonWithTitle:FRLocalizedString(@"OK", nil)];
            [alert setMessageText:FRLocalizedString(@"Sorry, failed to submit your feedback to the server.", nil)];
            [alert setInformativeText:[NSString stringWithFormat:FRLocalizedString(@"Error: %@", nil), line]];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert runModal];

            return;
        }
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date]
                                              forKey:DEFAULTS_KEY_LASTSUBMISSIONDATE];
    
    [[NSUserDefaults standardUserDefaults] setObject:[[self emailBox] stringValue]
                                              forKey:DEFAULTS_KEY_SENDEREMAIL];

    [self close];
}

- (void) windowWillClose: (NSNotification *) n
{
    assert(n); (void)n;

    [[self uploader] cancel];

    if ([[self type] isEqualToString:FR_EXCEPTION]) {
        NSString *exitAfterException = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_EXITAFTEREXCEPTION];
        if (exitAfterException && [exitAfterException isEqualToString:@"YES"]) {
            // We want a pure exit() here I think.
            // As an exception has already been raised there is no
            // guarantee that the code path to [NSAapp terminate] is functional.
            // Calling abort() will crash the app here but is that more desirable?
            exit(EXIT_FAILURE);
        }
    }
}

- (void) windowDidLoad
{
    [[self window] setDelegate:self];

    [[self window] setTitle:FRLocalizedString(@"Feedback", nil)];

    [[self emailLabel] setStringValue:FRLocalizedString(@"Email address:", nil)];
    [[self detailsLabel] setStringValue:FRLocalizedString(@"Details", nil)];

    [[self tabSystem] setLabel:FRLocalizedString(@"System", nil)];
    [[self tabConsole] setLabel:FRLocalizedString(@"Console", nil)];
    [[self tabCrash] setLabel:FRLocalizedString(@"CrashLog", nil)];
    [[self tabScript] setLabel:FRLocalizedString(@"Script", nil)];
    [[self tabPreferences] setLabel:FRLocalizedString(@"Preferences", nil)];
    [[self tabException] setLabel:FRLocalizedString(@"Exception", nil)];

    [[self sendButton] setTitle:FRLocalizedString(@"Send", nil)];
    [[self cancelButton] setTitle:FRLocalizedString(@"Cancel", nil)];

    // Use a fixed pitch font for the text views that show code-like things.
    // Oddly, setting the font in the xib doesn't seem to work.
    NSFont *font = [NSFont userFixedPitchFontOfSize:[NSFont labelFontSize]];

    NSString *emptyString = @"";

    [[[self consoleView] textContainer] setWidthTracksTextView:NO];
    [[self consoleView] setString:emptyString];
    [[self consoleView] setFont:font];

    [[[self crashesView] textContainer] setWidthTracksTextView:NO];
    [[self crashesView] setString:emptyString];
    [[self crashesView] setFont:font];

    [[[self scriptView] textContainer] setWidthTracksTextView:NO];
    [[self scriptView] setString:emptyString];
    [[self scriptView] setFont:font];

    [[[self preferencesView] textContainer] setWidthTracksTextView:NO];
    [[self preferencesView] setString:emptyString];
    [[self preferencesView] setFont:font];

    [[[self exceptionView] textContainer] setWidthTracksTextView:NO];
    [[self exceptionView] setString:emptyString];
    [[self exceptionView] setFont:font];
}

- (void) stopSpinner
{
    [[self indicator] stopAnimation:self];
    [[self indicator] setHidden:YES];
    [[self sendButton] setEnabled:YES];
}

- (void) insertTabViewItemInCorrectOrder:(NSTabViewItem *)inTabViewItem
{
    assert(inTabViewItem);

    // If it's already present, do nothing.
    if ([[self tabView] indexOfTabViewItem:inTabViewItem] != NSNotFound) {
        return;
    }

    NSString *identifier = [inTabViewItem identifier];
    assert(identifier);
    
    // This is the order we want them in.
    NSArray *orderedIdentifiers = @[@"System",
                                    @"Console",
                                    @"Crashes",
                                    @"Shell",
                                    @"Preferences",
                                    @"Exception"];
    NSUInteger fullIndex = [orderedIdentifiers indexOfObject:identifier];
    assert(fullIndex != NSNotFound);

    // Determine the index to insert at. If there are no items yet, we'll insert at the beginning.
    NSInteger runningIndex = 0;
    NSArray *existingTabItems = [[self tabView] tabViewItems];
    for (NSTabViewItem *item in existingTabItems)
    {
        NSString *testIdentifier = [item identifier];
        NSUInteger testFullIndex = [orderedIdentifiers indexOfObject:testIdentifier];
        assert(testFullIndex != NSNotFound);
        assert(testFullIndex != fullIndex);
        if (fullIndex < testFullIndex)
        {
            // We found the index to insert.
            break;
        }
        runningIndex++;
    }

    // Insert the given TabViewItem at the calculated index.
    [[self tabView] insertTabViewItem:inTabViewItem atIndex:runningIndex];
}

- (void) populateSystemTab:(NSArray *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabSystem]];
    [[self systemDiscovery] setContent:inInfo];
}

- (void) populateConsoleTab:(NSString *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabConsole]];
    [[self consoleView] setString:inInfo];
}

- (void) populateCrashTab:(NSString *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabCrash]];
    [[self crashesView] setString:inInfo];
}

- (void) populateScriptTab:(NSString *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabScript]];
    [[self scriptView] setString:inInfo];
}

- (void) populatePreferencesTab:(NSString *)inInfo
{
    assert(inInfo);
    [self insertTabViewItemInCorrectOrder:[self tabPreferences]];
    [[self preferencesView] setString:inInfo];
}

- (void) populateExceptionTab
{
    [self insertTabViewItemInCorrectOrder:[self tabException]];
    // exceptionView's string was set elsewhere
}

- (void) populateAllTabViews
{
    NSString *reportType = [self type];

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t workQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    __weak FRFeedbackController *weakSelf = self;

    dispatch_group_async(group, workQueue, ^{
        //sleep(5 + arc4random_uniform(10));
        NSArray *systemProfile = [FRSystemProfile discover];
        if ([systemProfile count] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf populateSystemTab:systemProfile];
            });
        }
    });

    dispatch_group_async(group, workQueue, ^{
        //sleep(5 + arc4random_uniform(10));
        NSString *consoleLog = [weakSelf consoleLog];
        if ([consoleLog length] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf populateConsoleTab:consoleLog];
            });
        }
    });

    if ([reportType isEqualToString:FR_CRASH]) {
        dispatch_group_async(group, workQueue, ^{
            //sleep(5 + arc4random_uniform(10));
            NSString *crashLog = [weakSelf crashLog];
            if ([crashLog length] > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf populateCrashTab:crashLog];
                });
            }
        });
    }

    dispatch_group_async(group, workQueue, ^{
        //sleep(5 + arc4random_uniform(10));
        NSString *scriptLog = [weakSelf scriptLog];
        if ([scriptLog length] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf populateScriptTab:scriptLog];
            });
        }
    });

    dispatch_group_async(group, workQueue, ^{
        //sleep(5 + arc4random_uniform(10));
        NSString *preferences = [weakSelf preferences];
        if ([preferences length] > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf populatePreferencesTab:preferences];
            });
        }
    });

    if ([reportType isEqualToString:FR_EXCEPTION]) {
       [self populateExceptionTab];
    }

    // When they've all finished, stop the spinner animating.
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [weakSelf stopSpinner];
    });
}

- (void) reset
{
    // Remove them all because we don't know which we'll need to show. But keep the "System" tab because it can always show something. Also select it, because the other tab views have weird resizing issues if they are selected before they are populated.
    [[self tabView] removeTabViewItem:[self tabConsole]];
    [[self tabView] removeTabViewItem:[self tabCrash]];
    [[self tabView] removeTabViewItem:[self tabScript]];
    [[self tabView] removeTabViewItem:[self tabPreferences]];
    [[self tabView] removeTabViewItem:[self tabException]];
    [[self tabView] selectTabViewItemWithIdentifier:@"System"];

    ABPerson *me = [[ABAddressBook sharedAddressBook] me];
    ABMutableMultiValue *emailAddresses = [me valueForProperty:kABEmailProperty];

    NSUInteger count = [emailAddresses count];

    [[self emailBox] removeAllItems];

    [[self emailBox] addItemWithObjectValue:FRLocalizedString(@"anonymous", nil)];

    for (NSUInteger i=0; i<count; i++) {

        NSString *emailAddress = [emailAddresses valueAtIndex:i];

        [[self emailBox] addItemWithObjectValue:emailAddress];
    }

    NSInteger found = NSNotFound;
    NSString *email = [[NSUserDefaults standardUserDefaults] stringForKey:DEFAULTS_KEY_SENDEREMAIL];
    if (email) {
        found = [[self emailBox] indexOfItemWithObjectValue:email];
    }
    if (found != NSNotFound) {
        [[self emailBox] selectItemAtIndex:found];
    } else if ([[self emailBox] numberOfItems] >= 2) {
        NSString *defaultSender = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_DEFAULTSENDER];
        NSUInteger idx = (defaultSender && [defaultSender isEqualToString:@"firstEmail"]) ? 1 : 0;
        [[self emailBox] selectItemAtIndex:idx];
    }

    [[self headingField] setStringValue:@""];
    [[self messageView] setString:@""];
    [[self exceptionView] setString:@""];

    [self showDetails:NO animate:NO];
    [[self detailsButton] setIntValue:NO];

    [[self indicator] setHidden:NO];
    [[self indicator] startAnimation:self];
    [[self sendButton] setEnabled:NO];

    //  setup 'send details' checkbox...
    [[self sendDetailsCheckbox] setTitle:FRLocalizedString(@"Send details", nil)];
    [[self sendDetailsCheckbox] setState:NSOnState];
    NSString *sendDetailsIsOptional = [[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_SENDDETAILSISOPTIONAL];
    if (sendDetailsIsOptional && [sendDetailsIsOptional isEqualToString:@"YES"]) {
        [[self detailsLabel] setHidden:YES];
        [[self sendDetailsCheckbox] setHidden:NO];
    } else {
        [[self detailsLabel] setHidden:NO];
        [[self sendDetailsCheckbox] setHidden:YES];
    }
}

- (void) showWindow:(id)sender
{
    NSString *reportType = [self type];
    if ([reportType isEqualToString:FR_FEEDBACK]) {
        [[self messageLabel] setStringValue:FRLocalizedString(@"Feedback comment label", nil)];
    } else {
        [[self messageLabel] setStringValue:FRLocalizedString(@"Comments:", nil)];
    }

    [self populateAllTabViews];

    [super showWindow:sender];
}

- (BOOL) isShown
{
    NSWindow *window = [self window];
    return [window isVisible];
}

@end
