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

  /// Resolve a relative href against the chapter's directory.
  String _resolveHref(String baseHref, String relativeHref) {
    // Already absolute
    if (relativeHref.startsWith('/')) return relativeHref.substring(1);

    // Strip fragment identifier
    final hashIdx = relativeHref.indexOf('#');
    final cleanHref = hashIdx >= 0 ? relativeHref.substring(0, hashIdx) : relativeHref;
    if (cleanHref.isEmpty) return '';

    // Resolve relative to the base href's directory
    final baseDir = baseHref.contains('/') ? baseHref.substring(0, baseHref.lastIndexOf('/') + 1) : _opfDir;
    final parts = '$baseDir$cleanHref'.split('/');
    final resolved = <String>[];
    for (final part in parts) {
      if (part == '..') {
        if (resolved.isNotEmpty) resolved.removeLast();
      } else if (part != '.' && part.isNotEmpty) {
        resolved.add(part);
      }
    }
    return resolved.join('/');
  }

  /// Read file content from archive as bytes, with caching.
  List<int>? _readFileBytes(String path) {
    final file = _findFileInArchive(path);
    if (file == null) return null;
    try {
      return file.content as List<int>;
    } catch (_) {
      return null;
    }
  }

  /// Convert image bytes to a base64 data URI.
  String _bytesToDataUri(List<int> bytes, String mediaType) {
    final b64 = base64Encode(bytes);
    return 'data:$mediaType;base64,$b64';
  }

  /// Get the media type for a file extension.
  String _mediaTypeForExt(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'png': return 'image/png';
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'gif': return 'image/gif';
      case 'svg': return 'image/svg+xml';
      case 'webp': return 'image/webp';
      case 'css': return 'text/css';
      default: return 'application/octet-stream';
    }
  }

  /// Get the XHTML content of a chapter by spine index.
  /// Returns HTML suitable for flutter_html rendering.
  Future<String> getChapterHtml(int index) async {
    if (index < 0 || index >= _spine.length) return '';
    final item = _spine[index];
    final chapterHref = item.manifestItem.href;
    final fullPath = '$_opfDir$chapterHref';
    final file = _findFileInArchive(fullPath);
    if (file == null) return '<p>Chapter not found: $chapterHref</p>';

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

      // Extract and inline CSS <link> and <style> content
      content = await _inlineCss(content, chapterHref);

      // Resolve image src paths to base64 data URIs
      content = _resolveImages(content, chapterHref);

      // Extract body content
      try {
        final doc = XmlDocument.parse(content);
        // Look for body element (any namespace)
        final body = doc.descendants
            .whereType<XmlElement>()
            .where((el) => el.name.local == 'body');
        if (body.isNotEmpty) {
          final inner = body.first.innerXml;
          if (inner.trim().isNotEmpty) return inner;
        }
        // Fallback: return full document
        return doc.toXmlString();
      } on XmlException {
        // Not valid XML — return as-is (flutter_html can handle raw HTML)
        return content;
      }
    } catch (e) {
      return '<p>Error loading chapter: $e</p>';
    }
  }

  /// Inline CSS from <link> tags and <style> tags.
  Future<String> _inlineCss(String html, String chapterHref) async {
    // Use . to match either quote character
    final linkPattern = RegExp(r'<link[^>]+rel=.stylesheet.[^>]*>', caseSensitive: false);
    final hrefAttrPattern = RegExp(r'href=.([^"]*?)\.');
    String result = html.replaceAllMapped(linkPattern, (match) {
      final tag = match.group(0)!;
      final hrefMatch = hrefAttrPattern.firstMatch(tag);
      if (hrefMatch == null) return '';
      final cssHref = _resolveHref(chapterHref, hrefMatch.group(1)!);
      final cssBytes = _readFileBytes(cssHref);
      if (cssBytes == null) return '';
      final cssContent = utf8.decode(cssBytes, allowMalformed: true);
      return '<style>$cssContent</style>';
    });

    return result;
  }

  /// Resolve image src attributes to base64 data URIs.
  String _resolveImages(String html, String chapterHref) {
    // Match <img ... src="..." ... > using . for quote char
    final imgPattern = RegExp(r'<img([^>]*?)src=.([^"]+?)\.([^>]*?)', caseSensitive: false);
    return html.replaceAllMapped(imgPattern, (match) {
      final prefix = match.group(1) ?? '';
      final src = match.group(2) ?? '';
      final suffix = match.group(3) ?? '';

      // Skip data URIs and http URLs
      if (src.startsWith('data:') || src.startsWith('http://') || src.startsWith('https://')) {
        return '<img$prefix src="$src"$suffix>';
      }

      // Resolve relative path
      final resolvedPath = _resolveHref(chapterHref, src);
      final bytes = _readFileBytes(resolvedPath);
      if (bytes == null) {
        return '<img$prefix src=""$suffix>';
      }

      final mediaType = _mediaTypeForExt(resolvedPath);
      final dataUri = _bytesToDataUri(bytes, mediaType);
      return '<img$prefix src="$dataUri"$suffix>';
    });
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
          final titleEl = doc.findAllElements('title');
          if (titleEl.isNotEmpty) return titleEl.first.innerText.trim();
          final h1 = doc.findAllElements('h1');
          if (h1.isNotEmpty) return h1.first.innerText.trim();
          final h2 = doc.findAllElements('h2');
          if (h2.isNotEmpty) return h2.first.innerText.trim();
        } on XmlException {
          final titleMatch = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false)
              .firstMatch(content);
          if (titleMatch != null) return titleMatch.group(1)!.trim();
          final h1Match = RegExp(r'<h1[^>]*>([^<]+)</h1>', caseSensitive: false)
              .firstMatch(content);
          if (h1Match != null) return h1Match.group(1)!.trim();
        }
      }
    } catch (_) {}
    return _getTocTitle(index) ?? getChapterHref(index);
  }

  /// Try to get title from NCX navigation document.
  String? _getTocTitle(int spineIndex) {
    try {
      for (final item in _manifest.values) {
        if (item.mediaType == 'application/x-dtbncx+xml') {
          final fullPath = '$_opfDir${item.href}';
          final file = _findFileInArchive(fullPath);
          if (file == null) continue;
          final content = utf8.decode(file.content as List<int>, allowMalformed: true);
          final ncx = XmlDocument.parse(content);
          final spineHref = getChapterHref(spineIndex);
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
    for (int i = 0; i < _spine.length; i++) {
      if (_spine[i].manifestItem.href.contains(href) ||
          href.contains(_spine[i].manifestItem.href)) return i;
    }
    return 0;
  }

  /// Extract an image from the EPUB as bytes.
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
