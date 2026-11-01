import Foundation
import zlib

/// Original indexed artwork with independently compressed frames and one decoded-frame cache.
public final class IndexedAnimation {
    public let width:Int,height:Int,count:Int,period:Int
    private let data:[UInt8],offsets:[Int],base:Int
    private var frame = -1,pixels:[UInt8]=[]
    public init(_ data:[UInt8]) throws {
        func u16(_ p:Int)->Int {Int(data[p]) | Int(data[p+1])<<8}
        func u32(_ p:Int)->Int {u16(p) | u16(p+2)<<16}
        guard data.count>=20,Array(data.prefix(4))==Array("TOSA".utf8) else {throw JsonError("invalid animation")}
        let width=u16(4),height=u16(6),count=u16(8),period=u32(12)
        guard (1...256).contains(width),(1...256).contains(height),(1...1000).contains(count),(1...1_000_000).contains(period) else {throw JsonError("invalid animation geometry")}
        let base=16+4*(count+1);guard base<=data.count else {throw JsonError("invalid animation table")}
        let offsets=(0...count).map {u32(16+4*$0)}
        guard offsets[0]==0,offsets[count]==data.count-base,zip(offsets,offsets.dropFirst()).allSatisfy({$0.0<$0.1}) else {throw JsonError("invalid animation offsets")}
        self.width=width;self.height=height;self.count=count;self.period=period;self.base=base;self.offsets=offsets;self.data=data
    }
    public func pixels(_ nowMs:Int64) throws -> [UInt8] {
        let index=Int(max(0,nowMs)%Int64(period))*count/period
        if index==frame {return pixels}
        var out=[UInt8](repeating:0,count:width*height),size=uLongf(width*height)
        let code=out.withUnsafeMutableBytes {dst in data.withUnsafeBytes {src in uncompress(dst.baseAddress!.assumingMemoryBound(to:UInt8.self),&size,src.baseAddress!.assumingMemoryBound(to:UInt8.self)+base+offsets[index],uLong(offsets[index+1]-offsets[index]))}}
        guard code==Z_OK,size==out.count,out.allSatisfy({$0==255 || $0<16}) else {throw JsonError("invalid animation frame")}
        pixels=out;frame=index;return pixels
    }
}
