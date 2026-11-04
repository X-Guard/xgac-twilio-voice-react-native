//
//  TwilioVoiceReactNative.m
//  TwilioVoiceReactNative
//
//  Copyright © 2022 Twilio, Inc. All rights reserved.
//

@import AVKit;

#import "TwilioVoicePushRegistry.h"
#import "TwilioVoiceReactNative.h"
#import "TwilioVoiceReactNativeConstants.h"
#import "TwilioVoiceStatsReport.h"

NSString * const kTwilioVoiceReactNativeVoiceError = @"Voice error";
dispatch_time_t const kPushRegistryDeviceTokenRetryTimeout = 3;
dispatch_time_t const kExponentialBackoff = 2;

// Call & call invite
NSString * const kTwilioVoiceReactNativeEventKeyCall = @"call";
NSString * const kTwilioVoiceReactNativeEventKeyCallInvite = @"callInvite";
NSString * const kTwilioVoiceReactNativeEventKeyCancelledCallInvite = @"cancelledCallInvite";

// Audio device
NSString * const kTwilioVoiceAudioDeviceUid = @"uid";

static TVODefaultAudioDevice *sTwilioAudioDevice;
static __weak TwilioVoiceReactNative *sRouteObserverModule;

static dispatch_queue_t TwilioVoiceAudioSessionQueryQueue(void) {
    static dispatch_once_t onceToken;
    static dispatch_queue_t queue;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.xguard.twilio.audioSessionQuery", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Plain copies of AVAudioSessionPortDescription so the XPC read can leave the main queue.
static NSArray<NSDictionary *> *TwilioVoicePortSnapshots(NSArray<AVAudioSessionPortDescription *> *ports) {
    NSMutableArray *snapshots = [NSMutableArray arrayWithCapacity:ports.count];
    for (AVAudioSessionPortDescription *port in ports) {
        [snapshots addObject:@{
            @"type": port.portType ?: @"",
            @"name": port.portName ?: @"",
            @"uid": port.UID ?: @"",
        }];
    }
    return snapshots;
}

@import TwilioVoice;

#pragma mark - Custom AVRoutePickerView Implementation

@interface TVRNAVRoutePickerView : AVRoutePickerView

- (void)present;

@end

@implementation TVRNAVRoutePickerView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.hidden = YES;
    }

    return self;
}

- (void)present {
    UIButton *routePickerButton;
    for (id view in self.subviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            routePickerButton = (UIButton *)view;
            [routePickerButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            break;
        }
    }
}

@end

#pragma mark - TwilioVoiceReactNative

@interface TwilioVoiceReactNative ()

@property (nonatomic, strong) TwilioVoicePushRegistry *twilioVoicePushRegistry;

@property(nonatomic, strong) NSData *deviceTokenData;
@property(nonatomic, strong) NSMutableDictionary *audioDevices;

/**
 * Maps an audio device's stable platform identifier to the UUID reported to
 * JavaScript, so the same physical device keeps the same UUID for the lifetime
 * of this module.
 *
 * Without this, `availableAudioDevices` mints a fresh UUID every time it runs,
 * and it runs on every route change. A device selected by UUID then came back
 * under a different one, so `selectedAudioDevice` never matched what the
 * caller had chosen. Android carried the same defect and was fixed the same
 * way in AudioSwitchManager.
 */
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *audioDeviceUuids;
@property(nonatomic, strong) NSDictionary *selectedAudioDevice;
@property(nonatomic, copy) dispatch_block_t routeRefreshCoalesceBlock;
// Bumped when a refresh starts and when the route observer stops, so a late
// background AVAudioSession read cannot apply after teardown or a newer refresh.
@property(nonatomic, assign) NSUInteger audioRouteRefreshGeneration;
@property(nonatomic, assign) BOOL registrationInProgress;

@end

@implementation TwilioVoiceReactNative {
    BOOL _hasObserver;
}

- (instancetype)init {
    if (self = [super init]) {
        _callMap = [NSMutableDictionary dictionary];
        _callConnectMap = [NSMutableDictionary dictionary];
        _callInviteMap = [NSMutableDictionary dictionary];
        _cancelledCallInviteMap = [NSMutableDictionary dictionary];
        _callCanSpeakMap = [NSMutableDictionary dictionary];
        _jsMuteCompletions = [NSMutableDictionary dictionary];
        _audioDevices = [NSMutableDictionary dictionary];
        _audioDeviceUuids = [NSMutableDictionary dictionary];
        _iceServersMap = [NSMutableDictionary dictionary];
        _iceTransportPolicyMap = [NSMutableDictionary dictionary];
        _callPromiseResolvers = [NSMutableDictionary dictionary];

        NSString *reactNativeSDK = kTwilioVoiceReactNativeReactNativeVoiceSDK;
        setenv("global-env-sdk", [reactNativeSDK UTF8String], 1);

        NSString *reactNativeSdkVersion = kTwilioVoiceReactNativeReactNativeVoiceSDKVer;
        setenv("com.twilio.voice.env.sdk.version", [reactNativeSdkVersion UTF8String], 1);

        // The Expo SDK version baked in by the config plugin, if any. `Voice`
        // also reports this version from JavaScript, but a PushKit wake-up can
        // reach the native layer before the JavaScript bundle has constructed
        // `Voice`, and the native SDK memoizes publisher metadata on its first
        // insights event, so a miss there persists for the rest of the process.
        // The value from JavaScript arrives later and takes precedence, because
        // it is read from the running manifest rather than baked in at build
        // time.
        id expoVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"TwilioVoiceExpoVersion"];
        if ([expoVersion isKindOfClass:[NSString class]] && [(NSString *)expoVersion length] > 0) {
            setenv("com.twilio.voice.env.sdk.expo_version", [(NSString *)expoVersion UTF8String], 1);
        }

        // Singleton: RN may re-init this module while Twilio media stack is still
        // active (incoming push / bridge reload). Re-assigning audioDevice then throws
        // TVOAudioDeviceMustBeSetBeforeMediaStackSetup (twilio-voice-react-native#413).
        if (!sTwilioAudioDevice) {
            sTwilioAudioDevice = [TVODefaultAudioDevice audioDevice];
            // Keep disabled until CallKit activates the session (didActivateAudioSession).
            // Default enabled=YES can seize AVAudioSession on init and interrupt A2DP.
            sTwilioAudioDevice.enabled = NO;
            TwilioVoiceSDK.audioDevice = sTwilioAudioDevice;
        }

        TwilioVoiceSDK.logLevel = TVOLogLevelTrace;

        [self subscribeToNotifications];
        [self initializeCallKit];
        [self initializeAudioDeviceList];
    }

    return self;
}

- (void)initializePushRegistry {
    self.twilioVoicePushRegistry = [TwilioVoicePushRegistry new];
    [self.twilioVoicePushRegistry updatePushRegistry];
}

- (void)subscribeToNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePushRegistryNotification:)
                                                 name:kTwilioVoicePushRegistryNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handlePushRegistryNotification:(NSNotification *)notification {
    NSMutableDictionary *eventBody = [notification.userInfo mutableCopy];
    NSString *type = eventBody[kTwilioVoiceReactNativeVoiceEventType];
    if ([type isEqualToString:kTwilioVoicePushRegistryNotificationDeviceTokenUpdated]) {
        self.deviceTokenData = eventBody[kTwilioVoicePushRegistryNotificationDeviceToken];

        // Skip the event emitting since 1, the listener has not registered and 2, the app does not need to know about this
        return;
    } else if ([type isEqualToString:kTwilioVoicePushRegistryNotificationIncomingPushReceived]) {
        NSDictionary *payload = eventBody[kTwilioVoicePushRegistryNotificationIncomingPushPayload];
        [TwilioVoiceSDK handleNotification:payload delegate:self delegateQueue:nil callMessageDelegate:self];
    }
}

+ (TVODefaultAudioDevice *)twilioAudioDevice {
    return sTwilioAudioDevice;
}

- (void)startRouteChangeObserver {
    if (sRouteObserverModule != nil && sRouteObserverModule != self) {
        [sRouteObserverModule stopRouteChangeObserver];
    }

    if (sRouteObserverModule != self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
        sRouteObserverModule = self;
    }

    // CallKit posts the activation route change before this observer exists, so
    // handleRouteChange: misses it. The session is already active here — read the
    // route now or selectedAudioDevice stays nil for the whole call.
    [self refreshAudioDevicesAndEmitVoiceEvent];
}

- (void)stopRouteChangeObserver {
    if (sRouteObserverModule != self) {
        return;
    }

    [self cancelRouteRefreshCoalesce];
    self.audioRouteRefreshGeneration += 1;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVAudioSessionRouteChangeNotification
                                                  object:nil];
    sRouteObserverModule = nil;
}

- (void)cancelRouteRefreshCoalesce {
    if (self.routeRefreshCoalesceBlock) {
        dispatch_block_cancel(self.routeRefreshCoalesceBlock);
        self.routeRefreshCoalesceBlock = nil;
    }
}

// Query AVAudioSession off the main queue (Fully Blocked App Hang, XGAC-RN-ALARM-14H).
// currentRoute / availableInputs can block on audiosessiond XPC for multiple seconds
// (iOS 26+). The device list and voice event are applied back on the main queue.
// The activation seed in startRouteChangeObserver calls this unconditionally, because
// skipping it leaves selectedAudioDevice nil for the whole call.
- (void)refreshAudioDevicesAndEmitVoiceEvent {
    NSUInteger generation = self.audioRouteRefreshGeneration + 1;
    self.audioRouteRefreshGeneration = generation;

    __weak TwilioVoiceReactNative *weakSelf = self;
    dispatch_async(TwilioVoiceAudioSessionQueryQueue(), ^{
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSArray *availableInputs = TwilioVoicePortSnapshots(session.availableInputs);
        AVAudioSessionRouteDescription *currentRoute = session.currentRoute;
        NSArray *routeInputs = TwilioVoicePortSnapshots(currentRoute.inputs);
        NSArray *routeOutputs = TwilioVoicePortSnapshots(currentRoute.outputs);

        dispatch_async(dispatch_get_main_queue(), ^{
            TwilioVoiceReactNative *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.audioRouteRefreshGeneration != generation) {
                return;
            }

            [strongSelf applyAudioDevicesFromAvailableInputs:availableInputs
                                                 routeInputs:routeInputs
                                                routeOutputs:routeOutputs];

            NSMutableArray *nativeAudioDeviceInfos = [NSMutableArray array];
            for (NSString *key in [strongSelf.audioDevices allKeys]) {
                [nativeAudioDeviceInfos addObject:strongSelf.audioDevices[key]];
            }

            NSMutableDictionary *eventBody = [@{
                kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventAudioDevicesUpdated,
                kTwilioVoiceReactNativeAudioDeviceKeyAudioDevices: nativeAudioDeviceInfos
            } mutableCopy];

            if (strongSelf.selectedAudioDevice != nil) {
                eventBody[kTwilioVoiceReactNativeAudioDeviceKeySelectedDevice] = strongSelf.selectedAudioDevice;
            }

            [strongSelf sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:eventBody];
        });
    });
}

- (void)scheduleCoalescedRouteRefresh {
    [self cancelRouteRefreshCoalesce];

    __weak TwilioVoiceReactNative *weakSelf = self;
    dispatch_block_t block = dispatch_block_create(0, ^{
        TwilioVoiceReactNative *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        strongSelf.routeRefreshCoalesceBlock = nil;

        // The call can end inside the coalesce window — re-check before the XPC read.
        if (!sTwilioAudioDevice.enabled || strongSelf.callMap.count == 0) {
            return;
        }

        [strongSelf refreshAudioDevicesAndEmitVoiceEvent];
    });
    self.routeRefreshCoalesceBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   block);
}

- (void)handleRouteChange:(NSNotification *)notification {
    // startRouteChangeObserver already seeds devices when CallKit activates audio.
    // CategoryChange is the activation notification — handling it again duplicates
    // synchronous AVAudioSession XPC on the main thread (Sentry App Hang cluster).
    NSNumber *reasonValue = notification.userInfo[AVAudioSessionRouteChangeReasonKey];
    if (reasonValue.unsignedIntegerValue == AVAudioSessionRouteChangeReasonCategoryChange) {
        return;
    }

    // AVAudioSession posts this on its own queue, not necessarily the main one. Gate and
    // coalesce on the main queue so callMap and routeRefreshCoalesceBlock have a single
    // owning queue — stopRouteChangeObserver cancels from the CallKit delegates there.
    dispatch_async(dispatch_get_main_queue(), ^{
        // A replacement module can take the observer before this block runs.
        // stopRouteChangeObserver cancels a pending coalesce, not this queued block.
        if (sRouteObserverModule != self) {
            return;
        }

        if (!sTwilioAudioDevice.enabled || self.callMap.count == 0) {
            return;
        }

        [self scheduleCoalescedRouteRefresh];
    });
}

/**
 * The UUID for an audio device, stable across calls.
 *
 * `uid` is the platform's own identifier: the port UID for a real port, or the
 * port type constant for the two built-in devices, which have no port until
 * they are routed to.
 *
 * @param uid the platform identifier for the device
 * @returns the UUID string already assigned to that device, or a new one
 */
- (NSString *)audioDeviceUuidForUid:(NSString *)uid {
    NSString *existing = self.audioDeviceUuids[uid];
    if (existing != nil) {
        return existing;
    }

    NSString *uuid = [NSUUID UUID].UUIDString;
    self.audioDeviceUuids[uid] = uuid;
    return uuid;
}

- (void)initializeAudioDeviceList {
    NSString *receiverUuid = [self audioDeviceUuidForUid:AVAudioSessionPortBuiltInReceiver];
    NSDictionary *builtInReceiver = @{ kTwilioVoiceReactNativeAudioDeviceKeyUuid: receiverUuid,
                                       kTwilioVoiceReactNativeAudioDeviceKeyType: kTwilioVoiceReactNativeAudioDeviceKeyEarpiece,
                                       kTwilioVoiceReactNativeAudioDeviceKeyNativeType: AVAudioSessionPortBuiltInReceiver,
                                       kTwilioVoiceReactNativeAudioDeviceKeyName: @"iPhone",
                                       kTwilioVoiceAudioDeviceUid: AVAudioSessionPortBuiltInReceiver};
    self.audioDevices[receiverUuid] = builtInReceiver;

    NSString *speakerUuid = [self audioDeviceUuidForUid:AVAudioSessionPortBuiltInSpeaker];
    NSDictionary *builtInSpeaker = @{ kTwilioVoiceReactNativeAudioDeviceKeyUuid: speakerUuid,
                                      kTwilioVoiceReactNativeAudioDeviceKeyType: kTwilioVoiceReactNativeAudioDeviceKeySpeaker,
                                      kTwilioVoiceReactNativeAudioDeviceKeyNativeType: AVAudioSessionPortBuiltInSpeaker,
                                      kTwilioVoiceReactNativeAudioDeviceKeyName: @"Speaker",
                                      kTwilioVoiceAudioDeviceUid: AVAudioSessionPortBuiltInSpeaker};
    self.audioDevices[speakerUuid] = builtInSpeaker;
}

// Main queue only. `ports` are TwilioVoicePortSnapshots dictionaries.
- (void)applyAudioDevicesFromAvailableInputs:(NSArray<NSDictionary *> *)availableInputs
                                 routeInputs:(NSArray<NSDictionary *> *)routeInputs
                                routeOutputs:(NSArray<NSDictionary *> *)routeOutputs {
    // Pop all except the built-in earpiece and speaker
    for (NSString *key in [self.audioDevices allKeys]) {
        NSDictionary *audioDevice = self.audioDevices[key];
        if (![audioDevice[kTwilioVoiceAudioDeviceUid] isEqualToString:AVAudioSessionPortBuiltInReceiver] &&
            ![audioDevice[kTwilioVoiceAudioDeviceUid] isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            [self.audioDevices removeObjectForKey:key];
        }
    }

    NSLog(@"Available audio input devices");
    for (NSDictionary *port in availableInputs) {
        NSString *portType = port[@"type"];
        NSString *portName = port[@"name"];
        NSString *portUid = port[@"uid"];
        NSLog(@"\t%@, %@, %@", portType, portName, portUid);

        if ([portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
            NSString *uuid = [self audioDeviceUuidForUid:portUid];
            NSDictionary *bluetoothHfpDevice = @{ kTwilioVoiceReactNativeAudioDeviceKeyUuid: uuid,
                                                  kTwilioVoiceReactNativeAudioDeviceKeyType: [self audioPortTypeMapping:portType],
                                                  kTwilioVoiceReactNativeAudioDeviceKeyNativeType: portType,
                                                  kTwilioVoiceReactNativeAudioDeviceKeyName: portName,
                                                  kTwilioVoiceAudioDeviceUid: portUid };
            self.audioDevices[uuid] = bluetoothHfpDevice;
        }
    }

    NSLog(@"Current route, inputs");
    for (NSDictionary *port in routeInputs) {
        NSLog(@"\t%@, %@, %@", port[@"type"], port[@"name"], port[@"uid"]);
    }

    NSLog(@"Current route, outputs");
    for (NSDictionary *port in routeOutputs) {
        NSString *portType = port[@"type"];
        NSString *portName = port[@"name"];
        NSString *portUid = port[@"uid"];
        NSLog(@"\t%@, %@, %@", portType, portName, portUid);

        if ([portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
            for (NSString *key in [self.audioDevices allKeys]) {
                NSDictionary *device = self.audioDevices[key];
                if ([device[kTwilioVoiceReactNativeAudioDeviceKeyType] isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeyEarpiece]) {
                    self.selectedAudioDevice = device;
                    break;
                }
            }
        } else if ([portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            for (NSString *key in [self.audioDevices allKeys]) {
                NSDictionary *device = self.audioDevices[key];
                if ([device[kTwilioVoiceReactNativeAudioDeviceKeyType] isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeySpeaker]) {
                    self.selectedAudioDevice = device;
                }
            }
        } else {
            BOOL found = NO;
            for (NSString *key in [self.audioDevices allKeys]) {
                NSDictionary *device = self.audioDevices[key];
                if ([device[kTwilioVoiceAudioDeviceUid] isEqualToString:portUid]) {
                    found = YES;
                    self.selectedAudioDevice = device;
                    break;
                }
            }

            if (!found) {
                NSLog(@"Unidentified output device selected: %@, %@, %@", portType, portName, portUid);
                NSString *uuid = [self audioDeviceUuidForUid:portUid];
                NSDictionary *unidentifiedDevice = @{ kTwilioVoiceReactNativeAudioDeviceKeyUuid: uuid,
                                                      kTwilioVoiceReactNativeAudioDeviceKeyType: [self audioPortTypeMapping:portType],
                                                      kTwilioVoiceReactNativeAudioDeviceKeyNativeType: portType,
                                                      kTwilioVoiceReactNativeAudioDeviceKeyName: portName,
                                                      kTwilioVoiceAudioDeviceUid: portUid };
                self.audioDevices[uuid] = unidentifiedDevice;
                self.selectedAudioDevice = unidentifiedDevice;
            }
        }
    }
}

- (NSString *)audioPortTypeMapping:(NSString *)portType {
    if ([portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
        return kTwilioVoiceReactNativeAudioDeviceKeyEarpiece;
    } else if ([portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
        return kTwilioVoiceReactNativeAudioDeviceKeySpeaker;
    } else if ([portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
        return kTwilioVoiceReactNativeAudioDeviceKeyBluetooth;
    }

    return kTwilioVoiceReactNativeAudioDeviceKeyUnknown;
}

- (BOOL)selectAudioDevice:(NSString *)uuid {
    if (!self.audioDevices[uuid]) {
        NSLog(@"No matching audio device found for %@", uuid);
        return NO;
    }

    NSDictionary *device = self.audioDevices[uuid];
    NSString *portUid = device[kTwilioVoiceAudioDeviceUid];
    NSString *portType = device[kTwilioVoiceReactNativeAudioDeviceKeyType];

    NSLog(@"Selecting %@(%@), %@", device[kTwilioVoiceReactNativeAudioDeviceKeyName], device[kTwilioVoiceReactNativeAudioDeviceKeyType], device[kTwilioVoiceAudioDeviceUid]);

    AVAudioSessionPortDescription *portDescription = nil;
    if ([portType isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeyEarpiece]) {
        NSArray *availableInputs = [[AVAudioSession sharedInstance] availableInputs];
        for (AVAudioSessionPortDescription *port in availableInputs) {
            if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                portDescription = port;
                break;
            }
        }

        if (!portDescription) {
            NSLog(@"Built-in mic not found");
            return NO;
        }
    } else if ([portType isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeyBluetooth]) {
        NSArray *availableInputs = [[AVAudioSession sharedInstance] availableInputs];
        for (AVAudioSessionPortDescription *port in availableInputs) {
            if ([port.UID isEqualToString:portUid]) {
                portDescription = port;
                break;
            }
        }

        if (!portDescription) {
            NSLog(@"Bluetooth device %@ not found", device[kTwilioVoiceReactNativeAudioDeviceKeyName]);
            return NO;
        }
    } else if ([portType isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeyUnknown]) {
        NSArray *availableInputs = [[AVAudioSession sharedInstance] availableInputs];
        for (AVAudioSessionPortDescription *port in availableInputs) {
            if ([port.UID isEqualToString:portUid]) {
                portDescription = port;
                break;
            }
        }

        if (!portDescription) {
            NSLog(@"Unknown device %@ not found", device[kTwilioVoiceReactNativeAudioDeviceKeyName]);
            return NO;
        }
    }

    // Update preferred input
    NSError *inputError;
    [[AVAudioSession sharedInstance] setPreferredInput:portDescription error:&inputError];
    if (inputError) {
        NSLog(@"Failed to set preferred input: %@", inputError);
        return NO;
    }

    // Route the output.
    //
    // The override has to be cleared as well as set. Setting the preferred
    // input moves only the input, so once the speaker had been selected the
    // override stayed latched and every later selection kept playing out of
    // the speaker: selecting the earpiece reported "Speaker" back from
    // `getAudioDevices`, because that was genuinely still the route.
    AVAudioSessionPortOverride outputOverride =
        [portType isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeySpeaker]
            ? AVAudioSessionPortOverrideSpeaker
            : AVAudioSessionPortOverrideNone;

    NSError *outputError;
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:outputOverride error:&outputError];
    if (outputError) {
        NSLog(@"Failed to override output port: %@", outputError);
        return NO;
    }

    return YES;
}

// TODO: Move to separate utility file someday
- (NSDictionary *)callInfo:(TVOCall *)call {
    NSMutableDictionary *callInfo = [@{kTwilioVoiceReactNativeCallInfoIsMuted: @(call.isMuted),
                                       kTwilioVoiceReactNativeCallInfoIsOnHold: @(call.isOnHold),
                                       kTwilioVoiceReactNativeCallInfoSid: call.sid,
                                       kTwilioVoiceReactNativeCallInfoState: [self stringOfState:call.state]} mutableCopy];

    if (call.uuid != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoUuid] = call.uuid.UUIDString;
    }

    if (call.from != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoFrom] = call.from;
    }

    if (call.to != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoTo] = call.to;
    }

    NSString *initialConnectedTimestamp = self.callConnectMap[call.uuid.UUIDString];
    if (initialConnectedTimestamp != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoInitialConnectedTimestamp] = initialConnectedTimestamp;
    }

    TVOCallInvite *callInvite = self.callInviteMap[call.uuid.UUIDString];
    if (callInvite && callInvite.customParameters) {
        callInfo[kTwilioVoiceReactNativeCallInviteInfoCustomParameters] = [callInvite.customParameters copy];
    }

    return callInfo;
}

- (NSDictionary *)callInviteInfo:(TVOCallInvite *)callInvite {
    NSMutableDictionary *callInviteInfo = [@{kTwilioVoiceReactNativeCallInviteInfoUuid: callInvite.uuid.UUIDString,
                                             kTwilioVoiceReactNativeCallInviteInfoCallSid: callInvite.callSid,
                                             kTwilioVoiceReactNativeCallInviteInfoTo: callInvite.to} mutableCopy];

    if (callInvite.from != nil) {
        callInviteInfo[kTwilioVoiceReactNativeCallInviteInfoFrom] = callInvite.from;
    }

    if (callInvite.customParameters != nil) {
        callInviteInfo[kTwilioVoiceReactNativeCallInviteInfoCustomParameters] = [callInvite.customParameters copy];
    }

    return callInviteInfo;
}

- (NSDictionary *)cancelledCallInviteInfo:(TVOCancelledCallInvite *)cancelledCallInvite {
    NSMutableDictionary *cancelledCallInviteInfo = [@{
        kTwilioVoiceReactNativeCancelledCallInviteInfoCallSid: cancelledCallInvite.callSid,
        kTwilioVoiceReactNativeCancelledCallInviteInfoTo: cancelledCallInvite.to
    } mutableCopy];

    if (cancelledCallInvite.from != nil) {
        cancelledCallInviteInfo[kTwilioVoiceReactNativeCancelledCallInviteInfoFrom] = cancelledCallInvite.from;
    }

    if (cancelledCallInvite.customParameters != nil) {
        cancelledCallInviteInfo[kTwilioVoiceReactNativeCancelledCallInviteInfoCustomParameters] = [cancelledCallInvite.customParameters copy];
    }

    return cancelledCallInviteInfo;
}

RCT_EXPORT_MODULE();

#pragma mark - React Native

- (NSArray<NSString *> *)supportedEvents
{
    return @[kTwilioVoiceReactNativeScopeVoice, kTwilioVoiceReactNativeScopeCall, kTwilioVoiceReactNativeScopeCallInvite, kTwilioVoiceReactNativeScopeCallMessage, kTwilioVoiceReactNativeScopePreflightTest];
}

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

- (void)startObserving {
    NSLog(@"Started observing");
    _hasObserver = YES;
}

- (void)stopObserving {
    NSLog(@"Stopped observing");
    _hasObserver = NO;
}

- (void)sendEventWithName:(NSString *)eventName body:(id)body {
    if (_hasObserver) {
        [super sendEventWithName:eventName body:body];
    } else {
        NSLog(@"No event observer registered yet. Omitting event: %@, event body: %@", eventName, body);
    }
}

#pragma mark - Bindings (Voice methods)

RCT_EXPORT_METHOD(voice_getVersion:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self resolvePromise:resolver value:TwilioVoiceSDK.sdkVersion];
}

RCT_EXPORT_METHOD(voice_getDeviceToken:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    if (self.deviceTokenData) {
        const char *tokenBytes = (const char *)[self.deviceTokenData bytes];
        NSMutableString *deviceTokenString = [NSMutableString string];
        for (NSUInteger i = 0; i < [self.deviceTokenData length]; ++i) {
            [deviceTokenString appendFormat:@"%02.2hhx", tokenBytes[i]];
        }
        [self resolvePromise:resolver value:deviceTokenString];
    } else {
        [self resolvePromise:resolver value:@""];
    }
}

RCT_EXPORT_METHOD(voice_initializePushRegistry:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self initializePushRegistry];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_setCallKitConfiguration:(NSDictionary *)configuration
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self initializeCallKitWithConfiguration:configuration];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_register:(NSString *)accessToken
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
#if TARGET_IPHONE_SIMULATOR
    if (!self.deviceTokenData) {
        NSLog(@"Please note that PushKit and incoming call are not supported on simulators");
        NSString *testDeviceToken = @"deadbeefdeadbeefdeadbeefdeadbeef";
        self.deviceTokenData = [testDeviceToken dataUsingEncoding:NSUTF8StringEncoding];
    }
#endif

    if (self.registrationInProgress) {
        NSString *errorMessage = @"Registration in progress. Please try again later";
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
        return;
    }

    self.registrationInProgress = YES;

    [self asyncPushRegistryInitialization:kPushRegistryDeviceTokenRetryTimeout
                               completion:^(NSData *deviceTokenData) {
        if (deviceTokenData) {
            [TwilioVoiceSDK registerWithAccessToken:accessToken
                                        deviceToken:deviceTokenData
                                         completion:^(NSError *error) {
                self.registrationInProgress = NO;
                if (error) {
                    NSString *errorMessage = [error localizedDescription];
                    NSNumber *errorCode = @(error.code);
                    
                    NSDictionary *payload = @{
                        kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventError,
                        kTwilioVoiceReactNativeVoiceErrorKeyError: @{
                            kTwilioVoiceReactNativeVoiceErrorKeyCode: errorCode,
                            kTwilioVoiceReactNativeVoiceErrorKeyMessage: errorMessage
                        }
                    };
                    [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:payload];
                    
                    [self rejectPromiseWithCode:resolver code:errorCode message:errorMessage];
                } else {
                    NSDictionary *payload = @{
                        kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventRegistered
                    };
                    [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:payload];
                    
                    [self resolvePromise:resolver value:[NSNull null]];
                }
            }];
        } else {
            self.registrationInProgress = NO;
            [self rejectPromiseWithName:resolver
                name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
                message:@"Failed to initialize PushKit device token"
            ];
        }
    }];
}

- (void)asyncPushRegistryInitialization:(dispatch_time_t)timeout
                             completion:(void(^)(NSData *deviceTokenData))completion {
    if (self.deviceTokenData) {
        completion(self.deviceTokenData);
        return;
    }

    if (timeout > 0) {
        __block dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_after(delay, dispatch_get_main_queue(), ^{
            dispatch_time_t backoffTimeout = (timeout > kExponentialBackoff)? timeout - kExponentialBackoff : 0;
            [weakSelf asyncPushRegistryInitialization:backoffTimeout completion:completion];
        });
    } else {
        // Device token could be nil. The voice_register() method will handle the promise.
        completion(self.deviceTokenData);
    }
}

RCT_EXPORT_METHOD(voice_unregister:(NSString *)accessToken
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
#if TARGET_IPHONE_SIMULATOR
    if (!self.deviceTokenData) {
        NSLog(@"Please note that PushKit and incoming call are not supported on simulators");
        NSString *testDeviceToken = @"deadbeefdeadbeefdeadbeefdeadbeef";
        self.deviceTokenData = [testDeviceToken dataUsingEncoding:NSUTF8StringEncoding];
    }
#endif

    if (self.registrationInProgress) {
        NSString *errorMessage = @"Registration in progress. Please try again later";
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
        return;
    }

    self.registrationInProgress = YES;

    [self asyncPushRegistryInitialization:kPushRegistryDeviceTokenRetryTimeout
                               completion:^(NSData *deviceTokenData) {
        if (deviceTokenData) {
            [TwilioVoiceSDK unregisterWithAccessToken:accessToken
                                          deviceToken:deviceTokenData
                                           completion:^(NSError *error) {
                self.registrationInProgress = NO;
                if (error) {
                    NSString *errorMessage = [error localizedDescription];
                    NSNumber *errorCode = @(error.code);
                    
                    NSDictionary *payload = @{
                        kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventError,
                        kTwilioVoiceReactNativeVoiceErrorKeyError: @{
                            kTwilioVoiceReactNativeVoiceErrorKeyCode: errorCode,
                            kTwilioVoiceReactNativeVoiceErrorKeyMessage: errorMessage
                        }
                    };
                    
                    [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:payload];
                    [self rejectPromiseWithCode:resolver code:errorCode message:errorMessage];
                } else {
                    NSDictionary *payload = @{
                        kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventUnregistered
                    };
                    [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:payload];
                    [self resolvePromise:resolver value:[NSNull null]];
                }
            }];
        } else {
            self.registrationInProgress = NO;
            
            NSString *errorMessage = @"Failed to initialize PushKit device token";
            [self rejectPromiseWithName:resolver
                name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
                message:errorMessage
            ];
        }
    }];
}

RCT_EXPORT_METHOD(voice_connect_ios:(NSString *)accessToken
                  params:(NSDictionary *)params
                  contactHandle:(NSString *)contactHandle
                  iceServers:(NSArray<NSDictionary *> * _Nullable)iceServers
                  iceTransportPolicy:(NSString * _Nullable)iceTransportPolicy
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    // The resolver is handed over rather than assigned afterwards: the CallKit
    // transaction is asynchronous, so its completion block could otherwise run
    // before the assignment, find no resolver and leave this promise pending
    // for the lifetime of the application.
    [self makeCallWithAccessToken:accessToken
                           params:params
                    contactHandle:contactHandle
                       iceServers:iceServers
               iceTransportPolicy:iceTransportPolicy
                         resolver:resolver];
}

RCT_EXPORT_METHOD(voice_getCalls:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSMutableArray *callInfoArray = [NSMutableArray array];
    for (NSString *uuid in [self.callMap allKeys]) {
        TVOCall *call = self.callMap[uuid];
        [callInfoArray addObject:[self callInfo:call]];
    }
    [self resolvePromise:resolver value:callInfoArray];
}

RCT_EXPORT_METHOD(voice_getCallInvites:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSMutableArray *callInviteInfoArray = [NSMutableArray array];
    for (NSString *uuid in [self.callInviteMap allKeys]) {
        TVOCallInvite *callInvite = self.callInviteMap[uuid];
        [callInviteInfoArray addObject:[self callInviteInfo:callInvite]];
    }
    [self resolvePromise:resolver value:callInviteInfoArray];
}

RCT_EXPORT_METHOD(voice_getAudioDevices:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    // Route seeding in startRouteChangeObserver mutates audioDevices on the main
    // queue. Snapshot there so ringing/connect do not enumerate mid-mutation.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *nativeAudioDeviceInfos = [NSMutableArray array];
        for (NSString *key in [self.audioDevices allKeys]) {
            [nativeAudioDeviceInfos addObject:self.audioDevices[key]];
        }

        // Nil selectedAudioDevice (before the in-call route read) cannot go in a
        // dictionary literal — that throws NSInvalidArgumentException.
        NSMutableDictionary *info = [@{
            kTwilioVoiceReactNativeAudioDeviceKeyAudioDevices: nativeAudioDeviceInfos
        } mutableCopy];
        if (self.selectedAudioDevice != nil) {
            info[kTwilioVoiceReactNativeAudioDeviceKeySelectedDevice] = self.selectedAudioDevice;
        }
        [self resolvePromise:resolver value:info];
    });
}

// This does not update `selectedAudioDevice`. The selection is recomputed from
// the route the session settled on, by `handleRouteChange:`. With no call in
// progress the session is never activated, so the route never moves, no
// notification arrives, and `voice_getAudioDevices` keeps reporting the
// previous device. Selecting the earpiece before dialing reports the speaker.
//
// TODO: VBLOCKS-7216
// Investigate setting `selectedAudioDevice` here, so the selection reports the
// caller's intent rather than only a route change that cannot happen yet.
RCT_EXPORT_METHOD(voice_selectAudioDevice:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    if ([self selectAudioDevice:uuid]) {
        [self resolvePromise:resolver value:[NSNull null]];
    } else {
        NSString *errorMessage = [NSString stringWithFormat:@"Failed to select audio device %@", uuid];
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
    }
}

RCT_EXPORT_METHOD(voice_showNativeAvRoutePicker:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVRNAVRoutePickerView *routePicker = [[TVRNAVRoutePickerView alloc] initWithFrame:CGRectZero];

    UIWindow *window = [UIApplication sharedApplication].windows[0];
    UIViewController *rootViewController = window.rootViewController;
    if (rootViewController) {
        UIViewController *topViewController = rootViewController;
        while (topViewController.presentedViewController) {
            topViewController = topViewController.presentedViewController;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [topViewController.view addSubview:routePicker];
            [routePicker present];
        });
    }

    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_setExpoVersion:(NSString *)expoVersion
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    // An absent version leaves whatever was baked into Info.plist in place
    // rather than unsetting it. The variable is unset at process start, so
    // there is nothing to clear in a non-Expo application.
    if ([expoVersion length] > 0) {
        setenv("com.twilio.voice.env.sdk.expo_version", [expoVersion UTF8String], 1);
    }
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_setIncomingCallContactHandleTemplate:(NSString *)template
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *preferenceKey = @"incomingCallContactHandleTemplate";
    [preferences setObject:template forKey:preferenceKey];
    [preferences synchronize];
    [self resolvePromise:resolver value:[NSNull null]];
}

// Push whether CallKit may unmute for a live call (defaults to YES when unset).
// Optional statusName updates CXCallUpdate.localizedCallerName on the CallKit screen.
// Resolves raw (not the SDK promise envelope): app code calls this on NativeModules directly.
RCT_EXPORT_METHOD(voice_setCallKitCanSpeak:(NSString *)uuid
                  canSpeak:(BOOL)canSpeak
                  statusName:(NSString *)statusName
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    if (!uuid || uuid.length == 0) {
        reject(kTwilioVoiceReactNativeVoiceError, @"Call uuid is required", nil);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *callUuid = uuid.uppercaseString;
        self.callCanSpeakMap[callUuid] = @(canSpeak);

        if (statusName != nil && statusName.length > 0) {
            [self updateCall:callUuid callerHandle:statusName];
        }

        resolve(nil);
    });
}

#pragma mark - Bindings (Call)

- (TVOCall *)getCallFromMap:(NSString *)uuid resolver:(RCTPromiseResolveBlock)resolver {
    TVOCall *call = self.callMap[uuid];
    
    if (!call) {
        NSString *errorMessage = [NSString stringWithFormat:@"Call with uuid '%@' not found", uuid];
        [self rejectPromiseWithName:resolver
            name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
            message:errorMessage
        ];
        return nil;
    }
    
    return call;
}

RCT_EXPORT_METHOD(call_disconnect:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [self endCallWithUuid:[[NSUUID alloc] initWithUUIDString:uuid]];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(call_getState:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    NSString *state = [self stringOfState:call.state];
    [self resolvePromise:resolver value:state];
}

RCT_EXPORT_METHOD(call_getSid:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    NSString *callSid = call.state != TVOCallStateConnecting ? call.sid : @"";
    [self resolvePromise:resolver value:callSid];
}

RCT_EXPORT_METHOD(call_getFrom:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    NSString *from = [call.from length] > 0 ? call.from : @"";
    [self resolvePromise:resolver value:from];
}

RCT_EXPORT_METHOD(call_getTo:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    NSString *to = [call.to length] > 0 ? call.to : @"";
    [self resolvePromise:resolver value:to];
}

RCT_EXPORT_METHOD(call_hold:(NSString *)uuid
                  onHold:(BOOL)onHold
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call setOnHold:onHold];
    [self resolvePromise:resolver value:@(call.isOnHold)];
}

RCT_EXPORT_METHOD(call_isOnHold:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [self resolvePromise:resolver value:@(call.isOnHold)];
}

RCT_EXPORT_METHOD(call_mute:(NSString *)uuid
                  muted:(BOOL)muted
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;

    if (!self.callKitCallController) {
        [call setMuted:muted];
        [self resolvePromise:resolver value:@(call.isMuted)];
        return;
    }

    [self requestCallKitMute:muted forUuid:uuid completion:^(NSError *error) {
        TVOCall *liveCall = self.callMap[uuid];
        if (error && liveCall) {
            // CallKit transaction failed (e.g. start still in flight) — still apply the track mute.
            [liveCall setMuted:muted];
            [self sendEventWithName:kTwilioVoiceReactNativeScopeCall
                               body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventMutedChanged,
                                      kTwilioVoiceReactNativeEventKeyCall: [self callInfo:liveCall]}];
        }
        BOOL isMuted = liveCall ? liveCall.isMuted : muted;
        [self resolvePromise:resolver value:@(isMuted)];
    }];
}

RCT_EXPORT_METHOD(call_isMuted:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [self resolvePromise:resolver value:@(call.isMuted)];
}

RCT_EXPORT_METHOD(call_sendDigits:(NSString *)uuid
                  digits:(NSString *)digits
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call sendDigits:digits];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(call_postFeedback:(NSString *)uuid
                  score:(NSString *)score
                  issue:(NSString *)issue
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call postFeedback:[self scoreFromString:score] issue:[self issueFromString:issue]];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(call_getStats:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call getStatsWithBlock:^(NSArray<TVOStatsReport *> *statsReports) {
        NSAssert([statsReports count] >= 1, @"Invalid stats reports array size");
        NSArray *statsReportJson = [TwilioVoiceStatsReport jsonWithStatsReportsArray:statsReports];
        [self resolvePromise:resolver value:statsReportJson];
    }];
}

RCT_EXPORT_METHOD(call_sendMessage:(NSString *)uuid
                  content:(NSString *)content
                  contentType:(NSString *)contentType
                  messageType:(NSString *)messageType
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = self.callInviteMap[uuid];
    TVOCall *call = self.callMap[uuid];
    if (call) {
        TVOCallMessage *callMessage = [TVOCallMessage messageWithContent:content
                                                             messageType:messageType
                                                                   block:^(TVOCallMessageBuilder *builder) {
            builder.contentType = contentType;
        }];
        NSString *voiceEventSid = [call sendMessage:callMessage];
        [self resolvePromise:resolver value:voiceEventSid];
    } else if (callInvite) {
        TVOCallMessage *callMessage = [TVOCallMessage messageWithContent:content
                                                             messageType:messageType
                                                                   block:^(TVOCallMessageBuilder *builder) {
            builder.contentType = contentType;
        }];
        NSString *voiceEventSid = [callInvite sendMessage:callMessage];
        [self resolvePromise:resolver value:voiceEventSid];
    } else {
        NSString *errorMessage = [NSString stringWithFormat:@"Call with %@ not found", uuid];
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
    }
}

#pragma mark - Bindings (Call Invite)

- (TVOCallInvite *)getCallInviteFromMap:(NSString *)uuid resolver:(RCTPromiseResolveBlock)resolver {
    TVOCallInvite *callInvite = self.callInviteMap[uuid];
    
    if (!callInvite) {
        [self rejectPromiseWithName:resolver
            name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
            message:@"No matching call invite"
        ];
        return nil;
    }
    
    return callInvite;
}

RCT_EXPORT_METHOD(callInvite_accept:(NSString *)uuid
                  acceptOptions:(NSDictionary *)acceptOptions
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSArray<NSDictionary *> *iceServers = acceptOptions[kTwilioVoiceReactNativeCallOptionsKeyIceServers];
    NSString *iceTransportPolicy = acceptOptions[kTwilioVoiceReactNativeCallOptionsKeyIceTransportPolicy];

    if (iceServers) {
        self.iceServersMap[uuid] = iceServers;
    }
    if (iceTransportPolicy) {
        self.iceTransportPolicyMap[uuid] = iceTransportPolicy;
    }

    [self answerCallInvite:[[NSUUID alloc] initWithUUIDString:uuid]
                completion:^(BOOL success, NSError *error) {
        [self.iceServersMap removeObjectForKey:uuid];
        [self.iceTransportPolicyMap removeObjectForKey:uuid];

        if (!success) {
            [self rejectPromiseWithCode:resolver code:@(error.code) message:error.localizedDescription];
            return;
        }

        for (NSString *uuidKey in [self.callMap allKeys]) {
            if ([uuidKey isEqualToString:uuid]) {
                TVOCall *call = self.callMap[uuidKey];
                [self resolvePromise:resolver value:[self callInfo:call]];
                return;
            }
        }

        NSString *errorMessage = @"No matching call";
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
    }];
}

RCT_EXPORT_METHOD(callInvite_reject:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self endCallWithUuid:[[NSUUID alloc] initWithUUIDString:uuid]];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(callInvite_isValid:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self resolvePromise:resolver value:@(YES)];
}

RCT_EXPORT_METHOD(callInvite_getCallSid:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = [self getCallInviteFromMap:uuid resolver:resolver];
    if (!callInvite) return;
    
    [self resolvePromise:resolver value:callInvite.callSid];
}

RCT_EXPORT_METHOD(callInvite_getFrom:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = [self getCallInviteFromMap:uuid resolver:resolver];
    if (!callInvite) return;
    
    [self resolvePromise:resolver value:callInvite.from];
}

RCT_EXPORT_METHOD(callInvite_getTo:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = [self getCallInviteFromMap:uuid resolver:resolver];
    if (!callInvite) return;
    
    [self resolvePromise:resolver value:callInvite.to];
}

RCT_EXPORT_METHOD(callInvite_updateCallerHandle:(NSString *)uuid
                  handle:(NSString *)handle
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = [self getCallInviteFromMap:uuid resolver:resolver];
    if (!callInvite) return;
    
    [self updateCall:uuid callerHandle:handle];
    [self resolvePromise:resolver value:[NSNull null]];
}

- (TVOCancelledCallInvite *)getCancelledCallInviteFromMap:(NSString *)uuid resolver:(RCTPromiseResolveBlock)resolver {
    TVOCancelledCallInvite *cancelledCallInvite = self.cancelledCallInviteMap[uuid];
    if (!cancelledCallInvite) {
        NSString *errorMessage = @"No matching cancelled call invite";
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
        return nil;
    }
    
    return cancelledCallInvite;
}

RCT_EXPORT_METHOD(cancelledCallInvite_getCallSid:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCancelledCallInvite *cancelledCallInvite = [self getCancelledCallInviteFromMap:uuid resolver:resolver];
    if (!cancelledCallInvite) return;
    
    [self resolvePromise:resolver value:cancelledCallInvite.callSid];
}

RCT_EXPORT_METHOD(cancelledCallInvite_getFrom:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCancelledCallInvite *cancelledCallInvite = [self getCancelledCallInviteFromMap:uuid resolver:resolver];
    if (!cancelledCallInvite) return;
    
    [self resolvePromise:resolver value:cancelledCallInvite.from];
}

RCT_EXPORT_METHOD(cancelledCallInvite_getTo:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCancelledCallInvite *cancelledCallInvite = [self getCancelledCallInviteFromMap:uuid resolver:resolver];
    if (!cancelledCallInvite) return;
    
    [self resolvePromise:resolver value:cancelledCallInvite.to];
}

#pragma mark - utility

- (NSString *)stringOfState:(TVOCallState)state {
    switch (state) {
        case TVOCallStateConnecting:
            return kTwilioVoiceReactNativeCallStateConnecting;
        case TVOCallStateRinging:
            return kTwilioVoiceReactNativeCallStateRinging;
        case TVOCallStateConnected:
            return kTwilioVoiceReactNativeCallStateConnected;
        case TVOCallStateReconnecting:
            return kTwilioVoiceReactNativeCallStateReconnecting;
        case TVOCallStateDisconnected:
            return kTwilioVoiceReactNativeCallStateDisconnected;
        default:
            return kTwilioVoiceReactNativeCallStateConnecting;
    }
}

- (TVOCallFeedbackScore)scoreFromString:(NSString *)score {
    if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreNotReported]) {
        return TVOCallFeedbackScoreNotReported;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreOne]) {
        return TVOCallFeedbackScoreOnePoint;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreTwo]) {
        return TVOCallFeedbackScoreTwoPoints;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreThree]) {
        return TVOCallFeedbackScoreThreePoints;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreFour]) {
        return TVOCallFeedbackScoreFourPoints;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreFive]) {
        return TVOCallFeedbackScoreFivePoints;
    }
    return TVOCallFeedbackScoreNotReported;
}

- (TVOCallFeedbackIssue)issueFromString:(NSString *)issue {
    if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueNotReported]) {
        return TVOCallFeedbackIssueNotReported;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueDroppedCall]) {
        return TVOCallFeedbackIssueDroppedCall;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueAudioLatency]) {
        return TVOCallFeedbackIssueAudioLatency;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueOneWayAudio]) {
        return TVOCallFeedbackIssueOneWayAudio;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueChoppyAudio]) {
        return TVOCallFeedbackIssueChoppyAudio;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueNoisyCall]) {
        return TVOCallFeedbackIssueNoisyCall;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueEcho]) {
        return TVOCallFeedbackIssueEcho;
    }
    return TVOCallFeedbackIssueNotReported;
}

- (NSString *)warningNameWithNumber:(NSNumber *)warning {
    if ([warning intValue] < 0 || [warning intValue] > 4) {
        NSLog(@"Warning number out of TVOCallQualityWarning range");
        return @"undefined";
    }
    
    TVOCallQualityWarning warningValue = [warning intValue];
    switch (warningValue) {
        case TVOCallQualityWarningHighRtt:
            return @"high-rtt";
        case TVOCallQualityWarningHighJitter:
            return @"high-jitter";
        case TVOCallQualityWarningHighPacketsLostFraction:
            return @"high-packets-lost-fraction";
        case TVOCallQualityWarningLowMos:
            return @"low-mos";
        case TVOCallQualityWarningConstantAudioInputLevel:
            return @"constant-audio-input-level";
        default:
            return @"undefined";
    }
}

- (NSMutableArray *)callQualityWarningsArrayFromSet:(NSSet<NSNumber *> *)qualityWarnings {
  NSMutableArray<NSString *> *warningEvents = [NSMutableArray array];
  for (NSNumber *warning in qualityWarnings) {
      NSString *event = [self warningNameWithNumber:warning];
      [warningEvents addObject:event];
  }
  return warningEvents;
}

@end
