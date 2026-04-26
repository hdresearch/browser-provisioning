plugins {
    kotlin("jvm") version "2.1.0"
    application
}

application {
    mainClass.set("com.vers.examples.MainKt")
}

repositories {
    mavenCentral()
    mavenLocal()
}

dependencies {
    // Use the Java SDK (installed to mavenLocal from sterling/generated/java)
    implementation("com.vers:vers-sdk:0.1.7")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.17.0")
}
