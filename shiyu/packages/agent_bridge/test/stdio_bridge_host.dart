import 'dart:convert';
import 'dart:io';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:agent_bridge/src/private_descriptor.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

/// Controlled App-owner authority for an independent compiled proxy process.
/// No model/CLI account, native window, audio, real material or Codex config.
Future<void> main(List<String> args)async{
  if(args.length!=3){exitCode=2;return;}
  final plan=File(args[0]),receipt=File(args[1]);
  final root=await Directory.systemTemp.createTemp('shiyu-stdio-authority-');
  LearningRootLock? lock;FileMaterialStore? materials;FileLearningStore? learning;
  AgentBridgeController? bridge;AgentBridgeClient? sourceClient;
  try{
    lock=await LearningRootLock.acquire(root);
    materials=await FileMaterialStore.open(root:Directory('${root.path}/materials'),trustedOwnerId:'controlled-owner');
    learning=await FileLearningStore.open(root:Directory('${root.path}/learning'),materials:materials);
    final draft=await materials.createDraft(title:'Original stdio sample',text:'我来说明一下计划。');
    final version=await materials.confirmVersion(materialId:draft.materialId,expectedRevision:draft.revision);
    bridge=AgentBridgeController.attach(materials:materials,candidates:learning,
      privateDirectory:Directory('${root.path}/bridge'),rootLock:lock,proxyCommand:[args[2]]);
    await bridge.authorize(AgentBridgeGrantRequest(materialVersionId:version.versionId));
    final setup=await bridge.setup();
    final descriptor=await readPrivateDescriptor(setup.descriptorPath);
    if(setup.configurationToml.contains(descriptor.capability)||setup.configurationToml.contains(descriptor.proofKey)){
      throw StateError('secret_in_setup');
    }
    sourceClient=AgentBridgeClient(descriptorPath:setup.descriptorPath);
    final binding=await sourceClient.getSourceReference();
    await plan.writeAsString(jsonEncode({'descriptor_path':setup.descriptorPath,
      'binding':binding,'proxy_executable':args[2],
      'configuration_toml':setup.configurationToml}),flush:true);
    stdout.writeln('READY');
    await for(final command in stdin.transform(utf8.decoder).transform(const LineSplitter())){
      if(command=='VERIFY'){
        final candidates=await learning.listCandidates();
        final before=await learning.listVersions();
        if(candidates.length!=1||before.isNotEmpty||bridge.current.phase!=AgentBridgePhase.enabled){
          throw StateError('unexpected_store_or_client_closed_authority');
        }
        final candidate=candidates.single;
        final confirmed=await learning.confirmCandidate(candidateId:candidate.candidateId,expectedRevision:candidate.revision);
        final again=await learning.confirmCandidate(candidateId:candidate.candidateId,expectedRevision:candidate.revision);
        await receipt.writeAsString(jsonEncode({'actualCandidateCount':candidates.length,
          'beforeOwnerConfirmationLearningCount':before.length,
          'partialAfterOwnerConfirmation':confirmed.state==LearningState.partial,
          'externalSource':confirmed.textProvenance.origin==ContentOrigin.external,
          'confirmedIdempotent':confirmed.binding.learningVersionId==again.binding.learningVersionId,
          'learningVersionCount':(await learning.listVersions()).length,
          'noMedia':confirmed.media==null,'proxyEOFDidNotCloseApp':true,
          'sourceReadGranted':bridge.current.allowSourceRead,
          'declaredProviderUnknown':candidate.declaration.provider==null,
          'transportLocalCapability':candidate.submission.transport==CandidateTransport.localCapability,
          'realAssistantIntegration':false}),flush:true);
        stdout.writeln('VERIFIED');break;
      }
    }
  }catch(error){stderr.writeln('HOST_FAIL ${error is AgentBridgeException?error.code.name:error.runtimeType}');exitCode=1;}
  finally{
    try{await sourceClient?.close();}catch(_){}
    try{await bridge?.close();}catch(_){}
    try{await learning?.close();}catch(_){}
    try{await materials?.close();}catch(_){}
    try{await lock?.release();}catch(_){}
    await root.delete(recursive:true);
  }
}
