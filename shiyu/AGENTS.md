# Shiyu engineering rules

- Follow the reviewed product → requirements → architecture → implementation → human acceptance → staged release process. Do not expand a feasibility experiment into product implementation without the appropriate review.
- The product manager owns the next work item; architects resolve internal design/build blockers. Each item requires independent expert/QA acceptance with scoped evidence before advancing. Preserve failed runs and do not weaken assertions to obtain approval.
- Continue already authorized reversible work after a gate passes. Escalate actual user decisions, external resources/data/cost, human acceptance or release boundaries only after a concrete reviewable result is prepared; do not repeatedly ask the user to choose implementation parameters.
- Use the newest approved prototype; navigation is 学习、材料、添加、分享、我的. Adding materials and sharing works are separate flows.
- Keep reading content, playback/progress, practice controls, and the compact bottom dictionary in the agreed order.
- Professional acoustic assessment is required for pronunciation scoring. ASR text similarity is not pronunciation accuracy.
- Preserve four-platform scope; distinguish built, statically checked, locally tested, device verified, and released.
- Never commit user recordings, private material, credentials, browser profiles, SDK/cache/build directories, local receipts, signing keys or device identifiers. Use synthetic fixtures.
- SDK terms, privacy grants and device consent belong to the current user/environment; do not inherit a previous operator's approval from code.
- Keep `pubspec.lock`; do not silently change dependency versions. Review merged Android permissions and retain system-document-picker/private-storage boundaries.
- Use isolated local test services and adapters; no production data/service changes or automatic sharing.
- Routine reversible engineering work and scoped Git delivery can proceed under the user's stated authorization; do not repeatedly ask users to pick framework parameters. Respect actual external data, cost, device and release boundaries.
- End engineering replies with the current stage, next recommended action, and user action required (none when none). Do not claim work continues after the turn without an actual running task.

- Unattended work must not activate host desktop windows, move the mouse, send keyboard input, lock the computer or play host audio. Use background builds/tests and explicitly hidden, muted, task-owned probes. Defer real desktop input, lock/unlock and audible acceptance until the user explicitly agrees to participate. Do not let a first-frame Show/SetFocus defeat a hidden test flag.
