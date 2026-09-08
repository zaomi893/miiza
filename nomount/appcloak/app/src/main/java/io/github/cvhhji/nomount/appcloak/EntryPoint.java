package io.github.cvhhji.nomount.appcloak;

import com.v7878.r8.annotations.DoNotObfuscate;
import com.v7878.r8.annotations.DoNotObfuscateType;
import com.v7878.r8.annotations.DoNotShrink;
import com.v7878.r8.annotations.DoNotShrinkType;

@DoNotObfuscateType
@DoNotShrinkType
public final class EntryPoint {
    private EntryPoint() {}

    @DoNotObfuscate @DoNotShrink
    public static void premain() {}

    @DoNotObfuscate @DoNotShrink
    public static void main() {
        AppCloak.start();
    }
}
