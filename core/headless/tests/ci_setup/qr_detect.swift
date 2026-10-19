// Reads every .png in a directory and prints one line per image: name <TAB> OK|NONE|ERROR <TAB> decoded text.
// Used by qr_check_macos.sh: the operating system's own QR detector (CoreImage) is the independent judge of ci_setup.qr.
import CoreImage
import Foundation

let dir = CommandLine.arguments[1]
let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.sorted()
let context = CIContext()
let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: context,
                          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
for name in names {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: dir + "/" + name)) else {
        print("\(name)\tERROR\tcannot load")
        continue
    }
    if let code = detector.features(in: image).first as? CIQRCodeFeature, let text = code.messageString {
        print("\(name)\tOK\t\(text.replacingOccurrences(of: "\n", with: "\\n"))")
    } else {
        print("\(name)\tNONE\t")
    }
}
