// browser-provisioning / Scala — vers-sdk (sbt local) + vers CLI + puppeteer-core (inside VM)
// VERS_API_KEY must be set. `vers` CLI must be on PATH.

import sh.vers.sdk.Client
import scala.collection.mutable
import scala.io.Source
import scala.util.Try

object Main:
  private val activeVms = mutable.Set[String]()
  private lazy val client = Client()

  private def cleanup(): Unit =
    for vm <- activeVms.toList do
      Try { System.err.println(s"[cleanup] Deleting VM $vm..."); client.deleteVm(vm) }
    activeVms.clear()

  private def versExec(vmId: String, script: String, timeout: Int = 600): String =
    val cmd = Seq("bash", "-c", s"cat <<'EOFSCRIPT' | vers exec -i -t $timeout $vmId bash\n$script\nEOFSCRIPT")
    val out = new StringBuilder
    scala.sys.process.Process(cmd).!(scala.sys.process.ProcessLogger(out.append(_).append('\n'), _ => ()))
    out.toString

  private def versWait(vmId: String): Unit =
    for _ <- 0 until 40 do
      if Try(versExec(vmId, "echo ready", 10)).toOption.exists(_.contains("ready")) then return
      Thread.sleep(3000)
    throw new RuntimeException(s"VM $vmId not ready")

  def main(args: Array[String]): Unit =
    Runtime.getRuntime.addShutdownHook(new Thread(() => cleanup()))
    try
      println("=== [Scala] Building golden image ===\n")

      println("[1/4] Creating root VM...")
      val root = client.createNewRootVm(
        ujson.Obj("vm_config" -> ujson.Obj("vcpu_count" -> 2, "mem_size_mib" -> 4096,
          "fs_size_mib" -> 8192, "kernel_name" -> "default.bin", "image_name" -> "default")),
        wait_boot = Some(true))
      val buildVm = root("vm_id").str
      activeVms += buildVm
      println(s"  VM: $buildVm")

      println("[2/4] Waiting for VM..."); versWait(buildVm)
      println("[3/4] Installing Chromium...")
      versExec(buildVm, Source.fromFile("../install.sh").mkString)

      println("[4/4] Committing...")
      val commitId = client.commitVm(buildVm, ujson.Obj())("commit_id").str
      println(s"  Commit: $commitId")
      client.deleteVm(buildVm); activeVms -= buildVm
      println("  Build VM deleted\n")

      println("=== Branching from commit & scraping ===\n")
      println("[1/3] Branching...")
      val vmId = client.branchByCommit(commitId, ujson.Obj())("vms")(0)("vm_id").str
      activeVms += vmId
      println(s"  VM: $vmId")

      println("[2/3] Waiting for VM..."); versWait(vmId)
      println("[3/3] Scraping...\n")
      val output = versExec(vmId, Source.fromFile("../scrape.sh").mkString, 120)
      for line <- output.trim.split('\n') if line.startsWith("{") do
        val d = ujson.read(line)
        println(s"Title: ${d("title").str}")
        val links = d("links").arr
        println(s"Links (${links.length}):")
        for l <- links do println(s"  ${l("text").str} → ${l("href").str}")

      client.deleteVm(vmId); activeVms -= vmId
      println(s"\nVM $vmId deleted. Done.")
    catch case e: Throwable =>
      System.err.println(s"Fatal: $e"); cleanup(); sys.exit(1)
