
tasks {
    //val clean by getting {
        //gradle.includedBuilds.forEach { this.dependsOn(it.task(":cleanAll")) }
    //}

    val build by getting {
        gradle.includedBuilds.forEach { this.dependsOn(it.task(":buildAll")) }
    }
}

