import Foundation

/// Runs an include-only original DolDoc link through the explicit program launcher.
public struct OriginalProgramLink {
    public let label:String,path:String
    public static func parse(_ format:String,_ cwd:String)->OriginalProgramLink? {
        let chars=Array(format)
        func quoted(_ at:Int)->String? {
            if at<0 || at>=chars.count || chars[at] != "\"" {return nil}
            var out="",i=at+1
            while i<chars.count {let c=chars[i];i+=1;if c=="\"" {return out};if c=="\\" && i<chars.count {out.append(chars[i]);i+=1} else {out.append(c)}};return nil
        }
        guard let marker=format.range(of:",LM=") else {return nil}
        let at=format.distance(from:format.startIndex,to:marker.upperBound)
        guard let macro=quoted(at),let regex=try? NSRegularExpression(pattern:#"\s*#include\s+"([^"]+)"\s*;?\s*"#),let m=regex.firstMatch(in:macro,range:NSRange(location:0,length:(macro as NSString).length)),m.range.length==(macro as NSString).length else {return nil}
        guard var path=Paths.normalize(cwd,(macro as NSString).substring(with:m.range(at:1))) else {return nil}
        if !Paths.name(path).contains(".") {path+=".HC"};if path.lowercased().hasSuffix(".z") {path=String(path.dropLast(2))}
        let tag=chars.firstIndex(of:"\"") ?? -1
        return OriginalProgramLink(label:quoted(tag) ?? "",path:path)
    }
}
