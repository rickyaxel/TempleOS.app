// GenVectors: writes vectors.txt, the expected java.lang.StrictMath results that
// FdLibmTests.swift checks the Swift fdlibm port (TempleCore/HolyC/FdLibm.swift)
// against, bit for bit.
//
// Run from this directory with JDK 17+ (single-file source launch):
//     java GenVectors.java [output-path]       (default: ./vectors.txt)
//
// Output: one case per line, all values as 16-digit lowercase hex IEEE-754
// bit patterns:
//     <func> <in> <out>              unary functions
//     <func> <in1> <in2> <out>       atan2(y, x) and pow(x, y)
// Lines starting with '#' are comments. Inputs are deterministic (a fixed
// SplitMix64 seed), so regenerating produces an identical file.
import java.io.IOException;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.function.DoubleBinaryOperator;
import java.util.function.DoubleUnaryOperator;

public class GenVectors {
    static final int UNARY_TARGET = 2200;
    static final int BINARY_TARGET = 3000;

    // ---- deterministic PRNG (SplitMix64) ----
    static long state = 0x7E3D_1E05_F00D_CAFEL;

    static long nextLong() {
        long z = (state += 0x9E3779B97F4A7C15L);
        z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
        z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
        return z ^ (z >>> 31);
    }

    static double unit() { // [0, 1)
        return (nextLong() >>> 11) * 0x1.0p-53;
    }

    static double uniform(double a, double b) {
        return a + (b - a) * unit();
    }

    static int randInt(int lo, int hiInclusive) {
        return lo + (int) Long.remainderUnsigned(nextLong(), (long) hiInclusive - lo + 1);
    }

    /** Random double with unbiased exponent in [emin, emax], random mantissa, random sign if signed. */
    static double randExp(int emin, int emax, boolean signed) {
        int e = randInt(emin, emax);
        long mant = nextLong() & 0x000F_FFFF_FFFF_FFFFL;
        long bits;
        if (e < -1022) { // subnormal range
            int shift = -1022 - e;
            bits = (mant | 0x0010_0000_0000_0000L) >>> Math.min(shift, 63);
            if (bits == 0) bits = 1;
        } else {
            bits = ((long) (e + 1023) << 52) | mant;
        }
        if (signed && (nextLong() & 1) != 0) bits |= 0x8000_0000_0000_0000L;
        return Double.longBitsToDouble(bits);
    }

    static double fromWords(int hi, int lo) {
        return Double.longBitsToDouble(((long) hi << 32) | (lo & 0xFFFF_FFFFL));
    }

    // ---- input set helpers ----
    static void near(LinkedHashSet<Long> s, double v, int ulps, boolean bothSigns) {
        double up = v, dn = v;
        add(s, v, bothSigns);
        for (int i = 0; i < ulps; i++) {
            up = Math.nextUp(up);
            dn = Math.nextDown(dn);
            add(s, up, bothSigns);
            add(s, dn, bothSigns);
        }
    }

    static void add(LinkedHashSet<Long> s, double v, boolean bothSigns) {
        s.add(Double.doubleToRawLongBits(v));
        if (bothSigns) s.add(Double.doubleToRawLongBits(-v));
    }

    /** Boundary of a high-word test: last value below and first value at/above hi word h. */
    static void hiBoundary(LinkedHashSet<Long> s, int h, boolean bothSigns) {
        add(s, fromWords(h, 0), bothSigns);
        add(s, fromWords(h, 1), bothSigns);
        add(s, fromWords(h - 1, -1), bothSigns);
        add(s, fromWords(h - 1, 0x8000_0000), bothSigns);
        add(s, fromWords(h, 0x7fff_ffff), bothSigns);
        add(s, fromWords(h + 1, 0), bothSigns);
    }

    static void common(LinkedHashSet<Long> s) {
        double[] v = {
            0.0, Double.POSITIVE_INFINITY, Double.NaN, Double.MIN_VALUE, Double.MIN_NORMAL,
            Double.MAX_VALUE, 1.0, 0.5, 2.0, 3.0, 10.0, 0.1, 1e-300, 1e300, 1e-310,
            0x1.0p-27, 0x1.0p-28, 0x1.0p-29, 0x1.0p-54, 0x1.0p-55, 0x1.0p-57, 0x1.0p-1022,
            0x0.fffffffffffffp-1022, 0x0.8p-1022, 0x0.0000000000002p-1022, 0x1.0p-1060,
            Math.PI, Math.E, 0x1.0p20, 0x1.0p52, 0x1.0p53, 0x1.0p63, 0x1.0p64, 0x1.0p66,
            0x1.0p1000, 0x1.0p1023,
        };
        for (double d : v) add(s, d, true);
        near(s, 1.0, 3, true);
        near(s, Double.MAX_VALUE, 0, true);
        add(s, Math.nextDown(Double.MAX_VALUE), true);
        add(s, Math.nextUp(Double.MIN_NORMAL), true);
        add(s, Math.nextDown(Double.MIN_NORMAL), true);
        s.add(0x7ff0_0000_0000_0001L);            // signalling-pattern NaN
        s.add(0xfff8_0000_0000_0000L);            // negative quiet NaN
        for (int i = 0; i < 20; i++) add(s, randExp(-1074, -1023, true), false); // subnormals
    }

    static void fillRandom(LinkedHashSet<Long> s, int target, Runnable... gens) {
        int g = 0;
        int guard = 0;
        while (s.size() < target && guard++ < target * 50) {
            gens[g++ % gens.length].run();
        }
    }

    // ---- per-function input sets ----
    static LinkedHashSet<Long> trigInputs() {
        LinkedHashSet<Long> s = new LinkedHashSet<>();
        common(s);
        // multiples of pi/4 and pi/2, with neighbours (reduction cancellation cases)
        for (int k = 1; k <= 80; k++) near(s, k * Math.PI / 4, 2, true);
        for (int k = 81; k <= 400; k += 7) near(s, k * Math.PI / 2, 1, true);
        for (int e = 10; e <= 70; e += 2) near(s, Math.rint(Math.scalb(1.0, e) / (Math.PI / 2)) * (Math.PI / 2), 1, true);
        // reduction thresholds (high words)
        int[] his = {0x3fe9_21fb, 0x3fe9_21fc, 0x4002_d97c, 0x3ff9_21fb, 0x4139_21fb, 0x4139_21fc,
                     0x3e40_0000, 0x3e30_0000, 0x3fd3_3333, 0x3fe9_0000, 0x3fe5_9428};
        for (int h : his) hiBoundary(s, h, true);
        // npio2_hw table entries (n*pi/2 for n < 32)
        for (int n = 1; n <= 32; n++) near(s, n * (Math.PI / 2), 3, true);
        // huge arguments (large reduction path)
        double[] huge = {1e22, 1e300, 1e308, 0x1.0p1023, 0x1.0p1000, 0x1.0p200, 1e15, 1e19, 0x1.0p60,
                         6.5e5, 1.0e6, 2.1e9, 3.5e17, 8.9e100, 7.6e250};
        for (double d : huge) near(s, d, 2, true);
        // well-known hard case for argument reduction (closest double to a multiple of pi/2)
        near(s, Double.longBitsToDouble(0x6b9e_aeb5_ee72_c6f3L), 1, true);
        near(s, Double.longBitsToDouble(0x5e7f_4ee1_3d70_cc8eL), 1, true);
        near(s, 6381956970095103.0 * 0x1.0p797, 1, true);
        fillRandom(s, UNARY_TARGET,
            () -> add(s, uniform(-10, 10), false),
            () -> add(s, randExp(-30, 30, true), false),
            () -> add(s, randExp(-60, 1023, true), false),
            () -> add(s, randExp(18, 21, true), false),
            () -> add(s, randExp(-1074, 1023, true), false));
        return s;
    }

    static LinkedHashSet<Long> asinAcosInputs() {
        LinkedHashSet<Long> s = new LinkedHashSet<>();
        common(s);
        near(s, 1.0, 8, true);
        near(s, 0.5, 4, true);
        near(s, 0.975, 4, true);
        int[] his = {0x3ff0_0000, 0x3fe0_0000, 0x3e40_0000, 0x3fef_3333, 0x3c60_0000};
        for (int h : his) hiBoundary(s, h, true);
        fillRandom(s, UNARY_TARGET,
            () -> add(s, uniform(-1, 1), false),
            () -> add(s, uniform(0.5, 1) * ((nextLong() & 1) == 0 ? 1 : -1), false),
            () -> add(s, randExp(-60, -1, true), false),
            () -> add(s, randExp(-1074, 1023, true), false));
        return s;
    }

    static LinkedHashSet<Long> atanInputs() {
        LinkedHashSet<Long> s = new LinkedHashSet<>();
        common(s);
        double[] b = {7.0 / 16, 11.0 / 16, 19.0 / 16, 39.0 / 16, 0x1.0p66, 0x1.0p-29};
        for (double d : b) near(s, d, 3, true);
        int[] his = {0x4410_0000, 0x3fdc_0000, 0x3e20_0000, 0x3ff3_0000, 0x3fe6_0000, 0x4003_8000};
        for (int h : his) hiBoundary(s, h, true);
        fillRandom(s, UNARY_TARGET,
            () -> add(s, uniform(-3, 3), false),
            () -> add(s, randExp(-35, 70, true), false),
            () -> add(s, randExp(-1074, 1023, true), false));
        return s;
    }

    static LinkedHashSet<Long> hyperInputs() {
        LinkedHashSet<Long> s = new LinkedHashSet<>();
        common(s);
        double[] b = {22.0, 1.0, 0.5 * Math.log(2), Math.log(2), 709.782712893384, 710.4758600739439,
                      Double.longBitsToDouble(0x4086_33ce_8fb9_f87dL), 20.0, 0x1.0p-28, 0x1.0p-55};
        for (double d : b) near(s, d, 3, true);
        int[] his = {0x4036_0000, 0x3e30_0000, 0x3ff0_0000, 0x4086_2E42, 0x4086_33CE, 0x3fd6_2e43,
                     0x3c80_0000, 0x7ff0_0000};
        for (int h : his) hiBoundary(s, h, true);
        add(s, fromWords(0x4086_33ce, 0x8fb9_f87e), true);
        fillRandom(s, UNARY_TARGET,
            () -> add(s, uniform(-25, 25), false),
            () -> add(s, uniform(-712, 712), false),
            () -> add(s, randExp(-60, 10, true), false),
            () -> add(s, randExp(-1074, 1023, true), false));
        return s;
    }

    static LinkedHashSet<Long> expInputs() {
        LinkedHashSet<Long> s = new LinkedHashSet<>();
        common(s);
        double oT = Double.longBitsToDouble(0x4086_2e42_fefa_39efL);
        double uT = -Double.longBitsToDouble(0x4087_4910_d52d_3051L);
        near(s, oT, 6, false);
        near(s, uT, 6, false);
        near(s, -708.3964185322641, 4, false); // smallest normal result
        near(s, -1021 * Math.log(2), 4, false);
        near(s, -1022 * Math.log(2), 4, false);
        near(s, -745.1332191019411, 4, false);
        near(s, 0.5 * Math.log(2), 3, true);
        near(s, 1.5 * Math.log(2), 3, true);
        near(s, 56 * Math.log(2), 3, true);
        for (int k = -1080; k <= 1030; k += 13) near(s, k * Math.log(2), 1, false);
        int[] his = {0x4086_2E42, 0x3fd6_2e42, 0x3FF0_A2B2, 0x3e30_0000, 0x4043_687A, 0x3c90_0000};
        for (int h : his) hiBoundary(s, h, true);
        for (int k = 1; k <= 60; k++) near(s, k * Math.log(2), 1, true);
        fillRandom(s, UNARY_TARGET,
            () -> add(s, uniform(-746, 710), false),
            () -> add(s, uniform(-40, 40), false),
            () -> add(s, randExp(-60, 3, true), false),
            () -> add(s, randExp(-1074, 1023, true), false));
        return s;
    }

    static LinkedHashSet<Long> logInputs(boolean log1p) {
        LinkedHashSet<Long> s = new LinkedHashSet<>();
        common(s);
        near(s, 1.0, 10, false);
        for (int e = -1074; e <= 1023; e += 7) near(s, Math.scalb(1.0, e), 1, false);
        for (int n = -323; n <= 308; n += 3) near(s, Double.parseDouble("1e" + n), 1, false);
        for (int n = 0; n <= 22; n++) add(s, Double.parseDouble("1e" + n), false);
        for (int i = 1; i <= 40; i++) {
            add(s, 1.0 + i * 0x1.0p-21, true);
            add(s, 1.0 - i * 0x1.0p-22, true);
        }
        if (log1p) {
            near(s, -1.0, 6, false);
            double[] b = {0.41421356237309503, -0.2928932188134524, 0x1.0p-29, 0x1.0p-54, 0x1.0p53};
            for (double d : b) near(s, d, 3, true);
            int[] his = {0x3FDA_827A, 0x3ff0_0000, 0x3e20_0000, 0x3c90_0000, 0x4340_0000, 0xbfd2_bec3,
                         0xbfd2_bec4, 0x3fe6_a09e};
            for (int h : his) hiBoundary(s, h, false);
        }
        int[] his = {0x0010_0000, 0x3ff0_0000, 0x3fe6_a09e, 0x3ff6_a09e, 0x3ff6_147a, 0x3ff6_b851};
        for (int h : his) hiBoundary(s, h, false);
        fillRandom(s, UNARY_TARGET,
            () -> add(s, randExp(-1074, 1023, false), false),
            () -> add(s, uniform(0.5, 2.0), false),
            () -> add(s, log1p ? uniform(-1, 1) : uniform(0, 10), false),
            () -> add(s, randExp(-60, 60, log1p), false));
        return s;
    }

    // ---- binary inputs ----
    record Pair(long a, long b) {}

    static void addPair(LinkedHashSet<Pair> s, double a, double b) {
        s.add(new Pair(Double.doubleToRawLongBits(a), Double.doubleToRawLongBits(b)));
    }

    static LinkedHashSet<Pair> powInputs() {
        LinkedHashSet<Pair> s = new LinkedHashSet<>();
        double[] xs = {0.0, -0.0, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NaN,
            1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, -3.0, Double.MIN_VALUE, -Double.MIN_VALUE,
            Double.MAX_VALUE, -Double.MAX_VALUE, Math.nextUp(1.0), Math.nextDown(1.0),
            -Math.nextUp(1.0), -Math.nextDown(1.0), 10.0, -10.0, 1e-300, Math.E, 0.1,
            Double.MIN_NORMAL, 0x0.8p-1022};
        double[] ys = {0.0, -0.0, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NaN,
            1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, -3.0, 0x1.0p53 - 1, -(0x1.0p53 - 1), 0x1.0p53,
            -0x1.0p53, 0x1.0p53 + 2, 1e300, -1e300, 0.3, -0.3, 1.5, -1.5, 0x1.0p31, 0x1.0p31 + 1,
            -0x1.0p31 - 1, Double.MIN_VALUE, Double.MAX_VALUE, -Double.MAX_VALUE, 1023, 1024, 1074,
            1075, -1074, -1075, 0x1.00000ffffffffp31, 0x1.000010p31, 0.25, 4.0, 7.0, -7.0};
        for (double x : xs) for (double y : ys) addPair(s, x, y);
        // negative bases with integer exponents (odd / even) and non-integers
        for (int i = 0; i < 300; i++) {
            double x = -uniform(0.01, 12);
            addPair(s, x, randInt(-300, 300));
            addPair(s, x, randInt(-300, 300) + 0.5);
        }
        for (int i = 0; i < 60; i++) addPair(s, -uniform(0.5, 2), (double) (nextLong() >>> 12) * (1 - 2 * (i & 1)));
        // x close to 1 with huge |y| (the |y| > 2^31 path)
        for (int i = 0; i < 200; i++) {
            double x = 1.0 + randInt(-2000, 2000) * 0x1.0p-32;
            double y = randExp(31, 62, true);
            addPair(s, x, y);
            addPair(s, -x, Math.rint(y));
        }
        double[] xb = {0x1.fffff00000000p-1, 0x1.00000ffffffffp0};
        for (double x : xb) for (int d = -2; d <= 2; d++) {
            double xx = x;
            for (int k = 0; k < Math.abs(d); k++) xx = d < 0 ? Math.nextDown(xx) : Math.nextUp(xx);
            addPair(s, xx, 0x1.0p40);
            addPair(s, xx, -0x1.0p40);
        }
        // overflow / underflow thresholds
        double[] bases = {2.0, 3.0, 10.0, Math.E, 1.5, 0.5, 0.1, 7.0, 1.0001, 0.9999, 123.456, 0.75};
        for (double x : bases) {
            double l2 = Math.log(x) / Math.log(2);
            double[] targets = {1024, 1023.5, -1022, -1074, -1075, -1074.5, -1060, -1050.25};
            for (double tgt : targets) {
                double y0 = tgt / l2;
                double y = y0;
                for (int k = 0; k < 6; k++) { addPair(s, x, y); y = Math.nextUp(y); }
                y = y0;
                for (int k = 0; k < 6; k++) { y = Math.nextDown(y); addPair(s, x, y); }
                addPair(s, x, y0 * (1 + 1e-12));
                addPair(s, x, y0 * (1 - 1e-12));
            }
        }
        for (int e = -1076; e <= -1060; e++) { addPair(s, 2.0, e); addPair(s, 2.0, e + 0.5); addPair(s, -2.0, e); }
        addPair(s, 2.0, 1023); addPair(s, 2.0, Math.nextDown(1024.0)); addPair(s, -2.0, 1023);
        // subnormal results: e_pow.c's final scalbn must round exactly once
        // (regression cases where a double-rounding scalbn gets the last bit wrong)
        long[][] subn = {{0xc0190dfe0e8c0f1aL, 0xc078300000000000L}, {0x58d9c7aeab58ebfaL, 0xc0048de64ba02f52L},
                         {0xc02070ee35a936ecL, 0xc075400000000000L}};
        for (long[] p : subn) addPair(s, Double.longBitsToDouble(p[0]), Double.longBitsToDouble(p[1]));
        for (int i = 0; i < 500; i++) {
            double x = uniform(0.01, 100);
            double y = uniform(-1074.5, -1021) / (Math.log(x) / Math.log(2));
            addPair(s, x, y);
            if ((i & 3) == 0) addPair(s, -x, Math.rint(y));
        }
        // subnormal bases
        for (int i = 0; i < 60; i++) {
            double x = randExp(-1074, -1023, false);
            addPair(s, x, uniform(-1.05, 1.05));
            addPair(s, x, uniform(0, 0.02));
        }
        while (s.size() < BINARY_TARGET) {
            switch (s.size() % 5) {
                case 0 -> addPair(s, uniform(0, 4), uniform(-50, 50));
                case 1 -> {
                    double x = randExp(-1074, 1023, false);
                    double l2 = Math.abs(Math.log(x) / Math.log(2));
                    addPair(s, x, uniform(-1.15, 1.15) * 1100 / Math.max(l2, 1e-3));
                }
                case 2 -> addPair(s, -uniform(0, 20), randInt(-200, 200));
                case 3 -> addPair(s, randExp(-1074, 1023, true), randExp(-20, 12, true));
                default -> addPair(s, uniform(0.9, 1.1), randExp(-10, 30, true));
            }
        }
        return s;
    }

    static LinkedHashSet<Pair> atan2Inputs() {
        LinkedHashSet<Pair> s = new LinkedHashSet<>();
        double[] v = {0.0, -0.0, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NaN,
            1.0, -1.0, 2.0, -2.0, 0.5, -0.5, Double.MIN_VALUE, -Double.MIN_VALUE, Double.MAX_VALUE,
            -Double.MAX_VALUE, Math.PI, -Math.PI, 1e-300, -1e300, Math.nextUp(1.0), Math.nextDown(1.0)};
        for (double y : v) for (double x : v) addPair(s, y, x);
        // x == 1.0 exactly
        for (int i = 0; i < 100; i++) addPair(s, randExp(-40, 70, true), 1.0);
        // |y/x| around the 2^60 decisions
        for (int i = 0; i < 400; i++) {
            double x = randExp(-300, 300, true);
            int d = randInt(55, 65) * ((i & 1) == 0 ? 1 : -1);
            double y = Math.scalb(uniform(1, 2), Math.getExponent(x) + d) * ((nextLong() & 1) == 0 ? 1 : -1);
            addPair(s, y, x);
        }
        while (s.size() < BINARY_TARGET) {
            switch (s.size() % 4) {
                case 0 -> addPair(s, uniform(-10, 10), uniform(-10, 10));
                case 1 -> addPair(s, randExp(-30, 30, true), randExp(-30, 30, true));
                case 2 -> addPair(s, randExp(-1074, 1023, true), randExp(-1074, 1023, true));
                default -> {
                    double x = randExp(-100, 100, true);
                    addPair(s, Math.scalb(uniform(1, 2), Math.getExponent(x) + randInt(-70, 70))
                            * ((nextLong() & 1) == 0 ? 1 : -1), x);
                }
            }
        }
        return s;
    }

    // ---- output ----
    static String hex(double d) {
        return String.format(Locale.ROOT, "%016x", Double.doubleToRawLongBits(d));
    }

    static void unary(PrintWriter w, String name, LinkedHashSet<Long> in, DoubleUnaryOperator f) {
        for (long b : in) {
            double x = Double.longBitsToDouble(b);
            w.print(name); w.print(' '); w.print(hex(x)); w.print(' '); w.println(hex(f.applyAsDouble(x)));
        }
    }

    static void binary(PrintWriter w, String name, LinkedHashSet<Pair> in, DoubleBinaryOperator f) {
        for (Pair p : in) {
            double a = Double.longBitsToDouble(p.a()), b = Double.longBitsToDouble(p.b());
            w.print(name); w.print(' '); w.print(hex(a)); w.print(' '); w.print(hex(b)); w.print(' ');
            w.println(hex(f.applyAsDouble(a, b)));
        }
    }

    public static void main(String[] args) throws IOException {
        Path out = Path.of(args.length > 0 ? args[0] : "vectors.txt");
        List<String> counts = new ArrayList<>();
        try (PrintWriter w = new PrintWriter(Files.newBufferedWriter(out, StandardCharsets.US_ASCII))) {
            w.println("# java.lang.StrictMath vectors generated by GenVectors.java on "
                      + System.getProperty("java.vm.name") + " " + System.getProperty("java.runtime.version"));
            w.println("# format: func in [in2] out  (IEEE-754 bit patterns in hex; atan2 y x; pow x y)");
            LinkedHashSet<Long> trig = trigInputs();
            unary(w, "sin", trig, StrictMath::sin);
            unary(w, "cos", trig, StrictMath::cos);
            unary(w, "tan", trig, StrictMath::tan);
            counts.add("sin/cos/tan " + trig.size());
            LinkedHashSet<Long> as = asinAcosInputs();
            unary(w, "asin", as, StrictMath::asin);
            unary(w, "acos", as, StrictMath::acos);
            counts.add("asin/acos " + as.size());
            LinkedHashSet<Long> at = atanInputs();
            unary(w, "atan", at, StrictMath::atan);
            counts.add("atan " + at.size());
            LinkedHashSet<Long> hy = hyperInputs();
            unary(w, "sinh", hy, StrictMath::sinh);
            unary(w, "cosh", hy, StrictMath::cosh);
            unary(w, "tanh", hy, StrictMath::tanh);
            counts.add("sinh/cosh/tanh " + hy.size());
            LinkedHashSet<Long> ex = expInputs();
            unary(w, "exp", ex, StrictMath::exp);
            unary(w, "expm1", ex, StrictMath::expm1);
            counts.add("exp/expm1 " + ex.size());
            LinkedHashSet<Long> lg = logInputs(false);
            unary(w, "log", lg, StrictMath::log);
            unary(w, "log10", lg, StrictMath::log10);
            counts.add("log/log10 " + lg.size());
            LinkedHashSet<Long> l1 = logInputs(true);
            unary(w, "log1p", l1, StrictMath::log1p);
            counts.add("log1p " + l1.size());
            LinkedHashSet<Pair> a2 = atan2Inputs();
            binary(w, "atan2", a2, StrictMath::atan2);
            counts.add("atan2 " + a2.size());
            LinkedHashSet<Pair> pw = powInputs();
            binary(w, "pow", pw, StrictMath::pow);
            counts.add("pow " + pw.size());
        }
        System.out.println("wrote " + out.toAbsolutePath() + " (" + Files.size(out) + " bytes): " + counts);
    }
}
