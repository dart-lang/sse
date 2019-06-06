// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
@Timeout(Duration(seconds: 5))
import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';
import 'package:sse/server/sse_handler.dart';
import 'package:test/test.dart';
import 'package:webdriver/io.dart';

void main() {
  Process chromeDriver;
  HttpServer proxy;
  HttpServer server;
  SseHandler serverSse;
  WebDriver webdriver;

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

  setUp(() async {
    const ssePath = '/test';

    final staticWebHandler = createStaticHandler('test/web',
        listDirectories: true, defaultDocument: 'index.html');

    serverSse = SseHandler(Uri.parse(ssePath));
    final serverCascade = shelf.Cascade().add(serverSse.handler);
    server = await io.serve(serverCascade.handler, 'localhost', 0);

    final proxySse = SseProxyHandler(Uri.parse(ssePath),
        Uri.parse('http://localhost:${server.port}$ssePath'));
    final proxyCascade = shelf.Cascade()
        .add(proxySse.handler)
        .add(_faviconHandler)
        .add(staticWebHandler);
    proxy = await io.serve(proxyCascade.handler, 'localhost', 0);

    webdriver = await createDriver(desired: {
      'chromeOptions': {
        'args': ['--headless']
      }
    });
  });

  tearDown(() async {
    await webdriver.quit();
    await proxy.close();
    await server.close();
  });

  test('Can round trip messages', () async {
    await webdriver.get('http://localhost:${proxy.port}');
    var connection = await serverSse.connections.next;
    connection.sink.add('blah');
    expect(await connection.stream.first, 'blah');
  });

  test('Multiple clients can connect', () async {
    var connections = serverSse.connections;
    await webdriver.get('http://localhost:${proxy.port}');
    await connections.next;
    await webdriver.get('http://localhost:${proxy.port}');
    await connections.next;
  });

  test('Routes data correctly', () async {
    var connections = serverSse.connections;
    await webdriver.get('http://localhost:${proxy.port}');
    var connectionA = await connections.next;
    connectionA.sink.add('foo');
    expect(await connectionA.stream.first, 'foo');

    await webdriver.get('http://localhost:${proxy.port}');
    var connectionB = await connections.next;
    connectionB.sink.add('bar');
    expect(await connectionB.stream.first, 'bar');
  });

  test('Can close from the server', () async {
    expect(serverSse.numberOfClients, 0);
    await webdriver.get('http://localhost:${proxy.port}');
    var connection = await serverSse.connections.next;
    expect(serverSse.numberOfClients, 1);
    await connection.sink.close();
    await pumpEventQueue();
    expect(serverSse.numberOfClients, 0);
  });

  test('Can close from the client-side', () async {
    expect(serverSse.numberOfClients, 0);
    await webdriver.get('http://localhost:${proxy.port}');
    var connection = await serverSse.connections.next;
    expect(serverSse.numberOfClients, 1);

    var closeButton = await webdriver.findElement(const By.tagName('button'));
    await closeButton.click();

    // Should complete since the connection is closed.
    await connection.stream.toList();
    expect(serverSse.numberOfClients, 0);
  });

  test('Cancelling the listener closes the connection', () async {
    expect(serverSse.numberOfClients, 0);
    await webdriver.get('http://localhost:${proxy.port}');
    var connection = await serverSse.connections.next;
    expect(serverSse.numberOfClients, 1);

    var sub = connection.stream.listen((_) {});
    await sub.cancel();
    await pumpEventQueue();
    expect(serverSse.numberOfClients, 0);
  });

  test('Disconnects when navigating away', () async {
    await webdriver.get('http://localhost:${proxy.port}');
    await serverSse.connections.next;
    expect(serverSse.numberOfClients, 1);

    await webdriver.get('chrome://version/');
    expect(serverSse.numberOfClients, 0);
  });
}

FutureOr<shelf.Response> _faviconHandler(shelf.Request request) {
  if (request.url.path.endsWith('favicon.ico')) {
    return shelf.Response.ok('');
  }
  return shelf.Response.notFound('');
}
