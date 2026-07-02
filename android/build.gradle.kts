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

// Force every Android module (app + plugins) to the locally-installed NDK.
// Plugins default to Flutter's NDK (28.2.x) which isn't fully downloaded here;
// 27.1.x is installed and builds them fine, avoiding a ~1GB NDK download.
// Registered BEFORE evaluationDependsOn below so the hook runs after each
// module evaluates (not "already evaluated").
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            runCatching {
                ext.javaClass
                    .getMethod("setNdkVersion", String::class.java)
                    .invoke(ext, "27.1.12297006")
            }
            // Some plugins (e.g. clipboard_watcher) compile against SDK 33, but
            // their androidx deps require 34+. Force all modules to the
            // installed SDK 36.
            runCatching {
                ext.javaClass
                    .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(ext, 36)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
