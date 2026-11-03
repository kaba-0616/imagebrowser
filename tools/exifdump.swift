import Foundation
import ImageIO

let args = Array(CommandLine.arguments.dropFirst())
for path in args {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
        print("READ_FAIL \(path)"); continue
    }
    var dates: [String] = []
    func sweep(_ dict: [String: Any], _ prefix: String) {
        for (k, v) in dict {
            if let sub = v as? [String: Any] { sweep(sub, prefix + k + ".") }
            else if k.lowercased().contains("date") || k.lowercased().contains("time") {
                dates.append("\(prefix)\(k)=\(v)")
            }
        }
    }
    sweep(props, "")
    let w = props[kCGImagePropertyPixelWidth as String] ?? "?"
    let h = props[kCGImagePropertyPixelHeight as String] ?? "?"
    print("\((path as NSString).lastPathComponent) \(w)x\(h) :: \(dates.sorted().joined(separator: " | "))")
}
