[![Dart CI](https://github.com/dart-lang/sse/actions/workflows/test-package.yml/badge.svg)](https://github.com/dart-lang/sse/actions/workflows/test-package.yml)
[![pub package](https://img.shields.io/pub/v/sse.svg)](https://pub.dev/packages/sse)
[![package publisher](https://img.shields.io/pub/publisher/sse.svg)](https://pub.dev/packages/sse/publisher)

This package provides support for bi-directional communication through Server
Sent Events and corresponding POST requests.

This package is not intended to be a general purpose SSE package, but instead is
a bidirectional protocol for use when Websockets are unavailable. That is, both
the client and the server expose a `sink` and `stream` on which to send and
receive messages respectively.

Both the server and client have implicit assumptions on each other and therefore
a client from this package must be paired with a server from this package.

## Usage
# Create a Server Send Event (SSE)
To create a server send event you code should looks like this 
```dart
// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:shelf/shelf_io.dart' as io;
import 'package:sse/server/sse_handler.dart';

/// A basic server which sets up an SSE handler.
///
/// When a client connnects it will send a simple message and print the
/// response.
void main() async {
  var handler = SseHandler(Uri.parse('/sseHandler'));
  await io.serve(handler.handler, 'localhost', 0);
  var connections = handler.connections;
  while (await connections.hasNext) {
    var connection = await connections.next;
    connection.sink.add('foo');
    connection.stream.listen(print);
  }
}
```
To consume your server send event,first of all  you should connect to your SSE like this
```dart
var channel = SseClient('/sseHandler');
```
and listen to the different event like this 
```dart
 channel.stream.listen((s) {
    // Listen for messages and send them back.
    channel.sink.add(s);
  });
```
