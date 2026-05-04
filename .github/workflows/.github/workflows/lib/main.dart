import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

void main() {
  runApp(const FakeyArApp());
}

class FakeyArApp extends StatelessWidget {
  const FakeyArApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مترجم المانهوا',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF6B6B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const BrowserScreen(),
    );
  }
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  InAppWebViewController? _webViewController;
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  bool _isTranslating = false;
  String _status = 'جاهز للترجمة';
  String _apiKey = '';
  double _progress = 0;

  // مفتاح OpenRouter API
  static const String _defaultApiKey = 'YOUR_OPENROUTER_KEY_HERE';

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKey = prefs.getString('api_key') ?? _defaultApiKey;
    });
  }

  Future<void> _saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', key);
    setState(() => _apiKey = key);
  }

  void _loadUrl(String url) {
    if (!url.startsWith('http')) url = 'https://$url';
    _urlController.text = url;
    _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri(url)),
    );
  }

  Future<void> _translatePage() async {
    if (_isTranslating) return;
    if (_apiKey.isEmpty || _apiKey == 'YOUR_OPENROUTER_KEY_HERE') {
      _showApiKeyDialog();
      return;
    }

    setState(() {
      _isTranslating = true;
      _status = 'جاري تحليل الصفحة...';
      _progress = 0;
    });

    try {
      // حقن JavaScript لاستخراج الصور
      final result = await _webViewController?.evaluateJavascript(source: '''
(function() {
  var imgs = Array.from(document.querySelectorAll('img'));
  var validImgs = imgs.filter(function(img) {
    var w = img.naturalWidth || img.width;
    var h = img.naturalHeight || img.height;
    var rect = img.getBoundingClientRect();
    return w > 200 && h > 300 && rect.width > 100 &&
           !img.src.includes('avatar') &&
           !img.src.includes('logo') &&
           !img.src.includes('icon');
  });
  
  return validImgs.map(function(img) {
    var canvas = document.createElement('canvas');
    var maxW = 800;
    var w = img.naturalWidth;
    var h = img.naturalHeight;
    if (w > maxW) { h = h * maxW / w; w = maxW; }
    canvas.width = w;
    canvas.height = h;
    var ctx = canvas.getContext('2d');
    ctx.drawImage(img, 0, 0, w, h);
    return {
      src: img.src,
      base64: canvas.toDataURL('image/jpeg', 0.7).split(',')[1],
      id: img.id || Math.random().toString(36).substr(2,9)
    };
  }).filter(function(item) { return item.base64 && item.base64.length > 100; });
})();
''');

      if (result == null) {
        setState(() {
          _status = 'لم يتم العثور على صور';
          _isTranslating = false;
        });
        return;
      }

      final images = List<Map>.from(result as List);

      if (images.isEmpty) {
        setState(() {
          _status = 'لم يتم العثور على صور مانهوا';
          _isTranslating = false;
        });
        return;
      }

      setState(() => _status = 'ترجمة ${images.length} صورة...');

      for (int i = 0; i < images.length; i++) {
        if (!_isTranslating) break;

        setState(() {
          _progress = (i + 1) / images.length;
          _status = 'ترجمة صورة ${i + 1} من ${images.length}...';
        });

        final img = images[i];
        final translations = await _translateImage(img['base64'] as String);

        if (translations != null && translations.isNotEmpty) {
          await _applyTranslations(img['src'] as String, translations);
        }

        await Future.delayed(const Duration(milliseconds: 300));
      }

      setState(() {
        _status = '✓ تمت الترجمة بنجاح!';
        _isTranslating = false;
        _progress = 0;
      });

    } catch (e) {
      setState(() {
        _status = 'خطأ: ${e.toString()}';
        _isTranslating = false;
        _progress = 0;
      });
    }
  }

  Future<List<Map>?> _translateImage(String base64) async {
    try {
      final response = await http.post(
        Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://fakey-ar.app',
          'X-Title': 'FakeyAr',
        },
        body: jsonEncode({
          'model': 'anthropic/claude-sonnet-4-5',
          'max_tokens': 1000,
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/jpeg;base64,$base64'
                  }
                },
                {
                  'type': 'text',
                  'text': '''أنت خبير ترجمة مانهوا. ابحث عن كل النصوص في فقاعات الكلام وترجمها للعربية.
أرجع JSON فقط بهذا الشكل:
{"has_text": true, "translations": [{"original": "النص", "translated": "الترجمة", "position": "top/middle/bottom"}]}
إذا لا يوجد نص: {"has_text": false, "translations": []}'''
                }
              ]
            }
          ],
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final content = data['choices'][0]['message']['content'] as Stri
