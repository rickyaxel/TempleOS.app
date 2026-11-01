import Foundation

/// Sandboxed planar pixels for original VGA-writing examples. No guest CPU or hardware access.
public final class VgaFramebuffer {
    private unowned let k:Kernel
    private var address=0,register=0,mask=15
    private var previous=[UInt8]()
    private var planes:[UInt8]?
    public init(_ k:Kernel) {self.k=k}
    public func port(_ port:Int64,_ value:Int64) throws {
        if port==0x3C4 {register=Int(truncatingIfNeeded:value);return}
        if port != 0x3C5 || register != 2 {return}
        if address==0 {
            address=try k.mem.calloc(38400);planes=[UInt8](repeating:0,count:4*38400);previous=[UInt8](repeating:0,count:38400)
            k.mem.st8(k.o.global("text")+k.o.member("CTextGlbls","vga_alias"),Int64(address))
            let body=try k.mem.check(k.mem.ld8(Int(k.gfx.grDc)+k.o.dc("body")),640*480)
            k.mem.fill(body,0,640*480);k.graphicsUsed=true
        }
        try sync();mask=Int(truncatingIfNeeded:value)&15
    }
    public func sync() throws {
        guard planes != nil else {return}
        let mem=k.mem,source=try k.mem.check(Int64(address),38400)
        let dst=try mem.check(mem.ld8(Int(k.gfx.grDc)+k.o.dc("body")),640*480)
        for i in 0..<38400 {
            let v=UInt8(truncatingIfNeeded:mem.ld1(source+i))
            if v==previous[i] {continue};previous[i]=v
            for plane in 0...3 where mask&(1<<plane) != 0 {planes![plane*38400+i]=v}
            for bit in 0...7 {
                var color=0
                for plane in 0...3 where Int(planes![plane*38400+i])&(128>>bit) != 0 {color |= 1<<plane}
                mem.st1(dst+i*8+bit,Int64(color))
            }
        }
    }
}
