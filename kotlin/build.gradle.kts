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
    implementation("com.github.mwiede:jsch:0.2.21")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("io.ktor:ktor-client-cio:3.0.3")
    implementation("io.ktor:ktor-client-websockets:3.0.3")
}
