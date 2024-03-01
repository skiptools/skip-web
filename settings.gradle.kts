
pluginManagement {
    // create transpiled Kotlin and generate Gradle projects from SwiftPM modules
    exec { commandLine("swift", "build") }
}

includeBuild(".build/plugins/outputs/skip-web/SkipWeb/skipstone/")

