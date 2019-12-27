import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sheety_gui/services/payload/basic_payload.dart';
import 'package:sheety_gui/services/payload/code_execution_callback_response.dart';
import 'package:sheety_gui/services/payload/code_execution_request.dart';
import 'package:sheety_gui/services/payload/code_execution_response.dart';
import 'package:sheety_gui/services/payload/error_payload.dart';
import 'package:sheety_gui/services/payload/list_request.dart';
import 'package:sheety_gui/services/payload/list_response.dart';
import 'package:sheety_gui/services/payload_type.dart';
import 'package:uuid/uuid.dart';

final Uuid _uuid = Uuid();

class JavaConnectorService {
  bool connected = false;

  Socket _socket;

  Map<String, Request> waiting = {};

  Future<ListResponse> send() async {
    var completer = Completer<ListResponse>();

    sendRequest(
        payload: ListRequest('Query'),
        response: (response) => completer.complete(response));

    return completer.future;
  }

  Future<void> connect() async {
    print('Connecting...');

    await socketStart((data) {
      var json = jsonDecode(data);
      var basicPayload = BasicPayload.fromJson(json);

      if (!basicPayload.type.receivable) {
        print('Received payload that is not receivable! ${basicPayload.type}');
        return;
      }

      var uuid = basicPayload.state;

      ({
        PayloadType.ERROR: () {
          var error = ErrorPayload.fromJson(json);
          waiting[uuid]?.error(error);
        },
        PayloadType.LIST_RESPONSE: () {
          var response = ListResponse.fromJson(json);
          waiting[uuid]?.response(response);
        },
        PayloadType.CODE_EXECUTION_RESPONSE: () {
          var response = CodeExecutionResponse.fromJson(json);
          waiting[uuid]?.response(response);
        },
        PayloadType.CODE_EXECUTION_CALLBACK_RESPONSE: () {
          var response = CodeExecutionCallbackResponse.fromJson(json);

          var codeExecutionRequest = waiting[uuid] as CallbackRequest;
          codeExecutionRequest?.callback[response.callbackState]
              ?.call(response);
        },
      }[basicPayload.type])();
    });
  }

  Future<void> socketStart(Function(String) onReceive) async {
    _socket = await Socket.connect('localhost', 4567);
    print('Connected to: '
        '${_socket.remoteAddress.address}:${_socket.remotePort}');

    _socket.listen((input) {
      var string = String.fromCharCodes(input);
      onReceive(string);
    });
  }

  void sendRequest<T>(
      {BasicPayload payload,
        Function(T) response,
      Map<String, Function(CodeExecutionCallbackResponse)> callback,
      Function(ErrorPayload) error}) {
    assert(callback == null || payload is CodeExecutionRequest,
        'A callback can only be defined if a CodeExecutionRequest is being sent');
    var uuid = _uuid.v4();
    payload.state = uuid;
    write(jsonEncode(payload.toJson()));

    error ??= (error) {
      print(
          'Error received while sending request: ${error.message}\n${error.stacktrace}');
    };

    if (callback != null) {
      waiting[uuid] = CallbackRequest(
          response: (t) => response(t), callback: callback, error: error);
    } else {
      waiting[uuid] = BasicRequest(response: (payload) {
        waiting.remove(uuid);
        response(payload);
      }, error: (payload) {
        waiting.remove(uuid);
        error(payload);
      });
    }
  }

  void write(String data) => _socket.writeln(data);
}

abstract class Request {
  void Function(dynamic) response;
  void Function(ErrorPayload error) error;

  Request(this.response, this.error);
}

class BasicRequest extends Request {
  BasicRequest({Function(dynamic) response, Function(ErrorPayload) error})
      : super(response, error);
}

class CallbackRequest<T> extends Request {
  Map<String, Function(CodeExecutionCallbackResponse)> callback;

  CallbackRequest(
      {Function(dynamic) response,
      this.callback,
      Function(ErrorPayload) error})
      : super(response, error);
}
