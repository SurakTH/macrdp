#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/HostTime.h>
#import <Foundation/Foundation.h>
#include <stdatomic.h>

#if __has_include(<CoreAudio/AudioHardwareTapping.h>)
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

enum { TapSlots = 8, TapMaxFrames = 1024, TapTargetFrames = 256 };

typedef struct {
    uint32_t count;
    uint64_t hostTime;
    float left[TapMaxFrames];
    float right[TapMaxFrames];
} TapSamples;

typedef struct {
    AudioObjectID tap;
    AudioObjectID device;
    AudioDeviceIOProcID proc;
    bool started;
    _Atomic uint32_t readIndex;
    _Atomic uint32_t writeIndex;
    TapSamples slots[TapSlots];
} MacAudioTap;

static OSStatus receiveAudio(AudioObjectID device, const AudioTimeStamp *now,
                              const AudioBufferList *input, const AudioTimeStamp *inputTime,
                              AudioBufferList *output, const AudioTimeStamp *outputTime,
                              void *context) {
    (void)device;
    (void)now;
    (void)output;
    (void)outputTime;
    MacAudioTap *tap = context;
    uint32_t write = atomic_load_explicit(&tap->writeIndex, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&tap->readIndex, memory_order_acquire);
    if (write - read >= TapSlots || input->mNumberBuffers == 0) return noErr;

    const AudioBuffer *left = &input->mBuffers[0];
    const AudioBuffer *right = input->mNumberBuffers == 2 ? &input->mBuffers[1] : NULL;
    TapSamples *slot = &tap->slots[write % TapSlots];
    if (left->mData == NULL) return noErr;
    if (input->mNumberBuffers == 1 && left->mNumberChannels == 2) {
        uint32_t count = left->mDataByteSize / (sizeof(float) * 2);
        if (count == 0 || count > TapMaxFrames) return noErr;
        const float *samples = left->mData;
        for (uint32_t i = 0; i < count; i++) {
            slot->left[i] = samples[2 * i];
            slot->right[i] = samples[2 * i + 1];
        }
        slot->count = count;
    } else if (right && left->mNumberChannels == 1 && right->mNumberChannels == 1 &&
               right->mData && right->mDataByteSize == left->mDataByteSize) {
        uint32_t count = left->mDataByteSize / sizeof(float);
        if (count == 0 || count > TapMaxFrames) return noErr;
        memcpy(slot->left, left->mData, left->mDataByteSize);
        memcpy(slot->right, right->mData, right->mDataByteSize);
        slot->count = count;
    } else {
        return noErr;
    }

    slot->hostTime = inputTime->mFlags & kAudioTimeStampHostTimeValid ? inputTime->mHostTime : 0;
    atomic_store_explicit(&tap->writeIndex, write + 1, memory_order_release);
    return noErr;
}

void macrdp_audio_tap_close(MacAudioTap *tap) {
    if (@available(macOS 14.2, *)) {
        if (tap->started) AudioDeviceStop(tap->device, tap->proc);
        if (tap->proc) AudioDeviceDestroyIOProcID(tap->device, tap->proc);
        if (tap->device) AudioHardwareDestroyAggregateDevice(tap->device);
        if (tap->tap) AudioHardwareDestroyProcessTap(tap->tap);
    }
    free(tap);
}

MacAudioTap *macrdp_audio_tap_open(OSStatus *error) {
    *error = kAudioHardwareUnsupportedOperationError;
    if (@available(macOS 14.2, *)) {
        @autoreleasepool {
            MacAudioTap *tap = calloc(1, sizeof(*tap));
            if (!tap) return NULL;
            atomic_init(&tap->readIndex, 0);
            atomic_init(&tap->writeIndex, 0);

            NSDictionary *settings;
            CATapDescription *description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
            description.name = @"macrdp system audio";
            description.privateTap = YES;
            description.muteBehavior = CATapUnmuted;
            *error = AudioHardwareCreateProcessTap(description, &tap->tap);
            if (*error != noErr) goto fail;

            AudioStreamBasicDescription format = {0};
            UInt32 formatSize = sizeof(format);
            AudioObjectPropertyAddress formatProperty = {
                kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
            };
            *error = AudioObjectGetPropertyData(tap->tap, &formatProperty, 0, NULL, &formatSize, &format);
            if (*error != noErr) goto fail;
            if (format.mSampleRate != 48000 || format.mChannelsPerFrame != 2 ||
                format.mFormatID != kAudioFormatLinearPCM || format.mBitsPerChannel != 32 ||
                !(format.mFormatFlags & kAudioFormatFlagIsFloat) ||
                (format.mFormatFlags & kAudioFormatFlagIsBigEndian)) {
                *error = kAudioDeviceUnsupportedFormatError;
                goto fail;
            }

            settings = @{
                @kAudioAggregateDeviceNameKey: @"macrdp system audio",
                @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
                @kAudioAggregateDeviceIsPrivateKey: @YES,
                @kAudioAggregateDeviceTapAutoStartKey: @YES,
                @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: description.UUID.UUIDString}],
            };
            *error = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)settings, &tap->device);
            if (*error != noErr) goto fail;

            UInt32 frames = TapTargetFrames;
            AudioObjectPropertyAddress frameProperty = {
                kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
            };
            // The private aggregate can retain its default if the device
            // rejects the requested period.
            AudioObjectSetPropertyData(tap->device, &frameProperty, 0, NULL, sizeof(frames), &frames);
            *error = AudioDeviceCreateIOProcID(tap->device, receiveAudio, tap, &tap->proc);
            if (*error != noErr) goto fail;
            *error = AudioDeviceStart(tap->device, tap->proc);
            if (*error != noErr) goto fail;
            tap->started = true;
            return tap;

        fail:
            macrdp_audio_tap_close(tap);
        }
    }
    return NULL;
}

uint32_t macrdp_audio_tap_read(MacAudioTap *tap, float *left, float *right, uint32_t capacity, uint64_t *ageNanos) {
    uint32_t read = atomic_load_explicit(&tap->readIndex, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&tap->writeIndex, memory_order_acquire);
    if (write == read) return 0;
    // If the reader fell behind, prioritize recent samples. The producer
    // cannot overwrite any of these slots until readIndex advances.
    if (write - read > 4) read = write - 4;
    const TapSamples *slot = &tap->slots[read % TapSlots];
    uint32_t count = slot->count;
    if (count > capacity) {
        atomic_store_explicit(&tap->readIndex, read + 1, memory_order_release);
        return 0;
    }
    memcpy(left, slot->left, count * sizeof(float));
    memcpy(right, slot->right, count * sizeof(float));
    uint64_t now = AudioGetCurrentHostTime();
    *ageNanos = slot->hostTime != 0 && now >= slot->hostTime
        ? AudioConvertHostTimeToNanos(now - slot->hostTime) : UINT64_MAX;
    atomic_store_explicit(&tap->readIndex, read + 1, memory_order_release);
    return count;
}

bool macrdp_audio_tap_output_running(void) {
    AudioObjectID output = kAudioObjectUnknown;
    UInt32 size = sizeof(output);
    AudioObjectPropertyAddress property = {
        kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &output) != noErr ||
        output == kAudioObjectUnknown) {
        return false;
    }

    UInt32 running = 0;
    size = sizeof(running);
    property.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere;
    return AudioObjectGetPropertyData(output, &property, 0, NULL, &size, &running) == noErr && running != 0;
}
#else
void *macrdp_audio_tap_open(OSStatus *error) {
    *error = kAudioHardwareUnsupportedOperationError;
    return NULL;
}

void macrdp_audio_tap_close(void *tap) { (void)tap; }

uint32_t macrdp_audio_tap_read(void *tap, float *left, float *right, uint32_t capacity, uint64_t *ageNanos) {
    (void)tap;
    (void)left;
    (void)right;
    (void)capacity;
    (void)ageNanos;
    return 0;
}

bool macrdp_audio_tap_output_running(void) { return false; }
#endif
