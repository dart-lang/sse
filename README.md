This package provides support for bi-directional communication through
Server Sent Events and corresponding POST requests.

This package is not intended to be a general purpose SSE package, but instead
is intended to be a drop in replacement for Dart's Websocket implementation.
That is, both the client and the server expose a `sink` and `stream` on which to send
and receive messages respectively.

Both the server and client have implicit assumptions on each other and therefore a
client from this package must be paired with a server from this package.
