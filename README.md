
# react-native-network-stack

This is a promise-based socket networking library for React Native apps.

## Add to your project

``` bash
# Install as a dependency
npm install github:jjv360/react-native-network-stack

# Link native component into your app
react-native link react-native-network-stack
```

## Usage examples
```javascript
import { TCPSocket } from 'react-native-network-stack' 

// Connect to a socket and log all incoming data
let socket = await TCPSocket.connect('192.168.1.1', 8080)

// Read each line and log it
while (true) {

	// Read data
	let data = await socket.read({ until: '\n', format: 'utf8' })
	console.log(data)

}
```

```javascript
// Listen for incoming connections
let server = await TCPSocket.listen(8080)

// Send some text to each new client, then disconnect
while (true) {

	// Get new connection
	let client = await server.accept()

	// Send some data and disconnect
	await client.write('Hello!')
	await client.close()

}
```

## Feature Support

Feature                         | Android | iOS | Windows
--------------------------------|---------|-----|----------
**Documentation**               |         |     |   
**TCPSocket class**             | ✓       |     |   
Connect to remote socket        | ✓        |     | 
Accept incoming connections     | ✓       |     |   
Send strings                    | ✓        |     |  
Send binary data                |         |     |   
Send data from file             | ✓        |     |   
Receive strings                 | ✓        |     |   
Receive binary data             |         |     |   
Save to file                    | ✓        |     |
**UDPSocket class**             | ✓       |     |   
Send strings                    | ✓       |     |   
Send binary data                |         |     |   
Receive strings                 | ✓       |     |   
Receive binary data             |         |     |   
Bind to multicast address       | ✓       |     |   