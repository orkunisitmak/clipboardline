import Foundation
import AVFoundation
import CoreVideo
import AudioToolbox

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func make(_ suffix: String, type: AVFileType) throws {
    let file = destination.appendingPathComponent("synthetic-rgb-tone." + suffix)
    try? FileManager.default.removeItem(at: file)
    let writer = try AVAssetWriter(outputURL: file, fileType: type)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 160, AVVideoHeightKey: 120, AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 128_000, AVVideoMaxKeyFrameIntervalKey: 10,
            AVVideoAllowFrameReorderingKey: false]])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
    writer.add(video); writer.add(audio)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    var pcm = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
        mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &pcm,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format) == noErr)
    let group = DispatchGroup(); group.enter(); group.enter()
    var frame = 0, sample = 0
    video.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic-video")) {
        while video.isReadyForMoreMediaData && frame < 60 {
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess)
            let pixel = buffer!; CVPixelBufferLockBaseAddress(pixel, [])
            let data = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<120 { for x in 0..<160 {
                let at = y * stride + x * 4
                data[at] = frame >= 40 ? 220 : 0
                data[at + 1] = frame >= 20 && frame < 40 ? 220 : 0
                data[at + 2] = frame < 20 ? 220 : 0
                data[at + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(pixel, [])
            precondition(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
            frame += 1
        }
        if frame == 60 { frame += 1; video.markAsFinished(); group.leave() }
    }
    audio.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic-audio")) {
        while audio.isReadyForMoreMediaData && sample < 264_600 {
            let count = min(1024, 264_600 - sample)
            let values = (0..<count).map { Float(sin(Double(sample + $0) * 2 * .pi * 440 / 44_100) * 0.15) }
            var block: CMBlockBuffer?
            precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block) == noErr)
            values.withUnsafeBytes { precondition(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: count * 4) == noErr) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                presentationTimeStamp: CMTime(value: Int64(sample), timescale: 44_100), decodeTimeStamp: .invalid)
            var size = 4, ready: CMSampleBuffer?
            precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block!,
                formatDescription: format!, sampleCount: count, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &ready) == noErr)
            precondition(audio.append(ready!)); sample += count
        }
        if sample == 264_600 { sample += 1; audio.markAsFinished(); group.leave() }
    }
    precondition(group.wait(timeout: .now() + 30) == .success)
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    precondition(finished.wait(timeout: .now() + 30) == .success)
    guard writer.status == .completed else { throw writer.error! }
    print(file.lastPathComponent + " generated: 6 seconds, red/green/blue, 440 Hz AAC mono")
}
func makeSilent() throws {
    let source = AVURLAsset(url: destination.appendingPathComponent("synthetic-rgb-tone.mp4"))
    guard let sourceTrack = source.tracks(withMediaType: .video).first else {
        throw NSError(domain: "SyntheticFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Generated RGB video track is missing."])
    }
    let composition = AVMutableComposition()
    guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw NSError(domain: "SyntheticFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Silent composition could not be created."])
    }
    try video.insertTimeRange(sourceTrack.timeRange, of: sourceTrack, at: .zero)
    video.preferredTransform = sourceTrack.preferredTransform
    let file = destination.appendingPathComponent("synthetic-rgb-silent.mp4")
    try? FileManager.default.removeItem(at: file)
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
        throw NSError(domain: "SyntheticFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Silent passthrough export is unavailable."])
    }
    export.outputURL = file; export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true
    let finished = DispatchSemaphore(value: 0)
    export.exportAsynchronously { finished.signal() }
    precondition(finished.wait(timeout: .now() + 30) == .success)
    guard export.status == .completed else { throw export.error! }
    let result = AVURLAsset(url: file)
    precondition(result.tracks(withMediaType: .audio).isEmpty)
    precondition(result.tracks(withMediaType: .video).count == 1)
    print(file.lastPathComponent + " generated: original RGB H.264 track, no audio track")
}

if !CommandLine.arguments.contains("--silent-only") {
    try make("mp4", type: .mp4)
    try make("mov", type: .mov)
}
try makeSilent()
