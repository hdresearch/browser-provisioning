/// browser-provisioning / Dart — vers_sdk (git) + vers CLI + puppeteer-core (inside VM)
/// VERS_API_KEY must be set. `vers` CLI must be on PATH.
import 'dart:convert';
import 'dart:io';
import 'package:vers_sdk/client.dart';

final activeVms = <String>{};
late final VersSdkClient client;

void cleanup() {
  for (final vm in activeVms.toList()) {
    try { stderr.writeln('[cleanup] Deleting VM $vm...'); client.deleteVm(vm, null); } catch (_) {}
  }
}

String versExec(String vmId, String script, {int timeout = 600}) =>
    (Process.runSync('bash', ['-c', 'cat <<\'EOFSCRIPT\' | vers exec -i -t $timeout $vmId bash\n$script\nEOFSCRIPT'])
        .stdout as String);

void versWait(String vmId) {
  for (var i = 0; i < 40; i++) {
    try { if (versExec(vmId, 'echo ready', timeout: 10).contains('ready')) return; } catch (_) {}
    sleep(Duration(seconds: 3));
  }
  throw Exception('VM $vmId not ready');
}

Future<void> main() async {
  client = VersSdkClient();
  ProcessSignal.sigint.watch().listen((_) { cleanup(); exit(1); });
  ProcessSignal.sigterm.watch().listen((_) { cleanup(); exit(1); });

  try {
    print('=== [Dart] Building golden image ===\n');
    print('[1/4] Creating root VM...');
    final root = await client.createNewRootVm({
      'vm_config': {'vcpu_count': 2, 'mem_size_mib': 4096, 'fs_size_mib': 8192,
        'kernel_name': 'default.bin', 'image_name': 'default'},
    }, true);
    final buildVm = root['vm_id'] as String;
    activeVms.add(buildVm);
    print('  VM: $buildVm');

    print('[2/4] Waiting for VM...'); versWait(buildVm);
    print('[3/4] Installing Chromium...');
    versExec(buildVm, File('../install.sh').readAsStringSync());

    print('[4/4] Committing...');
    final commitId = (await client.commitVm(buildVm, {}, null, null))['commit_id'] as String;
    print('  Commit: $commitId');
    await client.deleteVm(buildVm, null); activeVms.remove(buildVm);
    print('  Build VM deleted\n');

    print('=== Branching from commit & scraping ===\n');
    print('[1/3] Branching...');
    final branch = await client.branchByCommit(commitId, {}, null);
    final vmId = (branch['vms'] as List).first['vm_id'] as String;
    activeVms.add(vmId);
    print('  VM: $vmId');

    print('[2/3] Waiting for VM...'); versWait(vmId);
    print('[3/3] Scraping...\n');
    final output = versExec(vmId, File('../scrape.sh').readAsStringSync(), timeout: 120);
    for (final line in output.trim().split('\n')) {
      if (line.startsWith('{')) {
        final d = jsonDecode(line) as Map<String, dynamic>;
        print('Title: ${d['title']}');
        print('Links (${(d['links'] as List).length}):');
        for (final l in d['links'] as List) print('  ${l['text']} → ${l['href']}');
        break;
      }
    }

    await client.deleteVm(vmId, null); activeVms.remove(vmId);
    print('\nVM $vmId deleted. Done.');
  } catch (e) { stderr.writeln('Fatal: $e'); cleanup(); exit(1); }
  finally { client.close(); }
}
