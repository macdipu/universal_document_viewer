# Security policy

universal_document_viewer reads files that may come from anywhere: email attachments, downloads, other apps. Its parsers (PDF through PDFium; Word, Excel, CSV, PowerPoint and text in Dart) are therefore its most security-sensitive parts.

## Reporting a vulnerability

Please **don't open a public issue**. Report privately through GitHub instead: [Report a vulnerability](https://github.com/macdipu/universal_document_viewer/security/advisories/new).

Include:

- the package version (or commit) and platform;
- what happens: a crash, a hang, runaway memory, reading outside the archive, and so on;
- the file that triggers it, if you can share it, or how to build one.

You'll get an answer within a week. Once it's fixed, a patch release goes out and the advisory is published, crediting you unless you'd rather not be named.

## In scope

- A document that crashes the app, hangs it, or makes it use unbounded memory or disk.
- An Office file whose ZIP paths or declared sizes get past `ZipSafetyGuard`.
- Links in a document that open something other than `http`, `https` or `mailto` without the app's consent.

## Out of scope

- Bugs in PDFium itself: report those to [PDFium](https://pdfium.googlesource.com/pdfium/). We'll update the pinned build once they're fixed.
- A document that merely renders wrongly. That's a normal bug; please open an issue.

## Supported versions

Fixes go into the latest release only.
