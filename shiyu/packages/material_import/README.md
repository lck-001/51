# material_import

Pure Dart TXT/DOCX extraction and narrow import-session contracts. The parser
creates no UI, file picker, Store, native application, network request or worker.
The application owns native bounded staging, the killable parser isolate,
session cancellation, user correction and actual MaterialStore persistence.

`extractMaterial(bytes:, filenameHint:, limits:)` returns exact extracted text,
source-byte and normalized-text SHA-256, UTF-16 offsets into that exact text,
block kinds/order/OOXML part names, stable warning enums and parser version.
It never returns an OS path. Filename hints select one of the supported adapters;
a DOCX must still have a real validated ZIP/OPC container. DOC/DOCM/PDF/PPTX and
unknown file types fail explicitly, rather than becoming successful empty text.

TXT supports strict UTF-8 (optional BOM) and UTF-16LE/BE with BOM. Odd UTF-16,
unpaired surrogates, malformed UTF-8 and binary control characters fail. CRLF/CR
normalize to LF; paragraph whitespace, Chinese and emoji remain. Unknown legacy
code pages are not guessed. Empty or over-budget output is not saved/truncated.

DOCX supports Transitional and Strict WordprocessingML namespace URIs with
arbitrary prefixes, ordinary paragraphs, explicit tabs/line breaks, and simple
tables in body order (LF between rows, TAB between cells, LF between cell
paragraphs). Blocks refer to extracted text, not later user-edited drafts.
Styles/layout are omitted. Images, headers/footers, comments/notes, embedded
objects/formulas/textboxes and tracked revisions are not represented as complete
content; detected omissions produce warnings. Nested table content is explicitly
omitted as an embedded object. Revisions are omitted rather than silently choosing
an accepted/rejected revision. Normal hyperlink text may remain, but external
relationships only produce a warning; no target is opened or downloaded.

## Resource and package checks

Exact `archive:4.6.0`, `xml:7.1.0`, `crypto:3.0.8`; locks/dependency resolution are
owned by the architecture task. No ZipDecoder, full archive extraction or path
write occurs. ZipDirectory.headers lazily enumerates the central directory; a
small metadata check additionally compares raw local/central names, flags,
methods, sizes, CRC claims and optional data descriptors, which the archive
library's local-name skip alone cannot establish. Duplicate/case-conflicting
parts, path traversal/ambiguity, links/special file modes, encryption, macro
content and overlapping entries fail. Initial safety policy rejects ZIP64,
Unicode-path extra-field renaming, legacy non-ASCII filename code pages and
self-extracting/prefixed ZIPs; this is not universal OOXML compatibility.

Every entry, including ignored binary parts, is actually streamed through a
counting/CRC output sink. Per-entry and cumulative output caps apply before
retention; discarded parts are not retained. Metadata claims never authorize
unbounded output. XML-sized parts are retained only within the configured XML-byte
budget, checked before each retention; XML uses a validated event iterator,
not a DOM. All recognized XML/relationship parts, even ignored styles/headers,
get strict decoding, DTD/entity refusal, character checks, depth/event/attribute
caps (event budget cumulative across parts) and explicit document/nesting/namespace
validation. Standard XML entities
work; unknown or bare entities fail rather than using upstream's permissive
fallback. Root relationships and main-part content type are verified.

Limits are the reviewed first-slice candidates, not proven universal device
capacity: compressed source20MiB, entry16MiB, cumulative inflated64MiB,
XML8MiB, text200000 code points, entries2048, depth128, events500000 and
attributes128 per element. Over-budget input requires splitting, never silent
truncation. Native compressed-output chunks have their own bounded transient
allocation; these counters do not claim a precise maximum process RSS. Parser
timeouts/cancellation require the app's real isolate termination; a Future timeout
around this synchronous function would not stop it.

No additional ratio heuristic is imposed: actual per-entry/cumulative output caps
apply even to extreme compression ratios, and the app must enforce the worker
deadline. This bounds work without rejecting a valid highly repetitive document
merely for being efficiently compressed.

## Verification

`test/implementation_regression.dart` contains implementation-side, original
synthetic fixtures. Independent acceptance belongs to the separate reviewer and
`test/extractor_independent.dart`. Neither suite uses private/user documents.
Recorded results are added only after actual runs; no native picker, Android/iOS/
macOS/Windows app integration, device memory baseline, or user acceptance follows
from pure-parser tests alone.

Implementation-side actual run:

```text
dart analyze lib/src test/implementation_regression.dart
No issues found!
dart run test/implementation_regression.dart
RESULT passed=11 failed=0 total=11
```

The representative synthetic 1000-paragraph DOCX produced all 1000 mapped blocks,
48889 text code points from a3763-byte ZIP. One final Windows Dart run took74ms;
the whole process max RSS was363921408 bytes, including JIT/compiler/runtime.
That number is not incremental parser memory, Android memory, a production latency
promise or proof that every candidate-limit-sized document is safe on every device.
Native staging caps, worker cancellation/deadline, actual Store persistence and
App flows require their own tests and independent review.
