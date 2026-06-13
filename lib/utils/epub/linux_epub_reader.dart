import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/utils/epub/epub_parser.dart';

/// A native EPUB reader for Linux that uses `flutter_html` instead of WebView.
/// This avoids the webkit2gtk GLX conflict on X11.
class LinuxEpubReader extends StatefulWidget {
  final Book book;
  final String? initialHref;
  final void Function(String cfi, double percentage, String chapterTitle,
      String chapterHref, int currentPage, int totalPages)? onProgressChanged;
  final void Function()? onLoadEnd;
  final void Function(Map<String, dynamic> toc)? onTocReady;
  final Color? backgroundColor;
  final Color? textColor;

  const LinuxEpubReader({
    super.key,
    required this.book,
    this.initialHref,
    this.onProgressChanged,
    this.onLoadEnd,
    this.onTocReady,
    this.backgroundColor,
    this.textColor,
  });

  @override
  State<LinuxEpubReader> createState() => _LinuxEpubReaderState();
}

class _LinuxEpubReaderState extends State<LinuxEpubReader> {
  EpubParser? _parser;
  bool _loading = true;
  String? _error;
  int _currentChapterIndex = 0;
  String _currentHtml = '';
  String _currentPlainText = '';
  bool _useHtml = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initEpub();
  }

  Future<void> _initEpub() async {
    try {
      final filePath = widget.book.fileFullPath;
      debugPrint('[LinuxEpubReader] Opening: $filePath');
      final file = File(filePath);
      if (!file.existsSync()) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '文件不存在: $filePath';
          });
        }
        return;
      }
      _parser = EpubParser(filePath);
      await _parser!.parse();
      debugPrint('[LinuxEpubReader] Parsed: ${_parser!.chapterCount} chapters');

      if (widget.initialHref != null && widget.initialHref!.isNotEmpty) {
        _currentChapterIndex = _parser!.findChapterByHref(widget.initialHref!);
      }

      await _loadChapter(_currentChapterIndex);
      _reportProgress();
      _buildToc();

      if (mounted) {
        setState(() => _loading = false);
      }
      widget.onLoadEnd?.call();
    } catch (e, st) {
      debugPrint('[LinuxEpubReader] ERROR: $e\n$st');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _loadChapter(int index) async {
    if (_parser == null || index < 0 || index >= _parser!.chapterCount) return;
    _currentChapterIndex = index;
    final rawHtml = await _parser!.getChapterHtml(index);
    debugPrint('[LinuxEpubReader] Chapter $index: ${rawHtml.length} chars');

    // Clean HTML: strip XML namespace prefixes that confuse flutter_html
    String cleaned = rawHtml
        .replaceAll(RegExp(r'xmlns[=:]"[^"]*"'), '')
        .replaceAllMapped(RegExp(r'</?[a-zA-Z]+:'), (Match m) => m.group(0)!.contains('/') ? '</' : '<')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Extract plain text as fallback
    _currentPlainText = _extractPlainText(cleaned);

    // Prepare HTML for flutter_html
    _currentHtml = cleaned;

    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
    _reportProgress();
  }

  /// Extract plain text from HTML by stripping tags
  String _extractPlainText(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void _reportProgress() {
    if (_parser == null) return;
    final title = _parser!.getChapterTitle(_currentChapterIndex);
    final href = _parser!.getChapterHref(_currentChapterIndex);
    final percentage = _parser!.chapterCount > 0
        ? (_currentChapterIndex + 1) / _parser!.chapterCount
        : 0.0;
    widget.onProgressChanged?.call(
      'epub:$_currentChapterIndex',
      percentage,
      title,
      href,
      _currentChapterIndex + 1,
      _parser!.chapterCount,
    );
  }

  void _buildToc() {
    if (_parser == null) return;
    final toc = <String, dynamic>{
      'chapters': <Map<String, dynamic>>[],
    };
    for (int i = 0; i < _parser!.chapterCount; i++) {
      (toc['chapters'] as List).add({
        'label': _parser!.getChapterTitle(i),
        'href': _parser!.getChapterHref(i),
        'index': i,
      });
    }
    widget.onTocReady?.call(toc);
  }

  void _nextChapter() {
    if (_parser == null) return;
    if (_currentChapterIndex < _parser!.chapterCount - 1) {
      _loadChapter(_currentChapterIndex + 1);
    }
  }

  void _prevChapter() {
    if (_currentChapterIndex > 0) {
      _loadChapter(_currentChapterIndex - 1);
    }
  }

  Widget _buildContent() {
    final fgColor = widget.textColor ?? Colors.black87;

    // Try HTML rendering first
    if (_useHtml && _currentHtml.isNotEmpty) {
      try {
        return Html(
          data: _currentHtml,
          style: {
            'body': Style(
              color: fgColor,
              fontSize: FontSize(18),
              lineHeight: LineHeight(1.8),
            ),
            'p': Style(
              color: fgColor,
              fontSize: FontSize(18),
              margin: Margins.only(bottom: 12),
            ),
            'div': Style(
              color: fgColor,
              fontSize: FontSize(18),
              lineHeight: LineHeight(1.8),
            ),
            'h1': Style(
              color: fgColor,
              fontSize: FontSize(28),
              fontWeight: FontWeight.bold,
            ),
            'h2': Style(
              color: fgColor,
              fontSize: FontSize(24),
              fontWeight: FontWeight.bold,
            ),
            'h3': Style(
              color: fgColor,
              fontSize: FontSize(20),
              fontWeight: FontWeight.bold,
            ),
            'h4': Style(
              color: fgColor,
              fontSize: FontSize(18),
              fontWeight: FontWeight.bold,
            ),
            'span': Style(color: fgColor),
            'a': Style(
              color: Theme.of(context).colorScheme.primary,
            ),
          },
        );
      } catch (e) {
        debugPrint('[LinuxEpubReader] flutter_html exception: $e');
        _useHtml = false;
        return _buildPlainText(fgColor);
      }
    }

    // Fallback: plain text
    return _buildPlainText(fgColor);
  }

  Widget _buildPlainText(Color fgColor) {
    return SelectableText(
      _currentPlainText,
      style: TextStyle(
        color: fgColor,
        fontSize: 18,
        height: 1.8,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('加载失败: $_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                    _useHtml = true;
                  });
                  _initEpub();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final bgColor = widget.backgroundColor ?? Colors.white;
    final fgColor = widget.textColor ?? Colors.black87;

    return ColoredBox(
      color: bgColor,
      child: Column(
        children: [
          // Chapter header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (_currentChapterIndex > 0)
                  IconButton(
                    icon: const Icon(Icons.chevron_left, size: 20),
                    onPressed: _prevChapter,
                    tooltip: '上一章',
                  ),
                Expanded(
                  child: Text(
                    _parser?.getChapterTitle(_currentChapterIndex) ?? '',
                    style: TextStyle(
                      fontSize: 14,
                      color: fgColor.withOpacity(0.7),
                    ),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_parser != null &&
                    _currentChapterIndex < _parser!.chapterCount - 1)
                  IconButton(
                    icon: const Icon(Icons.chevron_right, size: 20),
                    onPressed: _nextChapter,
                    tooltip: '下一章',
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Chapter content
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              itemCount: 1,
              itemBuilder: (context, index) {
                return _buildContent();
              },
            ),
          ),
          // Bottom navigation bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: bgColor,
              border: Border(
                top: BorderSide(color: fgColor.withOpacity(0.1)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_currentChapterIndex + 1} / ${_parser?.chapterCount ?? 0}',
                  style: TextStyle(fontSize: 13, color: fgColor.withOpacity(0.5)),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.fast_rewind, size: 18),
                      onPressed: _currentChapterIndex > 0 ? _prevChapter : null,
                      tooltip: '上一章',
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.fast_forward, size: 18),
                      onPressed: _parser != null &&
                              _currentChapterIndex < _parser!.chapterCount - 1
                          ? _nextChapter
                          : null,
                      tooltip: '下一章',
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}
