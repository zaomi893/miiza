package com.android.tools.r8;

/**
 * Compatibility marker expected by record-desugared AndroidVMTools bytecode.
 *
 * Android 16 provides java.lang.Record, but the prebuilt dependency still
 * carries one class-literal reference to R8's intermediate RecordTag name.
 * No methods or state are required; the type only needs to resolve while the
 * VMTools hook runtime initializes inside system_server.
 */
public abstract class RecordTag {
    private RecordTag() {}
}
