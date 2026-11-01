import Foundation

// Port of kernel/FsCommands.kt.

/** Shell-level file commands (Dir, Cd, Del, Copy...) on the virtual filesystem. */
public final class FsCommands {
    private let k: Kernel
    private let t: HTask

    public init(_ k: Kernel, _ t: HTask) { self.k = k; self.t = t }

    private var fs: VirtualFs? { k.env.fs }
    private func out(_ s: String) { k.console.write(s) }
    private func norm(_ p: String) throws -> String? { Paths.normalize(try k.curDir(t), p) }

    private func err(_ msg: String) throws -> Never { throw VmFault(chCode("File"), msg) }

    /** Kotlin String comparison (UTF-16 code units; Latin-1 text here). */
    private static func less(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }

    public func dir(_ mask0: String, _ full: Bool) throws -> Int64 {
        guard let vfs = fs else { return 0 }
        var mask = mask0
        var dir = try k.curDir(t)
        let asPath = try norm(mask0)
        if let ap = asPath, vfs.isDir(ap) { dir = ap; mask = "*" }
        else if mask0.contains("/") {
            let before = mask0.lastIndex(of: "/").map { String(mask0[..<$0]) } ?? mask0
            guard let p = try norm(before.isEmpty ? "/" : before) else { return 0 }
            dir = p; mask = mask0.substringAfterLast("/")
        }
        guard let entries = vfs.list(dir) else { out("$RED$Directory not found: \(dir)$FG$\n"); return 0 }
        out("$MA-X+PU,\"Directory\"$ of $GREEN$\(dir)$FG$\n")
        out("DATE_ TIME_ SIZE\n")
        var n: Int64 = 0
        let sorted = entries.sorted { x, y in
            if x.isDir != y.isDir { return x.isDir } // compareBy { !it.isDir }: false (dirs) first
            return FsCommands.less(x.name.lowercased(), y.name.lowercased())
        }
        for e in sorted {
            if !e.isDir && !Paths.matches(mask, e.name) { continue }
            let date = FsCommands.dirDate(e)
            let size = e.isDir ? "    " : String(format: "%04llX", min(e.size, 0xFFFF))
            let color = e.isDir ? "$CYAN$" : (e.readOnly ? "$BLUE$" : "$PURPLE$")
            out("\(date) \(size) \(color)\(e.name)\(e.isDir ? "/" : "")$FG$\n")
            n += 1
        }
        return n
    }

    /**
     * "MM/DD HH:MM" as TempleOS's Dir prints it. Bundled entries carry the ISO's wall-clock
     * time (shown as is, in UTC terms); user files carry a real instant (shown in local time).
     */
    static func dirDate(_ e: FsEntry) -> String {
        if e.modified <= 0 { return "--/-- --:--" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = e.readOnly ? TimeZone(identifier: "UTC")! : TimeZone.current
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: Date(timeIntervalSince1970: Double(e.modified) / 1000))
        return String(format: "%02ld/%02ld %02ld:%02ld", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    public func cd(_ target: String, _ makeDirs: Bool) throws -> Bool {
        guard let vfs = fs else { return false }
        guard let p = try norm(target) else { out("$RED$Invalid path$FG$\n"); return false }
        if !vfs.isDir(p) {
            if makeDirs {
                do { try vfs.mkdir(p) } catch let e as FsError { out("$RED$\(e.message)$FG$\n"); return false }
            } else { out("$RED$Directory not found: \(p)$FG$\n"); return false }
        }
        k.mem.st8(t.fsAddr + (k.o.task("cur_dir")), Int64(try k.prog.stringAddr(latin1(p))))
        return true
    }

    public func mkdir(_ target: String) throws -> Bool {
        guard let p = try norm(target) else { return false }
        do { try fs?.mkdir(p); return true } catch let e as FsError { out("$RED$\(e.message)$FG$\n"); return false }
    }

    private func expand(_ mask: String) throws -> [String] {
        guard let vfs = fs else { return [] }
        guard let p = try norm(mask) else { return [] }
        if !mask.contains("*") && !mask.contains("?") { return vfs.exists(p) ? [p] : [] }
        let dir = Paths.parent(p)
        let m = Paths.name(p)
        return vfs.list(dir)?.filter { Paths.matches(m, $0.name) }.map { $0.path } ?? []
    }

    public func del(_ mask: String, _ delDir: Bool, _ print: Bool) throws -> Int64 {
        var n: Int64 = 0
        for p in try expand(mask) {
            do {
                if fs!.isDir(p) && !delDir { continue }
                try fs!.delete(p)
                if print { out("Del \(p)\n") }
                n += 1
            } catch let e as FsError { out("$RED$\(e.message)$FG$\n") }
        }
        return n
    }

    public func delTree(_ mask: String) throws -> Int64 {
        var n: Int64 = 0
        for p in try expand(mask) {
            do { try fs!.delete(p, recursive: true); n += 1 } catch let e as FsError { out("$RED$\(e.message)$FG$\n") }
        }
        return n
    }

    public func copy(_ src: String, _ dst: String) throws -> Bool {
        guard let vfs = fs else { return false }
        let srcs = try expand(src)
        if srcs.isEmpty { out("$RED$File not found: \(src)$FG$\n"); return false }
        guard let d = try norm(dst) else { return false }
        for s in srcs {
            guard let data = vfs.readFile(s) else { continue }
            let target = vfs.isDir(d) ? "\(d)/\(Paths.name(s))" : d
            do { try vfs.writeFile(target, data); out("Copy \(s) \(target)\n") } catch let e as FsError { out("$RED$\(e.message)$FG$\n"); return false }
        }
        return true
    }

    public func move(_ src: String, _ dst: String) throws -> Bool {
        guard let vfs = fs else { return false }
        guard let s = try norm(src) else { return false }
        guard var d = try norm(dst) else { return false }
        if vfs.isDir(d) { d = "\(d)/\(Paths.name(s))" }
        do { try vfs.move(s, d); return true } catch let e as FsError { out("$RED$\(e.message)$FG$\n"); return false }
    }

    public func type(_ file: String) throws {
        guard let p = try norm(file) else { return }
        guard let data = fs?.readFile(p) else { out("$RED$File not found: \(file)$FG$\n"); return }
        let end = data.firstIndex(of: 0) ?? data.count
        k.console.write(data, 0, end)
        out("\n")
    }

    /** Compiles and runs a file inside the current task (nested; must not block). */
    public func exeFile(_ file: String) throws -> Int64 {
        guard let p = try norm(file) else { return 0 }
        guard let data = fs?.readFile(p) else { out("$RED$File not found: \(file)$FG$\n"); return 0 }
        let initF: FuncSym
        do {
            initF = try k.prog.compile(SourceFile.parse(p, data), Paths.parent(p), k.vfsProvider(), k.defines)
        } catch let e as CompileError { out("$RED$\(e.message)$FG$\n"); return 0 }
        return try k.vm.callFunction(t, k.prog.funcPtr(initF))
    }
}
