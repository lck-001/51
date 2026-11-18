library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_core/material_core.dart';
import 'package:material_import/material_import.dart';
import 'package:learning_core/learning_core.dart';
import 'package:playback_core/playback_core.dart';

/// Frozen v0.13 colors. No new palette or layout language is introduced.
abstract final class ShiyuClientTokens {
  static const paper = Color(0xFFFFFFFF);
  static const ink = Color(0xFF172641);
  static const action = Color(0xFF5557D7);
  static const muted = Color(0xFF8590A7);
  static const hint = Color(0xFFF5F5FF);
  static const warning = Color(0xFFFFF8ED);
  static const line = Color(0xFFE3E6F0);
  static ThemeData lightTheme() => ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: paper,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: action,
          brightness: Brightness.light,
        ).copyWith(
          primary: action,
          onPrimary: paper,
          surface: paper,
          onSurface: ink,
        ),
    fontFamily: 'Segoe UI',
    fontFamilyFallback: const ['Microsoft YaHei UI', 'Microsoft YaHei'],
    appBarTheme: const AppBarTheme(
      backgroundColor: paper,
      foregroundColor: ink,
      surfaceTintColor: paper,
      centerTitle: true,
    ),
  );
}

/// Root atomically pairs the coordinator's current binding with observed state.
/// Neither a command acknowledgement nor a selected row fabricates this value.
final class ClientPlaybackView {
  const ClientPlaybackView({this.learningVersionId, this.snapshot});
  final String? learningVersionId;
  final PlaybackSnapshot? snapshot;
}

final class WordLookupRequest {
  const WordLookupRequest({
    required this.word,
    required this.sentence,
    required this.binding,
  });
  final String word;
  final SentenceAnchor sentence;
  final LearningBinding binding;
}

final class WordLookupResult {
  const WordLookupResult({
    required this.sourceLabel,
    this.phonetic,
    this.meaning,
    this.example,
  });
  final String sourceLabel;
  final String? phonetic, meaning, example;
}

enum PracticeKind { listenAgain, repeatOrRetell }

final class PracticeRequest {
  const PracticeRequest({
    required this.binding,
    required this.sentence,
    required this.kind,
  });
  final LearningBinding binding;
  final SentenceAnchor sentence;
  final PracticeKind kind;
}

typedef OpenLearningCallback = Future<void> Function(LearningVersion version);
typedef PlaybackCommandCallback = Future<CommandResult> Function(
  LearningVersion expected,
  PlaybackCommand command,
);
typedef WordLookupCallback = Future<WordLookupResult?> Function(
  WordLookupRequest request,
);
typedef PracticeCallback = Future<void> Function(PracticeRequest request);

/// App-owned stores/coordinator outlive this Widget. No Player, microphone,
/// OS path, cloud generation, or native resource is created/disposed here.
class ShiyuClientShell extends StatefulWidget {
  const ShiyuClientShell({
    super.key,
    required this.materials,
    required this.learning,
    this.playback,
    this.onOpenLearning,
    this.onPlaybackCommand,
    this.onLookupWord,
    this.onPractice,
    this.onRootBack,
    this.onStartImport,
  });
  final MaterialStore materials;
  final LearningStore learning;
  final ValueListenable<ClientPlaybackView>? playback;
  final OpenLearningCallback? onOpenLearning;
  final PlaybackCommandCallback? onPlaybackCommand;
  final WordLookupCallback? onLookupWord;
  final PracticeCallback? onPractice;
  final Future<void> Function()? onRootBack;
  final StartMaterialImport? onStartImport;
  @override
  State<ShiyuClientShell> createState() => _ShiyuClientShellState();
}

class _ShiyuClientShellState extends State<ShiyuClientShell> {
  final _title = TextEditingController();
  final _text = TextEditingController();
  List<MaterialDraft> _drafts = [];
  Map<String, List<MaterialVersion>> _versions = {};
  List<LearningVersion> _learning = [];
  MaterialDraft? _editing;
  LearningVersion? _selected;
  WordLookupRequest? _word;
  WordLookupResult? _wordResult;
  String? _wordMessage, _message;
  int _tab = 0,
      _scopeEpoch = 0,
      _loadEpoch = 0,
      _selectionEpoch = 0,
      _lookupEpoch = 0,
      _inputEpoch = 0;
  bool _loading = true,
      _saving = false,
      _confirming = false,
      _opening = false,
      _commandBusy = false,
      _wordLoading = false,
      _wordExpanded = false,
      _dirty = false,
      _showChinese = true;
  String? _focusedSentence;
  bool _handlingBack = false;
  bool _importing = false;
  MaterialImportSession? _importSession;
  MaterialImportPreview? _importPreview;
  int _importRequest = 0;
  double? _seekPreview;
  bool get _sameOwner =>
      widget.materials.trustedOwnerId == widget.learning.trustedOwnerId;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant ShiyuClientShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.materials, widget.materials) ||
        !identical(oldWidget.learning, widget.learning)) {
      _scopeEpoch++;
      _selectionEpoch++;
      _lookupEpoch++;
      _inputEpoch++;
      _retireImport();
      _drafts = [];
      _versions = {};
      _learning = [];
      _selected = null;
      _editing = null;
      _word = null;
      _wordResult = null;
      _wordMessage = null;
      _title.clear();
      _text.clear();
      _message = null;
      _dirty = false;
      _loading = true;
      _saving = false;
      _confirming = false;
      _opening = false;
      _commandBusy = false;
      _wordLoading = false;
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _scopeEpoch++;
    _selectionEpoch++;
    _lookupEpoch++;
    _inputEpoch++;
    _retireImport();
    _title.dispose();
    _text.dispose();
    // External stores, playback, and coordinator remain owned by the app.
    super.dispose();
  }

  bool _scope(int value) => mounted && value == _scopeEpoch;

  void _retireImport() {
    _importRequest++;
    final previous = _importSession;
    _importSession = null;
    _importPreview = null;
    _importing = false;
    if (previous != null) unawaited(_cancelImport(previous));
  }

  Future<void> _cancelImport(MaterialImportSession session) async {
    try {
      await session.cancel();
    } catch (_) {
      // App-owned shutdown also waits for its import controller. A failed
      // cleanup is not reported as a complete rollback or a deleted artifact.
    }
  }

  Future<bool> _discardEdits() async {
    if (!_dirty) return true;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('放弃未保存的内容？'),
        content: const Text('这次修改还没有保存，离开后将丢失。'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    return result == true;
  }

  String _importMessage(Object error) => switch (error) {
    MaterialImportException(code: MaterialImportErrorCode.cancelled) =>
      '已取消导入。',
    MaterialImportException(code: MaterialImportErrorCode.busy) =>
      '上一次导入仍在结束，请稍后重试。',
    MaterialImportException(code: MaterialImportErrorCode.emptyMaterial) =>
      '没有找到可导入的正文；图片或扫描内容尚不能提取。',
    MaterialImportException(code: MaterialImportErrorCode.unsupportedFormat) =>
      '目前支持 TXT 和 Word（.docx）文件。',
    MaterialImportException(
      code: MaterialImportErrorCode.sourceTooLarge ||
          MaterialImportErrorCode.outputTooLarge,
    ) =>
      '这份内容超过本次处理上限，请按章节拆分后再导入。',
    MaterialImportException(code: MaterialImportErrorCode.encrypted) =>
      '请先移除文件密码，再导入副本。',
    MaterialImportException(code: MaterialImportErrorCode.readDenied) =>
      '无法读取这份文件，请重新选择并允许读取。',
    MaterialImportException(code: MaterialImportErrorCode.timedOut) =>
      '处理时间较长，请拆分文件后重试。',
    MaterialImportException(code: MaterialImportErrorCode.writeFailed) =>
      '文件来源保存未确认，原文件未改动，请重试。',
    MaterialImportException(
      code: MaterialImportErrorCode.sessionClosed ||
          MaterialImportErrorCode.ownerMismatch ||
          MaterialImportErrorCode.bindingMismatch,
    ) =>
      '这次导入已结束，请重新选择文件。',
    _ => '这份文件暂时无法处理，请确认文件完整或另存为 TXT、DOCX。',
  };

  String _importWarning(MaterialImportWarning warning) => switch (warning) {
    MaterialImportWarning.formattingOmitted => '未保留原排版。',
    MaterialImportWarning.imagesOmitted => '图片内容未提取。',
    MaterialImportWarning.headersFootersOmitted => '页眉页脚未提取。',
    MaterialImportWarning.annotationsOmitted => '批注未提取。',
    MaterialImportWarning.externalLinksNotFollowed => '未打开文档中的外部链接。',
    MaterialImportWarning.embeddedObjectsOmitted => '嵌入对象未提取。',
    MaterialImportWarning.trackedChangesOmitted => '修订内容可能不完整，请对照原文核对。',
  };

  Future<void> _startImport() async {
    final start = widget.onStartImport;
    if (start == null ||
        !_sameOwner ||
        _saving ||
        _confirming ||
        _importing ||
        _importSession != null ||
        _handlingBack)
      return;
    final scope = _scopeEpoch, input = _inputEpoch, request = ++_importRequest;
    setState(() => _importing = true);
    MaterialImportSession? session;
    try {
      if (!await _discardEdits() || !_scope(scope) || input != _inputEpoch) {
        return;
      }
      final previous = _importSession;
      _importSession = null;
      _importPreview = null;
      if (previous != null) await _cancelImport(previous);
      if (!_scope(scope) || input != _inputEpoch) return;
      session = start();
      if (session.ownerId != widget.materials.trustedOwnerId) {
        throw const MaterialImportException(
          MaterialImportErrorCode.ownerMismatch,
        );
      }
      _importSession = session;
      final preview = await session.preview;
      if (!_scope(scope) ||
          input != _inputEpoch ||
          !identical(_importSession, session))
        return;
      if (preview == null) {
        _importSession = null;
        await _cancelImport(session);
        return;
      }
      if (preview.ownerId != session.ownerId ||
          preview.sessionId != session.sessionId) {
        throw const MaterialImportException(
          MaterialImportErrorCode.bindingMismatch,
        );
      }
      _inputEpoch++;
      setState(() {
        _importPreview = preview;
        _editing = null;
        _title.text = preview.title;
        _text.text = preview.text;
        _dirty = true;
        _tab = 2;
        _importing = false;
        _message = '文件已在本机提取，请校对后保存。尚未创建草稿。';
      });
    } catch (error) {
      if (_scope(scope) && input == _inputEpoch) {
        setState(() {
          _importSession = null;
          _importPreview = null;
          _message = _importMessage(error);
        });
      }
      if (session != null) await _cancelImport(session);
    } finally {
      if (session != null && !identical(_importSession, session)) {
        await _cancelImport(session);
      }
      if (_scope(scope) && request == _importRequest) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _reload() async {
    final scope = _scopeEpoch, load = ++_loadEpoch;
    final materials = widget.materials, learning = widget.learning;
    if (!_sameOwner) {
      if (_scope(scope))
        setState(() {
          _loading = false;
          _message = '材料与学习数据的账号不一致，暂不显示内容。';
        });
      return;
    }
    try {
      final drafts = List<MaterialDraft>.of(await materials.listDrafts());
      final versions = <String, List<MaterialVersion>>{};
      for (final draft in drafts) {
        versions[draft.materialId] = await materials.listVersions(
          draft.materialId,
        );
      }
      final items = List<LearningVersion>.of(await learning.listVersions());
      if (!_scope(scope) || load != _loadEpoch) return;
      drafts.sort((a, b) => b.updatedAtUtc.compareTo(a.updatedAtUtc));
      items.sort((a, b) => b.createdAtUtc.compareTo(a.createdAtUtc));
      setState(() {
        _drafts = drafts;
        _versions = versions;
        _learning = items;
        _loading = false;
        if (_selected != null) {
          final current = items.where(
            (v) =>
                v.binding.learningVersionId ==
                _selected!.binding.learningVersionId,
          );
          _selected = current.isEmpty ? null : current.first;
        }
      });
    } catch (_) {
      if (_scope(scope) && load == _loadEpoch)
        setState(() {
          _loading = false;
          _message = '本机数据读取未确认，请保留原数据后重试。';
        });
    }
  }

  void _navigate(int tab) {
    if (_saving || _confirming) return;
    if (_importing && tab != 2) {
      _inputEpoch++;
      _retireImport();
    }
    setState(() {
      _tab = tab;
      _message = null;
    });
    if (tab == 0 || tab == 1 || tab == 4) unawaited(_reload());
  }

  void _newDraft() {
    if (_saving || _confirming) return;
    _inputEpoch++;
    _retireImport();
    setState(() {
      _editing = null;
      _title.clear();
      _text.clear();
      _dirty = false;
      _tab = 2;
      _message = null;
      _saving = false;
      _confirming = false;
    });
  }

  void _edit(MaterialDraft draft) {
    if (_saving || _confirming) return;
    _inputEpoch++;
    _retireImport();
    setState(() {
      _editing = draft;
      _title.text = draft.title;
      _text.text = draft.text;
      _dirty = false;
      _tab = 2;
      _message = null;
      _saving = false;
      _confirming = false;
    });
  }

  Future<void> _saveDraft() async {
    if (_saving ||
        _importing ||
        _confirming ||
        !_sameOwner ||
        _title.text.trim().isEmpty ||
        _text.text.trim().isEmpty)
      return;
    final scope = _scopeEpoch, input = _inputEpoch;
    final store = widget.materials, old = _editing, session = _importSession;
    final title = _title.text.trim(), text = _text.text;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      List<ArtifactRef>? importedRefs;
      if (session != null) {
        if (session.ownerId != store.trustedOwnerId) {
          throw const MaterialImportException(
            MaterialImportErrorCode.ownerMismatch,
          );
        }
        importedRefs = await session.prepareArtifacts();
        if (!_scope(scope) ||
            input != _inputEpoch ||
            !identical(_importSession, session))
          return;
        if (importedRefs.length != 2 ||
            importedRefs.map((r) => r.artifactId).toSet().length != 2 ||
            importedRefs.any((r) => r.ownerId != store.trustedOwnerId)) {
          throw const MaterialImportException(
            MaterialImportErrorCode.bindingMismatch,
          );
        }
      }
      // Recheck immediately before the irreversible-to-this-form draft commit.
      // Artifact preparation is not itself a saved/confirmed material.
      if (!_scope(scope) || input != _inputEpoch) return;
      final draft = old == null
          ? await store.createDraft(
              title: title,
              text: text,
              artifacts: importedRefs ?? const [],
            )
          : await store.updateDraft(
              materialId: old.materialId,
              expectedRevision: old.revision,
              title: title,
              text: text,
              artifacts: importedRefs,
            );
      final persisted = await store.readDraft(draft.materialId);
      if (!_scope(scope) || input != _inputEpoch) return;
      setState(() {
        _editing = persisted;
        _dirty = false;
        _message = '草稿已保存在本机。确认后才会创建固定版本。';
      });
      if (session != null) {
        try {
          await session.finish(savedMaterialId: persisted.materialId);
          if (_scope(scope) &&
              input == _inputEpoch &&
              identical(_importSession, session)) {
            setState(() {
              _importSession = null;
              _importPreview = null;
            });
          }
        } catch (_) {
          if (_scope(scope) && input == _inputEpoch) {
            setState(() {
              _message = '草稿已保存，导入来源的收尾尚未确认；原文件未改动。';
            });
          }
        }
      }
      await _reload();
    } on MaterialImportException catch (error) {
      if (_scope(scope) && input == _inputEpoch) {
        setState(() => _message = _importMessage(error));
      }
    } on MaterialStoreException catch (error) {
      if (_scope(scope) && input == _inputEpoch)
        setState(() {
          _message = error.code == MaterialErrorCode.revisionConflict
              ? '草稿已更新。当前输入已保留，请回材料页核对新版本。'
              : '保存未确认。当前输入已保留，请稍后重试。';
        });
    } catch (_) {
      if (_scope(scope) && input == _inputEpoch)
        setState(() {
          _message = '保存未确认，当前输入已保留。';
        });
    } finally {
      if (_scope(scope) && input == _inputEpoch)
        setState(() {
          _saving = false;
        });
    }
  }

  Future<void> _confirm() async {
    final draft = _editing;
    if (draft == null || _dirty || _saving || _confirming || _importing) return;
    final scope = _scopeEpoch, input = _inputEpoch, store = widget.materials;
    setState(() {
      _confirming = true;
      _message = null;
    });
    try {
      final version = await store.confirmVersion(
        materialId: draft.materialId,
        expectedRevision: draft.revision,
      );
      final saved = await store.readVersion(version.versionId);
      if (!_scope(scope) || input != _inputEpoch) return;
      await _reload();
      if (!_scope(scope) || input != _inputEpoch) return;
      setState(() {
        _tab = 1;
        _message = '已确认第 ${saved.versionNumber} 版。尚未翻译、生成音频或提交外部服务。';
      });
    } catch (_) {
      if (_scope(scope) && input == _inputEpoch)
        setState(() {
          _message = '版本确认未完成，请核对草稿是否已被更新；当前输入已保留。';
        });
    } finally {
      if (_scope(scope) && input == _inputEpoch)
        setState(() {
          _confirming = false;
        });
    }
  }

  Future<void> _choose(LearningVersion version) async {
    final scope = _scopeEpoch, request = ++_selectionEpoch;
    _lookupEpoch++;
    setState(() {
      _selected = version;
      _word = null;
      _wordResult = null;
      _wordMessage = null;
      _wordLoading = false;
      _wordExpanded = false;
      _focusedSentence = null;
      _commandBusy = false;
      _seekPreview = null;
      _tab = 0;
      _message = null;
      _opening = false;
    });
    final callback = widget.onOpenLearning;
    if (version.state != LearningState.ready || callback == null) return;
    setState(() {
      _opening = true;
    });
    try {
      await callback(version);
      if (!_scope(scope) || request != _selectionEpoch) return;
      setState(() {
        _message = '已提交打开。播放与定位状态以实际回执为准，不会自动播放。';
      });
    } catch (_) {
      if (_scope(scope) && request == _selectionEpoch)
        setState(() {
          _message = '打开未确认，请保留当前版本并重试。';
        });
    } finally {
      if (_scope(scope) && request == _selectionEpoch)
        setState(() {
          _opening = false;
        });
    }
  }

  Future<void> _lookup(String word, SentenceAnchor sentence) async {
    final version = _selected;
    if (version == null) return;
    final scope = _scopeEpoch,
        selection = _selectionEpoch,
        request = ++_lookupEpoch;
    final lookup = WordLookupRequest(
      word: word,
      sentence: sentence,
      binding: version.binding,
    );
    setState(() {
      _word = lookup;
      _wordResult = null;
      _focusedSentence = sentence.sentenceId;
      _wordMessage = widget.onLookupWord == null ? '词典尚未接入，暂不显示释义或音标。' : null;
      _wordLoading = widget.onLookupWord != null;
    });
    final callback = widget.onLookupWord;
    if (callback == null) return;
    try {
      final result = await callback(lookup);
      if (!_scope(scope) ||
          selection != _selectionEpoch ||
          request != _lookupEpoch)
        return;
      setState(() {
        _wordResult = result;
        _wordMessage = result == null ? '本次查询没有结果，可稍后重试。' : null;
      });
    } catch (_) {
      if (_scope(scope) &&
          selection == _selectionEpoch &&
          request == _lookupEpoch) {
        setState(() {
          _wordMessage = '查询未完成，原句和播放位置已保留。';
        });
      }
    } finally {
      if (_scope(scope) &&
          selection == _selectionEpoch &&
          request == _lookupEpoch) {
        setState(() {
          _wordLoading = false;
        });
      }
    }
  }

  Future<void> _command(PlaybackCommand command) async {
    final selected = _selected, callback = widget.onPlaybackCommand;
    if (selected == null || callback == null || _commandBusy || _opening)
      return;
    final scope = _scopeEpoch, selection = _selectionEpoch;
    setState(() {
      _commandBusy = true;
    });
    try {
      final result = await callback(selected, command);
      if (!_scope(scope) || selection != _selectionEpoch) return;
      if (!result.accepted)
        setState(() {
          _message = result.status == CommandStatus.unsupported
              ? '当前环境暂不支持这个播放操作。'
              : '播放操作未被接受，请核对当前版本与资源状态。';
        });
    } catch (_) {
      if (_scope(scope) && selection == _selectionEpoch)
        setState(() {
          _message = '播放操作未确认，请核查状态，不自动重试。';
        });
    } finally {
      if (_scope(scope) && selection == _selectionEpoch)
        setState(() {
          _commandBusy = false;
        });
    }
  }

  Future<void> _practice(PracticeKind kind) async {
    final version = _selected, callback = widget.onPractice;
    if (version == null || callback == null || version.sentences.isEmpty)
      return;
    final view = widget.playback?.value;
    final currentIndex = _playbackSentenceIndex(
      version,
      view == null ? null : _bound(view),
    );
    final sentence = currentIndex >= 0
        ? version.sentences[currentIndex]
        : version.sentences
                  .where((s) => s.sentenceId == _focusedSentence)
                  .firstOrNull ??
              version.sentences.first;
    final scope = _scopeEpoch, selection = _selectionEpoch;
    try {
      await callback(
        PracticeRequest(
          binding: version.binding,
          sentence: sentence,
          kind: kind,
        ),
      );
    } catch (_) {
      if (_scope(scope) && selection == _selectionEpoch)
        setState(() {
          _message = '练习未能开始，不会自动录音或补造评测。';
        });
    }
  }

  void _leaveReader() {
    _selectionEpoch++;
    _lookupEpoch++;
    setState(() {
      _selected = null;
      _word = null;
      _wordResult = null;
      _opening = false;
      _commandBusy = false;
    });
  }

  Future<void> _handleBack() async {
    if (_handlingBack || !mounted || _saving || _confirming) return;
    _handlingBack = true;
    if (_importing) {
      _inputEpoch++;
      _retireImport();
    }
    final scope = _scopeEpoch, input = _inputEpoch;
    try {
      if (_tab == 0 && _selected != null) {
        _leaveReader();
        return;
      }
      // Text can remain in the editor while another tab is selected. Protect
      // those edits at root exit too, not just when returning from the editor.
      if (_dirty && (_tab == 2 || _tab == 0)) {
        final discard = await _discardEdits();
        if (!_scope(scope) || input != _inputEpoch || !discard) return;
        _inputEpoch++;
        _retireImport();
        setState(() {
          _title.text = _editing?.title ?? '';
          _text.text = _editing?.text ?? '';
          _dirty = false;
        });
      }
      if (!_scope(scope)) return;
      if (_tab == 2) {
        _retireImport();
        _navigate(1);
      } else if (_tab != 0) {
        _navigate(0);
      } else {
        // Native stop/release remains app-owned. Ordinary page back never calls
        // this callback, creates a Player, or closes the externally owned stores.
        await widget.onRootBack?.call();
      }
    } catch (_) {
      if (_scope(scope)) {
        setState(() {
          _message = '暂时无法返回，请稍后重试。';
        });
      }
    } finally {
      _handlingBack = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_handleBack());
    },
    child: Theme(
      data: ShiyuClientTokens.lightTheme(),
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: ShiyuClientTokens.paper,
          appBar: AppBar(
            title: Text(
              _tab == 0 && _selected != null
                  ? _selected!.materialTitle
                  : const ['学习', '我的材料', '添加学习材料', '分享', '我的'][_tab],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            leading: _tab == 0 && _selected != null
                ? IconButton(
                    tooltip: '返回学习列表',
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                    onPressed: _leaveReader,
                  )
                : null,
            actions: [
              if (_tab == 0 && _selected != null)
                PopupMenuButton<String>(
                  tooltip: '更多播放操作',
                  onSelected: (_) => unawaited(_command(const Stop())),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'stop',
                      enabled: widget.onPlaybackCommand != null,
                      child: const Text('停止播放'),
                    ),
                  ],
                ),
              IconButton(
                key: const Key('refresh-data'),
                tooltip: '重新读取本机数据',
                onPressed: _loading ? null : () => unawaited(_reload()),
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (_message != null)
                  Container(
                    key: const Key('status-message'),
                    width: double.infinity,
                    color: ShiyuClientTokens.hint,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    child: Text(
                      _message!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: ShiyuClientTokens.ink,
                      ),
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : !_sameOwner
                      ? _empty(Icons.lock_outline, '账号不一致，未读取其他账号的材料。')
                      : switch (_tab) {
                          0 => _learningPage(),
                          1 => _materialsPage(),
                          2 => _addPage(),
                          3 => _empty(
                            Icons.ios_share_outlined,
                            '分享还未接入',
                            detail: '材料保持私有，不会自动上传或发布到第三方。',
                          ),
                          _ => _myPage(),
                        },
                ),
              ],
            ),
          ),
          bottomNavigationBar: _tab == 0 && _selected != null
              ? null
              : NavigationBar(
                  height: 68,
                  selectedIndex: _tab,
                  backgroundColor: ShiyuClientTokens.paper,
                  indicatorColor: ShiyuClientTokens.hint,
                  onDestinationSelected: _saving || _confirming
                      ? null
                      : _navigate,
                  destinations: [
                    const NavigationDestination(
                      key: Key('nav-learning'),
                      icon: Icon(Icons.headphones_outlined),
                      label: '学习',
                    ),
                    const NavigationDestination(
                      key: Key('nav-materials'),
                      icon: Icon(Icons.folder_outlined),
                      label: '材料',
                    ),
                    NavigationDestination(
                      key: const Key('nav-add'),
                      icon: Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          color: ShiyuClientTokens.action,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.add, color: Colors.white),
                      ),
                      label: '添加',
                    ),
                    const NavigationDestination(
                      key: Key('nav-share'),
                      icon: Icon(Icons.ios_share_outlined),
                      label: '分享',
                    ),
                    const NavigationDestination(
                      key: Key('nav-my'),
                      icon: Icon(Icons.person_outline),
                      label: '我的',
                    ),
                  ],
                ),
        ),
      ),
    ),
  );

  Widget _empty(
    IconData icon,
    String title, {
    String? detail,
    bool add = false,
  }) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: ShiyuClientTokens.muted),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: ShiyuClientTokens.ink,
            ),
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                detail,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: ShiyuClientTokens.muted,
                  height: 1.7,
                ),
              ),
            ),
          if (add)
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: FilledButton.icon(
                onPressed: _newDraft,
                icon: const Icon(Icons.add),
                label: const Text('添加自己的材料'),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _tag(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: ShiyuClientTokens.hint,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 11, color: ShiyuClientTokens.action),
    ),
  );

  Widget _materialsPage() => _drafts.isEmpty
      ? _empty(
          Icons.folder_outlined,
          '还没有材料',
          detail: '先粘贴一段文字，保存为自己的私有草稿。',
          add: true,
        )
      : ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                Text(
                  '本机材料 ${_drafts.length}',
                  key: const Key('material-count'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _newDraft,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加'),
                ),
              ],
            ),
            const Text(
              '草稿与已确认版本分开保留，当前未接云同步。',
              style: TextStyle(fontSize: 12, color: ShiyuClientTokens.muted),
            ),
            const SizedBox(height: 16),
            for (final draft in _drafts)
              Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: ShiyuClientTokens.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        draft.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        draft.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.7,
                          color: ShiyuClientTokens.muted,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _tag('草稿修订 ${draft.revision}'),
                          _tag(
                            '已确认 ${_versions[draft.materialId]?.length ?? 0} 版',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          OutlinedButton(
                            onPressed: () => _edit(draft),
                            child: const Text('校对草稿'),
                          ),
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed:
                                (_versions[draft.materialId] ?? []).isEmpty
                                ? null
                                : () => _showVersions(draft),
                            child: const Text('查看固定版本'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );

  void _showVersions(MaterialDraft draft) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            height: 360,
            child: ListView(
              children: [
                Text(
                  draft.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final version
                    in _versions[draft.materialId] ?? <MaterialVersion>[])
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '已确认第 ${version.versionNumber} 版',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(version.text, style: const TextStyle(height: 1.8)),
                        const SizedBox(height: 8),
                        const Text(
                          '固定原文版本，不表示已生成学习内容。',
                          style: TextStyle(
                            fontSize: 11,
                            color: ShiyuClientTokens.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _addPage() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text(
        '先把内容留下来',
        style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 9),
      const Text(
        '这里保存的是私有材料，不会自动翻译、计费或分享。',
        style: TextStyle(
          fontSize: 13,
          height: 1.7,
          color: ShiyuClientTokens.muted,
        ),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          _tag('粘贴文字'),
          OutlinedButton.icon(
            key: const Key('import-file'),
            onPressed:
                widget.onStartImport == null ||
                    _importSession != null ||
                    _importing ||
                    _saving ||
                    _confirming ||
                    _handlingBack
                ? null
                : () => unawaited(_startImport()),
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: Text(_importing ? '正在导入…' : '导入文件'),
          ),
          if (_importing)
            TextButton(
              key: const Key('import-cancel'),
              onPressed: () {
                _inputEpoch++;
                _retireImport();
                setState(() => _message = '未创建新草稿。');
              },
              child: const Text('取消导入'),
            ),
          const Chip(label: Text('口述 · 尚未接入')),
        ],
      ),
      if (widget.onStartImport != null)
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text(
            '支持 TXT、Word（.docx），仅在本机提取。过长内容请按章节拆分；PPT、PDF 后续接入。',
            style: TextStyle(
              fontSize: 12,
              height: 1.7,
              color: ShiyuClientTokens.muted,
            ),
          ),
        ),
      if (_importPreview != null)
        Container(
          key: const Key('import-preview-note'),
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          color: ShiyuClientTokens.hint,
          child: Text(
            '${_editing != null && !_dirty ? '导入草稿已保存 · 来源收尾待确认' : '导入预览 · 尚未保存'}${_importPreview!.warnings.isEmpty ? '' : '\n${_importPreview!.warnings.map(_importWarning).join(' ')}'}\n请先保存或返回处理当前预览，再选择其他文件。',
            style: const TextStyle(fontSize: 12, height: 1.7),
          ),
        ),
      const SizedBox(height: 18),
      TextField(
        key: const Key('draft-title'),
        controller: _title,
        enabled: !_saving && !_confirming && !_importing,
        onChanged: (_) => setState(() {
          _dirty = true;
        }),
        maxLength: 120,
        decoration: const InputDecoration(
          labelText: '材料标题',
          hintText: '给这段内容起个名字',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        key: const Key('draft-text'),
        controller: _text,
        enabled: !_saving && !_confirming && !_importing,
        onChanged: (_) => setState(() {
          _dirty = true;
        }),
        minLines: 8,
        maxLines: 16,
        decoration: const InputDecoration(
          labelText: '原文内容',
          alignLabelWithHint: true,
          hintText: '粘贴你的文字。原文会保留，后续学习内容另行准备。',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 18),
      FilledButton.icon(
        key: const Key('draft-save'),
        onPressed:
            _saving ||
                _importing ||
                _confirming ||
                _title.text.trim().isEmpty ||
                _text.text.trim().isEmpty
            ? null
            : () => unawaited(_saveDraft()),
        icon: const Icon(Icons.save_outlined, size: 18),
        label: Text(_saving ? '正在保存…' : '保存草稿'),
      ),
      const SizedBox(height: 12),
      OutlinedButton(
        key: const Key('draft-confirm'),
        onPressed:
            _editing == null || _dirty || _saving || _confirming || _importing
            ? null
            : () => unawaited(_confirm()),
        child: Text(_confirming ? '正在确认…' : '确认此版本'),
      ),
      const SizedBox(height: 10),
      Text(
        _editing == null
            ? '先保存草稿，再确认固定版本。'
            : _dirty
            ? '输入已修改，请先保存，再确认新版本。'
            : '已保存草稿修订 ${_editing!.revision}。确认不会触发外部处理。',
        style: const TextStyle(
          fontSize: 12,
          color: ShiyuClientTokens.muted,
          height: 1.7,
        ),
      ),
    ],
  );

  Widget _learningPage() {
    if (_selected != null) {
      final listenable = widget.playback;
      if (listenable == null) return _reader(const ClientPlaybackView());
      return ValueListenableBuilder<ClientPlaybackView>(
        valueListenable: listenable,
        builder: (_, view, __) => _reader(view),
      );
    }
    if (_learning.isEmpty)
      return _empty(
        Icons.headphones_outlined,
        '从自己的材料开始学习',
        detail: _drafts.isEmpty
            ? '添加一段文字，先保留原文。'
            : '材料已保存在本机，英文学习内容尚未准备。当前未接入自动翻译或音频生成。',
        add: true,
      );
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '我的学习内容',
          style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        const Text(
          '就绪、待准备和部分内容分别显示；不把人工或合成来源说成AI生成。',
          style: TextStyle(
            fontSize: 12,
            color: ShiyuClientTokens.muted,
            height: 1.7,
          ),
        ),
        const SizedBox(height: 20),
        for (final version in _learning)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              key: Key('learning-select-${version.binding.learningVersionId}'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: ShiyuClientTokens.line),
              ),
              title: Text(version.materialTitle),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${_stateLabel(version.state)} · ${_originLabel(version.textProvenance.origin)} · ${version.sentences.length} 句',
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unawaited(_choose(version)),
            ),
          ),
      ],
    );
  }

  String _stateLabel(LearningState state) => switch (state) {
    LearningState.ready => '结构已就绪',
    LearningState.partial => '部分内容',
    LearningState.pending => '待准备',
  };
  String _originLabel(ContentOrigin origin) =>
      origin == ContentOrigin.synthetic ? '合成示例' : '人工整理';
  String _time(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  String _actualLabel(PlaybackActual actual) => switch (actual) {
    PlaybackActual.idle => '尚未播放',
    PlaybackActual.loading => '正在加载',
    PlaybackActual.buffering => '正在缓冲',
    PlaybackActual.playing => '正在播放',
    PlaybackActual.paused => '已暂停',
    PlaybackActual.ended => '已结束',
    PlaybackActual.failed => '播放未确认',
  };

  PlaybackSnapshot? _bound(ClientPlaybackView view) {
    final selected = _selected, snapshot = view.snapshot;
    if (selected == null ||
        snapshot == null ||
        view.learningVersionId != selected.binding.learningVersionId ||
        snapshot.token.itemId != selected.binding.learningVersionId ||
        snapshot.itemRevision != selected.binding.mediaVersionId ||
        snapshot.ownerId != selected.binding.ownerId ||
        snapshot.ownerId != widget.materials.trustedOwnerId)
      return null;
    return snapshot;
  }

  // Navigation follows observed media time, independently of dictionary focus
  // and the slider's unsubmitted preview. Between timed sentences retain the
  // preceding sentence; before/after the timeline use its first/last sentence.
  int _playbackSentenceIndex(
    LearningVersion version,
    PlaybackSnapshot? snapshot,
  ) {
    if (snapshot == null) return -1;
    var current = -1;
    final position = snapshot.position.inMilliseconds;
    for (var i = 0; i < version.sentences.length; i++) {
      final sentence = version.sentences[i];
      final start = sentence.startMs, end = sentence.endMs;
      if (start == null || end == null || end <= start) continue;
      if (current < 0 || start <= position) current = i;
      if (start > position) break;
    }
    return current;
  }

  Widget _reader(ClientPlaybackView view) {
    final version = _selected!, snapshot = _bound(view);
    final nativeReady =
        version.state == LearningState.ready &&
        snapshot != null &&
        snapshot.engineAvailable &&
        widget.onPlaybackCommand != null &&
        !_opening &&
        !_commandBusy;
    final actual = snapshot?.actual;
    final duration = snapshot?.duration;
    final canSeek =
        nativeReady &&
        duration != null &&
        duration > Duration.zero &&
        snapshot.capabilities.seek &&
        snapshot.pendingSeek == null;
    final currentIndex = _playbackSentenceIndex(version, snapshot);
    final playingSentence = currentIndex < 0
        ? null
        : version.sentences[currentIndex].sentenceId;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxCard = math.max(
          64.0,
          math.min(190.0, constraints.maxHeight - 280),
        );
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 7, 20, 8),
              child: Row(
                children: [
                  _tag(_originLabel(version.textProvenance.origin)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _stateLabel(version.state),
                      style: const TextStyle(
                        fontSize: 11,
                        color: ShiyuClientTokens.muted,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _showChinese = !_showChinese;
                    }),
                    child: Text(_showChinese ? '双语' : '仅英文'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: version.sentences.isEmpty
                  ? _empty(
                      Icons.description_outlined,
                      '英文内容尚未准备',
                      detail: '不会用占位翻译或AI完成状态替代实际内容。',
                    )
                  : ListView(
                      key: const Key('learning-reader'),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      children: [
                        for (final sentence in version.sentences)
                          Container(
                            key: Key('sentence-${sentence.sentenceId}'),
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 8,
                            ),
                            decoration: BoxDecoration(
                              color: sentence.sentenceId == playingSentence
                                  ? ShiyuClientTokens.hint
                                  : Colors.transparent,
                              border: Border(
                                bottom: const BorderSide(
                                  color: ShiyuClientTokens.line,
                                ),
                                left: BorderSide(
                                  color: sentence.sentenceId == playingSentence
                                      ? ShiyuClientTokens.action
                                      : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 0,
                                  runSpacing: 5,
                                  children: _wordSpans(sentence),
                                ),
                                if (_showChinese)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: Text(
                                      sentence.translation.isEmpty
                                          ? '本句中文对照未提供'
                                          : sentence.translation,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: ShiyuClientTokens.muted,
                                        height: 1.8,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            Container(
              key: const Key('playback-controls'),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: ShiyuClientTokens.line)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  Slider(
                    value:
                        _seekPreview ??
                        (snapshot?.position.inMilliseconds.toDouble() ?? 0)
                            .clamp(0, duration?.inMilliseconds.toDouble() ?? 1),
                    max: math.max(
                      1.0,
                      duration?.inMilliseconds.toDouble() ?? 1,
                    ),
                    onChanged: canSeek
                        ? (value) => setState(() {
                            _seekPreview = value;
                          })
                        : null,
                    onChangeEnd: canSeek
                        ? (value) {
                            setState(() {
                              _seekPreview = null;
                            });
                            unawaited(
                              _command(
                                Seek(Duration(milliseconds: value.round())),
                              ),
                            );
                          }
                        : null,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        snapshot == null ? '尚未打开音频' : _time(snapshot.position),
                        style: const TextStyle(
                          fontSize: 11,
                          color: ShiyuClientTokens.muted,
                        ),
                      ),
                      Text(
                        _opening
                            ? '正在核对版本…'
                            : snapshot?.pendingSeek != null
                            ? '定位中 · 等待实际到位'
                            : snapshot == null
                            ? '此版本音频尚未打开'
                            : snapshot.engineAvailable
                            ? '${_actualLabel(actual!)} · ${duration == null ? '--:--' : _time(duration)}'
                            : '播放资源未确认',
                        style: const TextStyle(
                          fontSize: 10,
                          color: ShiyuClientTokens.muted,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '上一句',
                        onPressed:
                            canSeek &&
                                currentIndex > 0 &&
                                version.sentences[currentIndex - 1].startMs !=
                                    null
                            ? () => unawaited(
                                _command(
                                  Seek(
                                    Duration(
                                      milliseconds: version
                                          .sentences[currentIndex - 1]
                                          .startMs!,
                                    ),
                                  ),
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.skip_previous, size: 30),
                      ),
                      const SizedBox(width: 24),
                      IconButton.filled(
                        key: const Key('reader-play'),
                        tooltip: actual == PlaybackActual.playing ? '暂停' : '播放',
                        onPressed: nativeReady
                            ? () => unawaited(
                                _command(
                                  actual == PlaybackActual.playing
                                      ? const Pause()
                                      : const Play(),
                                ),
                              )
                            : null,
                        icon: Icon(
                          actual == PlaybackActual.playing
                              ? Icons.pause
                              : Icons.play_arrow,
                          size: 30,
                        ),
                      ),
                      const SizedBox(width: 24),
                      IconButton(
                        tooltip: '下一句',
                        onPressed:
                            canSeek &&
                                currentIndex >= 0 &&
                                currentIndex + 1 < version.sentences.length &&
                                version.sentences[currentIndex + 1].startMs !=
                                    null
                            ? () => unawaited(
                                _command(
                                  Seek(
                                    Duration(
                                      milliseconds: version
                                          .sentences[currentIndex + 1]
                                          .startMs!,
                                    ),
                                  ),
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.skip_next, size: 30),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              key: const Key('practice-controls'),
              padding: const EdgeInsets.fromLTRB(20, 5, 20, 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          widget.onPractice == null || version.sentences.isEmpty
                          ? null
                          : () =>
                                unawaited(_practice(PracticeKind.listenAgain)),
                      child: const Text('这一句没听懂'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed:
                          widget.onPractice == null ||
                              version.state != LearningState.ready
                          ? null
                          : () => unawaited(
                              _practice(PracticeKind.repeatOrRetell),
                            ),
                      child: const Text('跟读 / 复述'),
                    ),
                  ),
                ],
              ),
            ),
            _dictionary(maxCard),
          ],
        );
      },
    );
  }

  List<Widget> _wordSpans(SentenceAnchor sentence) {
    final tokens = RegExp(r"[A-Za-z]+(?:['’\-][A-Za-z]+)*|[^A-Za-z]+")
        .allMatches(sentence.english)
        .toList();
    return [
      for (var index = 0; index < tokens.length; index++)
        RegExp(r'^[A-Za-z]').hasMatch(tokens[index].group(0)!)
            ? InkWell(
                key: Key('word-${sentence.sentenceId}-$index'),
                onTap: () =>
                    unawaited(_lookup(tokens[index].group(0)!, sentence)),
                child: Text(
                  tokens[index].group(0)!,
                  style: const TextStyle(
                    fontSize: 18,
                    height: 1.6,
                    color: ShiyuClientTokens.ink,
                  ),
                ),
              )
            : Text(
                tokens[index].group(0)!,
                style: const TextStyle(
                  fontSize: 18,
                  height: 1.6,
                  color: ShiyuClientTokens.ink,
                ),
              ),
    ];
  }

  Widget _dictionary(double maxHeight) {
    final result = _wordResult;
    final subtitle = _wordLoading
        ? '正在查询，不影响原句与播放位置…'
        : _wordMessage ??
              result?.meaning ??
              (_word == null ? '点正文单词查词，词卡可在这里展开。' : '本次结果未提供释义。');
    return Container(
      key: const Key('dictionary-card'),
      width: double.infinity,
      height: _wordExpanded ? maxHeight : 72,
      padding: const EdgeInsets.fromLTRB(18, 4, 12, 8),
      decoration: BoxDecoration(
        color: ShiyuClientTokens.hint,
        border: Border.all(color: const Color(0xFFDCDCF7)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _word?.word ?? '点正文中的单词',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: ShiyuClientTokens.ink,
                  ),
                ),
              ),
              if (result?.phonetic != null)
                Flexible(
                  child: Text(
                    result!.phonetic!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: ShiyuClientTokens.muted,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              const Icon(
                Icons.volume_up_outlined,
                color: ShiyuClientTokens.muted,
                size: 20,
              ),
              IconButton(
                key: const Key('dictionary-expand'),
                tooltip: _wordExpanded ? '收起词卡' : '展开词卡',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => setState(() {
                  _wordExpanded = !_wordExpanded;
                }),
                icon: Icon(
                  _wordExpanded ? Icons.expand_more : Icons.expand_less,
                  color: ShiyuClientTokens.action,
                  size: 20,
                ),
              ),
            ],
          ),
          Text(
            subtitle,
            key: const Key('dictionary-meaning'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: ShiyuClientTokens.muted,
            ),
          ),
          if (_wordExpanded)
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (result?.example != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          result!.example!,
                          style: const TextStyle(fontSize: 13, height: 1.7),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        result == null
                            ? '词典、示范发音和词句本尚未接入时，不补造内容或收藏成功。'
                            : '词条来源：${result.sourceLabel}；示范发音和收藏另行接入。',
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.6,
                          color: ShiyuClientTokens.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _myPage() {
    final confirmed = _versions.values.fold<int>(
      0,
      (count, versions) => count + versions.length,
    );
    final ready = _learning.where((v) => v.state == LearningState.ready).length;
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          '我的本机空间',
          style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        const Text(
          '这里只显示真实本机记录，未接入账号登录或云同步。',
          style: TextStyle(
            fontSize: 13,
            height: 1.8,
            color: ShiyuClientTokens.muted,
          ),
        ),
        const SizedBox(height: 22),
        ListTile(
          title: const Text('材料'),
          trailing: Text(
            '${_drafts.length}',
            key: const Key('my-material-count'),
          ),
        ),
        ListTile(
          title: const Text('已确认材料版本'),
          trailing: Text(
            '$confirmed',
            key: const Key('confirmed-version-count'),
          ),
        ),
        ListTile(title: const Text('结构就绪的学习版本'), trailing: Text('$ready')),
        const Divider(),
        const ListTile(
          leading: Icon(Icons.insights_outlined),
          title: Text('学习进步'),
          subtitle: Text('尚无完整练习与专业评测记录，不显示虚构分数、天数或能力趋势。'),
        ),
        const ListTile(
          leading: Icon(Icons.privacy_tip_outlined),
          title: Text('数据保存在本机'),
          subtitle: Text('分享、云同步和第三方上传未接入，不会自动外发。'),
        ),
      ],
    );
  }
}
