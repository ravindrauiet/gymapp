allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some plugins (e.g. android_play_install_referrer) still compile against old SDKs, which current AndroidX
// libraries reject. Raise any plugin below API 36 to 36; this only affects compilation, not minSdk/targetSdk.
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") as? com.android.build.gradle.LibraryExtension
        if (android != null && (android.compileSdk ?: 0) < 36) android.compileSdk = 36
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
