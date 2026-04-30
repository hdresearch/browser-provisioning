ThisBuild / scalaVersion := "3.4.2"

lazy val root = (project in file("."))
  .settings(
    name := "browser-provisioning-scala",
    libraryDependencies ++= Seq(
      "sh.vers" %% "vers-sdk" % "0.1.8",
      "com.lihaoyi" %% "upickle" % "4.0.2"
    ),
    Compile / mainClass := Some("Main")
  )
