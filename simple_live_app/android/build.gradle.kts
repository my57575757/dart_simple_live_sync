allprojects {
    repositories {
        maven {
            url = uri(rootProject.projectDir.parentFile.resolve(".gradle-local-maven"))
        }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
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
    val rootPath = rootProject.projectDir.toPath().root
    val projectPath = project.projectDir.toPath().root
    if (rootPath == projectPath) {
        val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
        project.layout.buildDirectory.value(newSubprojectBuildDir)
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    if (name == "wasm_run_flutter") {
        afterEvaluate {
            extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
                // 插件固定 NDK 21.4 / minSdk 16 / compileSdk 31，但其 CMake 工程为空；
                // 无条件对齐本机已装组件（compileSdk 35 / minSdk 21），避免 AGP
                // 联网下载 platform-31、NDK 21.4（离线环境拉不到）。NDK 仅在能取到
                // app 的 Flutter NDK 版本时对齐，取不到也不阻断 compileSdk 修正。
                compileSdk = 35
                defaultConfig.minSdk = 21
                val appNdkVersion = rootProject.project(":app")
                    .extensions.findByType(com.android.build.gradle.BaseExtension::class.java)
                    ?.ndkVersion
                if (!appNdkVersion.isNullOrBlank()) {
                    ndkVersion = appNdkVersion
                }
            }
        }
    }
}

// 消除 “Java vs Kotlin JVM target 不一致” 编译失败：不动各模块已固化的
// Java 目标，只把 Kotlin jvmTarget 对齐到该模块的 Java 目标
subprojects {
    // 用延迟 Provider：KotlinCompile 执行时（所有配置已固化）才读该模块的
    // Java target，把 Kotlin jvmTarget 对齐到它，消除 Java/Kotlin 不一致
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
        val proj = this@subprojects
        compilerOptions.jvmTarget.set(
            proj.provider {
                val javaTarget = proj.extensions
                    .findByType(com.android.build.gradle.BaseExtension::class.java)
                    ?.compileOptions?.targetCompatibility
                if (javaTarget != null) {
                    val major = javaTarget.majorVersion
                    // Kotlin 只认 "1.8"，不认 Java 9+ 风格的 "8"
                    if (major == "8") {
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
                    } else {
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(major)
                    }
                } else {
                    org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
                }
            }
        )
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
