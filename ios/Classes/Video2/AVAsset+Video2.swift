import AVFoundation

extension AVAsset {
    func countFrames(exact: Bool) -> Int {
        var frameCount = 0
        if let videoReader = try? AVAssetReader(asset: self) {
            if let videoTrack = self.tracks(withMediaType: .video).first {
                frameCount = Int(CMTimeGetSeconds(self.duration) * Float64(videoTrack.nominalFrameRate))
                if exact {
                    frameCount = 0
                    let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
                    videoReader.add(videoReaderOutput)
                    videoReader.startReading()
                    while videoReaderOutput.copyNextSampleBuffer() != nil {
                        frameCount += 1
                    }
                    videoReader.cancelReading()
                }
            }
        }
        return frameCount
    }

    func makeStillImageTimeRange(percent: Float, inFrameCount: Int = 0) -> CMTimeRange {
        var time = self.duration
        var frameCount = inFrameCount
        if frameCount == 0 {
            frameCount = self.countFrames(exact: true)
        }
        guard frameCount > 0 else {
            return CMTimeRange(start: .zero, duration: .zero)
        }
        let frameDuration = Int64(Float(time.value) / Float(frameCount))
        time.value = Int64(Float(time.value) * percent)
        return CMTimeRangeMake(start: time, duration: CMTimeMake(value: frameDuration, timescale: time.timescale))
    }
}

