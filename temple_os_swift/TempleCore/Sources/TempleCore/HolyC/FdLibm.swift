// FdLibm: a bit-exact Swift port of Sun's fdlibm 5.3 ("Freely Distributable
// LIBM") for the transcendental functions HolyC programs use.
//
// Written directly from the fdlibm 5.3 C sources distributed by netlib
// (https://netlib.org/fdlibm/): e_rem_pio2.c, k_rem_pio2.c, k_sin.c, k_cos.c,
// k_tan.c, s_sin.c, s_cos.c, s_tan.c, e_asin.c, e_acos.c, s_atan.c,
// e_atan2.c, e_sinh.c, e_cosh.c, s_tanh.c, e_exp.c, s_expm1.c, e_log.c,
// e_log10.c, s_log1p.c, e_pow.c, s_scalbn.c, s_copysign.c (with the word
// access macros of fdlibm.h). Each function follows the C step for step, so
// it returns the same Double bit pattern as the C library. Because
// java.lang.StrictMath is specified to return the fdlibm 5.3 results, the
// values are also identical to StrictMath on the JVM and Android, which keeps
// HolyC programs computing the same numbers on iOS and Android. (NaN payloads
// are not guaranteed to match.)
//
// Porting rules followed throughout:
//  - __HI(x)/__LO(x) are the high/low 32 bits of `bitPattern`, handled as
//    Int32 exactly like C `int` (UInt32 where the C declares `unsigned`);
//    assigning a word builds a new Double with `make`/`setHi`/`setLo`.
//  - Shifts use `&<<` / `&>>` (arithmetic on Int32, logical on UInt32) and
//    integer arithmetic that may wrap in C uses `&+` / `&-`.
//  - `(int)` casts of doubles use `cInt` (truncation toward zero).
//  - sqrt is `squareRoot()`, which is IEEE correctly rounded like e_sqrt.c.
//  - Constants are the C decimal literals (each shown with the exact IEEE
//    words from the C comments); Swift converts decimal literals with
//    correct rounding, so they produce exactly those words.
//  - Expressions keep the C evaluation order; no fused multiply-add is used
//    (Swift does not contract a*b+c).
//
// Copyright notices of the original fdlibm 5.3 sources, preserved as their
// licence requires:
//
// e_rem_pio2.c, k_rem_pio2.c, k_sin.c, k_cos.c, s_sin.c, s_cos.c, s_tan.c,
// e_asin.c, e_acos.c, s_atan.c, e_atan2.c, e_sinh.c, e_cosh.c, s_tanh.c,
// e_log.c, e_log10.c, s_log1p.c, s_scalbn.c, s_copysign.c:
//   ====================================================
//   Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
//
//   Developed at SunSoft, a Sun Microsystems, Inc. business.
//   Permission to use, copy, modify, and distribute this
//   software is freely granted, provided that this notice
//   is preserved.
//   ====================================================
//
// e_exp.c, s_expm1.c, e_pow.c:
//   ====================================================
//   Copyright (C) 2004 by Sun Microsystems, Inc. All rights reserved.
//
//   Permission to use, copy, modify, and distribute this
//   software is freely granted, provided that this notice
//   is preserved.
//   ====================================================
//
// k_tan.c:
//   ====================================================
//   Copyright 2004 Sun Microsystems, Inc.  All Rights Reserved.
//
//   Permission to use, copy, modify, and distribute this
//   software is freely granted, provided that this notice
//   is preserved.
//   ====================================================

public enum FdLibm {

    // MARK: - fdlibm.h word access

    /// __HI(x): the high 32 bits (sign, exponent, top of the fraction).
    @inline(__always)
    private static func hi(_ x: Double) -> Int32 {
        Int32(truncatingIfNeeded: x.bitPattern >> 32)
    }

    /// __LO(x) as a C `int`.
    @inline(__always)
    private static func lo(_ x: Double) -> Int32 {
        Int32(truncatingIfNeeded: x.bitPattern)
    }

    /// __LO(x) as a C `unsigned`.
    @inline(__always)
    private static func ulo(_ x: Double) -> UInt32 {
        UInt32(truncatingIfNeeded: x.bitPattern)
    }

    /// The double whose high and low words are `h` and `l`.
    @inline(__always)
    private static func make(_ h: Int32, _ l: Int32) -> Double {
        Double(bitPattern: (UInt64(UInt32(bitPattern: h)) << 32) | UInt64(UInt32(bitPattern: l)))
    }

    /// `__HI(x) = h`.
    @inline(__always)
    private static func setHi(_ x: Double, _ h: Int32) -> Double { make(h, lo(x)) }

    /// `__LO(x) = l`.
    @inline(__always)
    private static func setLo(_ x: Double, _ l: Int32) -> Double { make(hi(x), l) }

    /// C `(int)d`: truncation toward zero. Every call site converts a value
    /// well inside Int32 range; out-of-range values clamp instead of trapping.
    @inline(__always)
    private static func cInt(_ d: Double) -> Int32 {
        if d.isNaN { return 0 }
        if d >= 2147483647.0 { return Int32.max }
        if d <= -2147483648.0 { return Int32.min }
        return Int32(d)
    }

    private static let signBit = Int32(bitPattern: 0x80000000)

    // MARK: - s_copysign.c, s_scalbn.c

    /// copysign(x, y): x with the sign bit of y.
    private static func copysign(_ x: Double, _ y: Double) -> Double {
        make((hi(x) & 0x7fffffff) | (hi(y) & signBit), lo(x))
    }

    /// scalbn(x, n) = x * 2**n computed by exponent manipulation.
    private static func scalbn(_ xIn: Double, _ n: Int32) -> Double {
        let two54 = 1.80143985094819840000e+16  // 0x43500000, 0x00000000
        let twom54 = 5.55111512312578270212e-17 // 0x3C900000, 0x00000000
        let huge = 1.0e+300
        let tiny = 1.0e-300

        var x = xIn
        var hx = hi(x)
        let lx = lo(x)
        var k = (hx & 0x7ff00000) &>> 20                  // extract exponent
        if k == 0 {                                       // 0 or subnormal x
            if (lx | (hx & 0x7fffffff)) == 0 { return x } // +-0
            x *= two54
            hx = hi(x)
            k = ((hx & 0x7ff00000) &>> 20) - 54
            if n < -50000 { return tiny * x }             // underflow
        }
        if k == 0x7ff { return x + x }                    // NaN or Inf
        k = k &+ n
        if k > 0x7fe { return huge * copysign(huge, x) }  // overflow
        if k > 0 {                                        // normal result
            return make((hx & Int32(bitPattern: 0x800fffff)) | (k &<< 20), lo(x))
        }
        if k <= -54 {
            if n > 50000 {                                // in case integer overflow in n+k
                return huge * copysign(huge, x)           // overflow
            } else {
                return tiny * copysign(tiny, x)           // underflow
            }
        }
        k += 54                                           // subnormal result
        x = make((hx & Int32(bitPattern: 0x800fffff)) | (k &<< 20), lo(x))
        return x * twom54
    }

    // MARK: - e_rem_pio2.c

    /// 396 hex digits (476 decimal) of 2/pi, 24 bits per entry.
    private static let twoOverPi: [Int32] = [
        0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
        0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
        0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
        0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
        0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
        0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
        0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
        0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
        0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
        0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
        0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,
    ]

    /// High words of n*pi/2 for n = 1...32.
    private static let npio2HW: [Int32] = [
        0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
        0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
        0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
        0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
        0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
        0x404858EB, 0x404921FB,
    ]

    /// __ieee754_rem_pio2(x, y): the remainder of x rem pi/2 as y0 + y1, and
    /// the quotient n.
    private static func remPio2(_ x: Double) -> (n: Int32, y0: Double, y1: Double) {
        let zero = 0.00000000000000000000e+00    // 0x00000000, 0x00000000
        let half = 5.00000000000000000000e-01    // 0x3FE00000, 0x00000000
        let two24 = 1.67772160000000000000e+07   // 0x41700000, 0x00000000
        let invpio2 = 6.36619772367581382433e-01 // 0x3FE45F30, 0x6DC9C883 (53 bits of 2/pi)
        let pio2_1 = 1.57079632673412561417e+00  // 0x3FF921FB, 0x54400000 (first 33 bits of pi/2)
        let pio2_1t = 6.07710050650619224932e-11 // 0x3DD0B461, 0x1A626331 (pi/2 - pio2_1)
        let pio2_2 = 6.07710050630396597660e-11  // 0x3DD0B461, 0x1A600000 (second 33 bits of pi/2)
        let pio2_2t = 2.02226624879595063154e-21 // 0x3BA3198A, 0x2E037073 (pi/2 - (pio2_1+pio2_2))
        let pio2_3 = 2.02226624871116645580e-21  // 0x3BA3198A, 0x2E000000 (third 33 bits of pi/2)
        let pio2_3t = 8.47842766036889956997e-32 // 0x397B839A, 0x252049C1 (pi/2 - (pio2_1+pio2_2+pio2_3))

        let hx = hi(x)
        let ix = hx & 0x7fffffff
        if ix <= 0x3fe921fb {                    // |x| ~<= pi/4, no need for reduction
            return (0, x, 0)
        }
        if ix < 0x4002d97c {                     // |x| < 3pi/4, special case with n=+-1
            var z: Double
            let y0: Double
            let y1: Double
            if hx > 0 {
                z = x - pio2_1
                if ix != 0x3ff921fb {            // 33+53 bit pi is good enough
                    y0 = z - pio2_1t
                    y1 = (z - y0) - pio2_1t
                } else {                         // near pi/2, use 33+33+53 bit pi
                    z -= pio2_2
                    y0 = z - pio2_2t
                    y1 = (z - y0) - pio2_2t
                }
                return (1, y0, y1)
            } else {                             // negative x
                z = x + pio2_1
                if ix != 0x3ff921fb {            // 33+53 bit pi is good enough
                    y0 = z + pio2_1t
                    y1 = (z - y0) + pio2_1t
                } else {                         // near pi/2, use 33+33+53 bit pi
                    z += pio2_2
                    y0 = z + pio2_2t
                    y1 = (z - y0) + pio2_2t
                }
                return (-1, y0, y1)
            }
        }
        if ix <= 0x413921fb {                    // |x| ~<= 2^19*(pi/2), medium size
            var t = x.magnitude
            let n = cInt(t * invpio2 + half)
            let fn = Double(n)
            var r = t - fn * pio2_1
            var w = fn * pio2_1t                 // 1st round good to 85 bit
            var y0: Double
            if n < 32 && ix != npio2HW[Int(n) - 1] {
                y0 = r - w                       // quick check no cancellation
            } else {
                let j = ix &>> 20
                y0 = r - w
                var i = j - ((hi(y0) &>> 20) & 0x7ff)
                if i > 16 {                      // 2nd iteration needed, good to 118
                    t = r
                    w = fn * pio2_2
                    r = t - w
                    w = fn * pio2_2t - ((t - r) - w)
                    y0 = r - w
                    i = j - ((hi(y0) &>> 20) & 0x7ff)
                    if i > 49 {                  // 3rd iteration needed, 151 bits acc
                        t = r                    // will cover all possible cases
                        w = fn * pio2_3
                        r = t - w
                        w = fn * pio2_3t - ((t - r) - w)
                        y0 = r - w
                    }
                }
            }
            let y1 = (r - y0) - w
            if hx < 0 { return (-n, -y0, -y1) }
            return (n, y0, y1)
        }
        // all other (large) arguments
        if ix >= 0x7ff00000 {                    // x is inf or NaN
            let v = x - x
            return (0, v, v)
        }
        // set z = scalbn(|x|, ilogb(x)-23)
        let e0 = (ix &>> 20) - 1046              // e0 = ilogb(z)-23
        var z = make(ix - (e0 &<< 20), lo(x))
        var tx: [Double] = [0, 0, 0]
        for i in 0..<2 {
            tx[i] = Double(cInt(z))
            z = (z - tx[i]) * two24
        }
        tx[2] = z
        var nx = 3
        while tx[nx - 1] == zero { nx -= 1 }     // skip zero term
        let (n, y0, y1) = kernelRemPio2(tx, e0, nx)
        if hx < 0 { return (-n, -y0, -y1) }
        return (n, y0, y1)
    }

    // MARK: - k_rem_pio2.c

    /// pi/2 cut into 24-bit chunks.
    private static let pio2Chunks: [Double] = [
        1.57079625129699707031e+00, // 0x3FF921FB, 0x40000000
        7.54978941586159635335e-08, // 0x3E74442D, 0x00000000
        5.39030252995776476554e-15, // 0x3CF84698, 0x80000000
        3.28200341580791294123e-22, // 0x3B78CC51, 0x60000000
        1.27065575308067607349e-29, // 0x39F01B83, 0x80000000
        1.22933308981111328932e-36, // 0x387A2520, 0x40000000
        2.73370053816464559624e-44, // 0x36E38222, 0x80000000
        2.16741683877804819444e-51, // 0x3569F31D, 0x00000000
    ]

    /// __kernel_rem_pio2(x, y, e0, nx, prec = 2, two_over_pi): the last three
    /// bits of N and y = x - N*pi/2 as y0 + y1. `x` holds nx 24-bit pieces of
    /// the (positive) argument with x[0]*2^e0 matching it to 24 bits.
    /// e_rem_pio2.c always asks for prec 2 (64-bit, jk = init_jk[2] = 4),
    /// which returns two doubles; only that precision is ported.
    private static func kernelRemPio2(_ x: [Double], _ e0: Int32, _ nx: Int) -> (Int32, Double, Double) {
        let zero = 0.0
        let one = 1.0
        let two24 = 1.67772160000000000000e+07   // 0x41700000, 0x00000000
        let twon24 = 5.96046447753906250000e-08  // 0x3E700000, 0x00000000

        let jk = 4                               // init_jk[prec] for prec = 2
        let jp = jk
        var iq = [Int32](repeating: 0, count: 20)
        var f = [Double](repeating: 0, count: 20)
        var fq = [Double](repeating: 0, count: 20)
        var q = [Double](repeating: 0, count: 20)

        // determine jx, jv, q0; note that 3 > q0
        let jx = nx - 1
        var jv = Int((e0 - 3) / 24)
        if jv < 0 { jv = 0 }
        var q0 = Int(e0) - 24 * (jv + 1)

        // set up f[0] to f[jx+jk] where f[jx+jk] = ipio2[jv+jk]
        var j = jv - jx
        let m = jx + jk
        for i in 0...m {
            f[i] = j < 0 ? zero : Double(twoOverPi[j])
            j += 1
        }

        // compute q[0], q[1], ... q[jk]
        for i in 0...jk {
            var fw = 0.0
            for j in 0...jx { fw += x[j] * f[jx + i - j] }
            q[i] = fw
        }

        var jz = jk
        var z: Double
        var n: Int32
        var ih: Int32
        while true {                             // recompute:
            // distill q[] into iq[] reversingly
            var i = 0
            j = jz
            z = q[jz]
            while j > 0 {
                let fw = Double(cInt(twon24 * z))
                iq[i] = cInt(z - two24 * fw)
                z = q[j - 1] + fw
                i += 1
                j -= 1
            }

            // compute n
            z = scalbn(z, Int32(q0))             // actual value of z
            z -= 8.0 * (z * 0.125).rounded(.down) // trim off integer >= 8
            n = cInt(z)
            z -= Double(n)
            ih = 0
            if q0 > 0 {                          // need iq[jz-1] to determine n
                let i2 = iq[jz - 1] &>> Int32(24 - q0)
                n += i2
                iq[jz - 1] -= i2 &<< Int32(24 - q0)
                ih = iq[jz - 1] &>> Int32(23 - q0)
            } else if q0 == 0 {
                ih = iq[jz - 1] &>> 23
            } else if z >= 0.5 {
                ih = 2
            }

            if ih > 0 {                          // q > 0.5
                n += 1
                var carry: Int32 = 0
                for i in 0..<jz {                // compute 1-q
                    let jj = iq[i]
                    if carry == 0 {
                        if jj != 0 {
                            carry = 1
                            iq[i] = 0x1000000 - jj
                        }
                    } else {
                        iq[i] = 0xffffff - jj
                    }
                }
                if q0 > 0 {                      // rare case: chance is 1 in 12
                    switch q0 {
                    case 1: iq[jz - 1] &= 0x7fffff
                    case 2: iq[jz - 1] &= 0x3fffff
                    default: break
                    }
                }
                if ih == 2 {
                    z = one - z
                    if carry != 0 { z -= scalbn(one, Int32(q0)) }
                }
            }

            // check if recomputation is needed
            if z == zero {
                var jj: Int32 = 0
                var ii = jz - 1
                while ii >= jk {
                    jj |= iq[ii]
                    ii -= 1
                }
                if jj == 0 {                     // need recomputation
                    var k = 1
                    while iq[jk - k] == 0 { k += 1 } // k = no. of terms needed
                    for ii in (jz + 1)...(jz + k) {  // add q[jz+1] to q[jz+k]
                        f[jx + ii] = Double(twoOverPi[jv + ii])
                        var fw = 0.0
                        for jj in 0...jx { fw += x[jj] * f[jx + ii - jj] }
                        q[ii] = fw
                    }
                    jz += k
                    continue
                }
            }
            break
        }

        // chop off zero terms
        if z == 0.0 {
            jz -= 1
            q0 -= 24
            while iq[jz] == 0 {
                jz -= 1
                q0 -= 24
            }
        } else {                                 // break z into 24-bit if necessary
            z = scalbn(z, Int32(-q0))
            if z >= two24 {
                let fw = Double(cInt(twon24 * z))
                iq[jz] = cInt(z - two24 * fw)
                jz += 1
                q0 += 24
                iq[jz] = cInt(fw)
            } else {
                iq[jz] = cInt(z)
            }
        }

        // convert integer "bit" chunk to floating-point value
        var fw = scalbn(one, Int32(q0))
        var i = jz
        while i >= 0 {
            q[i] = fw * Double(iq[i])
            fw *= twon24
            i -= 1
        }

        // compute PIo2[0,...,jp]*q[jz,...,0]
        i = jz
        while i >= 0 {
            fw = 0.0
            var k = 0
            while k <= jp && k <= jz - i {
                fw += pio2Chunks[k] * q[i + k]
                k += 1
            }
            fq[jz - i] = fw
            i -= 1
        }

        // compress fq[] into y[] (prec 2)
        fw = 0.0
        i = jz
        while i >= 0 {
            fw += fq[i]
            i -= 1
        }
        let y0 = ih == 0 ? fw : -fw
        fw = fq[0] - fw
        i = 1
        while i <= jz {
            fw += fq[i]
            i += 1
        }
        let y1 = ih == 0 ? fw : -fw
        return (n & 7, y0, y1)
    }

    // MARK: - k_sin.c, k_cos.c, k_tan.c

    /// __kernel_sin(x, y, iy): sin on [-pi/4, pi/4]; y is the tail of x,
    /// iy = 0 if y is zero.
    private static func kernelSin(_ x: Double, _ y: Double, _ iy: Int32) -> Double {
        let half = 5.00000000000000000000e-01 // 0x3FE00000, 0x00000000
        let S1 = -1.66666666666666324348e-01  // 0xBFC55555, 0x55555549
        let S2 = 8.33333333332248946124e-03   // 0x3F811111, 0x1110F8A6
        let S3 = -1.98412698298579493134e-04  // 0xBF2A01A0, 0x19C161D5
        let S4 = 2.75573137070700676789e-06   // 0x3EC71DE3, 0x57B1FE7D
        let S5 = -2.50507602534068634195e-08  // 0xBE5AE5E6, 0x8A2B9CEB
        let S6 = 1.58969099521155010221e-10   // 0x3DE5D93A, 0x5ACFD57C

        let ix = hi(x) & 0x7fffffff           // high word of x
        if ix < 0x3e400000 {                  // |x| < 2**-27
            if cInt(x) == 0 { return x }      // generate inexact
        }
        let z = x * x
        let v = z * x
        let r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
        if iy == 0 {
            return x + v * (S1 + z * r)
        } else {
            return x - ((z * (half * y - v * r) - y) - v * S1)
        }
    }

    /// __kernel_cos(x, y): cos on [-pi/4, pi/4]; y is the tail of x.
    private static func kernelCos(_ x: Double, _ y: Double) -> Double {
        let one = 1.00000000000000000000e+00 // 0x3FF00000, 0x00000000
        let C1 = 4.16666666666666019037e-02  // 0x3FA55555, 0x5555554C
        let C2 = -1.38888888888741095749e-03 // 0xBF56C16C, 0x16C15177
        let C3 = 2.48015872894767294178e-05  // 0x3EFA01A0, 0x19CB1590
        let C4 = -2.75573143513906633035e-07 // 0xBE927E4F, 0x809C52AD
        let C5 = 2.08757232129817482790e-09  // 0x3E21EE9E, 0xBDB4B1C4
        let C6 = -1.13596475577881948265e-11 // 0xBDA8FAE9, 0xBE8838D4

        let ix = hi(x) & 0x7fffffff          // ix = |x|'s high word
        if ix < 0x3e400000 {                 // if x < 2**27
            if cInt(x) == 0 { return one }   // generate inexact
        }
        let z = x * x
        let r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
        if ix < 0x3FD33333 {                 // if |x| < 0.3
            return one - (0.5 * z - (z * r - x * y))
        } else {
            let qx: Double
            if ix > 0x3fe90000 {             // x > 0.78125
                qx = 0.28125
            } else {
                qx = make(ix - 0x00200000, 0) // x/4
            }
            let hz = 0.5 * z - qx
            let a = one - qx
            return a - (hz - (z * r - x * y))
        }
    }

    /// __kernel_tan(x, y, k): tan (k = 1) or -1/tan (k = -1) on
    /// [-pi/4, pi/4]; y is the tail of x.
    private static func kernelTan(_ xIn: Double, _ yIn: Double, _ iy: Int32) -> Double {
        let T0 = 3.33333333333334091986e-01  // 3FD55555, 55555563
        let T1 = 1.33333333333201242699e-01  // 3FC11111, 1110FE7A
        let T2 = 5.39682539762260521377e-02  // 3FABA1BA, 1BB341FE
        let T3 = 2.18694882948595424599e-02  // 3F9664F4, 8406D637
        let T4 = 8.86323982359930005737e-03  // 3F8226E3, E96E8493
        let T5 = 3.59207910759131235356e-03  // 3F6D6D22, C9560328
        let T6 = 1.45620945432529025516e-03  // 3F57DBC8, FEE08315
        let T7 = 5.88041240820264096874e-04  // 3F4344D8, F2F26501
        let T8 = 2.46463134818469906812e-04  // 3F3026F7, 1A8D1068
        let T9 = 7.81794442939557092300e-05  // 3F147E88, A03792A6
        let T10 = 7.14072491382608190305e-05 // 3F12B80F, 32F0A7E9
        let T11 = -1.85586374855275456654e-05 // BEF375CB, DB605373
        let T12 = 2.59073051863633712884e-05 // 3EFB2A70, 74BF7AD4
        let one = 1.00000000000000000000e+00 // 3FF00000, 00000000
        let pio4 = 7.85398163397448278999e-01 // 3FE921FB, 54442D18
        let pio4lo = 3.06161699786838301793e-17 // 3C81A626, 33145C07

        var x = xIn
        var y = yIn
        var z: Double
        var r: Double
        var v: Double
        var w: Double
        var s: Double
        let hx = hi(x)                       // high word of x
        let ix = hx & 0x7fffffff             // high word of |x|
        if ix < 0x3e300000 {                 // x < 2**-28
            if cInt(x) == 0 {                // generate inexact
                if ((ix | lo(x)) | (iy &+ 1)) == 0 {
                    return one / x.magnitude
                } else {
                    if iy == 1 {
                        return x
                    } else {                 // compute -1 / (x+y) carefully
                        w = x + y
                        z = setLo(w, 0)
                        v = y - (z - x)
                        let a = -one / w
                        let t = setLo(a, 0)
                        s = one + t * z
                        return t + a * (s + t * v)
                    }
                }
            }
        }
        if ix >= 0x3FE59428 {                // |x| >= 0.6744
            if hx < 0 {
                x = -x
                y = -y
            }
            z = pio4 - x
            w = pio4lo - y
            x = z + w
            y = 0.0
        }
        z = x * x
        w = z * z
        // Break x^5*(T[1]+x^2*T[2]+...) into
        // x^5(T[1]+x^4*T[3]+...+x^20*T[11]) +
        // x^5(x^2*(T[2]+x^4*T[4]+...+x^22*[T12]))
        r = T1 + w * (T3 + w * (T5 + w * (T7 + w * (T9 + w * T11))))
        v = z * (T2 + w * (T4 + w * (T6 + w * (T8 + w * (T10 + w * T12)))))
        s = z * x
        r = y + z * (s * (r + v) + y)
        r += T0 * s
        w = x + r
        if ix >= 0x3FE59428 {
            v = Double(iy)
            return Double(1 - ((hx &>> 30) & 2)) * (v - 2.0 * (x - (w * w / (w + v) - r)))
        }
        if iy == 1 {
            return w
        } else {
            // compute -1.0 / (x+r) accurately
            z = setLo(w, 0)
            v = r - (z - x)                  // z+v = r+x
            let a = -1.0 / w                 // a = -1.0/w
            let t = setLo(a, 0)
            s = 1.0 + t * z
            return t + a * (s + t * v)
        }
    }

    // MARK: - s_sin.c, s_cos.c, s_tan.c

    /// sin(x).
    public static func sin(_ x: Double) -> Double {
        let ix = hi(x) & 0x7fffffff
        if ix <= 0x3fe921fb {                // |x| ~< pi/4
            return kernelSin(x, 0.0, 0)
        } else if ix >= 0x7ff00000 {         // sin(Inf or NaN) is NaN
            return x - x
        }
        let (n, y0, y1) = remPio2(x)         // argument reduction needed
        switch n & 3 {
        case 0: return kernelSin(y0, y1, 1)
        case 1: return kernelCos(y0, y1)
        case 2: return -kernelSin(y0, y1, 1)
        default: return -kernelCos(y0, y1)
        }
    }

    /// cos(x).
    public static func cos(_ x: Double) -> Double {
        let ix = hi(x) & 0x7fffffff
        if ix <= 0x3fe921fb {                // |x| ~< pi/4
            return kernelCos(x, 0.0)
        } else if ix >= 0x7ff00000 {         // cos(Inf or NaN) is NaN
            return x - x
        }
        let (n, y0, y1) = remPio2(x)         // argument reduction needed
        switch n & 3 {
        case 0: return kernelCos(y0, y1)
        case 1: return -kernelSin(y0, y1, 1)
        case 2: return -kernelCos(y0, y1)
        default: return kernelSin(y0, y1, 1)
        }
    }

    /// tan(x).
    public static func tan(_ x: Double) -> Double {
        let ix = hi(x) & 0x7fffffff
        if ix <= 0x3fe921fb {                // |x| ~< pi/4
            return kernelTan(x, 0.0, 1)
        } else if ix >= 0x7ff00000 {         // tan(Inf or NaN) is NaN
            return x - x
        }
        let (n, y0, y1) = remPio2(x)         // argument reduction needed
        return kernelTan(y0, y1, 1 - ((n & 1) &<< 1)) // 1 -- n even, -1 -- n odd
    }

    // MARK: - e_asin.c, e_acos.c

    private static let pS0 = 1.66666666666666657415e-01  // 0x3FC55555, 0x55555555
    private static let pS1 = -3.25565818622400915405e-01 // 0xBFD4D612, 0x03EB6F7D
    private static let pS2 = 2.01212532134862925881e-01  // 0x3FC9C155, 0x0E884455
    private static let pS3 = -4.00555345006794114027e-02 // 0xBFA48228, 0xB5688F3B
    private static let pS4 = 7.91534994289814532176e-04  // 0x3F49EFE0, 0x7501B288
    private static let pS5 = 3.47933107596021167570e-05  // 0x3F023DE1, 0x0DFDF709
    private static let qS1 = -2.40339491173441421878e+00 // 0xC0033A27, 0x1C8A2D4B
    private static let qS2 = 2.02094576023350569471e+00  // 0x40002AE5, 0x9C598AC8
    private static let qS3 = -6.88283971605453293030e-01 // 0xBFE6066C, 0x1B8D0159
    private static let qS4 = 7.70381505559019352791e-02  // 0x3FB3B8C5, 0xB12E9282

    /// asin(x).
    public static func asin(_ x: Double) -> Double {
        let one = 1.00000000000000000000e+00     // 0x3FF00000, 0x00000000
        let huge = 1.000e+300
        let pio2_hi = 1.57079632679489655800e+00 // 0x3FF921FB, 0x54442D18
        let pio2_lo = 6.12323399573676603587e-17 // 0x3C91A626, 0x33145C07
        let pio4_hi = 7.85398163397448278999e-01 // 0x3FE921FB, 0x54442D18

        var t: Double
        var w: Double
        var p: Double
        var q: Double
        let hx = hi(x)
        let ix = hx & 0x7fffffff
        if ix >= 0x3ff00000 {                    // |x| >= 1
            if ((ix - 0x3ff00000) | lo(x)) == 0 {
                // asin(1) = +-pi/2 with inexact
                return x * pio2_hi + x * pio2_lo
            }
            return (x - x) / (x - x)             // asin(|x|>1) is NaN
        } else if ix < 0x3fe00000 {              // |x| < 0.5
            if ix < 0x3e400000 {                 // if |x| < 2**-27
                if huge + x > one { return x }   // return x with inexact if x!=0
            }
            t = x * x
            p = t * (pS0 + t * (pS1 + t * (pS2 + t * (pS3 + t * (pS4 + t * pS5)))))
            q = one + t * (qS1 + t * (qS2 + t * (qS3 + t * qS4)))
            w = p / q
            return x + x * w
        }
        // 1 > |x| >= 0.5
        w = one - x.magnitude
        t = w * 0.5
        p = t * (pS0 + t * (pS1 + t * (pS2 + t * (pS3 + t * (pS4 + t * pS5)))))
        q = one + t * (qS1 + t * (qS2 + t * (qS3 + t * qS4)))
        let s = t.squareRoot()
        if ix >= 0x3FEF3333 {                    // if |x| > 0.975
            w = p / q
            t = pio2_hi - (2.0 * (s + s * w) - pio2_lo)
        } else {
            w = setLo(s, 0)
            let c = (t - w * w) / (s + w)
            let r = p / q
            p = 2.0 * s * r - (pio2_lo - 2.0 * c)
            q = pio4_hi - 2.0 * w
            t = pio4_hi - (p - q)
        }
        if hx > 0 { return t } else { return -t }
    }

    /// acos(x).
    public static func acos(_ x: Double) -> Double {
        let one = 1.00000000000000000000e+00     // 0x3FF00000, 0x00000000
        let pi = 3.14159265358979311600e+00      // 0x400921FB, 0x54442D18
        let pio2_hi = 1.57079632679489655800e+00 // 0x3FF921FB, 0x54442D18
        let pio2_lo = 6.12323399573676603587e-17 // 0x3C91A626, 0x33145C07

        let hx = hi(x)
        let ix = hx & 0x7fffffff
        if ix >= 0x3ff00000 {                    // |x| >= 1
            if ((ix - 0x3ff00000) | lo(x)) == 0 { // |x| == 1
                if hx > 0 { return 0.0 }         // acos(1) = 0
                else { return pi + 2.0 * pio2_lo } // acos(-1) = pi
            }
            return (x - x) / (x - x)             // acos(|x|>1) is NaN
        }
        if ix < 0x3fe00000 {                     // |x| < 0.5
            if ix <= 0x3c600000 { return pio2_hi + pio2_lo } // if |x| < 2**-57
            let z = x * x
            let p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * pS5)))))
            let q = one + z * (qS1 + z * (qS2 + z * (qS3 + z * qS4)))
            let r = p / q
            return pio2_hi - (x - (pio2_lo - x * r))
        } else if hx < 0 {                       // x < -0.5
            let z = (one + x) * 0.5
            let p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * pS5)))))
            let q = one + z * (qS1 + z * (qS2 + z * (qS3 + z * qS4)))
            let s = z.squareRoot()
            let r = p / q
            let w = r * s - pio2_lo
            return pi - 2.0 * (s + w)
        } else {                                 // x > 0.5
            let z = (one - x) * 0.5
            let s = z.squareRoot()
            let df = setLo(s, 0)
            let c = (z - df * df) / (s + df)
            let p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * pS5)))))
            let q = one + z * (qS1 + z * (qS2 + z * (qS3 + z * qS4)))
            let r = p / q
            let w = r * s + c
            return 2.0 * (df + w)
        }
    }

    // MARK: - s_atan.c, e_atan2.c

    private static let atanhi: [Double] = [
        4.63647609000806093515e-01, // atan(0.5)hi 0x3FDDAC67, 0x0561BB4F
        7.85398163397448278999e-01, // atan(1.0)hi 0x3FE921FB, 0x54442D18
        9.82793723247329054082e-01, // atan(1.5)hi 0x3FEF730B, 0xD281F69B
        1.57079632679489655800e+00, // atan(inf)hi 0x3FF921FB, 0x54442D18
    ]

    private static let atanlo: [Double] = [
        2.26987774529616870924e-17, // atan(0.5)lo 0x3C7A2B7F, 0x222F65E2
        3.06161699786838301793e-17, // atan(1.0)lo 0x3C81A626, 0x33145C07
        1.39033110312309984516e-17, // atan(1.5)lo 0x3C700788, 0x7AF0CBBD
        6.12323399573676603587e-17, // atan(inf)lo 0x3C91A626, 0x33145C07
    ]

    /// atan(x).
    public static func atan(_ xIn: Double) -> Double {
        let aT0 = 3.33333333333329318027e-01  // 0x3FD55555, 0x5555550D
        let aT1 = -1.99999999998764832476e-01 // 0xBFC99999, 0x9998EBC4
        let aT2 = 1.42857142725034663711e-01  // 0x3FC24924, 0x920083FF
        let aT3 = -1.11111104054623557880e-01 // 0xBFBC71C6, 0xFE231671
        let aT4 = 9.09088713343650656196e-02  // 0x3FB745CD, 0xC54C206E
        let aT5 = -7.69187620504482999495e-02 // 0xBFB3B0F2, 0xAF749A6D
        let aT6 = 6.66107313738753120669e-02  // 0x3FB10D66, 0xA0D03D51
        let aT7 = -5.83357013379057348645e-02 // 0xBFADDE2D, 0x52DEFD9A
        let aT8 = 4.97687799461593236017e-02  // 0x3FA97B4B, 0x24760DEB
        let aT9 = -3.65315727442169155270e-02 // 0xBFA2B444, 0x2C6A6C2F
        let aT10 = 1.62858201153657823623e-02 // 0x3F90AD3A, 0xE322DA11
        let one = 1.0
        let huge = 1.0e300

        var x = xIn
        let id: Int
        let hx = hi(x)
        let ix = hx & 0x7fffffff
        if ix >= 0x44100000 {                // if |x| >= 2^66
            if ix > 0x7ff00000 || (ix == 0x7ff00000 && lo(x) != 0) {
                return x + x                 // NaN
            }
            if hx > 0 { return atanhi[3] + atanlo[3] }
            else { return -atanhi[3] - atanlo[3] }
        }
        if ix < 0x3fdc0000 {                 // |x| < 0.4375
            if ix < 0x3e200000 {             // |x| < 2^-29
                if huge + x > one { return x } // raise inexact
            }
            id = -1
        } else {
            x = x.magnitude
            if ix < 0x3ff30000 {             // |x| < 1.1875
                if ix < 0x3fe60000 {         // 7/16 <= |x| < 11/16
                    id = 0
                    x = (2.0 * x - one) / (2.0 + x)
                } else {                     // 11/16 <= |x| < 19/16
                    id = 1
                    x = (x - one) / (x + one)
                }
            } else {
                if ix < 0x40038000 {         // |x| < 2.4375
                    id = 2
                    x = (x - 1.5) / (one + 1.5 * x)
                } else {                     // 2.4375 <= |x| < 2^66
                    id = 3
                    x = -1.0 / x
                }
            }
        }
        // end of argument reduction
        var z = x * x
        let w = z * z
        // break sum from i=0 to 10 aT[i]z**(i+1) into odd and even poly
        let s1 = z * (aT0 + w * (aT2 + w * (aT4 + w * (aT6 + w * (aT8 + w * aT10)))))
        let s2 = w * (aT1 + w * (aT3 + w * (aT5 + w * (aT7 + w * aT9))))
        if id < 0 {
            return x - x * (s1 + s2)
        } else {
            z = atanhi[id] - ((x * (s1 + s2) - atanlo[id]) - x)
            return hx < 0 ? -z : z
        }
    }

    /// atan2(y, x).
    public static func atan2(_ y: Double, _ x: Double) -> Double {
        let tiny = 1.0e-300
        let zero = 0.0
        let pi_o_4 = 7.8539816339744827900E-01 // 0x3FE921FB, 0x54442D18
        let pi_o_2 = 1.5707963267948965580E+00 // 0x3FF921FB, 0x54442D18
        let pi = 3.1415926535897931160E+00     // 0x400921FB, 0x54442D18
        let pi_lo = 1.2246467991473531772E-16  // 0x3CA1A626, 0x33145C07

        let hx = hi(x)
        let ix = hx & 0x7fffffff
        let lx = ulo(x)
        let hy = hi(y)
        let iy = hy & 0x7fffffff
        let ly = ulo(y)
        if (UInt32(bitPattern: ix) | ((lx | (0 &- lx)) >> 31)) > 0x7ff00000
            || (UInt32(bitPattern: iy) | ((ly | (0 &- ly)) >> 31)) > 0x7ff00000 { // x or y is NaN
            return x + y
        }
        if (UInt32(bitPattern: hx &- 0x3ff00000) | lx) == 0 { return atan(y) } // x = 1.0
        let m = ((hy &>> 31) & 1) | ((hx &>> 30) & 2) // 2*sign(x)+sign(y)

        // when y = 0
        if (UInt32(bitPattern: iy) | ly) == 0 {
            switch m {
            case 0, 1: return y               // atan(+-0,+anything) = +-0
            case 2: return pi + tiny          // atan(+0,-anything) = pi
            default: return -pi - tiny        // atan(-0,-anything) = -pi
            }
        }
        // when x = 0
        if (UInt32(bitPattern: ix) | lx) == 0 { return hy < 0 ? -pi_o_2 - tiny : pi_o_2 + tiny }

        // when x is INF
        if ix == 0x7ff00000 {
            if iy == 0x7ff00000 {
                switch m {
                case 0: return pi_o_4 + tiny        // atan(+INF,+INF)
                case 1: return -pi_o_4 - tiny       // atan(-INF,+INF)
                case 2: return 3.0 * pi_o_4 + tiny  // atan(+INF,-INF)
                default: return -3.0 * pi_o_4 - tiny // atan(-INF,-INF)
                }
            } else {
                switch m {
                case 0: return zero                 // atan(+...,+INF)
                case 1: return -zero                // atan(-...,+INF)
                case 2: return pi + tiny            // atan(+...,-INF)
                default: return -pi - tiny          // atan(-...,-INF)
                }
            }
        }
        // when y is INF
        if iy == 0x7ff00000 { return hy < 0 ? -pi_o_2 - tiny : pi_o_2 + tiny }

        // compute y/x
        let k = (iy - ix) &>> 20
        var z: Double
        if k > 60 {                          // |y/x| > 2**60
            z = pi_o_2 + 0.5 * pi_lo
        } else if hx < 0 && k < -60 {        // |y|/x < -2**60
            z = 0.0
        } else {                             // safe to do y/x
            z = atan((y / x).magnitude)
        }
        switch m {
        case 0: return z                     // atan(+,+)
        case 1:                              // atan(-,+)
            z = setHi(z, hi(z) ^ signBit)
            return z
        case 2: return pi - (z - pi_lo)      // atan(+,-)
        default: return (z - pi_lo) - pi     // atan(-,-)
        }
    }

    // MARK: - e_exp.c

    /// exp(x).
    public static func exp(_ xIn: Double) -> Double {
        let one = 1.0
        let huge = 1.0e+300
        let twom1000 = 9.33263618503218878990e-302    // 2**-1000 = 0x01700000, 0
        let o_threshold = 7.09782712893383973096e+02  // 0x40862E42, 0xFEFA39EF
        let u_threshold = -7.45133219101941108420e+02 // 0xc0874910, 0xD52D3051
        let ln2HI = 6.93147180369123816490e-01        // 0x3fe62e42, 0xfee00000
        let ln2LO = 1.90821492927058770002e-10        // 0x3dea39ef, 0x35793c76
        let invln2 = 1.44269504088896338700e+00       // 0x3ff71547, 0x652b82fe
        let P1 = 1.66666666666666019037e-01           // 0x3FC55555, 0x5555553E
        let P2 = -2.77777777770155933842e-03          // 0xBF66C16C, 0x16BEBD93
        let P3 = 6.61375632143793436117e-05           // 0x3F11566A, 0xAF25DE2C
        let P4 = -1.65339022054652515390e-06          // 0xBEBBBD41, 0xC5D26BF1
        let P5 = 4.13813679705723846039e-08           // 0x3E663769, 0x72BEA4D0

        var x = xIn
        var hi_ = 0.0
        var lo_ = 0.0
        var k: Int32 = 0
        var hx = UInt32(bitPattern: hi(x))   // high word of x
        let xsb = Int32((hx >> 31) & 1)      // sign bit of x
        hx &= 0x7fffffff                     // high word of |x|

        // filter out non-finite argument
        if hx >= 0x40862E42 {                // if |x| >= 709.78...
            if hx >= 0x7ff00000 {
                if ((hx & 0xfffff) | ulo(x)) != 0 {
                    return x + x             // NaN
                } else {
                    return xsb == 0 ? x : 0.0 // exp(+-inf) = {inf,0}
                }
            }
            if x > o_threshold { return huge * huge }           // overflow
            if x < u_threshold { return twom1000 * twom1000 }   // underflow
        }

        // argument reduction
        if hx > 0x3fd62e42 {                 // if |x| > 0.5 ln2
            if hx < 0x3FF0A2B2 {             // and |x| < 1.5 ln2
                hi_ = x - (xsb == 0 ? ln2HI : -ln2HI)
                lo_ = xsb == 0 ? ln2LO : -ln2LO
                k = 1 - xsb - xsb
            } else {
                k = cInt(invln2 * x + (xsb == 0 ? 0.5 : -0.5))
                let t = Double(k)
                hi_ = x - t * ln2HI          // t*ln2HI is exact here
                lo_ = t * ln2LO
            }
            x = hi_ - lo_
        } else if hx < 0x3e300000 {          // when |x| < 2**-28
            if huge + x > one { return one + x } // trigger inexact
        } else {
            k = 0
        }

        // x is now in primary range
        let t = x * x
        let c = x - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))))
        if k == 0 { return one - ((x * c) / (c - 2.0) - x) }
        let y = one - ((lo_ - (x * c) / (2.0 - c)) - hi_)
        if k >= -1021 {
            return setHi(y, hi(y) &+ (k &<< 20))          // add k to y's exponent
        } else {
            return setHi(y, hi(y) &+ ((k + 1000) &<< 20)) * twom1000
        }
    }

    // MARK: - s_expm1.c

    /// expm1(x) = exp(x) - 1.
    public static func expm1(_ xIn: Double) -> Double {
        let one = 1.0
        let huge = 1.0e+300
        let tiny = 1.0e-300
        let o_threshold = 7.09782712893383973096e+02 // 0x40862E42, 0xFEFA39EF
        let ln2_hi = 6.93147180369123816490e-01      // 0x3fe62e42, 0xfee00000
        let ln2_lo = 1.90821492927058770002e-10      // 0x3dea39ef, 0x35793c76
        let invln2 = 1.44269504088896338700e+00      // 0x3ff71547, 0x652b82fe
        // scaled coefficients related to expm1
        let Q1 = -3.33333333333331316428e-02         // BFA11111 111110F4
        let Q2 = 1.58730158725481460165e-03          // 3F5A01A0 19FE5585
        let Q3 = -7.93650757867487942473e-05         // BF14CE19 9EAADBB7
        let Q4 = 4.00821782732936239552e-06          // 3ED0CFCA 86E65239
        let Q5 = -2.01099218183624371326e-07         // BE8AFDB7 6E09C32D

        var x = xIn
        var y: Double
        var hi_ = 0.0
        var lo_ = 0.0
        var c = 0.0
        var t: Double
        var e: Double
        var k: Int32 = 0
        var hx = UInt32(bitPattern: hi(x))   // high word of x
        let xsb = hx & 0x80000000            // sign bit of x
        hx &= 0x7fffffff                     // high word of |x|

        // filter out huge and non-finite argument
        if hx >= 0x4043687A {                // if |x| >= 56*ln2
            if hx >= 0x40862E42 {            // if |x| >= 709.78...
                if hx >= 0x7ff00000 {
                    if ((hx & 0xfffff) | ulo(x)) != 0 {
                        return x + x         // NaN
                    } else {
                        return xsb == 0 ? x : -1.0 // exp(+-inf) = {inf,-1}
                    }
                }
                if x > o_threshold { return huge * huge } // overflow
            }
            if xsb != 0 {                    // x < -56*ln2, return -1.0 with inexact
                if x + tiny < 0.0 {          // raise inexact
                    return tiny - one        // return -1
                }
            }
        }

        // argument reduction
        if hx > 0x3fd62e42 {                 // if |x| > 0.5 ln2
            if hx < 0x3FF0A2B2 {             // and |x| < 1.5 ln2
                if xsb == 0 {
                    hi_ = x - ln2_hi
                    lo_ = ln2_lo
                    k = 1
                } else {
                    hi_ = x + ln2_hi
                    lo_ = -ln2_lo
                    k = -1
                }
            } else {
                k = cInt(invln2 * x + (xsb == 0 ? 0.5 : -0.5))
                t = Double(k)
                hi_ = x - t * ln2_hi         // t*ln2_hi is exact here
                lo_ = t * ln2_lo
            }
            x = hi_ - lo_
            c = (hi_ - x) - lo_
        } else if hx < 0x3c900000 {          // when |x| < 2**-54, return x
            t = huge + x                     // return x with inexact flags when x!=0
            return x - (t - (huge + x))
        } else {
            k = 0
        }

        // x is now in primary range
        let hfx = 0.5 * x
        let hxs = x * hfx
        let r1 = one + hxs * (Q1 + hxs * (Q2 + hxs * (Q3 + hxs * (Q4 + hxs * Q5))))
        t = 3.0 - r1 * hfx
        e = hxs * ((r1 - t) / (6.0 - x * t))
        if k == 0 { return x - (x * e - hxs) } // c is 0
        e = (x * (e - c) - c)
        e -= hxs
        if k == -1 { return 0.5 * (x - e) - 0.5 }
        if k == 1 {
            if x < -0.25 {
                return -2.0 * (e - (x + 0.5))
            } else {
                return one + 2.0 * (x - e)
            }
        }
        if k <= -2 || k > 56 {               // suffice to return exp(x)-1
            y = one - (e - x)
            y = setHi(y, hi(y) &+ (k &<< 20)) // add k to y's exponent
            return y - one
        }
        t = one
        if k < 20 {
            t = setHi(t, 0x3ff00000 - (0x200000 &>> k)) // t = 1-2^-k
            y = t - (e - x)
            y = setHi(y, hi(y) &+ (k &<< 20)) // add k to y's exponent
        } else {
            t = setHi(t, (0x3ff - k) &<< 20) // 2^-k
            y = x - (e + t)
            y += one
            y = setHi(y, hi(y) &+ (k &<< 20)) // add k to y's exponent
        }
        return y
    }

    // MARK: - e_log.c, e_log10.c, s_log1p.c

    /// log(x), the natural logarithm.
    public static func log(_ xIn: Double) -> Double {
        let ln2_hi = 6.93147180369123816490e-01 // 3fe62e42 fee00000
        let ln2_lo = 1.90821492927058770002e-10 // 3dea39ef 35793c76
        let two54 = 1.80143985094819840000e+16  // 43500000 00000000
        let Lg1 = 6.666666666666735130e-01      // 3FE55555 55555593
        let Lg2 = 3.999999999940941908e-01      // 3FD99999 9997FA04
        let Lg3 = 2.857142874366239149e-01      // 3FD24924 94229359
        let Lg4 = 2.222219843214978396e-01      // 3FCC71C5 1D8E78AF
        let Lg5 = 1.818357216161805012e-01      // 3FC74664 96CB03DE
        let Lg6 = 1.531383769920937332e-01      // 3FC39A09 D078C69F
        let Lg7 = 1.479819860511658591e-01      // 3FC2F112 DF3E5244
        let zero = 0.0

        var x = xIn
        var hx = hi(x)                       // high word of x
        let lx = lo(x)                       // low word of x

        var k: Int32 = 0
        if hx < 0x00100000 {                 // x < 2**-1022
            if ((hx & 0x7fffffff) | lx) == 0 {
                return -two54 / zero         // log(+-0) = -inf
            }
            if hx < 0 { return (x - x) / zero } // log(-#) = NaN
            k -= 54
            x *= two54                       // subnormal number, scale up x
            hx = hi(x)                       // high word of x
        }
        if hx >= 0x7ff00000 { return x + x }
        k += (hx &>> 20) - 1023
        hx &= 0x000fffff
        var i = (hx + 0x95f64) & 0x100000
        x = setHi(x, hx | (i ^ 0x3ff00000))  // normalize x or x/2
        k += (i &>> 20)
        let f = x - 1.0
        if (0x000fffff & (2 + hx)) < 3 {     // |f| < 2**-20
            if f == zero {
                if k == 0 {
                    return zero
                } else {
                    let dk = Double(k)
                    return dk * ln2_hi + dk * ln2_lo
                }
            }
            let R = f * f * (0.5 - 0.33333333333333333 * f)
            if k == 0 {
                return f - R
            } else {
                let dk = Double(k)
                return dk * ln2_hi - ((R - dk * ln2_lo) - f)
            }
        }
        let s = f / (2.0 + f)
        let dk = Double(k)
        let z = s * s
        i = hx - 0x6147a
        let w = z * z
        let j = 0x6b851 - hx
        let t1 = w * (Lg2 + w * (Lg4 + w * Lg6))
        let t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)))
        i |= j
        let R = t2 + t1
        if i > 0 {
            let hfsq = 0.5 * f * f
            if k == 0 {
                return f - (hfsq - s * (hfsq + R))
            } else {
                return dk * ln2_hi - ((hfsq - (s * (hfsq + R) + dk * ln2_lo)) - f)
            }
        } else {
            if k == 0 {
                return f - s * (f - R)
            } else {
                return dk * ln2_hi - ((s * (f - R) - dk * ln2_lo) - f)
            }
        }
    }

    /// log10(x), the base 10 logarithm.
    public static func log10(_ xIn: Double) -> Double {
        let two54 = 1.80143985094819840000e+16     // 0x43500000, 0x00000000
        let ivln10 = 4.34294481903251816668e-01    // 0x3FDBCB7B, 0x1526E50E
        let log10_2hi = 3.01029995663611771306e-01 // 0x3FD34413, 0x509F6000
        let log10_2lo = 3.69423907715893078616e-13 // 0x3D59FEF3, 0x11F12B36
        let zero = 0.0

        var x = xIn
        var hx = hi(x)                       // high word of x
        let lx = lo(x)                       // low word of x

        var k: Int32 = 0
        if hx < 0x00100000 {                 // x < 2**-1022
            if ((hx & 0x7fffffff) | lx) == 0 {
                return -two54 / zero         // log(+-0) = -inf
            }
            if hx < 0 { return (x - x) / zero } // log(-#) = NaN
            k -= 54
            x *= two54                       // subnormal number, scale up x
            hx = hi(x)                       // high word of x
        }
        if hx >= 0x7ff00000 { return x + x }
        k += (hx &>> 20) - 1023
        let i = Int32(bitPattern: (UInt32(bitPattern: k) & 0x80000000) >> 31)
        hx = (hx & 0x000fffff) | ((0x3ff - i) &<< 20)
        let y = Double(k + i)
        x = setHi(x, hx)
        let z = y * log10_2lo + ivln10 * log(x)
        return z + y * log10_2hi
    }

    /// log1p(x) = log(1 + x).
    public static func log1p(_ x: Double) -> Double {
        let ln2_hi = 6.93147180369123816490e-01 // 3fe62e42 fee00000
        let ln2_lo = 1.90821492927058770002e-10 // 3dea39ef 35793c76
        let two54 = 1.80143985094819840000e+16  // 43500000 00000000
        let Lp1 = 6.666666666666735130e-01      // 3FE55555 55555593
        let Lp2 = 3.999999999940941908e-01      // 3FD99999 9997FA04
        let Lp3 = 2.857142874366239149e-01      // 3FD24924 94229359
        let Lp4 = 2.222219843214978396e-01      // 3FCC71C5 1D8E78AF
        let Lp5 = 1.818357216161805012e-01      // 3FC74664 96CB03DE
        let Lp6 = 1.531383769920937332e-01      // 3FC39A09 D078C69F
        let Lp7 = 1.479819860511658591e-01      // 3FC2F112 DF3E5244
        let zero = 0.0

        var f = 0.0
        var c = 0.0
        var hu: Int32 = 0
        let hx = hi(x)                       // high word of x
        let ax = hx & 0x7fffffff

        var k: Int32 = 1
        if hx < 0x3FDA827A {                 // x < 0.41422
            if ax >= 0x3ff00000 {            // x <= -1.0
                if x == -1.0 {
                    return -two54 / zero     // log1p(-1) = -inf
                } else {
                    return (x - x) / (x - x) // log1p(x<-1) = NaN
                }
            }
            if ax < 0x3e200000 {             // |x| < 2**-29
                if two54 + x > zero          // raise inexact
                    && ax < 0x3c900000 {     // |x| < 2**-54
                    return x
                } else {
                    return x - x * x * 0.5
                }
            }
            if hx > 0 || hx <= Int32(bitPattern: 0xbfd2bec3) {
                k = 0                        // -0.2929 < x < 0.41422
                f = x
                hu = 1
            }
        }
        if hx >= 0x7ff00000 { return x + x }
        if k != 0 {
            var u: Double
            if hx < 0x43400000 {
                u = 1.0 + x
                hu = hi(u)                   // high word of u
                k = (hu &>> 20) - 1023
                c = k > 0 ? 1.0 - (u - x) : x - (u - 1.0) // correction term
                c /= u
            } else {
                u = x
                hu = hi(u)                   // high word of u
                k = (hu &>> 20) - 1023
                c = 0
            }
            hu &= 0x000fffff
            if hu < 0x6a09e {
                u = setHi(u, hu | 0x3ff00000) // normalize u
            } else {
                k += 1
                u = setHi(u, hu | 0x3fe00000) // normalize u/2
                hu = (0x00100000 - hu) &>> 2
            }
            f = u - 1.0
        }
        let hfsq = 0.5 * f * f
        if hu == 0 {                         // |f| < 2**-20
            if f == zero {
                if k == 0 {
                    return zero
                } else {
                    c += Double(k) * ln2_lo
                    return Double(k) * ln2_hi + c
                }
            }
            let R = hfsq * (1.0 - 0.66666666666666666 * f)
            if k == 0 {
                return f - R
            } else {
                return Double(k) * ln2_hi - ((R - (Double(k) * ln2_lo + c)) - f)
            }
        }
        let s = f / (2.0 + f)
        let z = s * s
        let R = z * (Lp1 + z * (Lp2 + z * (Lp3 + z * (Lp4 + z * (Lp5 + z * (Lp6 + z * Lp7))))))
        if k == 0 {
            return f - (hfsq - s * (hfsq + R))
        } else {
            return Double(k) * ln2_hi - ((hfsq - (s * (hfsq + R) + (Double(k) * ln2_lo + c))) - f)
        }
    }

    // MARK: - e_pow.c

    /// pow(x, y) = x**y.
    public static func pow(_ x: Double, _ y: Double) -> Double {
        let zero = 0.0
        let one = 1.0
        let two = 2.0
        let two53 = 9007199254740992.0               // 0x43400000, 0x00000000
        let huge = 1.0e300
        let tiny = 1.0e-300
        // poly coefs for (3/2)*(log(x)-2s-2/3*s**3
        let L1 = 5.99999999999994648725e-01          // 0x3FE33333, 0x33333303
        let L2 = 4.28571428578550184252e-01          // 0x3FDB6DB6, 0xDB6FABFF
        let L3 = 3.33333329818377432918e-01          // 0x3FD55555, 0x518F264D
        let L4 = 2.72728123808534006489e-01          // 0x3FD17460, 0xA91D4101
        let L5 = 2.30660745775561754067e-01          // 0x3FCD864A, 0x93C9DB65
        let L6 = 2.06975017800338417784e-01          // 0x3FCA7E28, 0x4A454EEF
        let P1 = 1.66666666666666019037e-01          // 0x3FC55555, 0x5555553E
        let P2 = -2.77777777770155933842e-03         // 0xBF66C16C, 0x16BEBD93
        let P3 = 6.61375632143793436117e-05          // 0x3F11566A, 0xAF25DE2C
        let P4 = -1.65339022054652515390e-06         // 0xBEBBBD41, 0xC5D26BF1
        let P5 = 4.13813679705723846039e-08          // 0x3E663769, 0x72BEA4D0
        let lg2 = 6.93147180559945286227e-01         // 0x3FE62E42, 0xFEFA39EF
        let lg2_h = 6.93147182464599609375e-01       // 0x3FE62E43, 0x00000000
        let lg2_l = -1.90465429995776804525e-09      // 0xBE205C61, 0x0CA86C39
        let ovt = 8.0085662595372944372e-17          // -(1024-log2(ovfl+.5ulp))
        let cp = 9.61796693925975554329e-01          // 0x3FEEC709, 0xDC3A03FD = 2/(3ln2)
        let cp_h = 9.61796700954437255859e-01        // 0x3FEEC709, 0xE0000000 = (float)cp
        let cp_l = -7.02846165095275826516e-09       // 0xBE3E2FE0, 0x145B01F5 = tail of cp_h
        let ivln2 = 1.44269504088896338700e+00       // 0x3FF71547, 0x652B82FE = 1/ln2
        let ivln2_h = 1.44269502162933349609e+00     // 0x3FF71547, 0x60000000 = 24b 1/ln2
        let ivln2_l = 1.92596299112661746887e-08     // 0x3E54AE0B, 0xF85DDF44 = 1/ln2 tail

        var z: Double
        var ax: Double
        var p_h: Double
        var p_l: Double
        var t1: Double
        var t2: Double
        var t: Double
        var u: Double
        var v: Double
        var w: Double
        var r: Double
        var i: Int32
        var j: Int32
        var k: Int32
        var n: Int32
        var yisint: Int32

        let hx = hi(x)
        let lx = ulo(x)
        let hy = hi(y)
        let ly = ulo(y)
        var ix = hx & 0x7fffffff
        let iy = hy & 0x7fffffff

        // y == zero: x**0 = 1
        if (UInt32(bitPattern: iy) | ly) == 0 { return one }

        // +-NaN return x+y
        if ix > 0x7ff00000 || (ix == 0x7ff00000 && lx != 0)
            || iy > 0x7ff00000 || (iy == 0x7ff00000 && ly != 0) {
            return x + y
        }

        // determine if y is an odd int when x < 0
        // yisint = 0 ... y is not an integer
        // yisint = 1 ... y is an odd int
        // yisint = 2 ... y is an even int
        yisint = 0
        if hx < 0 {
            if iy >= 0x43400000 {
                yisint = 2                   // even integer y
            } else if iy >= 0x3ff00000 {
                k = (iy &>> 20) - 0x3ff      // exponent
                if k > 20 {
                    let uj = ly >> UInt32(52 - k)
                    if (uj << UInt32(52 - k)) == ly { yisint = 2 - Int32(bitPattern: uj & 1) }
                } else if ly == 0 {
                    j = iy &>> (20 - k)
                    if (j &<< (20 - k)) == iy { yisint = 2 - (j & 1) }
                }
            }
        }

        // special value of y
        if ly == 0 {
            if iy == 0x7ff00000 {            // y is +-inf
                if ((ix - 0x3ff00000) | Int32(bitPattern: lx)) == 0 {
                    return y - y             // inf**+-1 is NaN
                } else if ix >= 0x3ff00000 { // (|x|>1)**+-inf = inf,0
                    return hy >= 0 ? y : zero
                } else {                     // (|x|<1)**-,+inf = inf,0
                    return hy < 0 ? -y : zero
                }
            }
            if iy == 0x3ff00000 {            // y is +-1
                if hy < 0 { return one / x } else { return x }
            }
            if hy == 0x40000000 { return x * x } // y is 2
            if hy == 0x3fe00000 {            // y is 0.5
                if hx >= 0 {                 // x >= +0
                    return x.squareRoot()
                }
            }
        }

        ax = x.magnitude
        // special value of x
        if lx == 0 {
            if ix == 0x7ff00000 || ix == 0 || ix == 0x3ff00000 {
                z = ax                       // x is +-0,+-inf,+-1
                if hy < 0 { z = one / z }    // z = (1/|x|)
                if hx < 0 {
                    if ((ix - 0x3ff00000) | yisint) == 0 {
                        z = (z - z) / (z - z) // (-1)**non-int is NaN
                    } else if yisint == 1 {
                        z = -z               // (x<0)**odd = -(|x|**odd)
                    }
                }
                return z
            }
        }

        n = (hx &>> 31) + 1

        // (x<0)**(non-int) is NaN
        if (n | yisint) == 0 { return (x - x) / (x - x) }

        var s = one                          // s (sign of result -ve**odd) = -1 else = 1
        if (n | (yisint - 1)) == 0 { s = -one } // (-ve)**(odd int)

        // |y| is huge
        if iy > 0x41e00000 {                 // if |y| > 2**31
            if iy > 0x43f00000 {             // if |y| > 2**64, must o/uflow
                if ix <= 0x3fefffff { return hy < 0 ? huge * huge : tiny * tiny }
                if ix >= 0x3ff00000 { return hy > 0 ? huge * huge : tiny * tiny }
            }
            // over/underflow if x is not close to one
            if ix < 0x3fefffff { return hy < 0 ? s * huge * huge : s * tiny * tiny }
            if ix > 0x3ff00000 { return hy > 0 ? s * huge * huge : s * tiny * tiny }
            // now |1-x| is tiny <= 2**-20, suffice to compute
            // log(x) by x-x^2/2+x^3/3-x^4/4
            t = ax - one                     // t has 20 trailing zeros
            w = (t * t) * (0.5 - t * (0.3333333333333333333333 - t * 0.25))
            u = ivln2_h * t                  // ivln2_h has 21 sig. bits
            v = t * ivln2_l - w * ivln2
            t1 = u + v
            t1 = setLo(t1, 0)
            t2 = v - (t1 - u)
        } else {
            n = 0
            // take care subnormal number
            if ix < 0x00100000 {
                ax *= two53
                n -= 53
                ix = hi(ax)
            }
            n += (ix &>> 20) - 0x3ff
            j = ix & 0x000fffff
            // determine interval
            ix = j | 0x3ff00000              // normalize ix
            if j <= 0x3988E {                // |x| < sqrt(3/2)
                k = 0
            } else if j < 0xBB67A {          // |x| < sqrt(3)
                k = 1
            } else {
                k = 0
                n += 1
                ix -= 0x00100000
            }
            ax = setHi(ax, ix)
            let bp = k == 0 ? 1.0 : 1.5      // bp[] = {1.0, 1.5}
            let dp_h = k == 0 ? 0.0 : 5.84962487220764160156e-01 // 0x3FE2B803, 0x40000000
            let dp_l = k == 0 ? 0.0 : 1.35003920212974897128e-08 // 0x3E4CFDEB, 0x43CFD006

            // compute ss = s_h+s_l = (x-1)/(x+1) or (x-1.5)/(x+1.5)
            u = ax - bp
            v = one / (ax + bp)
            let ss = u * v
            let s_h = setLo(ss, 0)
            // t_h = ax+bp[k] High
            var t_h = make(((ix &>> 1) | 0x20000000) &+ 0x00080000 &+ (k &<< 18), 0)
            var t_l = ax - (t_h - bp)
            let s_l = v * ((u - s_h * t_h) - s_h * t_l)
            // compute log(ax)
            var s2 = ss * ss
            r = s2 * s2 * (L1 + s2 * (L2 + s2 * (L3 + s2 * (L4 + s2 * (L5 + s2 * L6)))))
            r += s_l * (s_h + ss)
            s2 = s_h * s_h
            t_h = 3.0 + s2 + r
            t_h = setLo(t_h, 0)
            t_l = r - ((t_h - 3.0) - s2)
            // u+v = ss*(1+...)
            u = s_h * t_h
            v = s_l * t_h + t_l * ss
            // 2/(3log2)*(ss+...)
            p_h = u + v
            p_h = setLo(p_h, 0)
            p_l = v - (p_h - u)
            let z_h = cp_h * p_h             // cp_h+cp_l = 2/(3*log2)
            let z_l = cp_l * p_h + p_l * cp + dp_l
            // log2(ax) = (ss+..)*2/(3*log2) = n + dp_h + z_h + z_l
            t = Double(n)
            t1 = (((z_h + z_l) + dp_h) + t)
            t1 = setLo(t1, 0)
            t2 = z_l - (((t1 - t) - dp_h) - z_h)
        }

        // split up y into y1+y2 and compute (y1+y2)*(t1+t2)
        let y1 = setLo(y, 0)
        p_l = (y - y1) * t1 + y * t2
        p_h = y1 * t1
        z = p_l + p_h
        j = hi(z)
        i = lo(z)
        if j >= 0x40900000 {                 // z >= 1024
            if ((j - 0x40900000) | i) != 0 { // if z > 1024
                return s * huge * huge       // overflow
            } else {
                if p_l + ovt > z - p_h { return s * huge * huge } // overflow
            }
        } else if (j & 0x7fffffff) >= 0x4090cc00 { // z <= -1075
            if ((j &- Int32(bitPattern: 0xc090cc00)) | i) != 0 { // z < -1075
                return s * tiny * tiny       // underflow
            } else {
                if p_l <= z - p_h { return s * tiny * tiny } // underflow
            }
        }
        // compute 2**(p_h+p_l)
        i = j & 0x7fffffff
        k = (i &>> 20) - 0x3ff
        n = 0
        if i > 0x3fe00000 {                  // if |z| > 0.5, set n = [z+0.5]
            n = j &+ (0x00100000 &>> (k + 1))
            k = ((n & 0x7fffffff) &>> 20) - 0x3ff // new k for n
            t = make(n & ~(0x000fffff &>> k), 0)
            n = ((n & 0x000fffff) | 0x00100000) &>> (20 - k)
            if j < 0 { n = -n }
            p_h -= t
        }
        t = p_l + p_h
        t = setLo(t, 0)
        u = t * lg2_h
        v = (p_l - (t - p_h)) * lg2 + t * lg2_l
        z = u + v
        w = v - (z - u)
        t = z * z
        t1 = z - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))))
        r = (z * t1) / (t1 - two) - (w + z * w)
        z = one - (r - z)
        j = hi(z)
        j = j &+ (n &<< 20)
        if (j &>> 20) <= 0 {
            z = scalbn(z, n)                 // subnormal output
        } else {
            z = setHi(z, hi(z) &+ (n &<< 20))
        }
        return s * z
    }

    // MARK: - e_sinh.c, e_cosh.c, s_tanh.c

    /// sinh(x).
    public static func sinh(_ x: Double) -> Double {
        let one = 1.0
        let shuge = 1.0e307

        // High word of |x|.
        let jx = hi(x)
        let ix = jx & 0x7fffffff

        // x is INF or NaN
        if ix >= 0x7ff00000 { return x + x }

        var h = 0.5
        if jx < 0 { h = -h }
        // |x| in [0,22], return sign(x)*0.5*(E+E/(E+1)))
        if ix < 0x40360000 {                 // |x| < 22
            if ix < 0x3e300000 {             // |x| < 2**-28
                if shuge + x > one { return x } // sinh(tiny) = tiny with inexact
            }
            let t = expm1(x.magnitude)
            if ix < 0x3ff00000 { return h * (2.0 * t - t * t / (t + one)) }
            return h * (t + t / (t + one))
        }

        // |x| in [22, log(maxdouble)] return 0.5*exp(|x|)
        if ix < 0x40862E42 { return h * exp(x.magnitude) }

        // |x| in [log(maxdouble), overflowthresold]
        let lx = ulo(x)
        if ix < 0x408633CE || (ix == 0x408633ce && lx <= 0x8fb9f87d) {
            let w = exp(0.5 * x.magnitude)
            let t = h * w
            return t * w
        }

        // |x| > overflowthresold, sinh(x) overflow
        return x * shuge
    }

    /// cosh(x).
    public static func cosh(_ x: Double) -> Double {
        let one = 1.0
        let half = 0.5
        let huge = 1.0e300

        // High word of |x|.
        let ix = hi(x) & 0x7fffffff

        // x is INF or NaN
        if ix >= 0x7ff00000 { return x * x }

        // |x| in [0,0.5*ln2], return 1+expm1(|x|)^2/(2*exp(|x|))
        if ix < 0x3fd62e43 {
            let t = expm1(x.magnitude)
            let w = one + t
            if ix < 0x3c800000 { return w }  // cosh(tiny) = 1
            return one + (t * t) / (w + w)
        }

        // |x| in [0.5*ln2,22], return (exp(|x|)+1/exp(|x|)/2
        if ix < 0x40360000 {
            let t = exp(x.magnitude)
            return half * t + half / t
        }

        // |x| in [22, log(maxdouble)] return half*exp(|x|)
        if ix < 0x40862E42 { return half * exp(x.magnitude) }

        // |x| in [log(maxdouble), overflowthresold]
        let lx = ulo(x)
        if ix < 0x408633CE || (ix == 0x408633ce && lx <= 0x8fb9f87d) {
            let w = exp(half * x.magnitude)
            let t = half * w
            return t * w
        }

        // |x| > overflowthresold, cosh(x) overflow
        return huge * huge
    }

    /// tanh(x).
    public static func tanh(_ x: Double) -> Double {
        let one = 1.0
        let two = 2.0
        let tiny = 1.0e-300

        // High word of |x|.
        let jx = hi(x)
        let ix = jx & 0x7fffffff

        // x is INF or NaN
        if ix >= 0x7ff00000 {
            if jx >= 0 {
                return one / x + one         // tanh(+-inf) = +-1
            } else {
                return one / x - one         // tanh(NaN) = NaN
            }
        }

        let z: Double
        if ix < 0x40360000 {                 // |x| < 22
            if ix < 0x3c800000 {             // |x| < 2**-55
                return x * (one + x)         // tanh(small) = small
            }
            if ix >= 0x3ff00000 {            // |x| >= 1
                let t = expm1(two * x.magnitude)
                z = one - two / (t + two)
            } else {
                let t = expm1(-two * x.magnitude)
                z = -t / (t + two)
            }
        } else {                             // |x| > 22, return +-1
            z = one - tiny                   // raised inexact flag
        }
        return jx >= 0 ? z : -z
    }
}
