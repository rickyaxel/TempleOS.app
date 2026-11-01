# The app uses no reflection; default optimization rules are sufficient.

# Kotlin's parameter null checks (Intrinsics.checkNotNullParameter) guard calls from Java code; every
# caller here is Kotlin, and on ART the calls cost about 3% of a native program's time (simpleperf on the
# OPPO, docs/native-validation). Explicit `!!` checks (checkNotNull) are kept.
-assumenosideeffects class kotlin.jvm.internal.Intrinsics {
    public static void checkNotNullParameter(java.lang.Object, java.lang.String);
    public static void checkParameterIsNotNull(java.lang.Object, java.lang.String);
    public static void checkNotNullExpressionValue(java.lang.Object, java.lang.String);
    public static void checkExpressionValueIsNotNull(java.lang.Object, java.lang.String);
}
