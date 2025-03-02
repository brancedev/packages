// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FLTCam.h"
#import <sys/utsname.h>
#import "FLTCam_Test.h"
@import CoreMotion;
@import Flutter;
#import <libkern/OSAtomic.h>

#import "FLTSavePhotoDelegate.h"
#import "FLTThreadSafeEventChannel.h"
#import "QueueUtils.h"
#import "messages.g.h"

static FlutterError *FlutterErrorFromNSError(NSError *error) {
  return [FlutterError errorWithCode:[NSString stringWithFormat:@"Error %d", (int)error.code]
                             message:error.localizedDescription
                             details:error.domain];
}

@implementation FLTImageStreamHandler

- (instancetype)initWithCaptureSessionQueue:(dispatch_queue_t)captureSessionQueue {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _captureSessionQueue = captureSessionQueue;
  return self;
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.captureSessionQueue, ^{
    weakSelf.eventSink = nil;
  });
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.captureSessionQueue, ^{
    weakSelf.eventSink = events;
  });
  return nil;
}
@end

@interface FLTCam () <AVCaptureVideoDataOutputSampleBufferDelegate,
                      AVCaptureAudioDataOutputSampleBufferDelegate>

@property(readonly, nonatomic) int64_t textureId;
@property(readonly, nonatomic) FCPPlatformMediaSettings *mediaSettings;
@property(readonly, nonatomic) FLTCamMediaSettingsAVWrapper *mediaSettingsAVWrapper;
@property(nonatomic) FLTImageStreamHandler *imageStreamHandler;
@property(readonly, nonatomic) AVCaptureSession *videoCaptureSession;
@property(readonly, nonatomic) AVCaptureSession *audioCaptureSession;

@property(readonly, nonatomic) AVCaptureInput *captureVideoInput;
/// Tracks the latest pixel buffer sent from AVFoundation's sample buffer delegate callback.
/// Used to deliver the latest pixel buffer to the flutter engine via the `copyPixelBuffer` API.
@property(readwrite, nonatomic) CVPixelBufferRef latestPixelBuffer;
@property(readonly, nonatomic) CGSize captureSize;
@property(strong, nonatomic) AVAssetWriter *videoWriter;
@property(strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property(strong, nonatomic) AVAssetWriterInput *audioWriterInput;
@property(strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *assetWriterPixelBufferAdaptor;
@property(strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;
@property(strong, nonatomic) AVCaptureAudioDataOutput *audioOutput;
@property(strong, nonatomic) NSString *videoRecordingPath;
@property(assign, nonatomic) BOOL isRecording;
@property(assign, nonatomic) BOOL isRecordingPaused;
@property(assign, nonatomic) BOOL videoIsDisconnected;
@property(assign, nonatomic) BOOL audioIsDisconnected;
@property(assign, nonatomic) BOOL isAudioSetup;

/// Number of frames currently pending processing.
@property(assign, nonatomic) int streamingPendingFramesCount;

/// Maximum number of frames pending processing.
@property(assign, nonatomic) int maxStreamingPendingFramesCount;

@property(assign, nonatomic) UIDeviceOrientation lockedCaptureOrientation;
@property(assign, nonatomic) CMTime lastVideoSampleTime;
@property(assign, nonatomic) CMTime lastAudioSampleTime;
@property(assign, nonatomic) CMTime videoTimeOffset;
@property(assign, nonatomic) CMTime audioTimeOffset;
@property(nonatomic) CMMotionManager *motionManager;
@property AVAssetWriterInputPixelBufferAdaptor *videoAdaptor;
/// All FLTCam's state access and capture session related operations should be on run on this queue.
@property(strong, nonatomic) dispatch_queue_t captureSessionQueue;
/// The queue on which `latestPixelBuffer` property is accessed.
/// To avoid unnecessary contention, do not access `latestPixelBuffer` on the `captureSessionQueue`.
@property(strong, nonatomic) dispatch_queue_t pixelBufferSynchronizationQueue;
/// The queue on which captured photos (not videos) are written to disk.
/// Videos are written to disk by `videoAdaptor` on an internal queue managed by AVFoundation.
@property(strong, nonatomic) dispatch_queue_t photoIOQueue;
@property(assign, nonatomic) UIDeviceOrientation deviceOrientation;
/// A wrapper for CMVideoFormatDescriptionGetDimensions.
/// Allows for alternate implementations in tests.
@property(nonatomic, copy) VideoDimensionsForFormat videoDimensionsForFormat;
/// A wrapper for AVCaptureDevice creation to allow for dependency injection in tests.
@property(nonatomic, copy) CaptureDeviceFactory captureDeviceFactory;

/// Reports the given error message to the Dart side of the plugin.
///
/// Can be called from any thread.
- (void)reportErrorMessage:(NSString *)errorMessage;
@end

@implementation FLTCam

NSString *const errorMethod = @"error";

- (instancetype)initWithCameraName:(NSString *)cameraName
                     mediaSettings:(FCPPlatformMediaSettings *)mediaSettings
            mediaSettingsAVWrapper:(FLTCamMediaSettingsAVWrapper *)mediaSettingsAVWrapper
                       orientation:(UIDeviceOrientation)orientation
               captureSessionQueue:(dispatch_queue_t)captureSessionQueue
                             error:(NSError **)error {
  return [self initWithCameraName:cameraName
                    mediaSettings:mediaSettings
           mediaSettingsAVWrapper:mediaSettingsAVWrapper
                      orientation:orientation
              videoCaptureSession:[[AVCaptureSession alloc] init]
              audioCaptureSession:[[AVCaptureSession alloc] init]
              captureSessionQueue:captureSessionQueue
                            error:error];
}

- (instancetype)initWithCameraName:(NSString *)cameraName
                     mediaSettings:(FCPPlatformMediaSettings *)mediaSettings
            mediaSettingsAVWrapper:(FLTCamMediaSettingsAVWrapper *)mediaSettingsAVWrapper
                       orientation:(UIDeviceOrientation)orientation
               videoCaptureSession:(AVCaptureSession *)videoCaptureSession
               audioCaptureSession:(AVCaptureSession *)audioCaptureSession
               captureSessionQueue:(dispatch_queue_t)captureSessionQueue
                             error:(NSError **)error {
  return [self initWithMediaSettings:mediaSettings
      mediaSettingsAVWrapper:mediaSettingsAVWrapper
      orientation:orientation
      videoCaptureSession:videoCaptureSession
      audioCaptureSession:videoCaptureSession
      captureSessionQueue:captureSessionQueue
      captureDeviceFactory:^AVCaptureDevice *(void) {
        return [AVCaptureDevice deviceWithUniqueID:cameraName];
      }
      videoDimensionsForFormat:^CMVideoDimensions(AVCaptureDeviceFormat *format) {
        return CMVideoFormatDescriptionGetDimensions(format.formatDescription);
      }
      error:error];
}

- (instancetype)initWithMediaSettings:(FCPPlatformMediaSettings *)mediaSettings
               mediaSettingsAVWrapper:(FLTCamMediaSettingsAVWrapper *)mediaSettingsAVWrapper
                          orientation:(UIDeviceOrientation)orientation
                  videoCaptureSession:(AVCaptureSession *)videoCaptureSession
                  audioCaptureSession:(AVCaptureSession *)audioCaptureSession
                  captureSessionQueue:(dispatch_queue_t)captureSessionQueue
                 captureDeviceFactory:(CaptureDeviceFactory)captureDeviceFactory
             videoDimensionsForFormat:(VideoDimensionsForFormat)videoDimensionsForFormat
                                error:(NSError **)error {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _mediaSettings = mediaSettings;
  _mediaSettingsAVWrapper = mediaSettingsAVWrapper;

  _captureSessionQueue = captureSessionQueue;
  _pixelBufferSynchronizationQueue =
      dispatch_queue_create("io.flutter.camera.pixelBufferSynchronizationQueue", NULL);
  _photoIOQueue = dispatch_queue_create("io.flutter.camera.photoIOQueue", NULL);
  _videoCaptureSession = videoCaptureSession;
  _audioCaptureSession = audioCaptureSession;
  _captureDeviceFactory = captureDeviceFactory;
  _captureDevice = captureDeviceFactory();
  _videoDimensionsForFormat = videoDimensionsForFormat;
  _flashMode = _captureDevice.hasFlash ? FCPPlatformFlashModeAuto : FCPPlatformFlashModeOff;
  _exposureMode = FCPPlatformExposureModeAuto;
  _focusMode = FCPPlatformFocusModeAuto;
  _lockedCaptureOrientation = UIDeviceOrientationUnknown;
  _deviceOrientation = orientation;
  _videoFormat = kCVPixelFormatType_32BGRA;
  _inProgressSavePhotoDelegates = [NSMutableDictionary dictionary];
  _fileFormat = FCPPlatformImageFileFormatJpeg;

  // To limit memory consumption, limit the number of frames pending processing.
  // After some testing, 4 was determined to be the best maximum value.
  // https://github.com/flutter/plugins/pull/4520#discussion_r766335637
  _maxStreamingPendingFramesCount = 4;

  NSError *localError = nil;
  AVCaptureConnection *connection = [self createConnection:&localError];
  if (localError) {
    if (error != nil) {
      *error = localError;
    }
    return nil;
  }

  [_videoCaptureSession addInputWithNoConnections:_captureVideoInput];
  [_videoCaptureSession addOutputWithNoConnections:_captureVideoOutput];
  [_videoCaptureSession addConnection:connection];

  _capturePhotoOutput = [AVCapturePhotoOutput new];
  [_capturePhotoOutput setHighResolutionCaptureEnabled:YES];
  [_videoCaptureSession addOutput:_capturePhotoOutput];

  _motionManager = [[CMMotionManager alloc] init];
  [_motionManager startAccelerometerUpdates];

  if (_mediaSettings.framesPerSecond) {
    // The frame rate can be changed only on a locked for configuration device.
    if ([mediaSettingsAVWrapper lockDevice:_captureDevice error:error]) {
      [_mediaSettingsAVWrapper beginConfigurationForSession:_videoCaptureSession];

      // Possible values for presets are hard-coded in FLT interface having
      // corresponding AVCaptureSessionPreset counterparts.
      // If _resolutionPreset is not supported by camera there is
      // fallback to lower resolution presets.
      // If none can be selected there is error condition.
      if (![self setCaptureSessionPreset:_mediaSettings.resolutionPreset withError:error]) {
        [_videoCaptureSession commitConfiguration];
        [_captureDevice unlockForConfiguration];
        return nil;
      }

      // Set frame rate with 1/10 precision allowing not integral values.
      int fpsNominator = floor([_mediaSettings.framesPerSecond doubleValue] * 10.0);
      CMTime duration = CMTimeMake(10, fpsNominator);

      [mediaSettingsAVWrapper setMinFrameDuration:duration onDevice:_captureDevice];
      [mediaSettingsAVWrapper setMaxFrameDuration:duration onDevice:_captureDevice];

      [_mediaSettingsAVWrapper commitConfigurationForSession:_videoCaptureSession];
      [_mediaSettingsAVWrapper unlockDevice:_captureDevice];
    } else {
      return nil;
    }
  } else {
    // If the frame rate is not important fall to a less restrictive
    // behavior (no configuration locking).
    if (![self setCaptureSessionPreset:_mediaSettings.resolutionPreset withError:error]) {
      return nil;
    }
  }

  [self updateOrientation];

  return self;
}

- (AVCaptureConnection *)createConnection:(NSError **)error {
  // Setup video capture input.
  _captureVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:_captureDevice error:error];

  // Test the return value of the `deviceInputWithDevice` method to see whether an error occurred.
  // Don’t just test to see whether the error pointer was set to point to an error.
  // See:
  // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/ErrorHandling/ErrorHandling.html
  if (!_captureVideoInput) {
    return nil;
  }

  // Setup video capture output.
  _captureVideoOutput = [AVCaptureVideoDataOutput new];
  _captureVideoOutput.videoSettings =
      @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(_videoFormat)};
  [_captureVideoOutput setAlwaysDiscardsLateVideoFrames:YES];
  [_captureVideoOutput setSampleBufferDelegate:self queue:_captureSessionQueue];

  // Setup video capture connection.
  AVCaptureConnection *connection =
      [AVCaptureConnection connectionWithInputPorts:_captureVideoInput.ports
                                             output:_captureVideoOutput];
  if ([_captureDevice position] == AVCaptureDevicePositionFront) {
    connection.videoMirrored = YES;
  }

  return connection;
}

- (void)reportInitializationState {
  // Get all the state on the current thread, not the main thread.
  FCPPlatformCameraState *state = [FCPPlatformCameraState
         makeWithPreviewSize:[FCPPlatformSize makeWithWidth:self.previewSize.width
                                                     height:self.previewSize.height]
                exposureMode:self.exposureMode
                   focusMode:self.focusMode
      exposurePointSupported:self.captureDevice.exposurePointOfInterestSupported
         focusPointSupported:self.captureDevice.focusPointOfInterestSupported];

  __weak typeof(self) weakSelf = self;
  FLTEnsureToRunOnMainQueue(^{
    [weakSelf.dartAPI initializedWithState:state
                                completion:^(FlutterError *error){
                                    // Ignore any errors, as this is just an event broadcast.
                                }];
  });
}

- (void)start {
  [_videoCaptureSession startRunning];
  [_audioCaptureSession startRunning];
}

- (void)stop {
  [_videoCaptureSession stopRunning];
  [_audioCaptureSession stopRunning];
}

- (void)setVideoFormat:(OSType)videoFormat {
  _videoFormat = videoFormat;
  _captureVideoOutput.videoSettings =
      @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(videoFormat)};
}

- (void)setImageFileFormat:(FCPPlatformImageFileFormat)fileFormat {
  _fileFormat = fileFormat;
}

- (void)setDeviceOrientation:(UIDeviceOrientation)orientation {
  if (_deviceOrientation == orientation) {
    return;
  }

  _deviceOrientation = orientation;
  [self updateOrientation];
}

- (void)updateOrientation {
  if (_isRecording) {
    return;
  }

  UIDeviceOrientation orientation = (_lockedCaptureOrientation != UIDeviceOrientationUnknown)
                                        ? _lockedCaptureOrientation
                                        : _deviceOrientation;

  [self updateOrientation:orientation forCaptureOutput:_capturePhotoOutput];
  [self updateOrientation:orientation forCaptureOutput:_captureVideoOutput];
}

- (void)updateOrientation:(UIDeviceOrientation)orientation
         forCaptureOutput:(AVCaptureOutput *)captureOutput {
  if (!captureOutput) {
    return;
  }

  AVCaptureConnection *connection = [captureOutput connectionWithMediaType:AVMediaTypeVideo];
  if (connection && connection.isVideoOrientationSupported) {
    connection.videoOrientation = [self getVideoOrientationForDeviceOrientation:orientation];
  }
}

- (void)captureToFileWithCompletion:(void (^)(NSString *_Nullable,
                                              FlutterError *_Nullable))completion {
  AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];

  if (self.mediaSettings.resolutionPreset == FCPPlatformResolutionPresetMax) {
    [settings setHighResolutionPhotoEnabled:YES];
  }

  NSString *extension;

  BOOL isHEVCCodecAvailable =
      [self.capturePhotoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeHEVC];

  if (_fileFormat == FCPPlatformImageFileFormatHeif && isHEVCCodecAvailable) {
    settings =
        [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey : AVVideoCodecTypeHEVC}];
    extension = @"heif";
  } else {
    extension = @"jpg";
  }

  AVCaptureFlashMode avFlashMode = FCPGetAVCaptureFlashModeForPigeonFlashMode(_flashMode);
  if (avFlashMode != -1) {
    [settings setFlashMode:avFlashMode];
  }
  NSError *error;
  NSString *path = [self getTemporaryFilePathWithExtension:extension
                                                 subfolder:@"pictures"
                                                    prefix:@"CAP_"
                                                     error:error];
  if (error) {
    completion(nil, FlutterErrorFromNSError(error));
    return;
  }

  __weak typeof(self) weakSelf = self;
  FLTSavePhotoDelegate *savePhotoDelegate = [[FLTSavePhotoDelegate alloc]
           initWithPath:path
                ioQueue:self.photoIOQueue
      completionHandler:^(NSString *_Nullable path, NSError *_Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.captureSessionQueue, ^{
          // cannot use the outter `strongSelf`
          typeof(self) strongSelf = weakSelf;
          if (!strongSelf) return;
          [strongSelf.inProgressSavePhotoDelegates removeObjectForKey:@(settings.uniqueID)];
        });

        if (error) {
          completion(nil, FlutterErrorFromNSError(error));
        } else {
          NSAssert(path, @"Path must not be nil if no error.");
          completion(path, nil);
        }
      }];

  NSAssert(dispatch_get_specific(FLTCaptureSessionQueueSpecific),
           @"save photo delegate references must be updated on the capture session queue");
  self.inProgressSavePhotoDelegates[@(settings.uniqueID)] = savePhotoDelegate;
  [self.capturePhotoOutput capturePhotoWithSettings:settings delegate:savePhotoDelegate];
}

- (AVCaptureVideoOrientation)getVideoOrientationForDeviceOrientation:
    (UIDeviceOrientation)deviceOrientation {
  if (deviceOrientation == UIDeviceOrientationPortrait) {
    return AVCaptureVideoOrientationPortrait;
  } else if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
    // Note: device orientation is flipped compared to video orientation. When UIDeviceOrientation
    // is landscape left the video orientation should be landscape right.
    return AVCaptureVideoOrientationLandscapeRight;
  } else if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
    // Note: device orientation is flipped compared to video orientation. When UIDeviceOrientation
    // is landscape right the video orientation should be landscape left.
    return AVCaptureVideoOrientationLandscapeLeft;
  } else if (deviceOrientation == UIDeviceOrientationPortraitUpsideDown) {
    return AVCaptureVideoOrientationPortraitUpsideDown;
  } else {
    return AVCaptureVideoOrientationPortrait;
  }
}

- (NSString *)getTemporaryFilePathWithExtension:(NSString *)extension
                                      subfolder:(NSString *)subfolder
                                         prefix:(NSString *)prefix
                                          error:(NSError *)error {
  NSString *docDir =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
  NSString *fileDir =
      [[docDir stringByAppendingPathComponent:@"camera"] stringByAppendingPathComponent:subfolder];
  NSString *fileName = [prefix stringByAppendingString:[[NSUUID UUID] UUIDString]];
  NSString *file =
      [[fileDir stringByAppendingPathComponent:fileName] stringByAppendingPathExtension:extension];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:fileDir]) {
    [[NSFileManager defaultManager] createDirectoryAtPath:fileDir
                              withIntermediateDirectories:true
                                               attributes:nil
                                                    error:&error];
    if (error) {
      return nil;
    }
  }

  return file;
}

- (BOOL)setCaptureSessionPreset:(FCPPlatformResolutionPreset)resolutionPreset
                      withError:(NSError **)error {
  switch (resolutionPreset) {
    case FCPPlatformResolutionPresetMax: {
      AVCaptureDeviceFormat *bestFormat =
          [self highestResolutionFormatForCaptureDevice:_captureDevice];
      if (bestFormat) {
        _videoCaptureSession.sessionPreset = AVCaptureSessionPresetInputPriority;
        if ([_captureDevice lockForConfiguration:NULL]) {
          // Set the best device format found and finish the device configuration.
          _captureDevice.activeFormat = bestFormat;
          [_captureDevice unlockForConfiguration];

          // Set the preview size based on values from the current capture device.
          _previewSize =
              CGSizeMake(_captureDevice.activeFormat.highResolutionStillImageDimensions.width,
                         _captureDevice.activeFormat.highResolutionStillImageDimensions.height);
          break;
        }
      }
    }
    case FCPPlatformResolutionPresetUltraHigh:
      if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset3840x2160]) {
        _videoCaptureSession.sessionPreset = AVCaptureSessionPreset3840x2160;
        _previewSize = CGSizeMake(3840, 2160);
        break;
      }
      if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
        _videoCaptureSession.sessionPreset = AVCaptureSessionPresetHigh;
        _previewSize =
            CGSizeMake(_captureDevice.activeFormat.highResolutionStillImageDimensions.width,
                       _captureDevice.activeFormat.highResolutionStillImageDimensions.height);
        break;
      }
    case FCPPlatformResolutionPresetVeryHigh:
      if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
        _videoCaptureSession.sessionPreset = AVCaptureSessionPreset1920x1080;
        _previewSize = CGSizeMake(1920, 1080);
        break;
      }
    case FCPPlatformResolutionPresetHigh:
      if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
        _videoCaptureSession.sessionPreset = AVCaptureSessionPreset1280x720;
        _previewSize = CGSizeMake(1280, 720);
        break;
      }
    case FCPPlatformResolutionPresetMedium:
      if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset640x480]) {
        _videoCaptureSession.sessionPreset = AVCaptureSessionPreset640x480;
        _previewSize = CGSizeMake(640, 480);
        break;
      }
    case FCPPlatformResolutionPresetLow:
      if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset352x288]) {
        _videoCaptureSession.sessionPreset = AVCaptureSessionPreset352x288;
        _previewSize = CGSizeMake(352, 288);
        break;
      }
    default:
      if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPresetLow]) {
        _videoCaptureSession.sessionPreset = AVCaptureSessionPresetLow;
        _previewSize = CGSizeMake(352, 288);
      } else {
        if (error != nil) {
          *error =
              [NSError errorWithDomain:NSCocoaErrorDomain
                                  code:NSURLErrorUnknown
                              userInfo:@{
                                NSLocalizedDescriptionKey :
                                    @"No capture session available for current capture session."
                              }];
        }
        return NO;
      }
  }
  _audioCaptureSession.sessionPreset = _videoCaptureSession.sessionPreset;
  return YES;
}

/// Finds the highest available resolution in terms of pixel count for the given device.
- (AVCaptureDeviceFormat *)highestResolutionFormatForCaptureDevice:
    (AVCaptureDevice *)captureDevice {
  AVCaptureDeviceFormat *bestFormat = nil;
  NSUInteger maxPixelCount = 0;
  for (AVCaptureDeviceFormat *format in _captureDevice.formats) {
    CMVideoDimensions res = self.videoDimensionsForFormat(format);
    NSUInteger height = res.height;
    NSUInteger width = res.width;
    NSUInteger pixelCount = height * width;
    if (pixelCount > maxPixelCount) {
      maxPixelCount = pixelCount;
      bestFormat = format;
    }
  }
  return bestFormat;
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  if (output == _captureVideoOutput) {
    CVPixelBufferRef newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CFRetain(newBuffer);

    __block CVPixelBufferRef previousPixelBuffer = nil;
    // Use `dispatch_sync` to avoid unnecessary context switch under common non-contest scenarios;
    // Under rare contest scenarios, it will not block for too long since the critical section is
    // quite lightweight.
    dispatch_sync(self.pixelBufferSynchronizationQueue, ^{
      // No need weak self because it's dispatch_sync.
      previousPixelBuffer = self.latestPixelBuffer;
      self.latestPixelBuffer = newBuffer;
    });
    if (previousPixelBuffer) {
      CFRelease(previousPixelBuffer);
    }
    if (_onFrameAvailable) {
      _onFrameAvailable();
    }
  }
  if (!CMSampleBufferDataIsReady(sampleBuffer)) {
    [self reportErrorMessage:@"sample buffer is not ready. Skipping sample"];
    return;
  }
  if (_isStreamingImages) {
    FlutterEventSink eventSink = _imageStreamHandler.eventSink;
    if (eventSink && (self.streamingPendingFramesCount < self.maxStreamingPendingFramesCount)) {
      self.streamingPendingFramesCount++;
      CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      // Must lock base address before accessing the pixel data
      CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

      size_t imageWidth = CVPixelBufferGetWidth(pixelBuffer);
      size_t imageHeight = CVPixelBufferGetHeight(pixelBuffer);

      NSMutableArray *planes = [NSMutableArray array];

      const Boolean isPlanar = CVPixelBufferIsPlanar(pixelBuffer);
      size_t planeCount;
      if (isPlanar) {
        planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
      } else {
        planeCount = 1;
      }

      for (int i = 0; i < planeCount; i++) {
        void *planeAddress;
        size_t bytesPerRow;
        size_t height;
        size_t width;

        if (isPlanar) {
          planeAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i);
          bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i);
          height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
          width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
        } else {
          planeAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
          bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
          height = CVPixelBufferGetHeight(pixelBuffer);
          width = CVPixelBufferGetWidth(pixelBuffer);
        }

        NSNumber *length = @(bytesPerRow * height);
        NSData *bytes = [NSData dataWithBytes:planeAddress length:length.unsignedIntegerValue];

        NSMutableDictionary *planeBuffer = [NSMutableDictionary dictionary];
        planeBuffer[@"bytesPerRow"] = @(bytesPerRow);
        planeBuffer[@"width"] = @(width);
        planeBuffer[@"height"] = @(height);
        planeBuffer[@"bytes"] = [FlutterStandardTypedData typedDataWithBytes:bytes];

        [planes addObject:planeBuffer];
      }
      // Lock the base address before accessing pixel data, and unlock it afterwards.
      // Done accessing the `pixelBuffer` at this point.
      CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

      NSMutableDictionary *imageBuffer = [NSMutableDictionary dictionary];
      imageBuffer[@"width"] = [NSNumber numberWithUnsignedLong:imageWidth];
      imageBuffer[@"height"] = [NSNumber numberWithUnsignedLong:imageHeight];
      imageBuffer[@"format"] = @(_videoFormat);
      imageBuffer[@"planes"] = planes;
      imageBuffer[@"lensAperture"] = [NSNumber numberWithFloat:[_captureDevice lensAperture]];
      Float64 exposureDuration = CMTimeGetSeconds([_captureDevice exposureDuration]);
      Float64 nsExposureDuration = 1000000000 * exposureDuration;
      imageBuffer[@"sensorExposureTime"] = [NSNumber numberWithInt:nsExposureDuration];
      imageBuffer[@"sensorSensitivity"] = [NSNumber numberWithFloat:[_captureDevice ISO]];

      dispatch_async(dispatch_get_main_queue(), ^{
        eventSink(imageBuffer);
      });
    }
  }
  if (_isRecording && !_isRecordingPaused) {
    if (_videoWriter.status == AVAssetWriterStatusFailed) {
      [self reportErrorMessage:[NSString stringWithFormat:@"%@", _videoWriter.error]];
      return;
    }

    // ignore audio samples until the first video sample arrives to avoid black frames
    // https://github.com/flutter/flutter/issues/57831
    if (_videoWriter.status != AVAssetWriterStatusWriting && output != _captureVideoOutput) {
      return;
    }

    CMTime currentSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    if (_videoWriter.status != AVAssetWriterStatusWriting) {
      [_videoWriter startWriting];
      [_videoWriter startSessionAtSourceTime:currentSampleTime];
    }

    if (output == _captureVideoOutput) {
      if (_videoIsDisconnected) {
        _videoIsDisconnected = NO;

        if (_videoTimeOffset.value == 0) {
          _videoTimeOffset = CMTimeSubtract(currentSampleTime, _lastVideoSampleTime);
        } else {
          CMTime offset = CMTimeSubtract(currentSampleTime, _lastVideoSampleTime);
          _videoTimeOffset = CMTimeAdd(_videoTimeOffset, offset);
        }

        return;
      }

      _lastVideoSampleTime = currentSampleTime;

      CVPixelBufferRef nextBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      CMTime nextSampleTime = CMTimeSubtract(_lastVideoSampleTime, _videoTimeOffset);
      [_videoAdaptor appendPixelBuffer:nextBuffer withPresentationTime:nextSampleTime];
    } else {
      CMTime dur = CMSampleBufferGetDuration(sampleBuffer);

      if (dur.value > 0) {
        currentSampleTime = CMTimeAdd(currentSampleTime, dur);
      }

      if (_audioIsDisconnected) {
        _audioIsDisconnected = NO;

        if (_audioTimeOffset.value == 0) {
          _audioTimeOffset = CMTimeSubtract(currentSampleTime, _lastAudioSampleTime);
        } else {
          CMTime offset = CMTimeSubtract(currentSampleTime, _lastAudioSampleTime);
          _audioTimeOffset = CMTimeAdd(_audioTimeOffset, offset);
        }

        return;
      }

      _lastAudioSampleTime = currentSampleTime;

      if (_audioTimeOffset.value != 0) {
        CMSampleBufferRef adjustedSampleBuffer =
            [self copySampleBufferWithAdjustedTime:sampleBuffer by:_audioTimeOffset];
        [self newAudioSample:adjustedSampleBuffer];
        CFRelease(adjustedSampleBuffer);
      } else {
        [self newAudioSample:sampleBuffer];
      }
    }
  }
}

- (CMSampleBufferRef)copySampleBufferWithAdjustedTime:(CMSampleBufferRef)sample by:(CMTime)offset {
  CMItemCount count;
  CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
  CMSampleTimingInfo *pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
  CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
  for (CMItemCount i = 0; i < count; i++) {
    pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
    pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
  }
  CMSampleBufferRef sout;
  CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
  free(pInfo);
  return sout;
}

- (void)newVideoSample:(CMSampleBufferRef)sampleBuffer {
  if (_videoWriter.status != AVAssetWriterStatusWriting) {
    if (_videoWriter.status == AVAssetWriterStatusFailed) {
      [self reportErrorMessage:[NSString stringWithFormat:@"%@", _videoWriter.error]];
    }
    return;
  }
  if (_videoWriterInput.readyForMoreMediaData) {
    if (![_videoWriterInput appendSampleBuffer:sampleBuffer]) {
      [self reportErrorMessage:@"Unable to write to video input"];
    }
  }
}

- (void)newAudioSample:(CMSampleBufferRef)sampleBuffer {
  if (_videoWriter.status != AVAssetWriterStatusWriting) {
    if (_videoWriter.status == AVAssetWriterStatusFailed) {
      [self reportErrorMessage:[NSString stringWithFormat:@"%@", _videoWriter.error]];
    }
    return;
  }
  if (_audioWriterInput.readyForMoreMediaData) {
    if (![_audioWriterInput appendSampleBuffer:sampleBuffer]) {
      [self reportErrorMessage:@"Unable to write to audio input"];
    }
  }
}

- (void)close {
  if (_autoLensSwitchingTimer) {
    [_autoLensSwitchingTimer invalidate];
    _autoLensSwitchingTimer = nil;
  }

  [self stop];
  for (AVCaptureInput *input in [_videoCaptureSession inputs]) {
    [_videoCaptureSession removeInput:input];
  }
  for (AVCaptureOutput *output in [_videoCaptureSession outputs]) {
    [_videoCaptureSession removeOutput:output];
  }
  for (AVCaptureInput *input in [_audioCaptureSession inputs]) {
    [_audioCaptureSession removeInput:input];
  }
  for (AVCaptureOutput *output in [_audioCaptureSession outputs]) {
    [_audioCaptureSession removeOutput:output];
  }
}

- (void)dealloc {
  if (_autoLensSwitchingTimer) {
    [_autoLensSwitchingTimer invalidate];
    _autoLensSwitchingTimer = nil;
  }

  if (_latestPixelBuffer) {
    CFRelease(_latestPixelBuffer);
  }
  [_motionManager stopAccelerometerUpdates];
}

- (CVPixelBufferRef)copyPixelBuffer {
  __block CVPixelBufferRef pixelBuffer = nil;
  // Use `dispatch_sync` because `copyPixelBuffer` API requires synchronous return.
  dispatch_sync(self.pixelBufferSynchronizationQueue, ^{
    // No need weak self because it's dispatch_sync.
    pixelBuffer = self.latestPixelBuffer;
    self.latestPixelBuffer = nil;
  });
  return pixelBuffer;
}

- (void)startVideoRecordingWithCompletion:(void (^)(FlutterError *_Nullable))completion
                    messengerForStreaming:(nullable NSObject<FlutterBinaryMessenger> *)messenger {
  if (!_isRecording) {
    if (messenger != nil) {
      [self startImageStreamWithMessenger:messenger];
    }

    NSError *error;
    _videoRecordingPath = [self getTemporaryFilePathWithExtension:@"mp4"
                                                        subfolder:@"videos"
                                                           prefix:@"REC_"
                                                            error:error];
    if (error) {
      completion(FlutterErrorFromNSError(error));
      return;
    }
    if (![self setupWriterForPath:_videoRecordingPath]) {
      completion([FlutterError errorWithCode:@"IOError"
                                     message:@"Setup Writer Failed"
                                     details:nil]);
      return;
    }
    _isRecording = YES;
    _isRecordingPaused = NO;
    _videoTimeOffset = CMTimeMake(0, 1);
    _audioTimeOffset = CMTimeMake(0, 1);
    _videoIsDisconnected = NO;
    _audioIsDisconnected = NO;
    completion(nil);
  } else {
    completion([FlutterError errorWithCode:@"Error"
                                   message:@"Video is already recording"
                                   details:nil]);
  }
}

- (void)stopVideoRecordingWithCompletion:(void (^)(NSString *_Nullable,
                                                   FlutterError *_Nullable))completion {
  if (_isRecording) {
    _isRecording = NO;

    if (_videoWriter.status != AVAssetWriterStatusUnknown) {
      [_videoWriter finishWritingWithCompletionHandler:^{
        if (self->_videoWriter.status == AVAssetWriterStatusCompleted) {
          [self updateOrientation];
          completion(self->_videoRecordingPath, nil);
          self->_videoRecordingPath = nil;
        } else {
          completion(nil, [FlutterError errorWithCode:@"IOError"
                                              message:@"AVAssetWriter could not finish writing!"
                                              details:nil]);
        }
      }];
    }
  } else {
    NSError *error =
        [NSError errorWithDomain:NSCocoaErrorDomain
                            code:NSURLErrorResourceUnavailable
                        userInfo:@{NSLocalizedDescriptionKey : @"Video is not recording!"}];
    completion(nil, FlutterErrorFromNSError(error));
  }
}

- (void)pauseVideoRecording {
  _isRecordingPaused = YES;
  _videoIsDisconnected = YES;
  _audioIsDisconnected = YES;
}

- (void)resumeVideoRecording {
  _isRecordingPaused = NO;
}

- (void)lockCaptureOrientation:(FCPPlatformDeviceOrientation)pigeonOrientation {
  UIDeviceOrientation orientation =
      FCPGetUIDeviceOrientationForPigeonDeviceOrientation(pigeonOrientation);
  if (_lockedCaptureOrientation != orientation) {
    _lockedCaptureOrientation = orientation;
    [self updateOrientation];
  }
}

- (void)unlockCaptureOrientation {
  _lockedCaptureOrientation = UIDeviceOrientationUnknown;
  [self updateOrientation];
}

- (void)setFlashMode:(FCPPlatformFlashMode)mode
      withCompletion:(void (^)(FlutterError *_Nullable))completion {
  if (mode == FCPPlatformFlashModeTorch) {
    if (!_captureDevice.hasTorch) {
      completion([FlutterError errorWithCode:@"setFlashModeFailed"
                                     message:@"Device does not support torch mode"
                                     details:nil]);
      return;
    }
    if (!_captureDevice.isTorchAvailable) {
      completion([FlutterError errorWithCode:@"setFlashModeFailed"
                                     message:@"Torch mode is currently not available"
                                     details:nil]);
      return;
    }
    if (_captureDevice.torchMode != AVCaptureTorchModeOn) {
      [_captureDevice lockForConfiguration:nil];
      [_captureDevice setTorchMode:AVCaptureTorchModeOn];
      [_captureDevice unlockForConfiguration];
    }
  } else {
    if (!_captureDevice.hasFlash) {
      completion([FlutterError errorWithCode:@"setFlashModeFailed"
                                     message:@"Device does not have flash capabilities"
                                     details:nil]);
      return;
    }
    AVCaptureFlashMode avFlashMode = FCPGetAVCaptureFlashModeForPigeonFlashMode(mode);
    if (![_capturePhotoOutput.supportedFlashModes
            containsObject:[NSNumber numberWithInt:((int)avFlashMode)]]) {
      completion([FlutterError errorWithCode:@"setFlashModeFailed"
                                     message:@"Device does not support this specific flash mode"
                                     details:nil]);
      return;
    }
    if (_captureDevice.torchMode != AVCaptureTorchModeOff) {
      [_captureDevice lockForConfiguration:nil];
      [_captureDevice setTorchMode:AVCaptureTorchModeOff];
      [_captureDevice unlockForConfiguration];
    }
  }
  _flashMode = mode;
  completion(nil);
}

- (void)setExposureMode:(FCPPlatformExposureMode)mode {
  _exposureMode = mode;
  [self applyExposureMode];
}

- (void)applyExposureMode {
  [_captureDevice lockForConfiguration:nil];
  switch (_exposureMode) {
    case FCPPlatformExposureModeLocked:
      [_captureDevice setExposureMode:AVCaptureExposureModeAutoExpose];
      break;
    case FCPPlatformExposureModeAuto:
      if ([_captureDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
        [_captureDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
      } else {
        [_captureDevice setExposureMode:AVCaptureExposureModeAutoExpose];
      }
      break;
  }
  [_captureDevice unlockForConfiguration];
}

- (void)setFocusMode:(FCPPlatformFocusMode)mode {
  _focusMode = mode;
  [self applyFocusMode];
}

- (void)applyFocusMode {
  [self applyFocusMode:_focusMode onDevice:_captureDevice];
}

- (void)applyFocusMode:(FCPPlatformFocusMode)focusMode onDevice:(AVCaptureDevice *)captureDevice {
  [captureDevice lockForConfiguration:nil];
  switch (focusMode) {
    case FCPPlatformFocusModeLocked:
      if ([captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        [captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
      }
      break;
    case FCPPlatformFocusModeAuto:
      if ([captureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
        [captureDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
      } else if ([captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        [captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
      }
      break;
  }
  [captureDevice unlockForConfiguration];
}

- (void)pausePreview {
  _isPreviewPaused = true;
}

- (void)resumePreview {
  _isPreviewPaused = false;
}

- (void)setDescriptionWhileRecording:(NSString *)cameraName
                      withCompletion:(void (^)(FlutterError *_Nullable))completion {
  if (!_isRecording) {
    completion([FlutterError errorWithCode:@"setDescriptionWhileRecordingFailed"
                                   message:@"Device was not recording"
                                   details:nil]);
    return;
  }

  _captureDevice = self.captureDeviceFactory();

  AVCaptureConnection *oldConnection =
      [_captureVideoOutput connectionWithMediaType:AVMediaTypeVideo];

  // Stop video capture from the old output.
  [_captureVideoOutput setSampleBufferDelegate:nil queue:nil];

  // Remove the old video capture connections.
  [_videoCaptureSession beginConfiguration];
  [_videoCaptureSession removeInput:_captureVideoInput];
  [_videoCaptureSession removeOutput:_captureVideoOutput];

  NSError *error = nil;
  AVCaptureConnection *newConnection = [self createConnection:&error];
  if (error) {
    completion(FlutterErrorFromNSError(error));
    return;
  }

  // Keep the same orientation the old connections had.
  if (oldConnection && newConnection.isVideoOrientationSupported) {
    newConnection.videoOrientation = oldConnection.videoOrientation;
  }

  // Add the new connections to the session.
  if (![_videoCaptureSession canAddInput:_captureVideoInput])
    completion([FlutterError errorWithCode:@"VideoError"
                                   message:@"Unable switch video input"
                                   details:nil]);
  [_videoCaptureSession addInputWithNoConnections:_captureVideoInput];
  if (![_videoCaptureSession canAddOutput:_captureVideoOutput])
    completion([FlutterError errorWithCode:@"VideoError"
                                   message:@"Unable switch video output"
                                   details:nil]);
  [_videoCaptureSession addOutputWithNoConnections:_captureVideoOutput];
  if (![_videoCaptureSession canAddConnection:newConnection])
    completion([FlutterError errorWithCode:@"VideoError"
                                   message:@"Unable switch video connection"
                                   details:nil]);
  [_videoCaptureSession addConnection:newConnection];
  [_videoCaptureSession commitConfiguration];

  completion(nil);
}

- (CGPoint)CGPointForPoint:(nonnull FCPPlatformPoint *)point
           withOrientation:(UIDeviceOrientation)orientation {
  double x = point.x;
  double y = point.y;
  switch (orientation) {
    case UIDeviceOrientationPortrait:  // 90 ccw
      y = 1 - point.x;
      x = point.y;
      break;
    case UIDeviceOrientationPortraitUpsideDown:  // 90 cw
      x = 1 - point.y;
      y = point.x;
      break;
    case UIDeviceOrientationLandscapeRight:  // 180
      x = 1 - point.x;
      y = 1 - point.y;
      break;
    case UIDeviceOrientationLandscapeLeft:
    default:
      // No rotation required
      break;
  }
  return CGPointMake(x, y);
}

- (void)setExposurePoint:(FCPPlatformPoint *)point
          withCompletion:(void (^)(FlutterError *_Nullable))completion {
  if (!_captureDevice.isExposurePointOfInterestSupported) {
    completion([FlutterError errorWithCode:@"setExposurePointFailed"
                                   message:@"Device does not have exposure point capabilities"
                                   details:nil]);
    return;
  }
  UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
  [_captureDevice lockForConfiguration:nil];
  // A nil point resets to the center.
  [_captureDevice
      setExposurePointOfInterest:[self CGPointForPoint:(point
                                                            ?: [FCPPlatformPoint makeWithX:0.5
                                                                                         y:0.5])
                                       withOrientation:orientation]];
  [_captureDevice unlockForConfiguration];
  // Retrigger auto exposure
  [self applyExposureMode];
  completion(nil);
}

- (void)setFocusPoint:(FCPPlatformPoint *)point
       withCompletion:(void (^)(FlutterError *_Nullable))completion {
  if (!_captureDevice.isFocusPointOfInterestSupported) {
    completion([FlutterError errorWithCode:@"setFocusPointFailed"
                                   message:@"Device does not have focus point capabilities"
                                   details:nil]);
    return;
  }
  UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
  [_captureDevice lockForConfiguration:nil];
  // A nil point resets to the center.
  [_captureDevice
      setFocusPointOfInterest:[self
                                  CGPointForPoint:(point ?: [FCPPlatformPoint makeWithX:0.5 y:0.5])
                                  withOrientation:orientation]];
  [_captureDevice unlockForConfiguration];
  // Retrigger auto focus
  [self applyFocusMode];
  completion(nil);
}

- (void)setExposureOffset:(double)offset {
  [_captureDevice lockForConfiguration:nil];
  [_captureDevice setExposureTargetBias:offset completionHandler:nil];
  [_captureDevice unlockForConfiguration];
}

- (void)startImageStreamWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  [self startImageStreamWithMessenger:messenger
                   imageStreamHandler:[[FLTImageStreamHandler alloc]
                                          initWithCaptureSessionQueue:_captureSessionQueue]];
}

- (void)startImageStreamWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger
                   imageStreamHandler:(FLTImageStreamHandler *)imageStreamHandler {
  if (!_isStreamingImages) {
    FlutterEventChannel *eventChannel = [FlutterEventChannel
        eventChannelWithName:@"plugins.flutter.io/camera_avfoundation/imageStream"
             binaryMessenger:messenger];
    FLTThreadSafeEventChannel *threadSafeEventChannel =
        [[FLTThreadSafeEventChannel alloc] initWithEventChannel:eventChannel];

    _imageStreamHandler = imageStreamHandler;
    __weak typeof(self) weakSelf = self;
    [threadSafeEventChannel setStreamHandler:_imageStreamHandler
                                  completion:^{
                                    typeof(self) strongSelf = weakSelf;
                                    if (!strongSelf) return;

                                    dispatch_async(strongSelf.captureSessionQueue, ^{
                                      // cannot use the outter strongSelf
                                      typeof(self) strongSelf = weakSelf;
                                      if (!strongSelf) return;

                                      strongSelf.isStreamingImages = YES;
                                      strongSelf.streamingPendingFramesCount = 0;
                                    });
                                  }];
  } else {
    [self reportErrorMessage:@"Images from camera are already streaming!"];
  }
}

- (void)stopImageStream {
  if (_isStreamingImages) {
    _isStreamingImages = NO;
    _imageStreamHandler = nil;
  } else {
    [self reportErrorMessage:@"Images from camera are not streaming!"];
  }
}

- (void)receivedImageStreamData {
  self.streamingPendingFramesCount--;
}

- (void)setZoomLevel:(CGFloat)zoom withCompletion:(void (^)(FlutterError *_Nullable))completion {
  if (_captureDevice.maxAvailableVideoZoomFactor < zoom ||
      _captureDevice.minAvailableVideoZoomFactor > zoom) {
    NSString *errorMessage = [NSString
        stringWithFormat:@"Zoom level out of bounds (zoom level should be between %f and %f).",
                         _captureDevice.minAvailableVideoZoomFactor,
                         _captureDevice.maxAvailableVideoZoomFactor];

    completion([FlutterError errorWithCode:@"ZOOM_ERROR" message:errorMessage details:nil]);
    return;
  }

  NSError *error = nil;
  if (![_captureDevice lockForConfiguration:&error]) {
    completion(FlutterErrorFromNSError(error));
    return;
  }
  _captureDevice.videoZoomFactor = zoom;
  [_captureDevice unlockForConfiguration];

  completion(nil);
}

- (CGFloat)minimumAvailableZoomFactor {
  return _captureDevice.minAvailableVideoZoomFactor;
}

- (CGFloat)maximumAvailableZoomFactor {
  return _captureDevice.maxAvailableVideoZoomFactor;
}

- (BOOL)setupWriterForPath:(NSString *)path {
  NSError *error = nil;
  NSURL *outputURL;
  if (path != nil) {
    outputURL = [NSURL fileURLWithPath:path];
  } else {
    return NO;
  }

  if (_mediaSettings.enableAudio && !_isAudioSetup) {
    [self setUpCaptureSessionForAudio];
  }

  _videoWriter = [[AVAssetWriter alloc] initWithURL:outputURL
                                           fileType:AVFileTypeMPEG4
                                              error:&error];
  NSParameterAssert(_videoWriter);
  if (error) {
    [self reportErrorMessage:error.description];
    return NO;
  }

  NSMutableDictionary<NSString *, id> *videoSettings = [[_mediaSettingsAVWrapper
      recommendedVideoSettingsForAssetWriterWithFileType:AVFileTypeMPEG4
                                               forOutput:_captureVideoOutput] mutableCopy];

  if (_mediaSettings.videoBitrate || _mediaSettings.framesPerSecond) {
    NSMutableDictionary *compressionProperties = [[NSMutableDictionary alloc] init];

    if (_mediaSettings.videoBitrate) {
      compressionProperties[AVVideoAverageBitRateKey] = _mediaSettings.videoBitrate;
    }

    if (_mediaSettings.framesPerSecond) {
      compressionProperties[AVVideoExpectedSourceFrameRateKey] = _mediaSettings.framesPerSecond;
    }

    videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties;
  }

  _videoWriterInput =
      [_mediaSettingsAVWrapper assetWriterVideoInputWithOutputSettings:videoSettings];

  _videoAdaptor = [AVAssetWriterInputPixelBufferAdaptor
      assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput
                                 sourcePixelBufferAttributes:@{
                                   (NSString *)kCVPixelBufferPixelFormatTypeKey : @(_videoFormat)
                                 }];

  NSParameterAssert(_videoWriterInput);

  _videoWriterInput.expectsMediaDataInRealTime = YES;

  // Add the audio input
  if (_mediaSettings.enableAudio) {
    AudioChannelLayout acl;
    bzero(&acl, sizeof(acl));
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    NSMutableDictionary *audioOutputSettings = [@{
      AVFormatIDKey : [NSNumber numberWithInt:kAudioFormatMPEG4AAC],
      AVSampleRateKey : [NSNumber numberWithFloat:44100.0],
      AVNumberOfChannelsKey : [NSNumber numberWithInt:1],
      AVChannelLayoutKey : [NSData dataWithBytes:&acl length:sizeof(acl)],
    } mutableCopy];

    if (_mediaSettings.audioBitrate) {
      audioOutputSettings[AVEncoderBitRateKey] = _mediaSettings.audioBitrate;
    }

    _audioWriterInput =
        [_mediaSettingsAVWrapper assetWriterAudioInputWithOutputSettings:audioOutputSettings];

    _audioWriterInput.expectsMediaDataInRealTime = YES;

    [_mediaSettingsAVWrapper addInput:_audioWriterInput toAssetWriter:_videoWriter];
    [_audioOutput setSampleBufferDelegate:self queue:_captureSessionQueue];
  }

  if (_flashMode == FCPPlatformFlashModeTorch) {
    [self.captureDevice lockForConfiguration:nil];
    [self.captureDevice setTorchMode:AVCaptureTorchModeOn];
    [self.captureDevice unlockForConfiguration];
  }

  [_mediaSettingsAVWrapper addInput:_videoWriterInput toAssetWriter:_videoWriter];

  [_captureVideoOutput setSampleBufferDelegate:self queue:_captureSessionQueue];

  return YES;
}

- (void)setUpCaptureSessionForAudio {
  // Don't setup audio twice or we will lose the audio.
  if (_isAudioSetup) {
    return;
  }

  NSError *error = nil;
  // Create a device input with the device and add it to the session.
  // Setup the audio input.
  AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice
                                                                           error:&error];
  if (error) {
    [self reportErrorMessage:error.description];
  }
  // Setup the audio output.
  _audioOutput = [[AVCaptureAudioDataOutput alloc] init];

  if ([_audioCaptureSession canAddInput:audioInput]) {
    [_audioCaptureSession addInput:audioInput];

    if ([_audioCaptureSession canAddOutput:_audioOutput]) {
      [_audioCaptureSession addOutput:_audioOutput];
      _isAudioSetup = YES;
    } else {
      [self reportErrorMessage:@"Unable to add Audio input/output to session capture"];
      _isAudioSetup = NO;
    }
  }
}

- (void)reportErrorMessage:(NSString *)errorMessage {
  __weak typeof(self) weakSelf = self;
  FLTEnsureToRunOnMainQueue(^{
    [weakSelf.dartAPI reportError:errorMessage
                       completion:^(FlutterError *error){
                           // Ignore any errors, as this is just an event broadcast.
                       }];
  });
}

- (void)setupAutoLensSwitchingWithAvailableCameras:(NSArray<AVCaptureDevice *> *)availableCameras {
  _autoLensSwitchingEnabled = YES;
  _availableCamerasByType = [NSMutableDictionary dictionary];

  // Initialize with a middle distance to prevent immediate switching
  _estimatedObjectDistance = 1.0;

  // Initialize last switch time
  _lastSwitchTime = CACurrentMediaTime();

  for (AVCaptureDevice *device in availableCameras) {
    if ([device position] == [_captureDevice position]) {  // Same position (front/back)
      if (@available(iOS 13.0, *)) {
        if ([device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInUltraWideCamera]) {
          _availableCamerasByType[@"UltraWide"] = device;
        }
      }
      if ([device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) {
        _availableCamerasByType[@"Wide"] = device;
      }
      if ([device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInTelephotoCamera]) {
        _availableCamerasByType[@"Telephoto"] = device;
      }
    }
  }

  // Stop any existing timer
  if (_autoLensSwitchingTimer) {
    [_autoLensSwitchingTimer invalidate];
    _autoLensSwitchingTimer = nil;
  }

  // Setup timer to check distance and switch lenses
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_autoLensSwitchingTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                         target:self
                                       selector:@selector(checkDistanceAndSwitchLensIfNeeded)
                                       userInfo:nil
                                        repeats:YES];
  });
}

- (void)checkDistanceAndSwitchLensIfNeeded {
  __weak typeof(self) weakSelf = self;
  dispatch_async(_captureSessionQueue, ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;

    if (!strongSelf->_autoLensSwitchingEnabled || strongSelf->_isRecording) {
      return;
    }

    // Don't switch if we're in cooldown period (3 seconds after init or last switch)
    NSTimeInterval currentTime = CACurrentMediaTime();
    if (currentTime - strongSelf->_lastSwitchTime < 3.0) {
      return;
    }

    // Combine lens position with zoom factor for better distance estimation
    float lensPosition = strongSelf->_captureDevice.lensPosition;
    float zoomFactor = strongSelf->_captureDevice.videoZoomFactor;

    // Adjust the distance formula - lower values for telephoto
    float baseDistance = (1.0 - lensPosition) * 10.0;
    float adjustedDistance;

    // Improved distance calculation based on lens type
    if ([strongSelf->_captureDevice.deviceType
            isEqualToString:AVCaptureDeviceTypeBuiltInTelephotoCamera]) {
      adjustedDistance = baseDistance * 0.5;  // Reduce distance estimate for telephoto
    } else if ([strongSelf->_captureDevice.deviceType
                   isEqualToString:AVCaptureDeviceTypeBuiltInUltraWideCamera]) {
      // More conservative approach - don't assume ultra-wide has macro capability
      adjustedDistance = baseDistance * 1.5;
    } else {
      adjustedDistance = baseDistance;
    }

    // Add exponential smoothing to reduce noisy measurements (alpha = 0.3)
    float alpha = 0.3;
    float smoothedDistance =
        alpha * adjustedDistance + (1 - alpha) * strongSelf->_estimatedObjectDistance;
    strongSelf->_estimatedObjectDistance = smoothedDistance;

    // Check focus status
    BOOL isFocusChanging = strongSelf->_captureDevice.isAdjustingFocus;
    if (isFocusChanging) {
      return;  // Don't switch while focus is adjusting
    }

    BOOL supportsMacro = [self deviceSupportsMacro];
    // Determine which lens to use with device-appropriate thresholds
    NSString *currentLens = strongSelf->_captureDevice.deviceType;
    AVCaptureDevice *newCamera = nil;
    NSString *targetDeviceType = nil;
    NSLog(@"[LensDebug] Current=%@, Distance=%.2f, SupportsMacro=%@", currentLens,
          strongSelf->_estimatedObjectDistance, supportsMacro ? @"YES" : @"NO");

    // IMPROVED LENS SELECTION LOGIC
    if ([currentLens isEqualToString:AVCaptureDeviceTypeBuiltInTelephotoCamera]) {
      // Switch from telephoto to wide for closer objects
      if (strongSelf->_estimatedObjectDistance < 4.5 &&
          strongSelf->_availableCamerasByType[@"Wide"]) {
        newCamera = strongSelf->_availableCamerasByType[@"Wide"];
        targetDeviceType = @"Wide";
      }
    } else if ([currentLens isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) {
      if (strongSelf->_estimatedObjectDistance < 1.0 && supportsMacro) {
        // Only switch to ultrawide for close-ups IF device supports macro
        if (strongSelf->_availableCamerasByType[@"UltraWide"]) {
          newCamera = strongSelf->_availableCamerasByType[@"UltraWide"];
          targetDeviceType = @"UltraWide";
        }
      } else if (strongSelf->_estimatedObjectDistance > 7.0 &&
                 strongSelf->_availableCamerasByType[@"Telephoto"]) {
        // Switch to telephoto for distant objects
        newCamera = strongSelf->_availableCamerasByType[@"Telephoto"];
        targetDeviceType = @"Telephoto";
      }
      // Stay on wide for all other cases, including close-ups on non-macro devices
    } else if ([currentLens isEqualToString:AVCaptureDeviceTypeBuiltInUltraWideCamera]) {
      // Only stay on ultrawide for close-ups if we support macro
      if (strongSelf->_estimatedObjectDistance < 1.0 && !supportsMacro) {
        // No macro support, switch to wide
        if (strongSelf->_availableCamerasByType[@"Wide"]) {
          newCamera = strongSelf->_availableCamerasByType[@"Wide"];
          targetDeviceType = @"Wide";
        }
      } else if (strongSelf->_estimatedObjectDistance > 1.0) {
        // Not close-up, switch to wide
        if (strongSelf->_availableCamerasByType[@"Wide"]) {
          newCamera = strongSelf->_availableCamerasByType[@"Wide"];
          targetDeviceType = @"Wide";
        }
      }
      // Stay on ultrawide for close-ups if we support macro
    }

    NSLog(@"[LensDecision] Current=%@, Distance=%.2f, SupportsMacro=%@, NewCamera=%@", currentLens,
          strongSelf->_estimatedObjectDistance, supportsMacro ? @"YES" : @"NO",
          newCamera ? targetDeviceType : @"STAYING");

    // Switch to selected lens if different from current
    if (newCamera && ![newCamera.uniqueID isEqualToString:strongSelf->_captureDevice.uniqueID]) {
      NSLog(@"[AutoLensSwitch] Switching from %@ to %@", currentLens, newCamera.deviceType);
      strongSelf->_lastSwitchTime = CACurrentMediaTime();
      [strongSelf switchToCamera:newCamera];
    }
  });
}

- (void)switchToCamera:(AVCaptureDevice *)newCamera {
  // Save current flash mode to restore later
  FCPPlatformFlashMode currentFlashMode = _flashMode;

  NSError *error;
  AVCaptureDeviceInput *newInput = [AVCaptureDeviceInput deviceInputWithDevice:newCamera
                                                                         error:&error];
  if (error) {
    [self reportErrorMessage:error.description];
    return;
  }

  // Get old connection
  AVCaptureConnection *oldConnection =
      [_captureVideoOutput connectionWithMediaType:AVMediaTypeVideo];

  // Stop video capture
  [_captureVideoOutput setSampleBufferDelegate:nil queue:nil];

  // Begin configuration
  [_videoCaptureSession beginConfiguration];

  // Remove old input and output
  [_videoCaptureSession removeInput:_captureVideoInput];
  [_videoCaptureSession removeOutput:_captureVideoOutput];

  // Update capture device and input
  _captureDevice = newCamera;
  _captureVideoInput = newInput;

  // Add new input and output
  if ([_videoCaptureSession canAddInput:_captureVideoInput]) {
    [_videoCaptureSession addInputWithNoConnections:_captureVideoInput];
  } else {
    [self reportErrorMessage:@"Unable to add new video input"];
    [_videoCaptureSession commitConfiguration];
    return;
  }

  if ([_videoCaptureSession canAddOutput:_captureVideoOutput]) {
    [_videoCaptureSession addOutputWithNoConnections:_captureVideoOutput];
  } else {
    [self reportErrorMessage:@"Unable to add new video output"];
    [_videoCaptureSession commitConfiguration];
    return;
  }

  // Create and add new connection
  AVCaptureConnection *newConnection =
      [AVCaptureConnection connectionWithInputPorts:_captureVideoInput.ports
                                             output:_captureVideoOutput];

  // Preserve orientation
  if (oldConnection && newConnection.isVideoOrientationSupported) {
    newConnection.videoOrientation = oldConnection.videoOrientation;
  }

  if ([_videoCaptureSession canAddConnection:newConnection]) {
    [_videoCaptureSession addConnection:newConnection];
  } else {
    [self reportErrorMessage:@"Unable to add new video connection"];
    [_videoCaptureSession commitConfiguration];
    return;
  }

  // Commit configuration
  [_videoCaptureSession commitConfiguration];

  // Restore delegate
  [_captureVideoOutput setSampleBufferDelegate:self queue:_captureSessionQueue];

  // Apply settings to new camera
  [self applyFocusMode];
  [self applyExposureMode];

  // Force an immediate focus after switching lenses
  if ([_captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
    [_captureDevice lockForConfiguration:nil];
    [_captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
    [_captureDevice unlockForConfiguration];
  }

  // Restore flash mode
  [self setFlashMode:currentFlashMode
      withCompletion:^(FlutterError *_Nullable error){
          // Ignore errors during restoration
      }];
}

BOOL isiPhone13ProOrLater() {
  struct utsname systemInfo;
  uname(&systemInfo);

  NSString *deviceModel = [NSString stringWithUTF8String:systemInfo.machine];

  // iPhone models that qualify (13 Pro and later)
  NSArray *qualifyingModels = @[
    // iPhone 13 Pro models
    @"iPhone14,2", @"iPhone14,3",
    // iPhone 14 models
    @"iPhone14,4", @"iPhone14,5", @"iPhone14,7", @"iPhone14,8",
    // iPhone 15 models
    @"iPhone15,1", @"iPhone15,2", @"iPhone15,3", @"iPhone15,4",
    // iPhone 16 models
    @"iPhone16,1", @"iPhone16,2", @"iPhone16,3", @"iPhone16,4"
  ];

  // Direct model check
  for (NSString *model in qualifyingModels) {
    if ([deviceModel isEqualToString:model]) {
      return YES;
    }
  }

  // Extract numeric parts for future models
  NSScanner *scanner = [NSScanner scannerWithString:deviceModel];
  [scanner scanString:@"iPhone" intoString:nil];

  NSInteger majorVersion;
  [scanner scanInteger:&majorVersion];

  // iPhone14,x are iPhone 13 models and later
  return majorVersion >= 14;
}

- (BOOL)deviceSupportsMacro {
  // First check device model to filter out older devices quickly
  if (!isiPhone13ProOrLater()) {
    return NO;
  }

  // For iOS 15+, use the more direct approach with triple camera check
  if (@available(iOS 15.0, *)) {
    AVCaptureDevice *ultraWideDevice =
        [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInUltraWideCamera
                                           mediaType:AVMediaTypeVideo
                                            position:AVCaptureDevicePositionBack];
    if (!ultraWideDevice) {
      return NO;
    }

    // Check if this is a triple camera device (which typically has macro support)
    AVCaptureDevice *tripleCamera =
        [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInTripleCamera
                                           mediaType:AVMediaTypeVideo
                                            position:AVCaptureDevicePositionBack];
    return (tripleCamera != nil);
  } else {
    // For iOS 14 and earlier, use the discovery session approach
    NSArray *deviceTypes = @[
      AVCaptureDeviceTypeBuiltInUltraWideCamera, AVCaptureDeviceTypeBuiltInWideAngleCamera,
      AVCaptureDeviceTypeBuiltInTelephotoCamera
    ];

    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:deviceTypes
                              mediaType:AVMediaTypeVideo
                               position:AVCaptureDevicePositionBack];

    NSMutableArray *availableDeviceTypes = [NSMutableArray array];
    for (AVCaptureDevice *device in discoverySession.devices) {
      [availableDeviceTypes addObject:device.deviceType];
    }

    return ([availableDeviceTypes count] >= 3);
  }
}

@end
