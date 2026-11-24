import 'dart:async';

import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:material_ui/material_ui.dart';

/// Local review only. Receiving an external payload cannot invoke this user's
/// confirmation action, select another reader, start playback or publish.
class CandidateReviewSheet extends StatefulWidget {
  const CandidateReviewSheet({
    super.key,
    required this.candidates,
    required this.materials,
    required this.candidateId,
    required this.isCurrentScope,
    this.onPrivateRoute,
  });
  final LearningCandidateStore candidates;
  final MaterialStore materials;
  final String candidateId;
  final bool Function() isCurrentScope;
  final void Function(BuildContext)? onPrivateRoute;
  @override
  State<CandidateReviewSheet> createState() => _CandidateReviewSheetState();
}

class _CandidateReviewSheetState extends State<CandidateReviewSheet> {
  Widget _privateSurface(BuildContext routeContext, Widget child) {
    widget.onPrivateRoute?.call(routeContext);
    return child;
  }

  LearningCandidate? _candidate;
  MaterialVersion? _source;
  final _english = <TextEditingController>[];
  final _chinese = <TextEditingController>[];
  bool _loading = true, _busy = false, _dirty = false, _blocked = false;
  String? _message;
  bool get _active => mounted && widget.isCurrentScope();
  bool get _editable =>
      !_loading &&
      !_busy &&
      !_blocked &&
      _candidate?.state == LearningCandidateState.pendingReview;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final candidate = await widget.candidates.readCandidate(
        widget.candidateId,
      );
      if (!_active) return;
      if (candidate.ownerId != widget.materials.trustedOwnerId ||
          candidate.ownerId != widget.candidates.trustedOwnerId) {
        throw const LearningStoreException(LearningErrorCode.ownerMismatch);
      }
      final source = await widget.materials.readVersion(
        candidate.materialVersionId,
      );
      if (!_active) return;
      for (final sentence in candidate.sentences) {
        _english.add(TextEditingController(text: sentence.english));
        _chinese.add(TextEditingController(text: sentence.translation));
      }
      setState(() {
        _candidate = candidate;
        _source = source;
        _loading = false;
      });
    } catch (_) {
      if (_active)
        setState(() {
          _loading = false;
          _blocked = true;
          _message = '候选或原文暂时无法读取，请返回后重试。';
        });
    }
  }

  @override
  void dispose() {
    for (final controller in [..._english, ..._chinese]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<LearningSentenceInput> _sentences() => [
    for (var i = 0; i < _english.length; i++)
      LearningSentenceInput(
        english: _english[i].text,
        translation: _chinese[i].text,
      ),
  ];

  void _updateDirty() {
    final saved = _candidate;
    if (saved == null) return;
    setState(
      () => _dirty = List.generate(
        _english.length,
        (i) =>
            _english[i].text != saved.sentences[i].english ||
            _chinese[i].text != saved.sentences[i].translation,
      ).any((v) => v),
    );
  }

  Future<void> _persistEdits() async {
    if (!_dirty) return;
    if (!_active) throw const LearningStoreException(LearningErrorCode.closed);
    final prior = _candidate!;
    final updated = await widget.candidates.reviseCandidate(
      candidateId: prior.candidateId,
      expectedRevision: prior.revision,
      sentences: _sentences(),
    );
    if (!_active) return;
    final stored = await widget.candidates.readCandidate(updated.candidateId);
    if (!_active) return;
    if (stored.ownerId != prior.ownerId ||
        stored.revision != updated.revision ||
        stored.state != LearningCandidateState.pendingReview) {
      throw const LearningStoreException(LearningErrorCode.revisionConflict);
    }
    setState(() {
      _candidate = stored;
      _dirty = false;
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (!_editable || !_active) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on LearningStoreException catch (error) {
      if (_active)
        setState(() {
          _blocked = switch (error.code) {
            LearningErrorCode.revisionConflict ||
            LearningErrorCode.invalidState ||
            LearningErrorCode.notFound ||
            LearningErrorCode.ownerMismatch => true,
            _ => false,
          };
          _message = switch (error.code) {
            LearningErrorCode.revisionConflict ||
            LearningErrorCode.invalidState => '候选已变化，当前输入已保留。请返回重新打开核对。',
            LearningErrorCode.bindingMismatch ||
            LearningErrorCode.notFound => '原文版本或来源不一致，请返回核对后重新送入。',
            LearningErrorCode.candidateLimitExceeded => '内容超过本次候选容量，请拆分后重新送入。',
            LearningErrorCode.invalidInput => '请检查每句英文和中文对照，不能留空。',
            LearningErrorCode.recoveryHold => '本机资料正在核验，暂不能保存或接收。请保留现有资料，稍后重试。',
            LearningErrorCode.mediaUnavailable =>
              '音频暂不可用，操作尚未确认；当前输入已保留，请稍后重试。',
            _ => '操作结果尚未确认，请先等待并查看候选列表，避免重复提交。',
          };
        });
    } catch (_) {
      if (_active) setState(() => _message = '操作尚未确认，当前输入已保留，请稍后重试。');
    } finally {
      if (_active) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _perform(() async {
    await _persistEdits();
    if (_active) setState(() => _message = '校对已保存，尚未加入学习。');
  });

  Future<void> _confirm() => _perform(() async {
    await _persistEdits();
    if (!_active) return;
    final candidate = _candidate!;
    final version = await widget.candidates.confirmCandidate(
      candidateId: candidate.candidateId,
      expectedRevision: candidate.revision,
    );
    if (!_active) return;
    final stored = await widget.candidates.readCandidate(candidate.candidateId);
    if (!_active) return;
    if (stored.state != LearningCandidateState.confirmed ||
        stored.confirmedLearningVersionId !=
            version.binding.learningVersionId ||
        version.binding.ownerId != candidate.ownerId) {
      throw const LearningStoreException(LearningErrorCode.bindingMismatch);
    }
    Navigator.of(context).pop(true);
  });

  Future<void> _reject() => _perform(() async {
    final reject = await showDialog<bool>(
      context: context,
      builder: (ctx) => _privateSurface(
        ctx,
        AlertDialog(
          title: const Text('拒绝这份候选？'),
          content: const Text('未保存的校对不会保留。原材料和已加入的学习内容不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('继续校对'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('拒绝候选'),
            ),
          ],
        ),
      ),
    );
    if (!_active || reject != true) return;
    await widget.candidates.rejectCandidate(
      candidateId: _candidate!.candidateId,
      expectedRevision: _candidate!.revision,
    );
    if (_active) Navigator.of(context).pop(true);
  });

  void _showSource() {
    final source = _source;
    if (source == null || !_active) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => _privateSurface(
        ctx,
        AlertDialog(
          title: Text('原文 · 第 ${source.versionNumber} 版'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(child: SelectableText(source.text)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('返回校对'),
            ),
          ],
        ),
      ),
    );
  }

  String _mediaSummary() {
    final candidate = _candidate!;
    final review = candidate.mediaReview;
    if (review == null) return '只有文字，音频尚未提供。';
    final changed = List.generate(
      _english.length,
      (i) => _english[i].text != candidate.sentences[i].english,
    ).any((v) => v);
    final binding = review.binding == CandidateMediaBinding.invalidated
        ? '英文曾在保存时发生变化，原配音与时间轴已失配；改回原文也不会恢复。'
        : changed
        ? '英文有未保存修改。保存后原配音与时间轴将失配；可在保存前恢复原文。'
        : '配音与已保存英文绑定一致；这不代表文件可读或专业音质已核验。';
    final issue = review.issues.contains('media_unavailable')
        ? '\n配套音频当前不可用，暂时无法读取；文字仍可校对，请稍后重试。'
        : review.issues.any((issue) => issue != 'media_english_changed')
        ? '\n音频尚未验证，暂未通过可用性检查，当前不开放播放。'
        : '';
    return '$binding$issue';
  }

  void _showDeclaration() {
    final candidate = _candidate;
    if (candidate == null || !_active) return;
    final d = candidate.declaration;
    showDialog<void>(
      context: context,
      builder: (ctx) => _privateSurface(
        ctx,
        AlertDialog(
          title: const Text('来源说明'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidate.submission.transport ==
                          CandidateTransport.controlledTest
                      ? '受控测试送入，非正式效果证明。'
                      : '通过本机授权入口送入。',
                ),
                const SizedBox(height: 12),
                const Text('以下是提供方自述，模型、版权和语言质量尚未独立核实。'),
                const Text(
                  '文字来源声明',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  '整理方式：${d.preparation}\n提供方：${d.provider ?? '未声明'}\n模型：${d.model ?? '未声明'}\n模型版本：${d.modelVersion ?? '未声明'}\n说明：${d.notes ?? '无'}',
                ),
                if (candidate.mediaReview case final review?) ...[
                  const SizedBox(height: 16),
                  const Text(
                    '音频来源声明',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Text('音频和时间轴由提供方声明，未独立核验其版权、声音权利或专业效果。'),
                  SelectableText(
                    '整理方式：${review.original.declaration.preparation}\n提供方：${review.original.declaration.provider ?? '未声明'}\n模型：${review.original.declaration.model ?? '未声明'}\n模型版本：${review.original.declaration.modelVersion ?? '未声明'}\n说明：${review.original.declaration.notes ?? '无'}\n时间轴说明：${review.original.timingDeclaration}',
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _close() async {
    if (_busy || !_active) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => _privateSurface(
          ctx,
          AlertDialog(
            title: const Text('放弃未保存的校对？'),
            content: const Text('已保存的候选和原材料会保留。'),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('继续校对'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('放弃修改'),
              ),
            ],
          ),
        ),
      );
      if (!_active || discard != true) return;
    }
    if (_active) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !_busy && !_dirty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_busy) unawaited(_close());
    },
    child: SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .9,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '校对学习候选',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('candidate-close'),
                      tooltip: '返回',
                      onPressed: _busy ? null : () => unawaited(_close()),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_message!, key: const Key('candidate-message')),
                  ),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                        children: [
                          if (_candidate != null) ...[
                            Text(
                              _candidate!.materialTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text('外部助手提供 · 请对照原文校对。'),
                            Text(
                              _mediaSummary(),
                              key: const Key('candidate-media-summary'),
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: _showSource,
                                  child: const Text('查看原文'),
                                ),
                                TextButton(
                                  onPressed: _showDeclaration,
                                  child: const Text('来源说明'),
                                ),
                              ],
                            ),
                            if (_candidate!.state !=
                                LearningCandidateState.pendingReview)
                              Text(
                                _candidate!.state ==
                                        LearningCandidateState.confirmed
                                    ? '这份候选已加入学习。'
                                    : '这份候选已拒绝，原材料仍保留。',
                              ),
                          ],
                          for (var i = 0; i < _english.length; i++) ...[
                            Text(
                              '第 ${i + 1} 句',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              key: Key('candidate-english-$i'),
                              controller: _english[i],
                              enabled: _editable,
                              minLines: 1,
                              maxLines: null,
                              onChanged: (_) => _updateDirty(),
                              decoration: const InputDecoration(
                                labelText: '英文',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              key: Key('candidate-chinese-$i'),
                              controller: _chinese[i],
                              enabled: _editable,
                              minLines: 1,
                              maxLines: null,
                              onChanged: (_) => _updateDirty(),
                              decoration: const InputDecoration(
                                labelText: '中文对照',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 18),
                          ],
                          if (_candidate?.state ==
                              LearningCandidateState.pendingReview)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          key: const Key('candidate-save'),
                                          onPressed: _editable && _dirty
                                              ? () => unawaited(_save())
                                              : null,
                                          child: const Text('保存校对'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: FilledButton(
                                          key: const Key('candidate-confirm'),
                                          onPressed: _editable
                                              ? () => unawaited(_confirm())
                                              : null,
                                          child: Text(
                                            _busy ? '正在保存…' : '确认加入学习',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  TextButton(
                                    key: const Key('candidate-reject'),
                                    onPressed: _editable
                                        ? () => unawaited(_reject())
                                        : null,
                                    child: const Text('拒绝候选'),
                                  ),
                                ],
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
