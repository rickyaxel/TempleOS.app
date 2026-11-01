import Foundation
import CryptoKit

// Port of purenative/NativeCatalog.kt.

/** The translated prelude: its data segment ([image], under the runtime's native/) and its module. */
public final class NativePreludeImage {
    public let image: String
    /** sha256 of the runtime HolyC it was translated from (Prelude, PreludeDefines, GrLib, KernelClasses). */
    public let sourceHash: String
    /** Number of prelude functions: program function indices start here. */
    public let split: Int
    public let create: (NativeRuntime) -> NativeModule
    public init(image: String, sourceHash: String, split: Int, create: @escaping (NativeRuntime) -> NativeModule) {
        self.image = image; self.sourceHash = sourceHash; self.split = split; self.create = create
    }
}

/** A translated program: its C:/ path, data segment, the sources it was translated from, and its module. */
public final class NativeProgramImage {
    public let path: String
    public let image: String
    /** sha256 of every source file the program's compilation read (the file and its #includes). */
    public let closure: [String: String]
    /**
     * Set when the translation cannot do what the program needs (e.g. "runtime_compile": it compiles
     * HolyC the user types): the app then offers Pure Terry instead.
     */
    public let requiresTerry: String?
    /** Programs completed at run time: units every variant shares (loaded before the choice is made). */
    public let common: Int
    /**
     * Programs completed at run time (TreeCheckers: macros from a PopUp answer, `DefinePrint`): one
     * translation per possible choice. [image] and [create] are the first variant's, used for the common units.
     */
    public let variants: [NativeVariant]
    public let create: (NativeRuntime, NativeModule) -> NativeModule
    public init(path: String, image: String, closure: [String: String], requiresTerry: String? = nil, common: Int = 0, variants: [NativeVariant] = [],
                create: @escaping (NativeRuntime, NativeModule) -> NativeModule) {
        self.path = path; self.image = image; self.closure = closure; self.requiresTerry = requiresTerry; self.common = common; self.variants = variants; self.create = create
    }
}

/** One specialization of a program completed at run time, selected by the macro texts the program defined. */
public final class NativeVariant {
    public let image: String
    /** Macro name -> the text `DefinePrint` gave it when this variant's source was compiled. */
    public let defines: [String: String]
    public let create: (NativeRuntime, NativeModule) -> NativeModule
    public init(image: String, defines: [String: String], create: @escaping (NativeRuntime, NativeModule) -> NativeModule) {
        self.image = image; self.defines = defines; self.create = create
    }
}

/** What the generated code provides (the generated NativeCatalog). */
public final class NativeCatalogSource {
    public let generator: String
    public let prelude: NativePreludeImage
    public let programs: [NativeProgramImage]
    public init(generator: String, prelude: NativePreludeImage, programs: [NativeProgramImage]) {
        self.generator = generator; self.prelude = prelude; self.programs = programs
    }
}

/**
 * The app's registry of translated programs (Pure Swift mode). The app installs the generated
 * catalog at startup; TempleCore never depends on generated code.
 */
public enum NativePrograms {
    private static let lock = NSLock()
    private static var _catalog: NativeCatalogSource?
    private static var byPath: [String: NativeProgramImage] = [:]

    public static var catalog: NativeCatalogSource? {
        get { lock.lock(); defer { lock.unlock() }; return _catalog }
        set {
            lock.lock(); defer { lock.unlock() }
            _catalog = newValue
            byPath = [:]
            for p in newValue?.programs ?? [] { byPath[p.path.lowercased()] = p }
        }
    }

    /** The translation of [path], if there is one. */
    public static func find(_ path: String) -> NativeProgramImage? { lock.lock(); defer { lock.unlock() }; return byPath[path.lowercased()] }

    /** Why [p] cannot run natively from [fs] now (a source file differs from the one translated), or nil when it can. */
    public static func staleReason(_ p: NativeProgramImage, _ fs: VirtualFs?) -> String? {
        guard let fs = fs else { return "no file system" }
        for (file, hash) in p.closure.sorted(by: { $0.key < $1.key }) {
            guard let b = fs.readFile(file) else { return "\(file) is missing" }
            if !sourceMatches(fs,file,b,hash) { return "\(file) was changed after translation" }
        }
        return nil
    }

    /// Only the leading line comment may differ; executable bytes and attachments remain identical.
    public static func sourceMatches(_ fs:VirtualFs?,_ path:String,_ current:[UInt8],_ hash:String)->Bool {
        if sha256(current)==hash {return true}
        guard let original=(fs as? LayeredFs)?.bundledBytes(path),sha256(original)==hash,current.starts(with:[47,47]),original.starts(with:[47,47]),let a=current.firstIndex(of:10),let b=original.firstIndex(of:10),!current[..<a].contains(0) else {return false}
        return current[a...].elementsEqual(original[b...])
    }

    public static func sha256(_ b: [UInt8]) -> String {
        SHA256.hash(data: Data(b)).map { String(format: "%02x", $0) }.joined()
    }
}

/**
 * Connects a kernel to the translated prelude and program (set as [Kernel.native] before boot).
 * Boot installs the [NativeRuntime] as the VM's engine and switches the program's compiler off.
 */
public final class NativeBinding {
    public let prelude: NativePreludeImage
    public let program: NativeProgramImage?
    public private(set) var runtime: NativeRuntime!
    private var seg: Segment!

    public init(_ prelude: NativePreludeImage, _ program: NativeProgramImage?) { self.prelude = prelude; self.program = program }

    public func bootPrelude(_ k: Kernel) throws -> FuncSym {
        let rt = NativeRuntime(k.vm)
        runtime = rt
        k.vm.engine = rt
        k.prog.nativeMode = true
        seg = Segment(k.prog, k.vm.natives)
        let units = try NativeBinding.units(k, prelude.image)
        guard units.count == 1, let initF = try seg.load(units[0]) else { throw VmKill("native prelude has no init function") }
        let m = prelude.create(rt)
        try m.bind(0, seg)
        rt.prelude = m
        rt.split = prelude.split
        return initF
    }

    fileprivate var programUnits: [Segment.Unit] = []
    private var registryLoaded: Set<String> = []

    /** The program's chunks, loaded one by one as the kernel runs them. */
    public func session(_ k: Kernel) throws -> ChunkSource {
        guard let p = program else { throw VmKill("no native program bound") }
        let units = try NativeBinding.units(k, p.image)
        programUnits = units
        let m = p.create(runtime, runtime.prelude)
        runtime.program = m
        return NativeChunks(self, k, p, units, seg, m)
    }

    public func fileCurrent(_ k:Kernel,_ path:String)->Bool {
        let key=path.hasSuffix(".Z") ? String(path.dropLast(2)) : path
        guard let hash=program?.closure.first(where:{$0.key.caseInsensitiveCompare(key) == .orderedSame})?.value,let bytes=k.env.fs?.readFile(path) else {return false}
        return hasFile(path) && NativePrograms.sourceMatches(k.env.fs,path,bytes,hash)
    }
    public func hasFile(_ path:String)->Bool {programUnits.contains {$0.registry?.lowercased()==("file:"+(path.hasSuffix(".Z") ? String(path.dropLast(2)) : path)).lowercased()}}
    public func fileSession(_ kernel:Kernel,_ path:String) throws -> ChunkSource {
        let canonical=path.lowercased().hasSuffix(".z") ? String(path.dropLast(2)) : path
        let ids=programUnits.indices.filter {programUnits[$0].registry?.lowercased()==("file:"+canonical).lowercased()}
        if ids.isEmpty {throw CompileError("No compiled native source package for \(path)")}
        guard let expected=program?.closure.first(where:{$0.key.lowercased()==canonical.lowercased()})?.value,
              let bytes=kernel.env.fs?.readFile(path), NativePrograms.sourceMatches(kernel.env.fs,path,bytes,expected) else {throw CompileError("Native source package changed: \(path)")}
        return NativeFileChunks(self,ids)
    }
    private final class NativeFileChunks:ChunkSource {
        private unowned let binding:NativeBinding
        private let ids:[Int];private var index=0
        init(_ binding:NativeBinding,_ ids:[Int]) {self.binding=binding;self.ids=ids}
        var answerKind:Int {Program.ANS_NONE}
        func next() throws -> FuncSym? {
            while index<ids.count {
                let id=ids[index];index+=1
                let f=try binding.seg.load(binding.programUnits[id]);try binding.runtime.program!.bind(id,binding.seg)
                if let f=f {return f}
            }
            return nil
        }
    }

    private static func defineText(_ k: Kernel, _ name: String) -> String? {
        guard let d = k.defineStrs[name] else { return nil }
        return try? k.mem.readStr(Int64(d.data))
    }

    private final class NativeChunks: ChunkSource {
        private unowned let binding: NativeBinding
        private unowned let k: Kernel
        private let p: NativeProgramImage
        private var units: [Segment.Unit]
        private let seg: Segment
        private var m: NativeModule
        private var i = 0
        init(_ binding: NativeBinding, _ k: Kernel, _ p: NativeProgramImage, _ units: [Segment.Unit], _ seg: Segment, _ m: NativeModule) {
            self.binding = binding; self.k = k; self.p = p; self.units = units; self.seg = seg; self.m = m
        }
        var answerKind: Int { Program.ANS_NONE }
        func next() throws -> FuncSym? {
            if i == p.common && !p.variants.isEmpty {
                // the program has made its run-time choice: continue with the translation of that choice
                let k = self.k
                guard let v = p.variants.first(where: { v in v.defines.allSatisfy { NativeBinding.defineText(k, $0.key) == $0.value } }) else {
                    let names = p.variants[0].defines.keys.sorted().map { "\($0)=\(NativeBinding.defineText(k, $0) ?? "")" }.joined(separator: ", ")
                    throw CompileError("this run-time choice has no translation (\(names)); run it in Pure Terry")
                }
                units = try NativeBinding.units(k, v.image)
                m = v.create(binding.runtime, binding.runtime.prelude)
                for j in 0..<i { try m.bind(j, seg) } // the common units, already loaded (same image text)
                binding.runtime.program = m
                binding.programUnits = units
            }
            while true {
                // registry units are loaded by RegExe, where the program runs it
                while i < units.count && units[i].registry != nil { i += 1 }
                if i >= units.count { return nil }
                let f = try seg.load(units[i])
                try m.bind(i, seg)
                i += 1
                if let f = f { return f }
            }
        }
    }

    /**
     * RegExe in a native program: load the registry unit the translator compiled from the program's RegDft
     * default (the same allocations), run its init, then give the declared globals the stored values.
     */
    public func regExe(_ k: Kernel, _ t: HTask, _ path: String, _ stored: String) throws -> Int64 {
        guard let m = runtime.program else { return 0 }
        var res: Int64 = 0
        if !registryLoaded.contains(path) {
            registryLoaded.insert(path)
            for (i, u) in programUnits.enumerated() where u.registry == path {
                let f = try seg.load(u)
                try m.bind(i, seg)
                if let f = f { res = try k.vm.callFunction(t, k.prog.funcPtr(f)) }
            }
        }
        guard let decls = RegistryDecls.parse(stored) else {
            k.console.write("$RED$Registry \(path): only declarations with numeric values can be read natively; using the defaults$FG$\n")
            return res
        }
        for (name, v) in decls {
            guard let g = k.prog.globals[name] as? GlobalSym else { continue }
            RegistryDecls.store(k.mem, g, v)
        }
        return res
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: [Segment.Unit]] = [:]

    private static func units(_ k: Kernel, _ image: String) throws -> [Segment.Unit] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let u = cache[image] { return u }
        guard let bytes = k.env.runtimeFile("native/\(image)") else { throw VmKill("native image \(image) is missing") }
        let u = try Segment.parse(latin1(bytes))
        cache[image] = u
        return u
    }
}

/**
 * Reads registry settings code that consists only of declarations with numeric initializers
 * (`I64 best_score0=0,best_score1=9999;` `F64 best_score=12.3456;`), which is all RegWrite
 * stores for the bundled programs, and stores the values as the compiler's constant initializers do.
 */
public enum RegistryDecls {
    public struct Value { public let isFloat: Bool; public let i: Int64; public let f: Double }

    public static func parse(_ src: String) -> [(String, Value)]? {
        let s = Array(src.unicodeScalars)
        var out: [(String, Value)] = []
        var p = 0
        func ws() { while p < s.count && CharacterSet.whitespacesAndNewlines.contains(s[p]) { p += 1 } }
        func ident() -> String? {
            ws()
            let st = p
            while p < s.count && (CharacterSet.alphanumerics.contains(s[p]) || s[p] == "_") { p += 1 }
            return p > st ? String(String.UnicodeScalarView(s[st..<p])) : nil
        }
        while true {
            ws()
            if p >= s.count { return out }
            if ident() == nil { return nil }
            while true {
                guard let name = ident() else { return nil }
                ws()
                if p >= s.count || s[p] != "=" { return nil }
                p += 1; ws()
                let st = p
                if p < s.count && (s[p] == "-" || s[p] == "+") { p += 1 }
                while p < s.count && (CharacterSet.alphanumerics.contains(s[p]) || s[p] == ".") { p += 1 }
                guard let v = number(String(String.UnicodeScalarView(s[st..<p]))) else { return nil }
                out.append((name, v))
                ws()
                if p < s.count && s[p] == "," { p += 1; continue }
                if p < s.count && s[p] == ";" { p += 1; break }
                return nil
            }
        }
    }

    public static func number(_ s: String) -> Value? {
        let neg = s.hasPrefix("-")
        var b = Substring(s)
        if b.hasPrefix("-") || b.hasPrefix("+") { b = b.dropFirst() }
        if b.isEmpty { return nil }
        if b.hasPrefix("0x") || b.hasPrefix("0X") {
            guard let u = UInt64(b.dropFirst(2), radix: 16) else { return nil }
            let v = Int64(bitPattern: u)
            return Value(isFloat: false, i: neg ? 0 &- v : v, f: 0)
        }
        if b.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // Kotlin toBigInteger().toLong(): the low 64 bits
            var v: Int64 = 0
            for c in b.utf8 { v = v &* 10 &+ Int64(c - 48) }
            return Value(isFloat: false, i: neg ? 0 &- v : v, f: 0)
        }
        guard let dd = Double(b) else { return nil }
        return Value(isFloat: true, i: 0, f: neg ? -dd : dd)
    }

    /** Stores [v] into [g] as CodeGen.writeConst would (integers truncated to the width; F64 as bits). */
    public static func store(_ mem: Arena, _ g: GlobalSym, _ v: Value) {
        let t: HType = g.type
        let a = g.addr
        if t is F64Type { mem.st8(a, bits(v.isFloat ? v.f : Double(v.i))); return }
        if !Types.isInt(t) && !(t is PtrType) { return }
        // Kotlin Double.toLong(): NaN is 0, out of range saturates
        let x: Int64 = !v.isFloat ? v.i : (v.f.isNaN ? 0 : (v.f >= 9.223372036854775807E18 ? Int64.max : (v.f <= -9.223372036854775808E18 ? Int64.min : Int64(v.f))))
        switch t.size { case 1: mem.st1(a, x); case 2: mem.st2(a, x); case 4: mem.st4(a, x); default: mem.st8(a, x) }
    }
}
