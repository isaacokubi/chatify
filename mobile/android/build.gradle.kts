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
// A few older Flutter plugins pin their Android library compile SDK below the
// API required by newer Flutter plugins. Align library modules with the app's
// compile SDK without changing their minSdk or targetSdk behavior.
subprojects {
    afterEvaluate {
        if (name != "app") {
            val androidExtension = extensions.findByName("android") ?: return@afterEvaluate
            val setter = androidExtension.javaClass.methods.firstOrNull { method ->
                method.name == "setCompileSdkVersion" &&
                    method.parameterCount == 1 &&
                    method.parameterTypes[0] == Int::class.javaPrimitiveType
            }
            setter?.invoke(androidExtension, 36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
