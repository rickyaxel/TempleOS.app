import Foundation

// Port of holyc/Types.kt. Kotlin `Type` is `HType` here (Swift reserves `.Type`).

public class HType: CustomStringConvertible {
    public var size: Int { 0 }
    public var name: String { "" }
    public var description: String { name }
}

/** Kotlin `object VoidType`: use `VoidType.shared`. */
public final class VoidType: HType {
    public static let shared = VoidType()
    public override var size: Int { 0 }
    public override var name: String { "U0" }
}

public final class IntType: HType {
    private let n: String
    private let s: Int
    public let signed: Bool
    public init(_ name: String, _ size: Int, _ signed: Bool) { n = name; s = size; self.signed = signed }
    public override var size: Int { s }
    public override var name: String { n }
}

/** Kotlin `object F64Type`: use `F64Type.shared`. */
public final class F64Type: HType {
    public static let shared = F64Type()
    public override var size: Int { 8 }
    public override var name: String { "F64" }
}

public final class PtrType: HType {
    public let target: HType
    public init(_ target: HType) { self.target = target }
    public override var size: Int { 8 }
    public override var name: String { "\(target) *" }
}

public final class ArrType: HType {
    public let elem: HType
    public let count: Int
    public init(_ elem: HType, _ count: Int) { self.elem = elem; self.count = count }
    public override var size: Int { elem.size * count }
    public override var name: String { "\(elem)[\(count)]" }
}

public final class Member {
    public let name: String
    public let type: HType
    public let offset: Int
    public let format: [UInt8]?
    public init(_ name: String, _ type: HType, _ offset: Int, _ format: [UInt8]? = nil) { self.name = name; self.type = type; self.offset = offset; self.format = format }
}

public final class ClassType: HType {
    private let n: String
    public let isUnion: Bool
    /**
     * Kotlin `LinkedHashMap<String, Member>`. Swift dictionaries are unordered,
     * so declaration order is kept in [memberList]. Kotlin `members[k] = m`
     * becomes `addMember(m)` (or `setMember(k, m)`), `members.values` becomes
     * `memberList`, and lookups stay `members[k]` / `find(k)`.
     */
    public private(set) var members: [String: Member] = [:]
    public private(set) var memberList: [Member] = []
    public var base: ClassType?
    /** For `I64 class X` style declarations: the type used when the class is used as a whole value. */
    public var valueType: IntType?
    public var defined = false
    public var sizeValue = 0

    public init(_ name: String, _ isUnion: Bool) { n = name; self.isUnion = isUnion }
    public override var name: String { n }
    /** Kotlin `override var size`; assign through `setSize` or `sizeValue`. */
    public override var size: Int { sizeValue }
    public func setSize(_ s: Int) { sizeValue = s }

    public func find(_ k: String) -> Member? { members[k] }
    /** Removes every member (purenative Segment redefines a class from the translated image). */
    public func clearMembers() { members = [:]; memberList = [] }
    public func addMember(_ m: Member) { setMember(m.name, m) }
    public func setMember(_ k: String, _ m: Member) {
        if let old = members[k], let i = memberList.firstIndex(where: { $0 === old }) { memberList[i] = m } else { memberList.append(m) }
        members[k] = m
    }
}

public final class Param {
    public let name: String
    public let type: HType
    public let defaultExpr: Expr?
    public init(_ name: String, _ type: HType, _ defaultExpr: Expr?) { self.name = name; self.type = type; self.defaultExpr = defaultExpr }
}

public final class FuncType: HType {
    public let ret: HType
    public let params: [Param]
    public let varargs: Bool
    public init(_ ret: HType, _ params: [Param], _ varargs: Bool) { self.ret = ret; self.params = params; self.varargs = varargs }
    public override var size: Int { 8 }
    public override var name: String { "\(ret)(\(params.map { $0.type.name }.joined(separator: ","))\(varargs ? ",..." : ""))" }
}

public enum Types {
    public static let U0: HType = VoidType.shared
    public static let I8 = IntType("I8", 1, true)
    public static let U8 = IntType("U8", 1, false)
    public static let I16 = IntType("I16", 2, true)
    public static let U16 = IntType("U16", 2, false)
    public static let I32 = IntType("I32", 4, true)
    public static let U32 = IntType("U32", 4, false)
    public static let I64 = IntType("I64", 8, true)
    public static let U64 = IntType("U64", 8, false)
    public static let Bool = IntType("Bool", 1, false)
    public static let F64: HType = F64Type.shared
    public static let U8Ptr = PtrType(U8)

    public static let builtins: [String: HType] = [
        "U0": U0, "I0": U0, "I8": I8, "U8": U8, "I16": I16, "U16": U16,
        "I32": I32, "U32": U32, "I64": I64, "U64": U64, "F64": F64, "Bool": Bool,
        "I8i": I8, "U8i": U8, "I16i": I16, "U16i": U16, "I32i": I32, "U32i": U32,
        "I64i": I64, "U64i": U64, "F64i": F64, "U0i": U0,
    ]

    public static func isInt(_ t: HType) -> Swift.Bool { t is IntType || ((t as? ClassType)?.valueType != nil) }
    public static func isScalar(_ t: HType) -> Swift.Bool { isInt(t) || t is F64Type || t is PtrType }
    public static func isPtrLike(_ t: HType) -> Swift.Bool { t is PtrType || t is ArrType }

    /** Integer view of a type (classes with a value type behave as that integer). */
    public static func asInt(_ t: HType) -> IntType? {
        if let i = t as? IntType { return i }
        if let c = t as? ClassType { return c.valueType }
        return nil
    }

    public static func isUnsigned64(_ t: HType) -> Swift.Bool {
        if let i = asInt(t), !i.signed, i.size == 8 { return true }
        return t is PtrType || t is ArrType
    }

    /** Any unsigned integer width (or pointer): TempleOS compares unsigned if either operand is (Compiler/OptLib.HC). */
    public static func isUnsignedAny(_ t: HType) -> Swift.Bool {
        if let i = asInt(t), !i.signed { return true }
        return t is PtrType || t is ArrType
    }

    public static func pointee(_ t: HType) -> HType {
        if let p = t as? PtrType { return p.target }
        if let a = t as? ArrType { return a.elem }
        return U8
    }

    /** Element size used for pointer arithmetic (U0 pointers scale by 1). */
    public static func scale(_ t: HType) -> Int {
        let s = pointee(t).size
        return s == 0 ? 1 : s
    }

    private static let subSizes: [String: IntType] = ["i8": I8, "u8": U8, "i16": I16, "u16": U16, "i32": I32, "u32": U32, "i64": I64, "u64": U64]

    /** Sub-integer members available on intrinsic integer unions (x.u8[i] etc). */
    public static func intSubMember(_ t: IntType, _ n: String) -> HType? {
        guard let e = subSizes[n] else { return nil }
        if e.size >= t.size && !(e.size == t.size && e.size == 8) { return nil }
        return ArrType(e, t.size / e.size)
    }
}
