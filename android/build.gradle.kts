// ---------------------- Buildscript ----------------------
buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        // Gradle plugin Android
        classpath("com.android.tools.build:gradle:8.1.1")
        // Google Services plugin (bắt buộc cho Firebase)
        classpath("com.google.gms:google-services:4.4.2")
    }
}

// ---------------------- All Projects ----------------------
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ---------------------- Custom Build Directory ----------------------
val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// ---------------------- Subprojects ----------------------
subprojects {
    project.evaluationDependsOn(":app")
}

// ---------------------- Clean Task ----------------------
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
