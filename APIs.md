# React Native Network Stack - API Documentation

This lists all the available classes in this library.

## Class: `TCPSocket`

- `localPort` : _(int)_ If bound, this is the local port the socket is bound to. When creating a server socket with an automatic address (ie port 0), use this to get the port that was assigned.
- `remotePort` : _(int)_ If bound, the remote port being used.
- `serverSocket` : _(TCPSocket)_ If this socket was the result of `accept()`ing an incoming connection from a server socket, this contains a reference to the server socket.
- `close()` : Closes the socket connection.
- `static `