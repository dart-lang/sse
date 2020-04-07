// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:stream_channel/stream_channel.dart';

// RFC 2616 requires carriage return delimiters.
String _sseHeaders(String origin) => 'HTTP/1.1 200 OK\r\n'
    'Content-Type: text/event-stream\r\n'
    'Cache-Control: no-cache\r\n'
    'Connection: keep-alive\r\n'
    'Access-Control-Allow-Credentials: true\r\n'
    'Access-Control-Allow-Origin: $origin\r\n'
    '\r\n\r\n';

/// A bi-directional SSE connection between server and browser.
class SseConnection extends StreamChannelMixin<String> {
  /// Incoming messages from the Browser client.
  final _incomingController = StreamController<String>();

  /// Outgoing messages to the Browser client.
  final _outgoingController = StreamController<String>();

  Sink _sink;

  /// How long to wait after a connection drops before considering it closed.
  final Duration _keepAlive;

  /// A timer counting down the KeepAlive period (null if hasn't disconnected).
  Timer _keepAliveTimer;

  /// Whether this connection is currently in the KeepAlive timeout period.
  bool get isInKeepAlivePeriod => _keepAliveTimer?.isActive ?? false;

  final _closedCompleter = Completer<void>();

  /// Creates an [SseConnection] for the supplied [_sink].
  ///
  /// If [keepAlive] is supplied, the connection will remain active for this
  /// period after a disconnect and can be reconnected transparently. If there
  /// is no reconnect within that period, the connection will be closed normally.
  ///
  /// If [keepAlive] is not supplied, the connection will be closed immediately
  /// after a disconnect.
  SseConnection(this._sink, {Duration keepAlive}) : _keepAlive = keepAlive {
    unawaited(_setUpListener());
    _outgoingController.onCancel = _close;
    _incomingController.onCancel = _close;
  }

  Future<void> _setUpListener() async {
    var outgoingStreamQueue = StreamQueue(_outgoingController.stream);
    while (await outgoingStreamQueue.hasNext) {
      // If we're in a KeepAlive timeout, there's nowhere to send messages so
      // wait a short period and check again.
      if (isInKeepAlivePeriod) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }

      // Peek the data so we don't remove it from the stream if we're unable to
      // send it.
      final data = await outgoingStreamQueue.peek;

      // Ignore outgoing messages since the connection may have closed while
      // waiting for the keep alive.
      if (_closedCompleter.isCompleted) break;

      try {
        // JSON encode the message to escape new lines.
        _sink.add('data: ${json.encode(data)}\n');
        _sink.add('\n');
        await outgoingStreamQueue.next; // Consume from stream if no errors.
      } catch (StateError) {
        if (_keepAlive == null || _closedCompleter.isCompleted) {
          rethrow;
        }
        // If we got here then the sink may have closed but the stream.onDone
        // hasn't fired yet, so pause the subscription and skip calling
        // `next` so the message remains in the queue to try again.
        _handleDisconnect();
      }
    }
  }

  /// The message added to the sink has to be JSON encodable.
  @override
  StreamSink<String> get sink => _outgoingController.sink;

  // Add messages to this [StreamSink] to send them to the server.
  /// [Stream] of messages sent from the server to this client.
  ///
  /// A message is a decoded JSON object.
  @override
  Stream<String> get stream => _incomingController.stream;

  void _acceptReconnection(Sink sink) {
    _keepAliveTimer?.cancel();
    _sink = sink;
  }

  void _handleDisconnect() {
    if (_keepAlive == null) {
      // Close immediately if we're not keeping alive.
      _close();
    } else if (!isInKeepAlivePeriod) {
      // Otherwise if we didn't already have an active timer, set a timer to
      // close after the timeout period. If the connection comes back, this will
      // be cancelled and all messages left in the queue tried again.
      _keepAliveTimer = Timer(_keepAlive, _close);
    }
  }

  void _close() {
    if (!_closedCompleter.isCompleted) {
      _closedCompleter.complete();
      _sink.close();
      if (!_outgoingController.isClosed) _outgoingController.close();
      if (!_incomingController.isClosed) _incomingController.close();
    }
  }
}

/// [SseHandler] handles requests on a user defined path to create
/// two-way communications of JSON encodable data between server and clients.
///
/// A server sends messages to a client through an SSE channel, while
/// a client sends message to a server through HTTP POST requests.
class SseHandler {
  final _logger = Logger('SseHandler');
  final Uri _uri;
  final Duration _keepAlive;
  final _connections = <String, SseConnection>{};
  final _connectionController = StreamController<SseConnection>();

  StreamQueue<SseConnection> _connectionsStream;

  SseHandler(this._uri, {Duration keepAlive}) : _keepAlive = keepAlive;

  StreamQueue<SseConnection> get connections =>
      _connectionsStream ??= StreamQueue(_connectionController.stream);

  shelf.Handler get handler => _handle;

  int get numberOfClients => _connections.length;

  shelf.Response _createSseConnection(shelf.Request req, String path) {
    req.hijack((channel) async {
      var sink = utf8.encoder.startChunkedConversion(channel.sink);
      sink.add(_sseHeaders(req.headers['origin']));
      var clientId = req.url.queryParameters['sseClientId'];

      // Check if we already have a connection for this ID that is in the process
      // of timing out (in which case we can reconnect it transparently).
      if (_connections[clientId] != null &&
          _connections[clientId].isInKeepAlivePeriod) {
        _connections[clientId]._acceptReconnection(sink);
      } else {
        var connection = SseConnection(sink, keepAlive: _keepAlive);
        _connections[clientId] = connection;
        unawaited(connection._closedCompleter.future.then((_) {
          _connections.remove(clientId);
        }));
        _connectionController.add(connection);
      }
      // Remove connection when it is remotely closed or the stream is
      // cancelled.
      channel.stream.listen((_) {
        // SSE is unidirectional. Responses are handled through POST requests.
      }, onDone: () {
        _connections[clientId]?._handleDisconnect();
      });
    });
    return shelf.Response.notFound('');
  }

  String _getOriginalPath(shelf.Request req) => req.requestedUri.path;

  Future<shelf.Response> _handle(shelf.Request req) async {
    var path = _getOriginalPath(req);
    if (_uri.path != path) {
      return shelf.Response.notFound('');
    }

    if (req.headers['accept'] == 'text/event-stream' && req.method == 'GET') {
      return _createSseConnection(req, path);
    }

    if (req.headers['accept'] != 'text/event-stream' && req.method == 'POST') {
      return _handleIncomingMessage(req, path);
    }

    return shelf.Response.notFound('');
  }

  Future<shelf.Response> _handleIncomingMessage(
      shelf.Request req, String path) async {
    try {
      var clientId = req.url.queryParameters['sseClientId'];
      var message = await req.readAsString();
      var jsonObject = json.decode(message) as String;
      _connections[clientId]?._incomingController?.add(jsonObject);
    } catch (e, st) {
      _logger.fine('Failed to handle incoming message. $e $st');
    }
    return shelf.Response.ok('', headers: {
      'access-control-allow-credentials': 'true',
      'access-control-allow-origin': _originFor(req),
    });
  }

  String _originFor(shelf.Request req) =>
      // Firefox does not set header "origin".
      // https://bugzilla.mozilla.org/show_bug.cgi?id=1508661
      req.headers['origin'] ?? req.headers['host'];
}

void closeSink(SseConnection connection) => connection._sink.close();
