// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';
import 'package:sse/server/sse_handler.dart';
import 'package:sse/src/server/sse_handler.dart' show closeSink;
import 'package:test/test.dart';
import 'package:webdriver/io.dart';

void main() {
  HttpServer server;
  WebDriver webdriver;
  SseHandler handler;
  Process chromeDriver;

  setUpAll(() async {
    try {
      chromeDriver = await Process.start(
          'chromedriver', ['--port=4444', '--url-base=wd/hub']);
    } catch (e) {
      throw StateError(
          'Could not start ChromeDriver. Is it installed?\nError: $e');
    }
  });

  tearDownAll(() {
    chromeDriver.kill();
  });

  group('SSE', () {
    setUp(() async {
      handler = SseHandler(Uri.parse('/test'));

      var cascade = shelf.Cascade()
          .add(handler.handler)
          .add(_faviconHandler)
          .add(createStaticHandler('test/web',
              listDirectories: true, defaultDocument: 'index.html'));

      server = await io.serve(cascade.handler, 'localhost', 0);
      var capabilities = Capabilities.chrome
        ..addAll({
          Capabilities.chromeOptions: {
            'args': ['--headless']
          }
        });
      webdriver = await createDriver(desired: capabilities);
    });

    tearDown(() async {
      await webdriver.quit();
      await server.close();
    });

    test('Can round trip messages', () async {
      await webdriver.get('http://localhost:${server.port}');
      var connection = await handler.connections.next;
      connection.sink.add('blah');
      expect(await connection.stream.first, 'blah');
    });

    test('Multiple clients can connect', () async {
      var connections = handler.connections;
      await webdriver.get('http://localhost:${server.port}');
      await connections.next;
      await webdriver.get('http://localhost:${server.port}');
      await connections.next;
    });

    test('Routes data correctly', () async {
      var connections = handler.connections;
      await webdriver.get('http://localhost:${server.port}');
      var connectionA = await connections.next;
      connectionA.sink.add('foo');
      expect(await connectionA.stream.first, 'foo');

      await webdriver.get('http://localhost:${server.port}');
      var connectionB = await connections.next;
      connectionB.sink.add('bar');
      expect(await connectionB.stream.first, 'bar');
    });

    test('Can close from the server', () async {
      expect(handler.numberOfClients, 0);
      await webdriver.get('http://localhost:${server.port}');
      var connection = await handler.connections.next;
      expect(handler.numberOfClients, 1);
      await connection.sink.close();
      await pumpEventQueue();
      expect(handler.numberOfClients, 0);
    });

    test('Client reconnects after being disconnected', () async {
      expect(handler.numberOfClients, 0);
      await webdriver.get('http://localhost:${server.port}');
      var connection = await handler.connections.next;
      expect(handler.numberOfClients, 1);
      await connection.sink.close();
      await pumpEventQueue();
      expect(handler.numberOfClients, 0);

      // Ensure the client reconnects
      await handler.connections.next;
    });

    test('Can close from the client-side', () async {
      expect(handler.numberOfClients, 0);
      await webdriver.get('http://localhost:${server.port}');
      var connection = await handler.connections.next;
      expect(handler.numberOfClients, 1);

      var closeButton = await webdriver.findElement(const By.tagName('button'));
      await closeButton.click();

      // Should complete since the connection is closed.
      await connection.stream.toList();
      expect(handler.numberOfClients, 0);
    });

    test('Cancelling the listener closes the connection', () async {
      expect(handler.numberOfClients, 0);
      await webdriver.get('http://localhost:${server.port}');
      var connection = await handler.connections.next;
      expect(handler.numberOfClients, 1);

      var sub = connection.stream.listen((_) {});
      await sub.cancel();
      await pumpEventQueue();
      expect(handler.numberOfClients, 0);
    });

    test('Disconnects when navigating away', () async {
      await webdriver.get('http://localhost:${server.port}');
      expect(handler.numberOfClients, 1);

      await webdriver.get('chrome://version/');
      expect(handler.numberOfClients, 0);
    });
  });

  group('SSE with server keep-alive', () {
    setUp(() async {
      handler =
          SseHandler(Uri.parse('/test'), keepAlive: const Duration(seconds: 5));

      var cascade = shelf.Cascade()
          .add(handler.handler)
          .add(_faviconHandler)
          .add(createStaticHandler('test/web',
              listDirectories: true, defaultDocument: 'index.html'));

      server = await io.serve(cascade.handler, 'localhost', 0);
      var capabilities = Capabilities.chrome
        ..addAll({
          Capabilities.chromeOptions: {
            'args': ['--headless']
          }
        });
      webdriver = await createDriver(desired: capabilities);
    });

    tearDown(() async {
      await webdriver.quit();
      await server.close();
    });

    test('Client reconnect use the same connection', () async {
      expect(handler.numberOfClients, 0);
      await webdriver.get('http://localhost:${server.port}');
      var connection = await handler.connections.next;
      expect(handler.numberOfClients, 1);

      // Close the underlying connection.
      closeSink(connection);

      // The isInKeepAlivePeriod flag may only be set for a short period because
      // the client may connect very quickly, so only pump until it changes.
      var maxPumps = 50;
      while (!connection.isInKeepAlivePeriod && maxPumps-- > 0) {
        await pumpEventQueue(times: 1);
      }

      // Ensure there's still a connection and it's marked as in the keep-alive
      // state.
      expect(connection.isInKeepAlivePeriod, isTrue);
      expect(handler.numberOfClients, 1);

      // Ensure we can still round-trip data on the original connection and that
      // the connection is no longer marked keep-alive once it's reconnected.
      connection.sink.add('bar');
      var queue = StreamQueue(connection.stream);
      expect(await queue.next, 'bar');
      expect(connection.isInKeepAlivePeriod, isFalse);

      // Now check that we can reconnect multiple times.
      closeSink(connection);
      maxPumps = 50;
      while (!connection.isInKeepAlivePeriod && maxPumps-- > 0) {
        await pumpEventQueue(times: 1);
      }
      expect(connection.isInKeepAlivePeriod, isTrue);
      expect(handler.numberOfClients, 1);
      connection.sink.add('bar');
      expect(await queue.next, 'bar');
      expect(connection.isInKeepAlivePeriod, isFalse);
    });

    test('Messages sent during disconnect arrive in-order', () async {
      expect(handler.numberOfClients, 0);
      await webdriver.get('http://localhost:${server.port}');
      var connection = await handler.connections.next;
      expect(handler.numberOfClients, 1);

      // Close the underlying connection.
      closeSink(connection);
      connection.sink.add('one');
      connection.sink.add('two');
      await pumpEventQueue();

      // Ensure there's still a connection.
      expect(handler.numberOfClients, 1);

      // Ensure messages arrive in the same order
      expect(await connection.stream.take(2).toList(), equals(['one', 'two']));
    });
  }, timeout: const Timeout(Duration(seconds: 120)));
}

FutureOr<shelf.Response> _faviconHandler(shelf.Request request) {
  if (request.url.path.endsWith('favicon.ico')) {
    return shelf.Response.ok('');
  }
  return shelf.Response.notFound('');
}
