import Foundation
import zlib

/// Original dictionary data, loaded only when source/native metadata requests the dictionary service.
public final class TempleDictionary {
    private unowned let k: Kernel
    private var words: [UInt8]?
    private var definitions: [UInt8]?
    private var lookup: [String:Int] = [:]
    public init(_ kernel: Kernel) {k=kernel}
    public func initialize() throws {
        if words != nil {return}
        guard let data=k.env.runtimeFile("dictionary/words.bin") else {throw VmFault(chCode("Dict"),"Original dictionary missing")}
        var p=0,count=0
        while p < data.count && data[p] == 1 {
            p+=1;let start=p
            while p < data.count && data[p] != 0 {p+=1}
            guard p+2 < data.count else {throw VmFault(chCode("Dict"),"Truncated dictionary word")}
            lookup[latin1(Array(data[start..<p])).uppercased()]=Int(data[p+1]) | Int(data[p+2]) << 8
            count+=1;p+=3
        }
        words=data
        let ptr=try k.mem.malloc(Int64(data.count+1));k.mem.writeBytes(ptr,data);k.mem.st1(ptr+data.count,0)
        let a=k.o.global("acd")
        k.mem.st8(a+k.o.member("CAutoCompleteDictGlbls","word_lst"),Int64(ptr))
        k.mem.st8(a+k.o.member("CAutoCompleteDictGlbls","word_lst_size"),Int64(data.count))
        k.mem.st8(a+k.o.member("CAutoCompleteDictGlbls","num_words"),Int64(count))
    }
    public func get(_ word:String,_ number:Int=1,all:Bool=false) throws -> [UInt8]? {
        try initialize()
        guard let block=lookup[word.uppercased()] else {return nil}
        if definitions == nil {definitions=k.env.runtimeFile("dictionary/definitions.bin")}
        guard let bytes=definitions else {return nil}
        func u32(_ o:Int) throws -> Int {
            guard o>=0, o+4<=bytes.count else {throw VmFault(chCode("Dict"),"Dictionary bounds")}
            return Int(bytes[o]) | Int(bytes[o+1]) << 8 | Int(bytes[o+2]) << 16 | Int(bytes[o+3]) << 24
        }
        guard bytes.count>=20, latin1(Array(bytes[0..<4]))=="TODI", try u32(8)==16384 else {throw VmFault(chCode("Dict"),"Dictionary format")}
        let count=try u32(12), base=16+(count+1)*4
        func inflate(_ index:Int) throws -> [UInt8] {
            if index>=count {return []}
            let start=try u32(16+index*4), end=try u32(20+index*4)
            guard end>=start,base+end<=bytes.count else {throw VmFault(chCode("Dict"),"Dictionary block bounds")}
            var out=[UInt8](repeating:0,count:16384), length=uLongf(16384)
            let status=bytes.withUnsafeBufferPointer {src in out.withUnsafeMutableBufferPointer {dst in
                uncompress(dst.baseAddress!, &length, src.baseAddress!+base+start, uLong(end-start))
            }}
            guard status==Z_OK else {throw VmFault(chCode("Dict"),"Dictionary block invalid")}
            return Array(out.prefix(Int(length)))
        }
        let data=try inflate(block)+inflate(block+1)
        var p=0
        while p<data.count {
            let marker=data[p];p+=1;if marker != 1 {continue}
            let start=p;while p<data.count && data[p] != 0 {p+=1}
            if latin1(Array(data[start..<p])).caseInsensitiveCompare(word) == .orderedSame {
                let begin=start-1;while p<data.count && data[p] != 1 {p+=1}
                if all {return Array(data[begin..<p])+[0]}
                var n=number,q=begin
                while q<p {
                    let marker=data[q];q+=1
                    if marker==2 {n-=1;if n==0 {let a=q;while q<p && data[q] != 0 {q+=1};return Array(data[a..<q])}}
                }
                return nil
            }
        }
        return nil
    }
}
