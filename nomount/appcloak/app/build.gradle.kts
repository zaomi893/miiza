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
        minSdk = 31
        targetSdk = 36
        versionCode = 10604
        versionName = "1.6.4"
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
