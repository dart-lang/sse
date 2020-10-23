// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:html';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

/// A client for bi-directional sse communcation.
///
/// The client can send any JSON-encodable messages to the server with optional
/// guaranteed order and listen to messages from the server on the [stream].
class SseClient {
  final _incomingController = StreamController<String>();

  final _outgoingController = StreamController<String>();

  final _logger = Logger('SseClient');

  EventSource _eventSource;

  String _serverUrl;

  Timer _errorTimer;

  /// [serverUrl] is the URL under which the server is listening for
  /// incoming bi-directional SSE connections.
  SseClient(String serverUrl) {
    var clientId = Uuid().v1();
    _eventSource =
        EventSource('$serverUrl?sseClientId=$clientId', withCredentials: true);
    _serverUrl = '$serverUrl?sseClientId=$clientId';
    _outgoingController.stream
        .listen(_onOutgoingMessage, onDone: _onOutgoingDone);
    _eventSource.addEventListener('message', _onIncomingMessage);
    _eventSource.addEventListener('control', _onIncomingControlMessage);
    _eventSource.onOpen.listen((_) {
      _errorTimer?.cancel();
    });
    _eventSource.onError.listen((error) {
      if (!(_errorTimer?.isActive ?? false)) {
        // By default the SSE client uses keep-alive.
        // Allow for a retry to connect before giving up.
        _errorTimer = Timer(const Duration(seconds: 5), () {
          _incomingController.addError(error);
          close();
        });
      }
    });

    _startPostingOrderedMessages();
  }

  Stream<Event> get onOpen => _eventSource.onOpen;

  /// Sends a JSON encodable message to the server.
  ///
  /// Messages can be recieved out of order unless [ordered] is true. Note that
  /// performance is impacted when order is guaranteed.
  ///
  /// Messages that fail to encode will be logged through a [Logger]
  void send(String message, {bool ordered}) {
    ordered ??= false;
    if (ordered) {
      _outgoingController.sink.add(message);
    } else {
      _encodeAndSend(message);
    }
  }

  /// [Stream] of messages sent from the server to this client.
  ///
  /// A message is a decoded JSON object.
  Stream<String> get stream => _incomingController.stream;

  void close() {
    _eventSource.close();
    _incomingController.close();
    _outgoingController.close();
  }

  void _onIncomingControlMessage(Event message) {
    var data = (message as MessageEvent).data;
    if (data == 'close') {
      close();
    } else {
      throw UnsupportedError('Illegal Control Message "$data"');
    }
  }

  void _onIncomingMessage(Event message) {
    var decoded =
        jsonDecode((message as MessageEvent).data as String) as String;
    _incomingController.add(decoded);
  }

  void _onOutgoingDone() {
    close();
  }

  final _messages = StreamController<String>();

  void _onOutgoingMessage(String message) async {
    _messages.add(message);
  }

  void _startPostingOrderedMessages() async {
    await for (var message in _messages.stream) {
      await _encodeAndSend(message);
    }
  }

  Future<void> _encodeAndSend(String message) async {
    try {
      await HttpRequest.request(_serverUrl,
          method: 'POST', sendData: jsonEncode(message), withCredentials: true);
    } on JsonUnsupportedObjectError catch (e) {
      _logger.warning('Unable to encode outgoing message: $e');
    } on ArgumentError catch (e) {
      _logger.warning('Invalid argument: $e');
    }
  }
}
