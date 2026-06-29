import 'package:dio/dio.dart';
import 'package:grpc/grpc.dart';
import 'package:zeon/core/localization/translations.dart';

typedef PresentableError = ({String type, String? message});

mixin Failure {
  ({String type, String? message}) present(TranslationsEn t);
}

/// failures that are not expected to happen but depending on [error] type might not be relevant (eg network errors)
mixin UnexpectedFailure {
  Object? get error;
  StackTrace? get stackTrace;
}

/// failures that are expected to happen and should be handled by the app
/// and should be logged, eg missing permissions
mixin ExpectedMeasuredFailure {}

/// failures ignored by analytics service etc.
mixin ExpectedFailure {}

extension ErrorPresenter on TranslationsEn {
  PresentableError errorToPair(Object error) => switch (error) {
    GrpcError(message: final nestedErr?) => errorToPair(nestedErr),
    UnexpectedFailure(error: final nestedErr?) => errorToPair(nestedErr),
    Failure() => error.present(this),
    DioException() => error.present(this),
    _ => (type: errors.unexpected, message: error.toString()),
  };

  PresentableError presentError(Object error, {String? action}) {
    final pair = errorToPair(error);
    if (action == null) return pair;
    return (type: action, message: pair.type + (pair.message == null ? "" : "\n${pair.message!}"));
  }

  String presentShortError(Object error, {String? action}) {
    final pair = errorToPair(error);
    final message = pair.message;
    final errorText = message == null || message.trim().isEmpty ? pair.type : "${pair.type}: $message";
    if (action == null) return errorText;
    return "$action: $errorText";
  }

  String diagnosticError(Object error, {String? action, StackTrace? stackTrace}) {
    final pair = presentError(error, action: action);
    final buffer = StringBuffer()
      ..writeln(pair.type)
      ..writeln(pair.message ?? '');

    void writeObject(Object value, [StackTrace? fallbackStackTrace]) {
      switch (value) {
        case GrpcError(message: final nested?):
          buffer
            ..writeln()
            ..writeln('Caused by:')
            ..writeln(nested);
          writeObject(nested);
        case UnexpectedFailure(error: final nested?, :final stackTrace):
          buffer
            ..writeln()
            ..writeln('Caused by:')
            ..writeln(nested);
          writeObject(nested, stackTrace ?? fallbackStackTrace);
        case UnexpectedFailure(:final error, :final stackTrace):
          if (error != null) {
            buffer
              ..writeln()
              ..writeln('Error:')
              ..writeln(error);
          }
          final trace = stackTrace ?? fallbackStackTrace;
          if (trace != null) {
            buffer
              ..writeln()
              ..writeln('Stack trace:')
              ..writeln(trace);
          }
        case DioException(:final message, :final response):
          buffer
            ..writeln()
            ..writeln('DioException:')
            ..writeln(message ?? value.toString());
          if (response != null) {
            buffer
              ..writeln('Status: ${response.statusCode}')
              ..writeln('Response: ${response.data}');
          }
          if (fallbackStackTrace != null) {
            buffer
              ..writeln()
              ..writeln('Stack trace:')
              ..writeln(fallbackStackTrace);
          }
        default:
          buffer
            ..writeln()
            ..writeln('Error:')
            ..writeln(value);
          if (fallbackStackTrace != null) {
            buffer
              ..writeln()
              ..writeln('Stack trace:')
              ..writeln(fallbackStackTrace);
          }
      }
    }

    writeObject(error, stackTrace);
    return buffer.toString().trim();
  }
}

extension DioExceptionPresenter on DioException {
  PresentableError present(TranslationsEn t) => switch (type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => (type: t.errors.connection.timeout, message: null),
    DioExceptionType.badCertificate => (type: t.errors.connection.badCertificate, message: message),
    DioExceptionType.badResponse => (type: t.errors.connection.badResponse, message: message),
    DioExceptionType.connectionError => (type: t.errors.connection.connectionError, message: message),
    _ => (type: t.errors.connection.unexpected, message: message),
  };
}
