import 'package:dio/dio.dart';

import 'config.dart';

/// Error surfaced to the UI with the server's message.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get needsPlan => statusCode == 402;

  @override
  String toString() => message;
}

/// Thin wrapper over Dio: attaches the bearer token, unwraps JSON and maps errors to [ApiException].
class ApiClient {
  ApiClient({required this.onUnauthorized})
      : _dio = Dio(BaseOptions(
          baseUrl: AppConfig.apiUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          contentType: Headers.jsonContentType,
        ));

  final Dio _dio;
  final void Function() onUnauthorized;
  String? token;

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _dio.get(path, queryParameters: _clean(query), options: _options()));

  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      _send(() => _dio.post(path, data: body, options: _options()));

  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      _send(() => _dio.patch(path, data: body, options: _options()));

  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      _send(() => _dio.put(path, data: body, options: _options()));

  Future<Map<String, dynamic>> delete(String path) => _send(() => _dio.delete(path, options: _options()));

  /// Multipart upload of a local image file (field "file"). Returns the JSON response.
  Future<Map<String, dynamic>> uploadImage(String path, String filePath, {void Function(double)? onProgress}) {
    final lower = filePath.toLowerCase();
    final subtype = lower.endsWith('.png') ? 'png' : (lower.endsWith('.webp') ? 'webp' : 'jpeg');
    return _send(() async => _dio.post(
          path,
          data: FormData.fromMap({
            'file': await MultipartFile.fromFile(filePath, contentType: DioMediaType('image', subtype)),
          }),
          options: _options().copyWith(contentType: 'multipart/form-data', sendTimeout: const Duration(seconds: 60)),
          onSendProgress: onProgress == null ? null : (sent, total) => total > 0 ? onProgress(sent / total) : null,
        ));
  }

  Options _options() => Options(headers: {if (token != null) 'Authorization': 'Bearer $token'});

  Map<String, dynamic>? _clean(Map<String, dynamic>? q) =>
      q == null ? null : (Map.of(q)..removeWhere((_, v) => v == null || v == ''));

  Future<Map<String, dynamic>> _send(Future<Response<dynamic>> Function() request) async {
    try {
      final res = await request();
      final data = res.data;
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final data = e.response?.data;
      if (status == 401 && token != null) onUnauthorized();
      final serverMessage = data is Map ? data['error'] as String? : null;
      throw ApiException(serverMessage ?? _networkMessage(e), statusCode: status);
    }
  }

  String _networkMessage(DioException e) => switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout =>
          'The server is taking too long. Please try again.',
        DioExceptionType.connectionError => 'Can\'t reach FITKEY. Check your internet connection.',
        _ => 'Something went wrong. Please try again.',
      };
}
