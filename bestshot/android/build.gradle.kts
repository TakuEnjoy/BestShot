allprojects {
    repositories {
        google()
        mavenCentral()
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
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
subprojects {
    project.evaluationDependsOn(":app")
}
subprojects {
    val configureSdk: () -> Unit = {
        val android = project.extensions.findByName("android")
        if (android != null) {
            for (method in android.javaClass.methods) {
                if ((method.name == "compileSdkVersion" || method.name == "setCompileSdk" || method.name == "setCompileSdkVersion") &&
                    method.parameterCount == 1 &&
                    (method.parameterTypes[0] == Int::class.javaPrimitiveType || method.parameterTypes[0] == java.lang.Integer::class.java)
                ) {
                    try {
                        method.invoke(android, 36)
                        println("[AGP 9] Updated compileSdk to 36 for " + project.name)
                        break
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }
    if (project.state.executed) {
        configureSdk()
    } else {
        project.afterEvaluate {
            configureSdk()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
