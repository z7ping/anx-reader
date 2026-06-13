import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Lightweight EPUB parser using the `archive` package.
/// Extracts spine order and chapter XHTML content without JavaScript.
class EpubParser {
  final String filePath;
  late Archive _archive;
  late String _opfDir; // base directory of the OPF file
  late XmlDocument _opfDoc;
  late List<_SpineItem> _spine;
  late Map<String, _ManifestItem> _manifest;

  EpubParser(this.filePath);

  /// Parse the EPUB file and extract structure.
  Future<void> parse() async {
    final bytes = await File(filePath).readAsBytes();
    _archive = ZipDecoder().decodeBytes(bytes);

    // 1. Read META-INF/container.xml to find the OPF path
    final containerFile = _archive.findFile('META-INF/container.xml');
    if (containerFile == null) throw Exception('Invalid EPUB: no container.xml');
    final containerXml = XmlDocument.parse(
      utf8.decode(containerFile.content as List<int>),
    );
    final rootfile = containerXml.findAllElements('rootfile').first;
    final opfPath = rootfile.getAttribute('full-path') ?? 'content.opf';

    // 2. Determine OPF base directory
    final lastSlash = opfPath.lastIndexOf('/');
    _opfDir = lastSlash >= 0 ? opfPath.substring(0, lastSlash + 1) : '';

    // 3. Parse the OPF
    final opfFile = _archive.findFile(opfPath);
    if (opfFile == null) throw Exception('Invalid EPUB: OPF not found at $opfPath');
    _opfDoc = XmlDocument.parse(utf8.decode(opfFile.content as List<int>));

    // 4. Build manifest map
    _manifest = {};
    final manifestEl = _opfDoc.findAllElements('manifest').first;
    for (final item in manifestEl.findAllElements('item')) {
      final id = item.getAttribute('id') ?? '';
      final href = item.getAttribute('href') ?? '';
      final mediaType = item.getAttribute('media-type') ?? '';
      _manifest[id] = _ManifestItem(id: id, href: href, mediaType: mediaType);
    }

    // 5. Build spine list
    final spineEl = _opfDoc.findAllElements('spine').first;
    _spine = [];
    for (final itemref in spineEl.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref') ?? '';
      final manifestItem = _manifest[idref];
      if (manifestItem != null) {
        _spine.add(_SpineItem(idref: idref, manifestItem: manifestItem));
      }
    }
  }

  /// Book title from OPF metadata.
  String get title {
    try {
      final metadata = _opfDoc.findAllElements('metadata').first;
      final dcTitle = metadata.findAllElements('dc:title');
      if (dcTitle.isNotEmpty) return dcTitle.first.innerText;
    } catch (_) {}
    return filePath.split('/').last;
  }

  /// Total number of spine items (chapters).
  int get chapterCount => _spine.length;

  /// Find a file in the archive, trying multiple path variations.
  ArchiveFile? _findFileInArchive(String path) {
    // Try exact path
    var file = _archive.findFile(path);
    if (file != null) return file;

    // Try URL-decoded path
    try {
      final decoded = Uri.decodeComponent(path);
      file = _archive.findFile(decoded);
      if (file != null) return file;
    } catch (_) {}

    // Try case-insensitive search
    final lowerPath = path.toLowerCase();
    for (final entry in _archive) {
      if (entry.name.toLowerCase() == lowerPath) return entry;
    }

    return null;
  }

  /// Get the XHTML content of a chapter by spine index.
  /// Returns HTML suitable for rendering.
  Future<String> getChapterHtml(int index) async {
    if (index < 0 || index >= _spine.length) return '';
    final item = _spine[index];
    final fullPath = '$_opfDir${item.manifestItem.href}';
    final file = _findFileInArchive(fullPath);
    if (file == null) return '<p>Chapter not found: ${item.manifestItem.href}</p>';

    try {
      final bytes = file.content as List<int>;
      String content;
      // Detect encoding from BOM or content
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        content = utf8.decode(bytes.sublist(3));
      } else {
        content = utf8.decode(bytes, allowMalformed: true);
      }

      // Try XML parsing to extract <body> content
      try {
        final doc = XmlDocument.parse(content);
        // Look for body element (with or without namespace)
        final body = doc.findAllElements('body');
        if (body.isNotEmpty) {
          return body.first.innerXml;
        }
        // Try with namespace prefix
        final allElements = doc.descendants.whereType<XmlElement>();
        for (final el in allElements) {
          if (el.name.local == 'body') {
            return el.innerXml;
          }
        }
        // Fallback: return the full document as string
        return doc.toXmlString();
      } on XmlException {
        // Not valid XML — treat as raw HTML
        return content;
      }
    } catch (e) {
      return '<p>Error loading chapter: $e</p>';
    }
  }

  /// Get chapter href (for tracking position).
  String getChapterHref(int index) {
    if (index < 0 || index >= _spine.length) return '';
    return _spine[index].manifestItem.href;
  }

  /// Get chapter title from the TOC or fallback to href.
  String getChapterTitle(int index) {
    try {
      final href = getChapterHref(index);
      final fullPath = '$_opfDir$href';
      final file = _findFileInArchive(fullPath);
      if (file != null) {
        final content = utf8.decode(file.content as List<int>, allowMalformed: true);
        try {
          final doc = XmlDocument.parse(content);
          // Look for <title> or first <h1>/<h2>
          final titleEl = doc.findAllElements('title');
          if (titleEl.isNotEmpty) return titleEl.first.innerText.trim();
          final h1 = doc.findAllElements('h1');
          if (h1.isNotEmpty) return h1.first.innerText.trim();
          final h2 = doc.findAllElements('h2');
          if (h2.isNotEmpty) return h2.first.innerText.trim();
        } on XmlException {
          // Try regex extraction from raw HTML
          final titleMatch = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false)
              .firstMatch(content);
          if (titleMatch != null) return titleMatch.group(1)!.trim();
          final h1Match = RegExp(r'<h1[^>]*>([^<]+)</h1>', caseSensitive: false)
              .firstMatch(content);
          if (h1Match != null) return h1Match.group(1)!.trim();
        }
      }
    } catch (_) {}
    // Fallback: try to get a nice title from the TOC/NCX
    return _getTocTitle(index) ?? getChapterHref(index);
  }

  /// Try to get title from NCX navigation document.
  String? _getTocTitle(int spineIndex) {
    try {
      // Find NCX file from manifest
      for (final item in _manifest.values) {
        if (item.mediaType == 'application/x-dtbncx+xml') {
          final fullPath = '$_opfDir${item.href}';
          final file = _findFileInArchive(fullPath);
          if (file == null) continue;
          final content = utf8.decode(file.content as List<int>, allowMalformed: true);
          final ncx = XmlDocument.parse(content);
          // Get the href for this spine index
          final spineHref = getChapterHref(spineIndex);
          // Search navPoints for matching src
          final navPoints = ncx.findAllElements('navPoint');
          for (final np in navPoints) {
            final contentEl = np.findAllElements('content').firstOrNull;
            final src = contentEl?.getAttribute('src') ?? '';
            if (src == spineHref || src.startsWith(spineHref)) {
              final label = np.findAllElements('navLabel').firstOrNull;
              final text = label?.findAllElements('text').firstOrNull;
              if (text != null) return text.innerText.trim();
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Find the spine index closest to a given href.
  int findChapterByHref(String href) {
    for (int i = 0; i < _spine.length; i++) {
      if (_spine[i].manifestItem.href == href) return i;
    }
    // Partial match
    for (int i = 0; i < _spine.length; i++) {
      if (_spine[i].manifestItem.href.contains(href) ||
          href.contains(_spine[i].manifestItem.href)) return i;
    }
    return 0;
  }

  /// Extract an image from the EPUB as bytes.
  /// [href] is the path relative to the OPF directory.
  List<int>? getImage(String href) {
    final fullPath = '$_opfDir$href';
    final file = _findFileInArchive(fullPath);
    if (file == null) return null;
    return file.content as List<int>;
  }
}

class _ManifestItem {
  final String id;
  final String href;
  final String mediaType;
  _ManifestItem({required this.id, required this.href, required this.mediaType});
}

class _SpineItem {
  final String idref;
  final _ManifestItem manifestItem;
  _SpineItem({required this.idref, required this.manifestItem});
}
