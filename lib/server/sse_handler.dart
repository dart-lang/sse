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

  /// Whether the connection is in the timeout period waiting for a reconnect.
  bool _isTimingOut = false;

  /// The subscription that passes messages outgoing messages to the sink. This
  /// will be paused during the timeout/reconnect period.
  StreamSubscription _outgoingStreamSubscription;

  final _closedCompleter = Completer<void>();

  SseConnection(this._sink, {Duration keepAlive}) : _keepAlive = keepAlive {
    _outgoingStreamSubscription = _outgoingController.stream.listen((data) {
      if (!_closedCompleter.isCompleted) {
        try {
          // JSON encode the message to escape new lines.
          _sink.add('data: ${json.encode(data)}\n');
          _sink.add('\n');
        } catch (e) {
          print('Error while trying to write "${json.encode(data)}": $e');
        }
      }
    });
    _outgoingController.onCancel = _close;
    _incomingController.onCancel = _close;
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
    _isTimingOut = false;
    _sink = sink;
    _outgoingStreamSubscription.resume();
  }

  void _handleDisconnect() {
    print('handling disconnect!');
    if (_keepAlive == null) {
      _close();
    } else {
      _outgoingStreamSubscription.pause();
      _isTimingOut = true;
      // If after the timeout period we're still in this state, we'll close.
      Timer(_keepAlive, () {
        if (_isTimingOut) {
          _isTimingOut = false;
          _close();
        }
      });
    }
  }

  // TODO(dantup): @visibleForTesting?
  void closeSink() => _sink.close();

  void _close() {
    if (!_closedCompleter.isCompleted) {
      _closedCompleter.complete();
      _outgoingStreamSubscription.cancel();
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
          _connections[clientId]._isTimingOut) {
        _connections[clientId]._acceptReconnection(sink);
      } else {
        var connection = SseConnection(sink, keepAlive: _keepAlive);
        _connections[clientId] = connection;
        unawaited(connection._closedCompleter.future.then((_) {
          _connections.remove(clientId);
        }));
        // Remove connection when it is remotely closed or the stream is
        // cancelled.
        channel.stream.listen((_) {
          // SSE is unidirectional. Responses are handled through POST requests.
        }, onDone: () {
          print('stream is done!');
          connection._handleDisconnect();
        });

        _connectionController.add(connection);
      }
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
