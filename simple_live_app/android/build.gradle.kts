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
