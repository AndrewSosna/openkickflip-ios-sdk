//
//  KFAACEncoder.m
//  Kickflip
//
//  Created by Christopher Ballinger on 12/18/13.
//  Copyright (c) 2013 Christopher Ballinger. All rights reserved.
//
//  http://stackoverflow.com/questions/10817036/can-i-use-avcapturesession-to-encode-an-aac-stream-to-memory

#import "KFAACEncoder.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "KFFrame.h"
#import "KFLog.h"

@interface CycledBuffer : NSObject

@property(readonly) size_t size;

- (instancetype)initWithMaxCapacityInBytes:(size_t)capacity;

- (void)push:(void*)buff size:(size_t)size;
- (void)popToBuffer:(void*)buff bytes:(size_t)bytes;

@end

@interface KFAACEncoder()

@property (nonatomic)   AudioConverterRef   audioConverter;
@property (nonatomic)   uint8_t             *aacBuffer;
@property (nonatomic)   size_t              aacBufferSize;
@property (nonatomic)   CycledBuffer*       cycledBuffer;

@end

@implementation KFAACEncoder

- (void) dealloc
{
    AudioConverterDispose(_audioConverter);
    free(_aacBuffer);
}

- (instancetype) initWithBitrate:(size_t)bitrate sampleRate:(size_t)sampleRate channels:(size_t)channels
{
    if (self = [super initWithBitrate:bitrate sampleRate:sampleRate channels:channels])
    {
        self.encoderQueue = dispatch_queue_create("KF Encoder Queue", DISPATCH_QUEUE_SERIAL);
        _audioConverter = NULL;
        _aacBufferSize = 4096;
        _addADTSHeader = NO;
        _aacBuffer = malloc(_aacBufferSize * sizeof(uint8_t));
        memset(_aacBuffer, 0, _aacBufferSize);
        
        self.cycledBuffer = [[CycledBuffer alloc] initWithMaxCapacityInBytes: 4096];
    }
    
    return self;
}

- (void) setupAACEncoderFromSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    AudioStreamBasicDescription inAudioStreamBasicDescription = *CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer));
    
    AudioStreamBasicDescription outAudioStreamBasicDescription = {0}; // Always initialize the fields of a new audio stream basic description structure to zero, as shown here: ...
    
    // The number of frames per second of the data in the stream, when the stream is played at normal speed. For compressed formats, this field indicates the number of frames per second of equivalent decompressed data. The mSampleRate field must be nonzero, except when this structure is used in a listing of supported formats (see “kAudioStreamAnyRate”).
    if (self.sampleRate != 0)
    {
        outAudioStreamBasicDescription.mSampleRate = self.sampleRate;
    } else
    {
        outAudioStreamBasicDescription.mSampleRate = inAudioStreamBasicDescription.mSampleRate;

    }
    outAudioStreamBasicDescription.mFormatID = kAudioFormatMPEG4AAC; // kAudioFormatMPEG4AAC_HE does not work. Can't find `AudioClassDescription`. `mFormatFlags` is set to 0.
    outAudioStreamBasicDescription.mFormatFlags = kMPEG4Object_AAC_LC; // Format-specific flags to specify details of the format. Set to 0 to indicate no format flags. See “Audio Data Format Identifiers” for the flags that apply to each format.
    outAudioStreamBasicDescription.mBytesPerPacket = 0; // The number of bytes in a packet of audio data. To indicate variable packet size, set this field to 0. For a format that uses variable packet size, specify the size of each packet using an AudioStreamPacketDescription structure.
    outAudioStreamBasicDescription.mFramesPerPacket = 1024; // The number of frames in a packet of audio data. For uncompressed audio, the value is 1. For variable bit-rate formats, the value is a larger fixed number, such as 1024 for AAC. For formats with a variable number of frames per packet, such as Ogg Vorbis, set this field to 0.
    outAudioStreamBasicDescription.mBytesPerFrame = 0; // The number of bytes from the start of one frame to the start of the next frame in an audio buffer. Set this field to 0 for compressed formats. ...
    
    // The number of channels in each frame of audio data. This value must be nonzero.
    if (self.channels != 0)
    {
        outAudioStreamBasicDescription.mChannelsPerFrame = inAudioStreamBasicDescription.mChannelsPerFrame;
    } else
    {
        outAudioStreamBasicDescription.mChannelsPerFrame = self.channels;
    }
    
    outAudioStreamBasicDescription.mBitsPerChannel = 0; // ... Set this field to 0 for compressed formats.
    outAudioStreamBasicDescription.mReserved = 0; // Pads the structure out to force an even 8-byte alignment. Must be set to 0.
    AudioClassDescription *description = [self
                                          getAudioClassDescriptionWithType:kAudioFormatMPEG4AAC
                                          fromManufacturer:kAppleSoftwareAudioCodecManufacturer];

    OSStatus status = AudioConverterNewSpecific(&inAudioStreamBasicDescription, &outAudioStreamBasicDescription, 1, description, &_audioConverter);
    if (status != 0) {
        DDLogError(@"setup converter: %d", (int)status);
    }
    
    if (self.bitrate != 0)
    {
        UInt32 ulBitRate = (UInt32)self.bitrate;
        UInt32 ulSize = sizeof(ulBitRate);
        AudioConverterSetProperty(_audioConverter, kAudioConverterEncodeBitRate, ulSize, & ulBitRate);
    }
}

- (AudioClassDescription *)getAudioClassDescriptionWithType:(UInt32)type
                                           fromManufacturer:(UInt32)manufacturer
{
    static AudioClassDescription desc;
    
    UInt32 encoderSpecifier = type;
    OSStatus st;
    
    UInt32 size;
    st = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders,
                                    sizeof(encoderSpecifier),
                                    &encoderSpecifier,
                                    &size);
    if (st)
    {
        DDLogError(@"error getting audio format propery info: %d", (int)(st));
        return nil;
    }
    
    unsigned int count = size / sizeof(AudioClassDescription);
    AudioClassDescription descriptions[count];
    st = AudioFormatGetProperty(kAudioFormatProperty_Encoders,
                                sizeof(encoderSpecifier),
                                &encoderSpecifier,
                                &size,
                                descriptions);
    if (st)
    {
        DDLogError(@"error getting audio format propery: %d", (int)(st));
        return nil;
    }
    
    for (unsigned int i = 0; i < count; i++)
    {
        if ((type == descriptions[i].mSubType) &&
            (manufacturer == descriptions[i].mManufacturer))
        {
            memcpy(&desc, &(descriptions[i]), sizeof(desc));
            return &desc;
        }
    }
    
    return nil;
}

static OSStatus inInputDataProc(AudioConverterRef inAudioConverter,
                                UInt32 *ioNumberDataPackets,
                                AudioBufferList *ioData,
                                AudioStreamPacketDescription **outDataPacketDescription,
                                void *inUserData)
{
    KFAACEncoder *encoder = (__bridge KFAACEncoder *)(inUserData);
    UInt32 requestedPackets = *ioNumberDataPackets;
    
    if(requestedPackets > encoder.cycledBuffer.size / 2)
    {
        //NSLog(@"PCM buffer isn't full enough!");
        *ioNumberDataPackets = 0;
        return  -1;
    }
    
    static size_t staticBuffSize = 4096;
    static void* staticBuff = nil;
    
    if(!staticBuff)
    {
        staticBuff = malloc(staticBuffSize);
    }
    
    size_t outputBytesSize = requestedPackets * 2;
    [encoder.cycledBuffer popToBuffer:staticBuff bytes: outputBytesSize];
    
    ioData->mBuffers[0].mData = staticBuff;
    ioData->mBuffers[0].mDataByteSize = outputBytesSize;
    
    *ioNumberDataPackets = 1;
    //NSLog(@"Copied %zu samples into ioData", copiedSamples);
    return noErr;
}

- (void) encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CFRetain(sampleBuffer);
    dispatch_async(self.encoderQueue,
    ^{
        
        if (!_audioConverter)
        {
            [self setupAACEncoderFromSampleBuffer:sampleBuffer];
        }
        
        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        CFRetain(blockBuffer);
        
        size_t pcmBufferSize = 0;
        void* pcmBuffer = nil;
        OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &pcmBufferSize, &pcmBuffer);
    
        [_cycledBuffer push:pcmBuffer size:pcmBufferSize];
        
        NSError *error = nil;
        
        if (status != kCMBlockBufferNoErr)
        {
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        }
        
        memset(_aacBuffer, 0, _aacBufferSize);
        AudioBufferList outAudioBufferList = {0};
        outAudioBufferList.mNumberBuffers = 1;
        outAudioBufferList.mBuffers[0].mNumberChannels = 1;
        outAudioBufferList.mBuffers[0].mDataByteSize = _aacBufferSize;
        outAudioBufferList.mBuffers[0].mData = _aacBuffer;
        AudioStreamPacketDescription *outPacketDescription = NULL;
        UInt32 ioOutputDataPacketSize = 1;
      
        status = AudioConverterFillComplexBuffer(_audioConverter,
                                                 inInputDataProc,
                                                 (__bridge void *)(self),
                                                 &ioOutputDataPacketSize,
                                                 &outAudioBufferList,
                                                 outPacketDescription);
        
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

        //NSLog(@"Status %d", status);
        
        NSData *data = nil;
        if (status == 0)
        {
            NSData *rawAAC = [NSData dataWithBytes:outAudioBufferList.mBuffers[0].mData length:outAudioBufferList.mBuffers[0].mDataByteSize];
            if (_addADTSHeader) {
                NSData *adtsHeader = [self adtsDataForPacketLength:rawAAC.length];
                NSMutableData *fullData = [NSMutableData dataWithData:adtsHeader];
                [fullData appendData:rawAAC];
                data = fullData;
            } else {
                data = rawAAC;
            }
        } else {
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        }
        if (self.delegate) {
            KFFrame *frame = [[KFFrame alloc] initWithData:data pts:pts];
            dispatch_async(self.callbackQueue, ^{
                [self.delegate encoder:self encodedFrame:frame];
            });
        }
        CFRelease(sampleBuffer);
        CFRelease(blockBuffer);
   });
}


/**
 *  Add ADTS header at the beginning of each and every AAC packet.
 *  This is needed as MediaCodec encoder generates a packet of raw
 *  AAC data.
 *
 *  Note the packetLen must count in the ADTS header itself.
 *  See: http://wiki.multimedia.cx/index.php?title=ADTS
 *  Also: http://wiki.multimedia.cx/index.php?title=MPEG-4_Audio#Channel_Configurations
 **/
- (NSData*) adtsDataForPacketLength:(size_t)packetLength {
    int adtsLength = 7;
    char *packet = malloc(sizeof(char) * adtsLength);
    // Variables Recycled by addADTStoPacket
    int profile = 2;  //AAC LC
    //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
    int freqIdx = 4;  //44.1KHz
    int chanCfg = 1;  //MPEG-4 Audio Channel Configuration. 1 Channel front-center
    size_t fullLength = adtsLength + packetLength;
    // fill in ADTS data
    packet[0] = (char)0xFF;	// 11111111  	= syncword
    packet[1] = (char)0xF9;	// 1111 1 00 1  = syncword MPEG-2 Layer CRC
    packet[2] = (char)(((profile-1)<<6) + (freqIdx<<2) +(chanCfg>>2));
    packet[3] = (char)(((chanCfg&3)<<6) + (fullLength>>11));
    packet[4] = (char)((fullLength&0x7FF) >> 3);
    packet[5] = (char)(((fullLength&7)<<5) + 0x1F);
    packet[6] = (char)0xFC;
    NSData *data = [NSData dataWithBytesNoCopy:packet length:adtsLength freeWhenDone:YES];
    return data;
}


@end

@implementation CycledBuffer
{
    UInt8*              _memoryBlock;
    UInt8*              _finalMemoryBlockAdress;
    size_t              _memoryBlockSizeInBytes;
    
    UInt8*              _readPointer;
    UInt8*              _writePointer;
    
    size_t              _bytesAvailable;
}

- (size_t)size
{
    return _bytesAvailable;
}

- (instancetype)initWithMaxCapacityInBytes:(size_t)capacity
{
    if(self = [super init])
    {
        _memoryBlockSizeInBytes = capacity;
        
        _memoryBlock = malloc(_memoryBlockSizeInBytes);
        _finalMemoryBlockAdress = _memoryBlock + _memoryBlockSizeInBytes;
        
        _readPointer = _memoryBlock;
        _writePointer = _memoryBlock;
    }
    
    return self;
}

- (void)push:(void*)inputBuffer size:(size_t)inputBufferSize
{
    size_t bytesWritten = 0;
    size_t bytesOffsetInInputBuffer = 0;
    
    @synchronized(self)
    {
        while (bytesWritten < inputBufferSize)
        {
            NSInteger bytesToWrite =  inputBufferSize - bytesWritten;
            NSInteger freeBytesInTheDestinationBuffer = (_finalMemoryBlockAdress - _writePointer);
            
            if(bytesToWrite > freeBytesInTheDestinationBuffer)
            {
                bytesToWrite = freeBytesInTheDestinationBuffer;
            }
            
            memcpy(_writePointer,
                   inputBuffer + bytesOffsetInInputBuffer,
                   bytesToWrite);
            
            _writePointer += bytesToWrite;
            
            if(_writePointer >= _finalMemoryBlockAdress)
            {
                _writePointer = _memoryBlock;
            }
            
            _bytesAvailable = _bytesAvailable + bytesToWrite;
            
            if(_bytesAvailable > _memoryBlockSizeInBytes)
            {
                _bytesAvailable = _memoryBlockSizeInBytes;
                _readPointer = _writePointer;
            }
            
            bytesWritten += bytesToWrite;
            bytesOffsetInInputBuffer += bytesToWrite;
            
        }
    }
}

- (void)popToBuffer:(void*)inputBuffer bytes:(size_t)inputBufferSize
{
    //cleanup buffer
    memset((UInt8*)inputBuffer, 0, inputBufferSize);
    
    NSUInteger bytesRead = 0;
    NSUInteger bytesOffsetInOutput = 0;
    
    @synchronized(self)
    {
        while(bytesRead < inputBufferSize && _bytesAvailable > 0)
        {
            NSInteger bytesToRead = (_finalMemoryBlockAdress - _readPointer);
            
            if(bytesToRead > inputBufferSize)
            {
                bytesToRead = inputBufferSize;
            }
            
            if(bytesToRead > _bytesAvailable)
            {
                bytesToRead = _bytesAvailable;
            }
            
            memcpy((UInt8*)inputBuffer + bytesOffsetInOutput,
                   _readPointer,
                   bytesToRead);
            
            bytesRead += bytesToRead;
            bytesOffsetInOutput += bytesToRead;
            _bytesAvailable -= bytesToRead;
            _readPointer += bytesToRead;
            
            if(_readPointer >= _finalMemoryBlockAdress)
            {
                _readPointer = _memoryBlock;
            }
        }
    }
}

@end
