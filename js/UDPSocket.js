
import { NativeModules } from 'react-native'
import Socket from './Socket'

/** Handles sending and receiving UDP datagrams. */
export default class UDPSocket extends Socket {

    /**
     * Creates and binds a UDP socket. Additional options:
     * - `broadcast` : _boolean_ If true, allows you to send packets to the broadcast address. 
     * - `reuse` : _boolean_ If true, allows you to bind to an already bound port.
     * 
     * @param {int} port The local port to bind to. Pass 0 to pick a random port.
     * @param {object} opts Additional options.
     */
    static async create(port = 0, opts = {}) {

        // Create native socket, get it's ID
        let info = await NativeModules.RNNetworkStack.udpBind(port, !!opts.broadcast, !!opts.reuse)

        // Create new instance
        let socket = new UDPSocket(info)

        // Done
        return socket

    }

    /**
     * Receives a packet of data from the socket. Blocks until a packet is received. Right now, only UTF8 encoding of data is supported.
     * 
     * @returns {Promise<object>} The read packet. Contains `data`, `senderAddress`, and `senderPort` fields.
     */
    async receive() {

        // Pass request to native lib
        return NativeModules.RNNetworkStack.udpRead(this.id)

    }

    /**
     * Send a packet of data to a remote device. Right now, only UTF8 encoding of data is supported.
     * 
     * @param {string} address The target address to send to
     * @param {int} port The target port to send to
     * @param {string} data The data to send.
     * @returns {Promise} 
     */
    async send(address, port, data) {

        // Pass request to native lib
        return NativeModules.RNNetworkStack.udpSend(this.id, address, port, data)

    }

    /**
     * Join the specified muticast group.
     * 
     * @param {string} address The multicast group address
     * @returns {Promise} 
     */
    async join(address) {

        // Pass request to native lib
        return NativeModules.RNNetworkStack.udpJoin(this.id, address)

    }

    /**
     * Leaves the specified muticast group.
     * 
     * @param {string} address The multicast group address
     * @returns {Promise} 
     */
    async leave(address) {

        // Pass request to native lib
        return NativeModules.RNNetworkStack.udpLeave(this.id, address)

    }

}