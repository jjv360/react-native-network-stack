
import { NativeModules, NativeEventEmitter } from 'react-native'

let eventEmitter = null

/** Base class for socket types */
export default class Socket {

    /** @private Constructor */
    constructor(info) {

        // Lame attempt at preventing people from using the constructor
        if (!info)
            throw new Error('Constructor is private, you must not call it.')

        /** @private The native socket ID */
        this.id = info.id

        /** The locally bound port */
        this.localPort = info.localPort

        /** The remote port, if not a server socket */
        this.remotePort = info.remotePort

        /** The locally bound address */
        this.localAddress = info.localAddress

        /** The remote address, if not a server socket */
        this.remoteAddress = info.remoteAddress

        /** If this is an incoming socket connection, this is a reference to the TCPSocket which received it. */
        this.serverSocket = null

    }

    /** Close the socket */
    close() {
        return NativeModules.RNNetworkStack.socketClose(this.id)
    }

    /** Get the native event emitter */
    static get emitter() {

        // Create if necessary. CAREFUL: When the library is linked locally with it's own node_modules/react-native copy, 
        // the emitter doesn't work at all.
        if (!eventEmitter)
            eventEmitter = new NativeEventEmitter(NativeModules.RNNetworkStack)

        // Return it
        return eventEmitter

    }

}