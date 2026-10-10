import AVFoundation
import CoreAudio
import Foundation

// The buffer is copied before transfer and only read on its processing queue.
struct OwnedPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let byteCount: Int

    static func byteCount(for buffer: AVAudioPCMBuffer) throws -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let expectedBufferCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let (bytesPerBuffer, frameOverflow) = Int(buffer.frameLength).multipliedReportingOverflow(by: bytesPerFrame)
        let (total, bufferOverflow) = bytesPerBuffer.multipliedReportingOverflow(by: buffers.count)
        guard bytesPerFrame > 0, buffers.count == expectedBufferCount, expectedBufferCount > 0,
              !frameOverflow, !bufferOverflow else {
            throw RecorderError.captureFailed("Invalid PCM buffer size.")
        }

        return total
    }

    init(copying source: AVAudioPCMBuffer, byteCount: Int) throws {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            throw RecorderError.captureFailed("Could not allocate an owned PCM buffer.")
        }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw RecorderError.captureFailed("PCM buffer channel layout does not match its format.")
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let destinationBuffer = destinationBuffers[index]
            let bytes = Int(destinationBuffer.mDataByteSize)
            guard bytes <= Int(sourceBuffer.mDataByteSize),
                  let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else {
                throw RecorderError.captureFailed("PCM buffer has missing or incomplete sample data.")
            }

            memcpy(destinationData, sourceData, bytes)
        }

        buffer = copy
        self.byteCount = byteCount
    }
}
