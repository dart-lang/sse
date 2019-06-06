// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_proxy/shelf_proxy.dart' as shelf_proxy;
import 'package:stream_channel/stream_channel.dart';

String _sseHeaders(String origin) => 'HTTP/1.1 200 OK\r\n'
    'Content-Type: text/event-stream\r\n'
    'Cache-Control: no-cache\r\n'
    'Connection: keep-alive\r\n'
    'Access-Control-Allow-Credentials: true\r\n'
    'Access-Control-Allow-Origin: $origin\r\n'
    '\r\n';

/// A bi-directional SSE connection between server and browser.
class SseConnection extends StreamChannelMixin<String> {
  /// Incoming messages from the Browser client.
  final _incomingController = StreamController<String>();

  /// Outgoing messages to the Browser client.
  final _outgoingController = StreamController<String>();

  final Sink _sink;

  final _closedCompleter = Completer<void>();

  SseConnection(this._sink) {
    _outgoingController.stream.listen((data) {
      if (!_closedCompleter.isCompleted) {
        // JSON encode the message to escape new lines.
        _sink.add('data: ${json.encode(data)}\n');
        _sink.add('\n');
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
  final _connections = <String, SseConnection>{};
  final _connectionController = StreamController<SseConnection>();

  StreamQueue<SseConnection> _connectionsStream;

  SseHandler(this._uri);

  StreamQueue<SseConnection> get connections =>
      _connectionsStream ??= StreamQueue(_connectionController.stream);

  shelf.Handler get handler => _handle;

  int get numberOfClients => _connections.length;

  shelf.Response _createSseConnection(shelf.Request req, String path) {
    req.hijack((channel) async {
      var sink = utf8.encoder.startChunkedConversion(channel.sink);
      sink.add(_sseHeaders(req.headers['origin']));
      var clientId = req.url.queryParameters['sseClientId'];
      var connection = SseConnection(sink);
      _connections[clientId] = connection;
      unawaited(connection._closedCompleter.future.then((_) {
        _connections.remove(clientId);
      }));
      // Remove connection when it is remotely closed or the stream is
      // cancelled.
      channel.stream.listen((_) {
        // SSE is unidirectional. Responses are handled through POST requests.
      }, onDone: () {
        connection._close();
      });

      _connectionController.add(connection);
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
      'access-control-allow-origin': req.headers['origin']
    });
  }
}

/// [SseProxyHandler] proxies two-way communications of JSON encodable data
/// between clients and an [SseHandler].
///
/// This handler provides the same communication interface as [SseHandler], but
/// simply forwards data back and forth between clients and the actual server.
class SseProxyHandler {
  final _httpClient = http.Client();
  shelf.Handler _incomingMessageProxyHandler;
  final _logger = Logger('SseProxyHandler');
  final String _proxyName;
  final Uri _proxyUri;
  final Uri _serverUri;

  /// Creates an SSE proxy handler that will handle EventSource requests to
  /// [proxyUri] by proxying them to [serverUri].
  SseProxyHandler(Uri proxyUri, Uri serverUri, {String proxyName})
      : _proxyUri = proxyUri,
        _serverUri = serverUri,
        _proxyName = proxyName;

  shelf.Handler get handler => _handle;

  Future<shelf.Response> _createSseConnection(
      shelf.Request req, String path) async {
    final serverReq = http.StreamedRequest(
        req.method, _serverUri.replace(query: req.requestedUri.query))
      ..followRedirects = false
      ..headers.addAll(req.headers)
      ..headers['Host'] = _serverUri.authority
      ..sink.close();

    final serverResponse = await _httpClient.send(serverReq);

    req.hijack((channel) {
      final sink = utf8.encoder.startChunkedConversion(channel.sink)
        ..add(_sseHeaders(req.headers['origin']));

      StreamSubscription serverSseSub;
      StreamSubscription reqChannelSub;

      serverSseSub =
          utf8.decoder.bind(serverResponse.stream).listen(sink.add, onDone: () {
        reqChannelSub?.cancel();
        sink.close();
      });

      reqChannelSub = channel.stream.listen((_) {
        // SSE is unidirectional.
      }, onDone: () {
        serverSseSub?.cancel();
        sink.close();
      });
    });
    return shelf.Response.notFound('');
  }

  Future<shelf.Response> _handle(shelf.Request req) async {
    final path = req.requestedUri.path;
    if (path != _proxyUri.path) {
      return shelf.Response.notFound('');
    }

    if (req.headers['accept'] == 'text/event-stream' && req.method == 'GET') {
      return _createSseConnection(req, path);
    }

    if (req.headers['accept'] != 'text/event-stream' && req.method == 'POST') {
      return _handleIncomingMessage(req);
    }

    return shelf.Response.notFound('');
  }

  Future<shelf.Response> _handleIncomingMessage(shelf.Request req) async {
    _incomingMessageProxyHandler ??= shelf_proxy.proxyHandler(
      _serverUri,
      client: _httpClient,
      proxyName: _proxyName,
    );
    return _incomingMessageProxyHandler(req);
  }
}
