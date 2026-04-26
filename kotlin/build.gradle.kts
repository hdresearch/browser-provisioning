plugins {
    kotlin("jvm") version "2.1.0"
    application
}

application {
    mainClass.set("com.vers.examples.MainKt")
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("com.vers.sdk:vers-sdk:0.1.7")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
}
