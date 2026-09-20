import com.v7878.zygisk.gradle.ZygoteLoader

plugins {
    id("com.android.application")
    id("com.github.aerath-stuff.ZygoteLoader")
}

android {
    namespace = "io.github.cvhhji.nomount.appcloak"
    compileSdk = 36
    defaultConfig {
        applicationId = namespace
        // AppCloak is injected only into the Android 16 system_server. Keeping
        // the real platform level prevents D8 from rewriting java.lang.Record
        // references in DexFile to its build-time-only R8 RecordTag marker.
        minSdk = 36
        targetSdk = 36
        versionCode = 10708
        versionName = "1.7.8"
    }
}

zygisk {
    packages(ZygoteLoader.PACKAGE_SYSTEM_SERVER)
    id = "nomount_appcloak"
    name = "NoMount AppCloak"
    author = "cvhhji"
    description = "NoMount-owned package visibility filter"
    entrypoint = "io.github.cvhhji.nomount.appcloak.EntryPoint"
    archiveName = "NoMount-AppCloak"
    updateJson = ""
    isAddVariantToArchiveName = true
}

dependencies {
    implementation("com.github.aerath-stuff:AndroidVMTools:c1da5dd")
    implementation("io.github.vova7878:R8Annotations:v1.0.1")
}
