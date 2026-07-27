import Flutter
import UIKit
import AVFoundation

public class SwiftLivePhotoPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "live_photo_maker", binaryMessenger: registrar.messenger())
    let instance = SwiftLivePhotoPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    self.createLivePhoto(method: call.method,arguments: call.arguments, result: result)
  }

   func createLivePhoto(method:String,arguments:Any?,result:@escaping FlutterResult) ->  Void{
      if method == "image_to_mov" {
             let argList = arguments as! Array<String>
             let imageURL = URL.init(fileURLWithPath: argList[0])
            var width:Int = Int(argList[1])!
            var height:Int = Int(argList[2])!
            let scale:Double = Double(width) / Double(height)
             while(width % 16 != 0){
                width -= 1;
             }
             height = Int(Double(width) / scale)
              print("\(width)+\(height)")
             let videoSettings = CXEImageToVideoSync.videoSettings(codec: AVVideoCodecType.h264.rawValue, width: width, height: height)
             let sync = CXEImageToVideoSync(videoSettings: videoSettings)
             let fileURL = sync.createMovieFrom(url: imageURL, duration: 4)
             result(fileURL.absoluteString.replacingOccurrences(of: "file://", with: ""))
      }else if method == "create_live_photo" {
               let pathList = arguments as! Array<String>
               let photoURL = URL.init(fileURLWithPath: pathList.first!)
               let sourceVideoPath = URL.init(fileURLWithPath: pathList.last!)

              LivePhotoMaker.generate(from: photoURL, videoURL: sourceVideoPath, progress: { (percent) in
              }) { (livePhoto, resources, errorMessage) in
                  guard let resources = resources else {
                      result(FlutterError(code: "live_photo_create_failed",
                                          message: errorMessage ?? "Live Photo generation failed.",
                                          details: nil))
                      return
                  }
                  LivePhotoMaker.saveToLibrary(resources, completion: { (success, saveError) in
                      if success {
                            result("success")
                      }
                      else {
                             result(FlutterError(code: "live_photo_save_failed",
                                                 message: saveError ?? "Couldn't save the Live Photo to the photo library.",
                                                 details: nil))
                      }
                  })
              }
           }
  }
}
